typedef struct {
    atomic_bool stopping;
    atomic_uint refs;
} mcp_environment_t;

static void stop_mcp_environment(void *data) {
    mcp_environment_t *owner = data;
    atomic_store(&owner->stopping, true);
}

static void release_mcp_environment(napi_env env, void *data, void *hint) {
    mcp_environment_t *owner = data;
    if (atomic_fetch_sub(&owner->refs, 1) == 1) free(owner);
}

typedef struct {
    atomic_uint refs;
    mcp_environment_t *owner;
    mutex_t lock;
    napi_threadsafe_function dispatch;
} mcp_connector_t;

typedef struct {
    atomic_uint refs;
    mutex_t lock;
    cond_t wake;
    const char *op;
    uintptr_t connection;
    uint32_t purpose, era, timeout;
    owned_t frame, body;
    uint32_t status, http_status;
    bool answered, end;
} mcp_call_t;

static void release_mcp_call(mcp_call_t *call) {
    if (atomic_fetch_sub(&call->refs, 1) != 1) return;
    free(call->frame.ptr);
    free(call->body.ptr);
    mutex_destroy(&call->lock);
    cond_destroy(&call->wake);
    free(call);
}

static void ticket_finalize(napi_env env, void *data, void *hint) { release_mcp_call(data); }

static void finish_mcp_call(mcp_call_t *call, uint32_t status, uint32_t http_status, owned_t body, bool end) {
    mutex_lock(&call->lock);
    if (!call->answered) {
        call->status = status;
        call->http_status = http_status;
        call->body = body;
        call->end = end;
        call->answered = true;
        cond_wake(&call->wake);
    } else {
        free(body.ptr);
    }
    mutex_unlock(&call->lock);
}

static napi_value mcp_reply(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value argv[5];
    mcp_call_t *call;
    uint32_t status, http_status;
    bool end;
    if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc != 5 ||
        napi_get_value_external(env, argv[0], (void **)&call) != napi_ok ||
        napi_get_value_uint32(env, argv[1], &status) != napi_ok ||
        napi_get_value_uint32(env, argv[2], &http_status) != napi_ok ||
        napi_get_value_bool(env, argv[4], &end) != napi_ok) return NULL;
    owned_t body = {0};
    void *ptr;
    size_t len;
    bool buffer = false;
    if (!status && napi_is_buffer(env, argv[3], &buffer) == napi_ok && buffer &&
        napi_get_buffer_info(env, argv[3], &ptr, &len) == napi_ok && len) {
        if (len > METASK_AGENTCORE_MAX_MCP_FRAME_BYTES_V1 || !(body = copy_bytes(ptr, len)).ptr)
            status = METASK_AGENTCORE_MCP_EXCHANGE_FATAL;
    }
    finish_mcp_call(call, status, http_status, body, end);
    return NULL;
}

static void mcp_call_js(napi_env env, napi_value dispatch, void *ctx, void *data) {
    mcp_call_t *call = data;
    napi_value args[7], receiver, result;
    if (!env || napi_create_external(env, call, ticket_finalize, NULL, &args[6]) != napi_ok) {
        finish_mcp_call(call, METASK_AGENTCORE_MCP_EXCHANGE_FATAL, 0, (owned_t){0}, true);
        release_mcp_call(call);
        return;
    }
    mutex_lock(&call->lock);
    bool expired = call->answered;
    mutex_unlock(&call->lock);
    if (expired) return;
    napi_get_undefined(env, &receiver);
    napi_create_string_utf8(env, call->op, NAPI_AUTO_LENGTH, &args[0]);
    args[1] = node_unsigned(env, call->connection);
    args[2] = make_string(env, &call->frame);
    free(call->frame.ptr);
    call->frame = (owned_t){0};
    napi_create_uint32(env, call->purpose, &args[3]);
    napi_create_uint32(env, call->era, &args[4]);
    napi_create_uint32(env, call->timeout, &args[5]);
    if (napi_call_function(env, receiver, dispatch, 7, args, &result) != napi_ok)
        finish_mcp_call(call, METASK_AGENTCORE_MCP_EXCHANGE_FATAL, 0, (owned_t){0}, true);
}

static mcp_call_t *post_mcp(mcp_connector_t *connector, const char *op, void *connection,
                            metask_agentcore_bytes_view_v1 frame, uint32_t purpose, uint32_t era, uint32_t timeout) {
    mcp_call_t *call = calloc(1, sizeof(*call));
    if (!call) return NULL;
    call->frame = copy_bytes(frame.ptr, frame.len);
    if (frame.len && !call->frame.ptr) { free(call); return NULL; }
    atomic_init(&call->refs, 2);
    mutex_init(&call->lock);
    cond_init(&call->wake);
    call->op = op;
    call->connection = (uintptr_t)connection;
    call->purpose = purpose;
    call->era = era;
    call->timeout = timeout;
    mutex_lock(&connector->lock);
    napi_status queued = napi_closing;
    if (!atomic_load(&connector->owner->stopping) && connector->dispatch) {
        queued = napi_call_threadsafe_function(connector->dispatch, call, napi_tsfn_nonblocking);
        if (queued == napi_closing) connector->dispatch = NULL;
    }
    mutex_unlock(&connector->lock);
    if (queued != napi_ok) {
        release_mcp_call(call);
        release_mcp_call(call);
        return NULL;
    }
    return call;
}

static uint32_t await_mcp(mcp_connector_t *connector, mcp_call_t *call, uint64_t deadline,
                          const metask_agentcore_mcp_cancellation_v1 *cancel) {
    if (!call) return METASK_AGENTCORE_MCP_EXCHANGE_FATAL;
    mutex_lock(&call->lock);
    while (!call->answered) {
        uint64_t now = monotonic_ms();
        if (now >= deadline || atomic_load(&connector->owner->stopping) || (cancel && cancel->is_cancelled(cancel->ctx))) {
            call->answered = true;
            call->status = now >= deadline ? METASK_AGENTCORE_MCP_EXCHANGE_TIMEOUT : METASK_AGENTCORE_MCP_EXCHANGE_CANCELLED;
            break;
        }
        cond_wait_ms(&call->wake, &call->lock, deadline - now < 25 ? (unsigned)(deadline - now) : 25);
    }
    uint32_t status = call->status;
    mutex_unlock(&call->lock);
    return status;
}

static void mcp_close(void *ctx, void *connection) {
    mcp_call_t *call = post_mcp(ctx, "close", connection, (metask_agentcore_bytes_view_v1){0}, 0, 0, 0);
    if (call) release_mcp_call(call);
}

static uint32_t mcp_open(void *ctx, uint32_t purpose, uint32_t era, uint32_t timeout, void **out) {
    static atomic_uintptr_t next_connection = 1;
    void *id = (void *)atomic_fetch_add(&next_connection, 1);
    mcp_call_t *call = post_mcp(ctx, "open", id, (metask_agentcore_bytes_view_v1){0}, purpose, era, timeout);
    uint32_t status = await_mcp(ctx, call, monotonic_ms() + timeout, NULL);
    if (!status) *out = id;
    else mcp_close(ctx, id);
    if (call) release_mcp_call(call);
    return status <= METASK_AGENTCORE_MCP_OPEN_FATAL ? status : METASK_AGENTCORE_MCP_OPEN_FATAL;
}

static uint32_t mcp_request(void *ctx, void *id, metask_agentcore_bytes_view_v1 frame, uint32_t timeout,
                            const metask_agentcore_mcp_cancellation_v1 *cancel, metask_agentcore_mcp_response_v1 *out) {
    mcp_call_t *call = post_mcp(ctx, "request", id, frame, 0, 0, timeout);
    uint32_t status = await_mcp(ctx, call, monotonic_ms() + timeout, cancel);
    if (!status) {
        out->http_status = call->http_status;
        out->body = (metask_agentcore_owned_bytes_v1){call->body.ptr, call->body.len};
        call->body = (owned_t){0};
    } else mcp_close(ctx, id);
    if (call) release_mcp_call(call);
    return status;
}

static uint32_t mcp_notify(void *ctx, void *id, metask_agentcore_bytes_view_v1 frame, uint32_t timeout,
                           const metask_agentcore_mcp_cancellation_v1 *cancel) {
    mcp_call_t *call = post_mcp(ctx, "notify", id, frame, 0, 0, timeout);
    uint32_t status = await_mcp(ctx, call, monotonic_ms() + timeout, cancel);
    if (status) mcp_close(ctx, id);
    if (call) release_mcp_call(call);
    return status ? METASK_AGENTCORE_MCP_NOTIFY_FAILED : METASK_AGENTCORE_MCP_NOTIFY_OK;
}

static uint32_t mcp_stream(void *ctx, void *id, metask_agentcore_bytes_view_v1 frame, uint32_t timeout,
                           const metask_agentcore_mcp_cancellation_v1 *cancel, const metask_agentcore_host_result_sink_v1 *sink) {
    const uint64_t deadline = monotonic_ms() + timeout;
    const char *op = "stream";
    for (;;) {
        bool expired = monotonic_ms() >= deadline;
        if (expired || (cancel && cancel->is_cancelled(cancel->ctx))) {
            mcp_close(ctx, id);
            return expired ? METASK_AGENTCORE_MCP_EXCHANGE_TIMEOUT : METASK_AGENTCORE_MCP_EXCHANGE_CANCELLED;
        }
        mcp_call_t *call = post_mcp(ctx, op, id, frame, 0, 0, timeout);
        uint32_t status = await_mcp(ctx, call, deadline, cancel);
        if (!call) return status;
        if (!status && call->body.len && sink->write(sink->ctx, view_of(&call->body)))
            status = METASK_AGENTCORE_MCP_EXCHANGE_FATAL;
        bool end = call->end;
        free(call->body.ptr);
        call->body = (owned_t){0};
        release_mcp_call(call);
        if (status) mcp_close(ctx, id);
        if (status || end) return status;
        frame = (metask_agentcore_bytes_view_v1){0};
        op = "next";
    }
}

static void mcp_free_body(void *ctx, void *id, metask_agentcore_owned_bytes_v1 *body) { free(body->ptr); }
static void mcp_retain(void *ctx) {
    mcp_connector_t *connector = ctx;
    atomic_fetch_add(&connector->refs, 1);
}
static void free_connector(mcp_connector_t *connector) {
    release_mcp_environment(NULL, connector->owner, NULL);
    mutex_destroy(&connector->lock);
    free(connector);
}

static void finalize_connector(napi_env env, void *data, void *hint) {
    mcp_connector_t *connector = data;
    mutex_lock(&connector->lock);
    connector->dispatch = NULL;
    bool last = atomic_fetch_sub(&connector->refs, 1) == 1;
    mutex_unlock(&connector->lock);
    if (last) free_connector(connector);
}

static void mcp_release(void *ctx) {
    mcp_connector_t *connector = ctx;
    mutex_lock(&connector->lock);
    unsigned previous = atomic_fetch_sub(&connector->refs, 1);
    if (previous == 2 && connector->dispatch)
        napi_release_threadsafe_function(connector->dispatch, napi_tsfn_release);
    mutex_unlock(&connector->lock);
    if (previous == 1) free_connector(connector);
}

static int read_connector(napi_env env, napi_value item, metask_agentcore_mcp_connector_v1 *out) {
    napi_value name, callback = node_field(env, item, "dispatch");
    mcp_connector_t *connector = calloc(1, sizeof(*connector));
    if (!connector) return 0;
    if (!callback || napi_get_instance_data(env, (void **)&connector->owner) != napi_ok ||
        napi_create_string_utf8(env, "metacodes.mcp", NAPI_AUTO_LENGTH, &name) != napi_ok ||
        napi_create_threadsafe_function(env, callback, NULL, name, 0, 1, connector, finalize_connector, NULL, mcp_call_js, &connector->dispatch) != napi_ok) {
        free(connector);
        return 0;
    }
    atomic_fetch_add(&connector->owner->refs, 1);
    atomic_init(&connector->refs, 2);
    mutex_init(&connector->lock);
    napi_unref_threadsafe_function(env, connector->dispatch);
    *out = (metask_agentcore_mcp_connector_v1){.struct_size = sizeof(*out), .ctx = connector,
        .open = mcp_open, .request = mcp_request, .request_tool_stream = mcp_stream, .notify = mcp_notify,
        .close = mcp_close, .release_response = mcp_free_body, .retain_connector = mcp_retain, .release_connector = mcp_release};
    return 1;
}
