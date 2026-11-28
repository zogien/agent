/* Node-API bridge to the AgentCore C ABI (sdk/metask/agentcore.h).
 *
 * The addon loads libmetask_agentcore at run time (dlopen), validates the
 * exact ABI revision with the header's own compatibility check, and exposes
 * a small set of functions that index.js wraps into the public API.
 *
 * Threading: a Run executes on a dedicated thread (never the libuv pool, which
 * a long agent Run would starve). AgentCore callbacks arrive on AgentCore
 * threads and are forwarded to JavaScript through one thread-safe function per
 * Session (events, UI requests, Run completion: one queue, so every event of a
 * Run reaches JavaScript before its completion) and one per Runtime (host tool
 * calls). Tool calls and UI requests block their AgentCore thread until
 * JavaScript answers through completeCall(); the JavaScript thread itself never
 * blocks on a Run. */

#define _GNU_SOURCE
#define NAPI_VERSION 8
#include <node_api.h>

#include <metask/agentcore.h>

#include "platform.h"
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const metask_agentcore_api_v1 *g_api = NULL;

napi_value node_field(napi_env env, napi_value object, const char *name) {
    napi_value out;
    return napi_get_named_property(env, object, name, &out) == napi_ok ? out : NULL;
}
napi_value node_element(napi_env env, napi_value array, uint32_t index) {
    napi_value out;
    return napi_get_element(env, array, index, &out) == napi_ok ? out : NULL;
}
bool node_set_field(napi_env env, napi_value object, const char *name, napi_value value) {
    return napi_set_named_property(env, object, name, value) == napi_ok;
}
bool node_set_element(napi_env env, napi_value array, uint32_t index, napi_value value) {
    return napi_set_element(env, array, index, value) == napi_ok;
}
napi_value node_unsigned(napi_env env, uint64_t x) {
    napi_value out;
    return napi_create_bigint_uint64(env, x, &out) == napi_ok ? out : NULL;
}
napi_value node_signed(napi_env env, int64_t x) {
    napi_value out;
    return napi_create_bigint_int64(env, x, &out) == napi_ok ? out : NULL;
}
extern const char *node_project(napi_env env, uint32_t kind, const uint8_t *ptr, size_t len, napi_value js);

/* ---------- small helpers ---------- */

static const char *status_name(uint32_t status) {
    switch (status) {
    case METASK_AGENTCORE_STATUS_OK: return "OK";
    case METASK_AGENTCORE_STATUS_INVALID_ARGUMENT: return "INVALID_ARGUMENT";
    case METASK_AGENTCORE_STATUS_OUT_OF_MEMORY: return "OUT_OF_MEMORY";
    case METASK_AGENTCORE_STATUS_BUSY: return "BUSY";
    case METASK_AGENTCORE_STATUS_STALE_RUN: return "STALE_RUN";
    case METASK_AGENTCORE_STATUS_TOO_LATE: return "TOO_LATE";
    case METASK_AGENTCORE_STATUS_INVALID_STATE: return "INVALID_STATE";
    case METASK_AGENTCORE_STATUS_CORE_ERROR: return "CORE_ERROR";
    case METASK_AGENTCORE_STATUS_CALLBACK_FAILED: return "CALLBACK_FAILED";
    case METASK_AGENTCORE_STATUS_INTERNAL_ERROR: return "INTERNAL_ERROR";
    case METASK_AGENTCORE_STATUS_RESOURCE_LIMIT: return "RESOURCE_LIMIT";
    case METASK_AGENTCORE_STATUS_SKILL_CATALOG_INVALID: return "SKILL_CATALOG_INVALID";
    case METASK_AGENTCORE_STATUS_STALE_CATALOG: return "STALE_CATALOG";
    case METASK_AGENTCORE_STATUS_SKILL_NOT_FOUND: return "SKILL_NOT_FOUND";
    case METASK_AGENTCORE_STATUS_INVALID_SKILL_ARGUMENTS: return "INVALID_SKILL_ARGUMENTS";
    case METASK_AGENTCORE_STATUS_SKILL_POLICY_VIOLATION: return "SKILL_POLICY_VIOLATION";
    case METASK_AGENTCORE_STATUS_SKILL_UNAVAILABLE: return "SKILL_UNAVAILABLE";
    case METASK_AGENTCORE_STATUS_STALE_COMPACT: return "STALE_COMPACT";
    case METASK_AGENTCORE_STATUS_CHECKPOINT_BUDGET_REQUIRED: return "CHECKPOINT_BUDGET_REQUIRED";
    case METASK_AGENTCORE_STATUS_CHECKPOINT_CORRUPT: return "CHECKPOINT_CORRUPT";
    case METASK_AGENTCORE_STATUS_CHECKPOINT_UNSUPPORTED: return "CHECKPOINT_UNSUPPORTED";
    case METASK_AGENTCORE_STATUS_CHECKPOINT_INCOMPATIBLE: return "CHECKPOINT_INCOMPATIBLE";
    case METASK_AGENTCORE_STATUS_CHECKPOINT_IO: return "CHECKPOINT_IO";
    case METASK_AGENTCORE_STATUS_LOGICAL_SESSION_CONFLICT: return "LOGICAL_SESSION_CONFLICT";
    case METASK_AGENTCORE_STATUS_MCP_NOT_REFRESHED: return "MCP_NOT_REFRESHED";
    case METASK_AGENTCORE_STATUS_INVALID_MCP_SELECTION: return "INVALID_MCP_SELECTION";
    case METASK_AGENTCORE_STATUS_SKILL_CATALOG_INCOMPLETE: return "SKILL_CATALOG_INCOMPLETE";
    case METASK_AGENTCORE_STATUS_IMAGE_INPUT_UNSUPPORTED: return "IMAGE_INPUT_UNSUPPORTED";
    case METASK_AGENTCORE_STATUS_IMAGE_INPUT_CAPABILITY_UNKNOWN: return "IMAGE_INPUT_CAPABILITY_UNKNOWN";
    case METASK_AGENTCORE_STATUS_GOAL_CONFLICT: return "GOAL_CONFLICT";
    case METASK_AGENTCORE_STATUS_MESSAGE_POSITION_OUT_OF_RANGE: return "MESSAGE_POSITION_OUT_OF_RANGE";
    case METASK_AGENTCORE_STATUS_NOT_USER_MESSAGE: return "NOT_USER_MESSAGE";
    case METASK_AGENTCORE_STATUS_MESSAGE_POSITION_COMPACTED: return "MESSAGE_POSITION_COMPACTED";
    default: return "STATUS_ERROR";
    }
}

typedef struct {
    uint8_t *ptr;
    size_t len;
} owned_t;

static owned_t copy_bytes(const void *ptr, size_t len) {
    owned_t out = {NULL, 0};
    if (ptr == NULL || len == 0) return out;
    out.ptr = (uint8_t *)malloc(len);
    if (out.ptr == NULL) return out;
    memcpy(out.ptr, ptr, len);
    out.len = len;
    return out;
}

static metask_agentcore_bytes_view_v1 view_of(const owned_t *bytes) {
    metask_agentcore_bytes_view_v1 view = {NULL, 0};
    if (bytes != NULL && bytes->ptr != NULL && bytes->len != 0) {
        view.ptr = bytes->ptr;
        view.len = bytes->len;
    }
    return view;
}

/* Throws a JS Error whose `code` is the status name and whose message carries
 * the library diagnostic, then releases the diagnostic. */
static void throw_status(napi_env env, const char *operation, uint32_t status,
                         metask_agentcore_owned_bytes_v1 *diagnostic) {
    char message[1024];
    int used = snprintf(message, sizeof(message), "%s failed: %s", operation, status_name(status));
    if (diagnostic != NULL && diagnostic->ptr != NULL && diagnostic->len != 0 && used > 0 &&
        (size_t)used < sizeof(message) - 3) {
        size_t room = sizeof(message) - (size_t)used - 3;
        size_t take = diagnostic->len < room ? (size_t)diagnostic->len : room;
        memcpy(message + used, ": ", 2);
        memcpy(message + used + 2, diagnostic->ptr, take);
        message[used + 2 + take] = '\0';
    }
    if (diagnostic != NULL) g_api->buffer_release(diagnostic);
    napi_throw_error(env, status_name(status), message);
}

static int get_string(napi_env env, napi_value value, owned_t *out) {
    size_t len = 0;
    out->ptr = NULL;
    out->len = 0;
    napi_valuetype type;
    if (napi_typeof(env, value, &type) != napi_ok) return 0;
    if (type == napi_undefined || type == napi_null) return 1;
    if (type != napi_string) {
        napi_throw_type_error(env, NULL, "expected a string");
        return 0;
    }
    if (napi_get_value_string_utf8(env, value, NULL, 0, &len) != napi_ok) return 0;
    if (len == 0) return 1;
    out->ptr = (uint8_t *)malloc(len + 1);
    if (out->ptr == NULL) {
        napi_throw_error(env, NULL, "out of memory");
        return 0;
    }
    if (napi_get_value_string_utf8(env, value, (char *)out->ptr, len + 1, &len) != napi_ok) {
        free(out->ptr);
        out->ptr = NULL;
        return 0;
    }
    out->len = len;
    return 1;
}

static int get_property_string(napi_env env, napi_value object, const char *name, owned_t *out) {
    napi_value value;
    if (napi_get_named_property(env, object, name, &value) != napi_ok) return 0;
    return get_string(env, value, out);
}

static napi_value project_protocol(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3];
    uint32_t kind;
    owned_t bytes;
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (argc != 3 || napi_get_value_uint32(env, argv[0], &kind) != napi_ok ||
        !get_string(env, argv[1], &bytes)) return NULL;
    const char *failure = bytes.ptr ? node_project(env, kind, bytes.ptr, bytes.len, argv[2]) : "empty JSON";
    free(bytes.ptr);
    if (failure) {
        napi_throw_error(env, "INVALID_PROTOCOL", failure);
        return NULL;
    }
    return argv[2];
}

static int get_id(napi_env env, napi_value value, uint64_t *id) {
    bool lossless = false;
    if (napi_get_value_bigint_uint64(env, value, id, &lossless) == napi_ok && lossless && *id) return 1;
    napi_throw_range_error(env, NULL, "expected a nonzero uint64 bigint");
    return 0;
}

static int get_property_u32(napi_env env, napi_value object, const char *name, uint32_t *out) {
    napi_value value;
    napi_valuetype type;
    *out = 0;
    if (napi_get_named_property(env, object, name, &value) != napi_ok) return 0;
    if (napi_typeof(env, value, &type) != napi_ok) return 0;
    if (type == napi_undefined || type == napi_null) return 1;
    return napi_get_value_uint32(env, value, out) == napi_ok;
}

/* A list of strings kept alive together with the views that borrow them. */
typedef struct {
    owned_t *items;
    metask_agentcore_bytes_view_v1 *views;
    uint32_t count;
} string_list_t;

static void free_list(string_list_t *list) {
    for (uint32_t i = 0; i < list->count; i++) free(list->items[i].ptr);
    free(list->items);
    free(list->views);
    memset(list, 0, sizeof(*list));
}

static int get_string_list(napi_env env, napi_value object, const char *name, string_list_t *out) {
    napi_value array;
    napi_valuetype type;
    bool is_array = false;
    memset(out, 0, sizeof(*out));
    if (napi_get_named_property(env, object, name, &array) != napi_ok) return 0;
    if (napi_typeof(env, array, &type) != napi_ok) return 0;
    if (type == napi_undefined || type == napi_null) return 1;
    if (napi_is_array(env, array, &is_array) != napi_ok || !is_array) {
        napi_throw_type_error(env, NULL, "expected an array of strings");
        return 0;
    }
    uint32_t count = 0;
    if (napi_get_array_length(env, array, &count) != napi_ok) return 0;
    if (count == 0) return 1;
    out->items = (owned_t *)calloc(count, sizeof(owned_t));
    out->views = (metask_agentcore_bytes_view_v1 *)calloc(count, sizeof(metask_agentcore_bytes_view_v1));
    if (out->items == NULL || out->views == NULL) {
        free_list(out);
        napi_throw_error(env, NULL, "out of memory");
        return 0;
    }
    for (uint32_t i = 0; i < count; i++) {
        napi_value element;
        if (napi_get_element(env, array, i, &element) != napi_ok ||
            !get_string(env, element, &out->items[i])) {
            out->count = i;
            free_list(out);
            return 0;
        }
        out->views[i] = view_of(&out->items[i]);
        out->count = i + 1;
    }
    return 1;
}

/* ---------- blocking calls into JavaScript (tool calls, UI requests) ---------- */

typedef struct pending_s {
    struct pending_s *next;
    uint64_t id;
    cond_t cond;
    int done;
    uint32_t status;
    owned_t result;
} pending_t;

static mutex_t gate = MUTEX_INITIALIZER;

enum message_kind { MSG_EVENT = 1, MSG_UI = 2, MSG_DONE = 3, MSG_TOOL = 4 };

typedef struct {
    enum message_kind kind;
    owned_t data;           /* event JSON, UI request JSON, tool arguments */
    uint64_t call_id;
    uint64_t run_id;
    owned_t session_id;
    uint32_t tool_index;    /* MSG_TOOL */
    uint32_t status;        /* MSG_DONE */
    metask_agentcore_run_result_v1 result; /* MSG_DONE */
} message_t;

static void free_message(message_t *message) {
    free(message->data.ptr);
    free(message->session_id.ptr);
    free(message);
}

static napi_value make_string(napi_env env, const owned_t *bytes) {
    napi_value value = NULL;
    napi_create_string_utf8(env, bytes->ptr ? (const char *)bytes->ptr : "", bytes->len, &value);
    return value;
}

/* ---------- Runtime ---------- */

struct runtime_s;

typedef struct {
    struct runtime_s *runtime;
    uint32_t index;
} tool_ctx_t;

typedef struct runtime_s {
    metask_agentcore_runtime *handle;
    struct session_s *sessions;
    atomic_uint refs;
    tool_ctx_t *tool_contexts;
    owned_t *tool_strings; /* 3 per tool: name, description, schema */
    uint32_t tool_count;
    int destroyed;
} runtime_t;

static uint32_t host_execute(void *ctx, const metask_agentcore_run_context_v1 *run,
                             metask_agentcore_bytes_view_v1 arguments, metask_agentcore_owned_bytes_v1 *out);

static void host_release(void *ctx, metask_agentcore_owned_bytes_v1 *owned) {
    (void)ctx;
    free(owned->ptr);
    owned->ptr = NULL;
    owned->len = 0;
}

static void release_runtime(runtime_t *runtime) {
    if (atomic_fetch_sub(&runtime->refs, 1) != 1) return;
    if (runtime->handle) {
        metask_agentcore_owned_bytes_v1 diagnostic = {0};
        g_api->runtime->destroy(runtime->handle, &diagnostic);
        g_api->buffer_release(&diagnostic);
    }
    for (uint32_t i = 0; i < runtime->tool_count * 3; i++) free(runtime->tool_strings[i].ptr);
    free(runtime->tool_strings);
    free(runtime->tool_contexts);
    free(runtime);
}

static void runtime_finalize(napi_env env, void *data, void *hint) {
    release_runtime(data);
}

static runtime_t *get_runtime(napi_env env, napi_value value) {
    void *data = NULL;
    if (napi_get_value_external(env, value, &data) != napi_ok || data == NULL) {
        napi_throw_type_error(env, NULL, "expected a runtime handle");
        return NULL;
    }
    runtime_t *runtime = (runtime_t *)data;
    if (runtime->destroyed) {
        napi_throw_error(env, "INVALID_STATE", "runtime is closed");
        return NULL;
    }
    return runtime;
}

/* runtimeCreate(tools: string[], hostTools: {name, description, schema}[], dispatch, preview) */
static napi_value runtime_create(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    bool preview = false;
    if (argc >= 3 && napi_get_value_bool(env, argv[2], &preview) != napi_ok) {
        napi_throw_type_error(env, NULL, "preview must be a boolean");
        return NULL;
    }
    if (g_api == NULL) {
        napi_throw_error(env, "INVALID_STATE", "load() the AgentCore library first");
        return NULL;
    }
    napi_value holder;
    napi_create_object(env, &holder);
    napi_set_named_property(env, holder, "tools", argv[0]);
    string_list_t builtin;
    if (!get_string_list(env, holder, "tools", &builtin)) return NULL;

    uint32_t host_count = 0;
    napi_get_array_length(env, argv[1], &host_count);
    runtime_t *runtime = (runtime_t *)calloc(1, sizeof(runtime_t));
    metask_agentcore_host_tool_v1 *host_tools = NULL;
    if (runtime == NULL) {
        free_list(&builtin);
        napi_throw_error(env, NULL, "out of memory");
        return NULL;
    }
    if (host_count > 0) {
        runtime->tool_contexts = (tool_ctx_t *)calloc(host_count, sizeof(tool_ctx_t));
        runtime->tool_strings = (owned_t *)calloc((size_t)host_count * 3, sizeof(owned_t));
        host_tools = (metask_agentcore_host_tool_v1 *)calloc(host_count, sizeof(metask_agentcore_host_tool_v1));
        if (runtime->tool_contexts == NULL || runtime->tool_strings == NULL || host_tools == NULL) {
            napi_throw_error(env, NULL, "out of memory");
            goto fail;
        }
    }
    for (uint32_t i = 0; i < host_count; i++) {
        napi_value spec;
        napi_get_element(env, argv[1], i, &spec);
        if (!get_property_string(env, spec, "name", &runtime->tool_strings[i * 3]) ||
            !get_property_string(env, spec, "description", &runtime->tool_strings[i * 3 + 1]) ||
            !get_property_string(env, spec, "schema", &runtime->tool_strings[i * 3 + 2]))
            goto fail;
        runtime->tool_count = i + 1;
        runtime->tool_contexts[i].runtime = runtime;
        runtime->tool_contexts[i].index = i;
        host_tools[i].struct_size = (uint32_t)sizeof(host_tools[i]);
        host_tools[i].ctx = &runtime->tool_contexts[i];
        host_tools[i].name = view_of(&runtime->tool_strings[i * 3]);
        host_tools[i].description = view_of(&runtime->tool_strings[i * 3 + 1]);
        host_tools[i].input_schema_json = view_of(&runtime->tool_strings[i * 3 + 2]);
        host_tools[i].execute = host_execute;
        host_tools[i].release_result = host_release;
    }

    atomic_init(&runtime->refs, 1);

    metask_agentcore_runtime_config_v1 config;
    memset(&config, 0, sizeof(config));
    config.struct_size = (uint32_t)sizeof(config);
    config.builtin_tools = builtin.views;
    config.builtin_tool_count = builtin.count;
    config.host_tools = host_tools;
    config.host_tool_count = host_count;
    config.preview = preview ? 1 : 0;
    metask_agentcore_owned_bytes_v1 diagnostic = {NULL, 0};
    uint32_t status = g_api->runtime->create(&config, NULL, &runtime->handle, &diagnostic);
    free_list(&builtin);
    free(host_tools);
    host_tools = NULL;
    if (status != METASK_AGENTCORE_STATUS_OK) {
        throw_status(env, "runtime.create", status, &diagnostic);
        goto fail_after_list;
    }
    g_api->buffer_release(&diagnostic);
    napi_value external;
    napi_create_external(env, runtime, runtime_finalize, NULL, &external);
    return external;

fail:
    free_list(&builtin);
fail_after_list:
    free(host_tools);
    for (uint32_t i = 0; i < runtime->tool_count * 3; i++) free(runtime->tool_strings[i].ptr);
    free(runtime->tool_strings);
    free(runtime->tool_contexts);
    free(runtime);
    return NULL;
}

static napi_value runtime_destroy(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    runtime_t *runtime = get_runtime(env, argv[0]);
    if (runtime == NULL) return NULL;
    metask_agentcore_owned_bytes_v1 diagnostic = {NULL, 0};
    uint32_t status = g_api->runtime->destroy(runtime->handle, &diagnostic);
    if (status != METASK_AGENTCORE_STATUS_OK) {
        throw_status(env, "runtime.destroy", status, &diagnostic);
        return NULL;
    }
    g_api->buffer_release(&diagnostic);
    runtime->destroyed = 1;
    runtime->handle = NULL;
    return NULL;
}

/* ---------- Session ---------- */

typedef struct session_s {
    struct session_s *next;
    runtime_t *runtime;
    atomic_uint refs;
    pending_t *pending;
    uint64_t next_call;
    int cancel_requested;
    int detached;
    int native_running;
    message_t *completion;
    metask_agentcore_session *handle;
    napi_threadsafe_function tsfn;
    int destroyed;
    int running;
    uint64_t run_id;
    owned_t text;
    uint32_t max_turns;
    uint32_t stream_retry_budget;
    metask_agentcore_context_block_v1 *blocks;
    uint32_t block_count;
} session_t;

static void release_input(session_t *session) {
    free(session->text.ptr);
    session->text = (owned_t){0};
    for (uint32_t i = 0; i < session->block_count; i++) {
        free((void *)session->blocks[i].label.ptr);
        free((void *)session->blocks[i].text.ptr);
    }
    free(session->blocks);
    session->blocks = NULL;
    session->block_count = 0;
}

static int copy_blocks(napi_env env, session_t *session, napi_value array) {
    uint32_t count;
    if (napi_get_array_length(env, array, &count) != napi_ok || count > 32) return 0;
    if (count == 0) return 1;
    session->blocks = calloc(count, sizeof(*session->blocks));
    if (!session->blocks) return 0;
    session->block_count = count;
    for (uint32_t i = 0; i < count; i++) {
        napi_value item;
        owned_t label, text;
        if (napi_get_element(env, array, i, &item) != napi_ok || !get_property_string(env, item, "label", &label)) return 0;
        session->blocks[i].struct_size = sizeof(*session->blocks);
        session->blocks[i].label = view_of(&label);
        if (!get_property_string(env, item, "text", &text)) return 0;
        session->blocks[i].text = view_of(&text);
    }
    return 1;
}

static void wake_pending(session_t *session) {
    for (pending_t *p = session->pending; p; p = p->next) {
        if (!p->done) {
            p->done = 1;
            cond_wake(&p->cond);
        }
    }
}

static uint32_t request_abort(session_t *session, metask_agentcore_owned_bytes_v1 *diagnostic) {
    session->cancel_requested = 1;
    uint32_t status = g_api->session->abort(session->handle, session->run_id, METASK_AGENTCORE_ABORT_USER_REQUEST, diagnostic);
    if (status == METASK_AGENTCORE_STATUS_OK || session->detached) wake_pending(session);
    return status;
}

static int enqueue(session_t *session, message_t *message) {
    if (!session->detached && napi_call_threadsafe_function(session->tsfn, message, napi_tsfn_nonblocking) == napi_ok) return 1;
    free_message(message);
    return 0;
}

static uint32_t session_on_event(void *ctx, const metask_agentcore_run_context_v1 *run,
                                 metask_agentcore_bytes_view_v1 event_json) {
    session_t *session = ctx;
    mutex_lock(&gate);
    if (session->cancel_requested) {
        metask_agentcore_owned_bytes_v1 diagnostic = {0};
        request_abort(session, &diagnostic);
        g_api->buffer_release(&diagnostic);
    }
    message_t *message = calloc(1, sizeof(*message));
    if (message) {
        message->kind = MSG_EVENT;
        message->data = copy_bytes(event_json.ptr, event_json.len);
        enqueue(session, message);
    }
    mutex_unlock(&gate);
    return METASK_AGENTCORE_EVENT_CONTINUE;
}

static uint32_t dispatch_request(session_t *session, const metask_agentcore_run_context_v1 *run,
                                 enum message_kind kind, uint32_t index, metask_agentcore_bytes_view_v1 input,
                                 metask_agentcore_owned_bytes_v1 *out) {
    uint32_t unavailable = kind == MSG_UI ? METASK_AGENTCORE_UI_UNAVAILABLE : METASK_AGENTCORE_HOST_FAILED;
    *out = (metask_agentcore_owned_bytes_v1){0};
    if (!session || session->detached || session->cancel_requested || session->next_call == UINT64_MAX) return unavailable;
    message_t *message = calloc(1, sizeof(*message));
    if (!message) return unavailable;
    pending_t pending = {.id = ++session->next_call, .status = unavailable, .next = session->pending};
    message->kind = kind;
    message->tool_index = index;
    message->run_id = run->run_id;
    message->call_id = pending.id;
    message->session_id = copy_bytes(run->session_id.ptr, run->session_id.len);
    message->data = copy_bytes(input.ptr, input.len);
    if (!enqueue(session, message)) return unavailable;
    session->pending = &pending;
    cond_init(&pending.cond);
    while (!pending.done) cond_wait(&pending.cond, &gate);
    pending_t **link = &session->pending;
    while (*link != &pending) link = &(*link)->next;
    *link = pending.next;
    cond_destroy(&pending.cond);
    out->ptr = pending.result.ptr;
    out->len = pending.result.len;
    return pending.status;
}

static uint32_t host_execute(void *ctx, const metask_agentcore_run_context_v1 *run,
                             metask_agentcore_bytes_view_v1 arguments, metask_agentcore_owned_bytes_v1 *out) {
    tool_ctx_t *tool = ctx;
    mutex_lock(&gate);
    session_t *session = tool->runtime->sessions;
    while (session && session->handle != run->session) session = session->next;
    uint32_t status = dispatch_request(session, run, MSG_TOOL, tool->index, arguments, out);
    mutex_unlock(&gate);
    return status;
}

static uint32_t session_on_ui_request(void *ctx, const metask_agentcore_run_context_v1 *run,
                                      metask_agentcore_bytes_view_v1 request_json, metask_agentcore_owned_bytes_v1 *out) {
    mutex_lock(&gate);
    uint32_t status = dispatch_request(ctx, run, MSG_UI, 0, request_json, out);
    mutex_unlock(&gate);
    return status;
}

static void answer(session_t *session, uint64_t id, uint32_t status, owned_t text) {
    mutex_lock(&gate);
    for (pending_t *p = session->pending; p; p = p->next) {
        if (p->id == id && !p->done) {
            p->result = text;
            text.ptr = NULL;
            p->status = status;
            p->done = 1;
            cond_wake(&p->cond);
            break;
        }
    }
    mutex_unlock(&gate);
    free(text.ptr);
}

static void session_release_response(void *ctx, metask_agentcore_owned_bytes_v1 *owned) {
    (void)ctx;
    free(owned->ptr);
    owned->ptr = NULL;
    owned->len = 0;
}

static void session_call_js(napi_env env, napi_value callback, void *context, void *data) {
    session_t *session = (session_t *)context;
    message_t *message = (message_t *)data;
    if (env == NULL) {
        free_message(message);
        return;
    }
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    napi_value argv[6];
    size_t argc = 0;
    if (message->kind == MSG_EVENT) {
        napi_create_string_utf8(env, "event", NAPI_AUTO_LENGTH, &argv[0]);
        argv[1] = make_string(env, &message->data);
        argc = 2;
    } else if (message->kind == MSG_UI || message->kind == MSG_TOOL) {
        napi_create_string_utf8(env, message->kind == MSG_UI ? "ui" : "tool", NAPI_AUTO_LENGTH, &argv[0]);
        argv[1] = node_unsigned(env, message->call_id);
        argv[2] = make_string(env, &message->data);
        napi_create_uint32(env, message->tool_index, &argv[3]);
        argv[4] = node_unsigned(env, message->run_id);
        argv[5] = make_string(env, &message->session_id);
        argc = 6;
    } else {
        session->running = 0;
        napi_unref_threadsafe_function(env, session->tsfn);
        release_input(session);
        napi_value result, value;
        napi_create_object(env, &result);
        napi_create_uint32(env, message->status, &value);
        napi_set_named_property(env, result, "status", value);
        napi_create_string_utf8(env, status_name(message->status), NAPI_AUTO_LENGTH, &value);
        napi_set_named_property(env, result, "statusName", value);
        napi_create_uint32(env, message->result.stop_reason_code, &value);
        napi_set_named_property(env, result, "stopReasonCode", value);
        napi_create_uint32(env, message->result.turns, &value);
        napi_set_named_property(env, result, "turns", value);
        napi_create_uint32(env, message->result.tool_calls, &value);
        napi_set_named_property(env, result, "toolCalls", value);
        napi_create_uint32(env, message->result.input_accepted_count, &value);
        napi_set_named_property(env, result, "inputAccepted", value);
        napi_create_uint32(env, message->result.input_adopted_count, &value);
        napi_set_named_property(env, result, "inputAdopted", value);
        napi_set_named_property(env, result, "diagnostic", make_string(env, &message->data));
        napi_create_string_utf8(env, "done", NAPI_AUTO_LENGTH, &argv[0]);
        argv[1] = result;
        argc = 2;
    }
    if (napi_call_function(env, undefined, callback, argc, argv, NULL) != napi_ok) {
        napi_value ignored;
        napi_get_and_clear_last_exception(env, &ignored);
        if (message->call_id) answer(session, message->call_id,
            message->kind == MSG_UI ? METASK_AGENTCORE_UI_UNAVAILABLE : METASK_AGENTCORE_HOST_FAILED, (owned_t){0});
    }
    free_message(message);
}

static void release_session(session_t *session) {
    if (atomic_fetch_sub(&session->refs, 1) == 1) free(session);
}

static void session_finalize(napi_env env, void *data, void *hint) {
    release_session(data);
}

static void unlink_session(session_t *session) {
    runtime_t *runtime = session->runtime;
    mutex_lock(&gate);
    session_t **link = &runtime->sessions;
    while (*link != session) link = &(*link)->next;
    *link = session->next;
    mutex_unlock(&gate);
    release_input(session);
    release_runtime(runtime);
    release_session(session);
}

static void destroy_detached(session_t *session) {
    metask_agentcore_owned_bytes_v1 diagnostic = {0};
    g_api->session->destroy(session->handle, &diagnostic);
    g_api->buffer_release(&diagnostic);
    unlink_session(session);
}

static void cleanup_session(void *data) {
    session_t *session = data;
    mutex_lock(&gate);
    session->detached = 1;
    int running = session->native_running;
    if (running) {
        metask_agentcore_owned_bytes_v1 diagnostic = {0};
        request_abort(session, &diagnostic);
        g_api->buffer_release(&diagnostic);
    }
    napi_release_threadsafe_function(session->tsfn, napi_tsfn_abort);
    mutex_unlock(&gate);
    if (!running) destroy_detached(session);
}

static session_t *get_session(napi_env env, napi_value value) {
    void *data = NULL;
    if (napi_get_value_external(env, value, &data) != napi_ok || data == NULL) {
        napi_throw_type_error(env, NULL, "expected a session handle");
        return NULL;
    }
    session_t *session = (session_t *)data;
    if (session->destroyed) {
        napi_throw_error(env, "INVALID_STATE", "session is closed");
        return NULL;
    }
    return session;
}

/* sessionCreate(runtime, config, dispatch) */
typedef struct {
    napi_env env;
    napi_value callback;
    napi_value buffer;
    uint8_t *bytes;
} checkpoint_io;

static const metask_agentcore_checkpoint_limits_v1 limits = {
    .struct_size = sizeof(limits), .hard_bytes = 64u << 20, .max_section_bytes = 64u << 20,
    .max_string_bytes = 16u << 20, .max_messages = 1000000, .max_blocks_per_message = 4096, .chunk_bytes = 65536
};

static uint32_t transfer(checkpoint_io *io, uint32_t capacity, uint32_t *count) {
    napi_handle_scope scope;
    if (napi_open_handle_scope(io->env, &scope) != napi_ok) return 1;
    napi_value receiver, args[2] = {io->buffer}, result;
    napi_get_undefined(io->env, &receiver);
    napi_create_uint32(io->env, capacity, &args[1]);
    int failed = napi_call_function(io->env, receiver, io->callback, 2, args, &result) != napi_ok ||
        napi_get_value_uint32(io->env, result, count) != napi_ok || *count > capacity;
    napi_close_handle_scope(io->env, scope);
    return failed;
}

static uint32_t write_checkpoint(void *ctx, metask_agentcore_bytes_view_v1 chunk) {
    checkpoint_io *io = ctx;
    for (uint64_t offset = 0; offset < chunk.len;) {
        uint32_t length = chunk.len - offset > limits.chunk_bytes ? limits.chunk_bytes : (uint32_t)(chunk.len - offset);
        memcpy(io->bytes, chunk.ptr + offset, length);
        uint32_t count;
        if (transfer(io, length, &count) || !count) return 1;
        offset += count;
    }
    return 0;
}

static uint32_t read_checkpoint(void *ctx, uint8_t *dest, uint64_t capacity, uint64_t *read) {
    checkpoint_io *io = ctx;
    uint32_t count;
    if (transfer(io, capacity > limits.chunk_bytes ? limits.chunk_bytes : (uint32_t)capacity, &count)) return 1;
    memcpy(dest, io->bytes, count);
    *read = count;
    return 0;
}

static napi_value session_export(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (!session) return NULL;
    checkpoint_io io = {.env = env, .callback = argv[1]};
    if (napi_create_buffer(env, limits.chunk_bytes, (void **)&io.bytes, &io.buffer) != napi_ok) return NULL;
    metask_agentcore_checkpoint_sink_v1 sink = {.struct_size = sizeof(sink), .ctx = &io, .write = write_checkpoint};
    metask_agentcore_checkpoint_export_config_v1 config = {.struct_size = sizeof(config), .sink = &sink, .limits = &limits};
    metask_agentcore_checkpoint_export_result_v1 result = {.struct_size = sizeof(result)};
    metask_agentcore_owned_bytes_v1 diagnostic = {0};
    uint32_t status = g_api->session_control->export_checkpoint(session->handle, &config, &result, &diagnostic);
    if (status) throw_status(env, "session.export_checkpoint", status, &diagnostic);
    else g_api->buffer_release(&diagnostic);
    return NULL;
}

static napi_value session_create(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    runtime_t *runtime = get_runtime(env, argv[0]);
    if (runtime == NULL) return NULL;
    napi_value cfg = argv[1];

    owned_t api_key = {0}, base_url = {0}, workspace_root = {0}, workspace_home = {0}, model = {0};
    string_list_t tools = {0}, allow = {0}, ask = {0}, deny = {0};
    metask_agentcore_session_host_config_v1 host;
    memset(&host, 0, sizeof(host));
    host.struct_size = (uint32_t)sizeof(host);
    session_t *session = NULL;
    napi_value external = NULL;

    if (!get_property_u32(env, cfg, "provider", &host.provider_kind_code) ||
        !get_property_u32(env, cfg, "protocol", &host.protocol_kind_code) ||
        !get_property_u32(env, cfg, "permissionMode", &host.permission_mode_code) ||
        !get_property_u32(env, cfg, "shell", &host.shell_policy_code) ||
        !get_property_string(env, cfg, "apiKey", &api_key) ||
        !get_property_string(env, cfg, "baseUrl", &base_url) ||
        !get_property_string(env, cfg, "workspaceRoot", &workspace_root) ||
        !get_property_string(env, cfg, "workspaceHome", &workspace_home) ||
        !get_property_string(env, cfg, "model", &model) ||
        !get_string_list(env, cfg, "tools", &tools) ||
        !get_string_list(env, cfg, "allow", &allow) ||
        !get_string_list(env, cfg, "ask", &ask) ||
        !get_string_list(env, cfg, "deny", &deny))
        goto done;

    host.api_key = view_of(&api_key);
    host.base_url = view_of(&base_url);
    host.workspace_root = view_of(&workspace_root);
    host.workspace_home = view_of(&workspace_home);
    host.allowed_tools = tools.views;
    host.allowed_tool_count = tools.count;
    metask_agentcore_permission_rule_set_v1 rules;
    memset(&rules, 0, sizeof(rules));
    if (allow.count || ask.count || deny.count) {
        rules.struct_size = (uint32_t)sizeof(rules);
        rules.allow = allow.views;
        rules.allow_count = allow.count;
        rules.ask = ask.views;
        rules.ask_count = ask.count;
        rules.deny = deny.views;
        rules.deny_count = deny.count;
        host.permission_rules = &rules;
    }
    metask_agentcore_session_create_config_v1 config;
    memset(&config, 0, sizeof(config));
    config.struct_size = (uint32_t)sizeof(config);
    config.host = &host;
    config.model = view_of(&model);

    session = (session_t *)calloc(1, sizeof(session_t));
    if (session == NULL) {
        napi_throw_error(env, NULL, "out of memory");
        goto done;
    }
    napi_value resource_name;
    napi_create_string_utf8(env, "metacodes.session", NAPI_AUTO_LENGTH, &resource_name);
    if (napi_create_threadsafe_function(env, argv[2], NULL, resource_name, 0, 1, NULL, NULL,
                                        session, session_call_js, &session->tsfn) != napi_ok) {
        napi_throw_error(env, NULL, "cannot create the event dispatcher");
        free(session);
        session = NULL;
        goto done;
    }
    napi_unref_threadsafe_function(env, session->tsfn);

    metask_agentcore_session_callbacks_v1 callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.struct_size = (uint32_t)sizeof(callbacks);
    callbacks.ctx = session;
    callbacks.on_event = session_on_event;
    callbacks.on_ui_request = session_on_ui_request;
    callbacks.release_response = session_release_response;
    metask_agentcore_owned_bytes_v1 diagnostic = {NULL, 0};
    uint32_t status;
    if (argc == 4) {
        checkpoint_io io = {.env = env, .callback = argv[3]};
        metask_agentcore_checkpoint_source_v1 source = {.struct_size = sizeof(source), .ctx = &io, .read = read_checkpoint};
        metask_agentcore_session_restore_config_v1 restore = {.struct_size = sizeof(restore), .host = &host, .source = &source, .limits = &limits};
        metask_agentcore_owned_bytes_v1 report = {0};
        status = napi_create_buffer(env, limits.chunk_bytes, (void **)&io.bytes, &io.buffer) == napi_ok
            ? g_api->session_control->restore(runtime->handle, &restore, &callbacks, &session->handle, &report, &diagnostic)
            : METASK_AGENTCORE_STATUS_OUT_OF_MEMORY;
        if (!status) {
            owned_t bytes = {report.ptr, report.len};
            napi_set_named_property(env, cfg, "restoreReport", make_string(env, &bytes));
        }
        g_api->buffer_release(&report);
    } else {
        status = g_api->session->create(runtime->handle, &config, &callbacks, &session->handle, &diagnostic);
    }
    if (status != METASK_AGENTCORE_STATUS_OK) {
        napi_release_threadsafe_function(session->tsfn, napi_tsfn_abort);
        free(session);
        session = NULL;
        throw_status(env, argc == 4 ? "session.restore" : "session.create", status, &diagnostic);
        goto done;
    }
    g_api->buffer_release(&diagnostic);
    session->runtime = runtime;
    atomic_init(&session->refs, 1);
    atomic_fetch_add(&runtime->refs, 1);
    mutex_lock(&gate);
    session->next = runtime->sessions;
    runtime->sessions = session;
    mutex_unlock(&gate);
    if (napi_add_env_cleanup_hook(env, cleanup_session, session) != napi_ok) {
        cleanup_session(session);
        napi_throw_error(env, NULL, "cannot register session cleanup");
        goto done;
    }
    if (napi_create_external(env, session, session_finalize, NULL, &external) != napi_ok) {
        napi_remove_env_cleanup_hook(env, cleanup_session, session);
        cleanup_session(session);
        goto done;
    }
    atomic_fetch_add(&session->refs, 1);

done:
    free(api_key.ptr);
    free(base_url.ptr);
    free(workspace_root.ptr);
    free(workspace_home.ptr);
    free(model.ptr);
    free_list(&tools);
    free_list(&allow);
    free_list(&ask);
    free_list(&deny);
    return external;
}

static THREAD_RESULT run_thread(void *arg) {
    session_t *session = (session_t *)arg;
    metask_agentcore_run_input_v1 input;
    memset(&input, 0, sizeof(input));
    input.struct_size = (uint32_t)sizeof(input);
    input.kind_code = METASK_AGENTCORE_RUN_INPUT_TEXT;
    input.text = view_of(&session->text);
    metask_agentcore_run_options_v1 options;
    memset(&options, 0, sizeof(options));
    options.struct_size = (uint32_t)sizeof(options);
    options.max_turns = session->max_turns;
    options.stream_retry_budget = session->stream_retry_budget;
    options.context_blocks = session->blocks;
    options.context_block_count = session->block_count;
    message_t *message = session->completion;
    message->result.struct_size = sizeof(message->result);
    metask_agentcore_owned_bytes_v1 diagnostic = {0};
    message->status = g_api->session->run_input(session->handle, session->run_id, &input, &options, &message->result, &diagnostic);
    message->kind = MSG_DONE;
    message->data = copy_bytes(diagnostic.ptr, (size_t)diagnostic.len);
    g_api->buffer_release(&diagnostic);
    mutex_lock(&gate);
    session->native_running = 0;
    int detached = session->detached;
    enqueue(session, message);
    mutex_unlock(&gate);
    if (detached) destroy_detached(session);
    return THREAD_DONE;
}

/* sessionRun(session, runId, text, maxTurns, streamRetryBudget): starts the Run;
 * completion is a "done" dispatch. */
static napi_value session_run(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value argv[6];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (session == NULL) return NULL;
    if (session->running) {
        napi_throw_error(env, "BUSY", "a Run is already active on this session");
        return NULL;
    }
    uint64_t run_id = 0;
    uint32_t max_turns = 0;
    uint32_t stream_retry_budget = 0;
    owned_t text;
    if (argc < 6 || !get_id(env, argv[1], &run_id) ||
        napi_get_value_uint32(env, argv[3], &max_turns) != napi_ok ||
        napi_get_value_uint32(env, argv[4], &stream_retry_budget) != napi_ok || !get_string(env, argv[2], &text)) {
        bool pending = false;
        napi_is_exception_pending(env, &pending);
        if (!pending) napi_throw_type_error(env, NULL, "invalid Run arguments");
        return NULL;
    }
    session->run_id = (uint64_t)run_id;
    session->text = text;
    if (!copy_blocks(env, session, argv[5])) {
        release_input(session);
        napi_throw_error(env, NULL, "cannot copy context blocks");
        return NULL;
    }
    session->max_turns = max_turns;
    session->stream_retry_budget = stream_retry_budget;
    session->completion = calloc(1, sizeof(*session->completion));
    if (!session->completion) {
        release_input(session);
        napi_throw_error(env, NULL, "out of memory");
        return NULL;
    }
    session->cancel_requested = 0;
    session->native_running = 1;
    session->running = 1;
    napi_ref_threadsafe_function(env, session->tsfn);
    int failed = spawn_thread(run_thread, session);
    if (failed) {
        free(session->completion);
        session->native_running = 0;
        session->running = 0;
        napi_unref_threadsafe_function(env, session->tsfn);
        release_input(session);
        napi_throw_error(env, NULL, "cannot start the Run thread");
    }
    return NULL;
}

static napi_value session_abort(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (session == NULL) return NULL;
    uint64_t run_id = 0;
    if (!get_id(env, argv[1], &run_id)) return NULL;
    metask_agentcore_owned_bytes_v1 diagnostic = {NULL, 0};
    mutex_lock(&gate);
    uint32_t status = session->native_running && session->run_id == run_id
        ? request_abort(session, &diagnostic) : METASK_AGENTCORE_STATUS_TOO_LATE;
    mutex_unlock(&gate);
    if (status != METASK_AGENTCORE_STATUS_OK && status != METASK_AGENTCORE_STATUS_STALE_RUN && status != METASK_AGENTCORE_STATUS_TOO_LATE) {
        throw_status(env, "session.abort", status, &diagnostic);
        return NULL;
    }
    g_api->buffer_release(&diagnostic);
    napi_value value;
    napi_create_uint32(env, status, &value);
    return value;
}

/* sessionSubmit(session, runId, inputId, text) -> receipt sequence */
static napi_value session_submit(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (session == NULL) return NULL;
    uint64_t run_id = 0, input_id = 0;
    owned_t text;
    if (!get_id(env, argv[1], &run_id) || !get_id(env, argv[2], &input_id)) return NULL;
    if (!get_string(env, argv[3], &text)) return NULL;
    metask_agentcore_submitted_input_v1 input;
    memset(&input, 0, sizeof(input));
    input.struct_size = (uint32_t)sizeof(input);
    input.input_id = (uint64_t)input_id;
    input.text = view_of(&text);
    metask_agentcore_input_receipt_v1 receipt;
    memset(&receipt, 0, sizeof(receipt));
    receipt.struct_size = (uint32_t)sizeof(receipt);
    metask_agentcore_owned_bytes_v1 diagnostic = {NULL, 0};
    uint32_t status = g_api->session->submit_input(session->handle, (uint64_t)run_id, &input, &receipt, &diagnostic);
    free(text.ptr);
    if (status != METASK_AGENTCORE_STATUS_OK) {
        throw_status(env, "session.submit_input", status, &diagnostic);
        return NULL;
    }
    g_api->buffer_release(&diagnostic);
    napi_value value;
    napi_create_uint32(env, receipt.sequence, &value);
    return value;
}

/* Zero a secret copy through volatile stores, which the compiler may not
 * drop as dead before free, then release it. */
static void erase_and_free(owned_t *bytes) {
    volatile uint8_t *cursor = bytes->ptr;
    for (size_t i = 0; cursor != NULL && i < bytes->len; i++) cursor[i] = 0;
    free(bytes->ptr);
    bytes->ptr = NULL;
    bytes->len = 0;
}

/* sessionUpdateCredential(session, apiKey): Revision 25. Runs on the JS
 * thread, which also owns destroy, so an update never races the release. */
static napi_value session_update_credential(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (session == NULL) return NULL;
    owned_t credential;
    if (!get_string(env, argv[1], &credential)) return NULL;
    metask_agentcore_owned_bytes_v1 diagnostic = {NULL, 0};
    uint32_t status = g_api->session->update_credential(session->handle, view_of(&credential), &diagnostic);
    erase_and_free(&credential);
    if (status != METASK_AGENTCORE_STATUS_OK) {
        throw_status(env, "session.update_credential", status, &diagnostic);
        return NULL;
    }
    g_api->buffer_release(&diagnostic);
    return NULL;
}

static napi_value session_describe(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (session == NULL) return NULL;
    metask_agentcore_owned_bytes_v1 output = {NULL, 0}, diagnostic = {NULL, 0};
    uint32_t status = g_api->session_control->describe(session->handle, &output, &diagnostic);
    if (status != METASK_AGENTCORE_STATUS_OK) {
        g_api->buffer_release(&output);
        throw_status(env, "session.describe", status, &diagnostic);
        return NULL;
    }
    g_api->buffer_release(&diagnostic);
    napi_value value;
    napi_create_string_utf8(env, output.ptr ? (const char *)output.ptr : "", (size_t)output.len, &value);
    g_api->buffer_release(&output);
    return value;
}

static napi_value session_set_model(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (session == NULL) return NULL;
    owned_t model;
    if (!get_string(env, argv[1], &model)) return NULL;
    metask_agentcore_owned_bytes_v1 diagnostic = {NULL, 0};
    uint32_t status = g_api->session_control->set_model(session->handle, view_of(&model), &diagnostic);
    free(model.ptr);
    if (status != METASK_AGENTCORE_STATUS_OK) {
        throw_status(env, "session.set_model", status, &diagnostic);
        return NULL;
    }
    g_api->buffer_release(&diagnostic);
    return NULL;
}

static napi_value session_set_permission_mode(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (session == NULL) return NULL;
    uint32_t mode = 0;
    napi_get_value_uint32(env, argv[1], &mode);
    metask_agentcore_owned_bytes_v1 diagnostic = {NULL, 0};
    uint32_t status = g_api->session_control->update_permission_mode(session->handle, mode, &diagnostic);
    if (status != METASK_AGENTCORE_STATUS_OK) {
        throw_status(env, "session.update_permission_mode", status, &diagnostic);
        return NULL;
    }
    g_api->buffer_release(&diagnostic);
    return NULL;
}

/* sessionRewindToUserMessage(session, position): index.js has checked that
 * position is a safe integer >= 1. */
static napi_value session_rewind_to_user_message(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (session == NULL) return NULL;
    uint64_t position;
    if (!get_id(env, argv[1], &position)) return NULL;
    metask_agentcore_owned_bytes_v1 diagnostic = {NULL, 0};
    uint32_t status = g_api->session_control->rewind_to_user_message(session->handle, (uint64_t)position, &diagnostic);
    if (status != METASK_AGENTCORE_STATUS_OK) {
        throw_status(env, "session.rewind_to_user_message", status, &diagnostic);
        return NULL;
    }
    g_api->buffer_release(&diagnostic);
    return NULL;
}

static napi_value session_destroy(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (session == NULL) return NULL;
    if (session->running) {
        napi_throw_error(env, "BUSY", "cannot close a session while a Run is active");
        return NULL;
    }
    metask_agentcore_owned_bytes_v1 diagnostic = {NULL, 0};
    uint32_t status = g_api->session->destroy(session->handle, &diagnostic);
    if (status != METASK_AGENTCORE_STATUS_OK) {
        throw_status(env, "session.destroy", status, &diagnostic);
        return NULL;
    }
    g_api->buffer_release(&diagnostic);
    session->destroyed = 1;
    napi_remove_env_cleanup_hook(env, cleanup_session, session);
    napi_release_threadsafe_function(session->tsfn, napi_tsfn_release);
    unlink_session(session);
    return NULL;
}

static napi_value complete_call(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    uint64_t id;
    uint32_t status;
    owned_t text;
    if (!session || !get_id(env, argv[1], &id) ||
        napi_get_value_uint32(env, argv[2], &status) != napi_ok || !get_string(env, argv[3], &text)) return NULL;
    answer(session, id, status, text);
    return NULL;
}

/* load(path) -> ABI revision */
static napi_value load_locked(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (g_api == NULL) {
        owned_t path;
        if (!get_string(env, argv[0], &path)) return NULL;
        if (path.ptr == NULL) {
            napi_throw_type_error(env, NULL, "library path required");
            return NULL;
        }
        void *library = open_library((const char *)path.ptr);
        free(path.ptr);
        if (library == NULL) {
            napi_throw_error(env, "LOAD_FAILED", library_error());
            return NULL;
        }
        const void *(*get_api)(uint32_t) = (const void *(*)(uint32_t))library_symbol(library, "metask_agentcore_get_api");
        if (get_api == NULL) {
            close_library(library);
            napi_throw_error(env, "LOAD_FAILED", "metask_agentcore_get_api not exported");
            return NULL;
        }
        const metask_agentcore_api_v1 *api = (const metask_agentcore_api_v1 *)get_api(METASK_AGENTCORE_ABI_V1);
        if (!metask_agentcore_api_v1_is_compatible(api)) {
            close_library(library);
            napi_throw_error(env, "ABI_MISMATCH",
                             "library does not provide the expected AgentCore ABI revision and layout");
            return NULL;
        }
        g_api = api; /* the library stays loaded for the life of the process */
    }
    napi_value value;
    napi_create_uint32(env, g_api->abi_revision, &value);
    return value;
}

static napi_value load_library(napi_env env, napi_callback_info info) {
    mutex_lock(&gate);
    napi_value revision = load_locked(env, info);
    mutex_unlock(&gate);
    return revision;
}

#define EXPORT(name, function)                                              \
    do {                                                                    \
        napi_value fn;                                                      \
        napi_create_function(env, name, NAPI_AUTO_LENGTH, function, NULL, &fn); \
        napi_set_named_property(env, exports, name, fn);                    \
    } while (0)

NAPI_MODULE_INIT() {
#ifdef _WIN32
    if (!load_host_api()) return NULL;
#endif
    mutex_lock(&gate);
    static int pinned;
    if (!pinned) pinned = pin_addon((void *)&load_library);
    mutex_unlock(&gate);
    if (!pinned) {
        napi_throw_error(env, "LOAD_FAILED", "cannot pin Node addon");
        return NULL;
    }
    EXPORT("load", load_library);
    EXPORT("project", project_protocol);
    EXPORT("runtimeCreate", runtime_create);
    EXPORT("runtimeDestroy", runtime_destroy);
    EXPORT("sessionCreate", session_create);
    EXPORT("sessionExport", session_export);
    EXPORT("sessionRun", session_run);
    EXPORT("sessionAbort", session_abort);
    EXPORT("sessionSubmit", session_submit);
    EXPORT("sessionUpdateCredential", session_update_credential);
    EXPORT("sessionDescribe", session_describe);
    EXPORT("sessionSetModel", session_set_model);
    EXPORT("sessionSetPermissionMode", session_set_permission_mode);
    EXPORT("sessionRewindToUserMessage", session_rewind_to_user_message);
    EXPORT("sessionDestroy", session_destroy);
    EXPORT("completeCall", complete_call);
    napi_value revision;
    napi_create_uint32(env, METASK_AGENTCORE_ABI_REVISION, &revision);
    napi_set_named_property(env, exports, "abiRevision", revision);
    return exports;
}
