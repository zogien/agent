
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

static int get_property_i32(napi_env env, napi_value object, const char *name, int32_t *out) {
    napi_value value;
    return napi_get_named_property(env, object, name, &value) == napi_ok &&
        napi_get_value_int32(env, value, out) == napi_ok;
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

enum message_kind { MSG_COMPACT = 5, MSG_EVENT = 1, MSG_UI = 2, MSG_DONE = 3, MSG_TOOL = 4 };

typedef struct {
    enum message_kind kind;
    owned_t data;           /* event JSON, UI request JSON, tool arguments */
    uint64_t call_id;
    uint64_t run_id;
    owned_t session_id;
    uint32_t tool_index;    /* MSG_TOOL */
    uint32_t status;        /* MSG_DONE */
    metask_agentcore_compact_result_v1 compact;
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

#include "mcp_bridge.h"

static int buffer_view(napi_env env, napi_value item, const char *key, metask_agentcore_bytes_view_v1 *view);

static int read_identity(napi_env env, napi_value item, const char *key, uint8_t target[32]) {
    metask_agentcore_bytes_view_v1 view;
    if (!buffer_view(env, item, key, &view) || view.len != 32) return 0;
    memcpy(target, view.ptr, 32);
    return 1;
}

typedef struct {
    metask_agentcore_mcp_server_v1 *items;
    metask_agentcore_mcp_protocol_limits_v1 *limits;
    uint32_t count;
} mcp_servers_t;

static void free_servers(mcp_servers_t *servers) {
    for (uint32_t i = 0; i < servers->count; i++) {
        void *ctx = servers->items[i].connector.ctx;
        if (ctx) mcp_release(ctx);
    }
    free(servers->items);
    free(servers->limits);
}

static int read_u64(napi_env env, napi_value object, const char *key, uint64_t *out);

static int read_protocol_limits(napi_env env, napi_value obj, metask_agentcore_mcp_protocol_limits_v1 *limits) {
    limits->struct_size = sizeof(*limits);
    return read_u64(env, obj, "maxFrameBytes", &limits->max_frame_bytes) &&
        read_u64(env, obj, "maxTools", &limits->max_tools) && read_u64(env, obj, "maxToolNameBytes", &limits->max_tool_name_bytes) &&
        read_u64(env, obj, "maxTextBytes", &limits->max_text_bytes) && read_u64(env, obj, "maxSchemaBytes", &limits->max_schema_bytes) &&
        read_u64(env, obj, "maxJsonDepth", &limits->max_json_depth) && read_u64(env, obj, "maxJsonNodes", &limits->max_json_nodes) &&
        read_u64(env, obj, "maxCursorBytes", &limits->max_cursor_bytes) && read_u64(env, obj, "maxVersions", &limits->max_versions);
}

static int read_servers(napi_env env, napi_value array, mcp_servers_t *out) {
    uint32_t count;
    if (napi_get_array_length(env, array, &count) != napi_ok || count > METASK_AGENTCORE_MAX_MCP_SERVERS_V1) return 0;
    if (!count) return 1;
    out->items = calloc(count, sizeof(*out->items));
    out->limits = calloc(count, sizeof(*out->limits));
    if (!out->items || !out->limits) return 0;
    out->count = count;
    for (uint32_t i = 0; i < count; i++) {
        metask_agentcore_mcp_server_v1 *s = &out->items[i];
        napi_value item = node_element(env, array, i);
        s->struct_size = sizeof(*s);
        napi_value limits = node_field(env, item, "limits");
        napi_valuetype type;
        if (napi_typeof(env, limits, &type) != napi_ok) return 0;
        if (type == napi_object) {
            if (!read_protocol_limits(env, limits, &out->limits[i])) return 0;
            s->protocol_limits = &out->limits[i];
        }
        if (!item || !read_identity(env, item, "identity", s->server_binding_identity) ||
            !read_identity(env, item, "fingerprint", s->configuration_fingerprint) ||
            !buffer_view(env, item, "namespace", &s->namespace_) || !buffer_view(env, item, "clientName", &s->client_name) ||
            !buffer_view(env, item, "clientVersion", &s->client_version) ||
            !get_property_u32(env, item, "transport", &s->transport_code) || !get_property_u32(env, item, "timeoutMs", &s->timeout_ms) ||
            !get_property_u32(env, item, "policy", &s->negotiation_policy_code) || !read_connector(env, item, &s->connector)) return 0;
    }
    return 1;
}

static int read_u64(napi_env env, napi_value object, const char *key, uint64_t *out) {
    napi_value value = node_field(env, object, key);
    bool lossless;
    return value && napi_get_value_bigint_uint64(env, value, out, &lossless) == napi_ok && lossless;
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
    uint32_t mcp_jobs;
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
    mcp_servers_t servers = {0};
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
    metask_agentcore_mcp_catalog_limits_v1 limits = {.struct_size = sizeof(limits)};
    if (argc == 4) {
        napi_value opts = argv[3], catalog = node_field(env, opts, "limits");
        napi_valuetype type;
        bool teams;
        if (!catalog || napi_typeof(env, catalog, &type) != napi_ok ||
            napi_get_value_bool(env, node_field(env, opts, "enableTeams"), &teams) != napi_ok ||
            !read_servers(env, node_field(env, opts, "servers"), &servers) ||
            (type != napi_null && (!read_u64(env, catalog, "maxServers", &limits.max_servers) ||
             !read_u64(env, catalog, "maxNamespaceBytes", &limits.max_namespace_bytes) || !read_u64(env, catalog, "maxIssues", &limits.max_issues)))) {
            napi_throw_type_error(env, NULL, "invalid runtime MCP or team options");
            goto fail;
        }
        config.enable_teams = teams;
        config.mcp_catalog_limits = type == napi_null ? NULL : &limits;
        config.mcp_servers = servers.items;
        config.mcp_server_count = servers.count;
    }
    metask_agentcore_owned_bytes_v1 diagnostic = {NULL, 0};
    uint32_t status = g_api->runtime->create(&config, NULL, &runtime->handle, &diagnostic);
    free_servers(&servers);
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
    free_servers(&servers);
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
    if (runtime->mcp_jobs) {
        napi_throw_error(env, "BUSY", "MCP operation in progress");
        return NULL;
    }
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

enum mcp_operation { MCP_REFRESH, MCP_APPLY, MCP_DESCRIBE };
typedef struct {
    runtime_t *runtime;
    enum mcp_operation operation;
    napi_threadsafe_function completion;
    mcp_environment_t *owner;
    mutex_t lock;
    cond_t wake;
    bool started, finished, stopping;
    napi_deferred promise;
    napi_ref inputs;
    mcp_servers_t servers;
    metask_agentcore_mcp_configuration_v1 config;
    metask_agentcore_mcp_apply_report_v1 report;
    uint64_t generation;
    uint32_t status;
    metask_agentcore_owned_bytes_v1 diagnostic, document;
} mcp_job_t;

static THREAD_RESULT execute_mcp_job(void *data) {
    mcp_job_t *job = data;
    metask_agentcore_runtime *r = job->runtime->handle;
    switch (job->operation) {
    case MCP_REFRESH: job->status = g_api->mcp->refresh(r, &job->generation, &job->diagnostic); break;
    case MCP_DESCRIBE: job->status = g_api->mcp->describe(r, &job->document, &job->diagnostic); break;
    case MCP_APPLY: job->status = g_api->mcp->apply_configuration(r, &job->config, &job->report, &job->diagnostic); break;
    }
    mutex_lock(&job->lock);
    job->finished = true;
    if (!job->stopping) {
        napi_status sent = napi_call_threadsafe_function(job->completion, NULL, napi_tsfn_nonblocking);
        if (sent != napi_closing) napi_release_threadsafe_function(job->completion, napi_tsfn_release);
    }
    cond_wake(&job->wake);
    mutex_unlock(&job->lock);
    return THREAD_DONE;
}

static void free_mcp_job(napi_env env, mcp_job_t *job) {
    free_servers(&job->servers);
    if (job->inputs) napi_delete_reference(env, job->inputs);
    cond_destroy(&job->wake);
    mutex_destroy(&job->lock);
    if (job->owner) release_mcp_environment(NULL, job->owner, NULL);
    release_runtime(job->runtime);
    free(job);
}

static void finalize_mcp_job(napi_env env, void *data, void *hint) {
    mcp_job_t *job = data;
    mutex_lock(&job->lock);
    if (job->started && !job->finished) {
        job->stopping = true;
        stop_mcp_environment(job->owner);
        while (!job->finished) cond_wait(&job->wake, &job->lock);
    }
    mutex_unlock(&job->lock);
    g_api->buffer_release(&job->diagnostic);
    g_api->buffer_release(&job->document);
    free_mcp_job(env, job);
}

static void complete_mcp_job(napi_env env, napi_value callback, void *ctx, void *data) {
    mcp_job_t *job = ctx;
    if (!env) return;
    job->runtime->mcp_jobs--;
    napi_value value;
    if (job->status) {
        const char *code = status_name(job->status);
        napi_value label, message;
        napi_create_string_utf8(env, code, NAPI_AUTO_LENGTH, &label);
        message = job->diagnostic.len ? make_string(env, &(owned_t){job->diagnostic.ptr, job->diagnostic.len}) : label;
        napi_create_error(env, label, message, &value);
        napi_reject_deferred(env, job->promise, value);
    } else {
        if (job->operation == MCP_APPLY) {
            napi_value disposition;
            napi_create_object(env, &value);
            const char *names[] = {"", "applied", "superseded", "rejected"};
            napi_create_string_utf8(env, names[job->report.disposition_code], NAPI_AUTO_LENGTH, &disposition);
            node_set_field(env, value, "disposition", disposition);
            node_set_field(env, value, "activeRevision", node_unsigned(env, job->report.active_revision));
            node_set_field(env, value, "desiredRevision", node_unsigned(env, job->report.desired_revision));
            node_set_field(env, value, "catalogGeneration", node_unsigned(env, job->report.catalog_generation));
        } else if (job->operation == MCP_DESCRIBE) {
            value = make_string(env, &(owned_t){job->document.ptr, job->document.len});
        } else value = node_unsigned(env, job->generation);
        napi_resolve_deferred(env, job->promise, value);
    }
}

static napi_value queue_mcp_job(napi_env env, napi_callback_info info, enum mcp_operation op) {
    size_t argc = 2;
    napi_value argv[2], name, promise;
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    runtime_t *runtime = get_runtime(env, argv[0]);
    if (!runtime) return NULL;
    mcp_job_t *job = calloc(1, sizeof(*job));
    if (!job) { napi_throw_error(env, NULL, "out of memory"); return NULL; }
    atomic_fetch_add(&runtime->refs, 1);
    mutex_init(&job->lock);
    cond_init(&job->wake);
    job->operation = op;
    job->runtime = runtime;
    if (napi_get_instance_data(env, (void **)&job->owner) != napi_ok) {
        free_mcp_job(env, job);
        return NULL;
    }
    atomic_fetch_add(&job->owner->refs, 1);
    if (op == MCP_APPLY) {
        if (argc != 2 || !read_u64(env, argv[1], "desiredRevision", &job->config.desired_revision) ||
            napi_create_reference(env, argv[1], 1, &job->inputs) != napi_ok ||
            !read_servers(env, node_field(env, argv[1], "servers"), &job->servers)) {
            napi_throw_type_error(env, NULL, "invalid MCP configuration");
            free_mcp_job(env, job);
            return NULL;
        }
        job->config.struct_size = sizeof(job->config);
        job->config.servers = job->servers.items;
        job->config.server_count = job->servers.count;
    }
    if (napi_create_string_utf8(env, "metacodes.mcp.control", NAPI_AUTO_LENGTH, &name) == napi_ok &&
        napi_create_promise(env, &job->promise, &promise) == napi_ok &&
        napi_create_threadsafe_function(env, NULL, NULL, name, 0, 1, job, finalize_mcp_job,
                                       job, complete_mcp_job, &job->completion) == napi_ok) {
        if (spawn_thread(execute_mcp_job, job) == 0) {
            job->started = true;
            runtime->mcp_jobs++;
            return promise;
        }
        napi_release_threadsafe_function(job->completion, napi_tsfn_abort);
    } else free_mcp_job(env, job);
    napi_throw_error(env, NULL, "cannot queue MCP operation");
    return NULL;
}

static napi_value refresh_mcp(napi_env env, napi_callback_info info) { return queue_mcp_job(env, info, MCP_REFRESH); }
static napi_value describe_mcp(napi_env env, napi_callback_info info) { return queue_mcp_job(env, info, MCP_DESCRIBE); }
static napi_value apply_mcp(napi_env env, napi_callback_info info) { return queue_mcp_job(env, info, MCP_APPLY); }

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
    metask_agentcore_run_input_v1 input;
    metask_agentcore_run_input_part_v1 *parts;
    uint64_t compact_id;
    metask_agentcore_run_options_v1 options;
    metask_agentcore_context_block_v1 *blocks;
    uint32_t block_count;
} session_t;

static void release_input(session_t *session) {
    for (uint32_t i = 0; i < session->input.part_count; i++) {
        free((void *)session->parts[i].text.ptr);
        free((void *)session->parts[i].media_type.ptr);
        free((void *)session->parts[i].data.ptr);
    }
    free(session->parts);
    session->parts = NULL;
    free((void *)session->input.text.ptr);
    free((void *)session->input.skill_id.ptr);
    free((void *)session->input.catalog_revision.ptr);
    free((void *)session->input.arguments_json.ptr);
    session->input = (metask_agentcore_run_input_v1){0};
    for (uint32_t i = 0; i < session->block_count; i++) {
        free((void *)session->blocks[i].label.ptr);
        free((void *)session->blocks[i].text.ptr);
    }
    free(session->blocks);
    session->blocks = NULL;
    session->block_count = 0;
}

static int copy_view(napi_env env, napi_value item, const char *key, metask_agentcore_bytes_view_v1 *out) {
    owned_t bytes;
    if (!get_property_string(env, item, key, &bytes)) return 0;
    *out = view_of(&bytes);
    return 1;
}

static int copy_input(napi_env env, session_t *session, napi_value value) {
    metask_agentcore_run_input_v1 *input = &session->input;
    input->struct_size = sizeof(*input);
    bool is_array;
    if (napi_is_array(env, value, &is_array) != napi_ok) return 0;
    if (!is_array) {
        napi_valuetype type;
        if (napi_typeof(env, value, &type) != napi_ok) return 0;
        if (type == napi_string) {
            owned_t text;
            if (!get_string(env, value, &text)) return 0;
            input->kind_code = METASK_AGENTCORE_RUN_INPUT_TEXT;
            input->text = view_of(&text);
            return 1;
        }
        if (!get_property_u32(env, value, "kind", &input->kind_code)) return 0;
        if (input->kind_code == METASK_AGENTCORE_RUN_INPUT_GOAL_CONTINUATION) return 1;
        return input->kind_code == METASK_AGENTCORE_RUN_INPUT_SKILL &&
            copy_view(env, value, "skillId", &input->skill_id) &&
            copy_view(env, value, "catalogRevision", &input->catalog_revision) &&
            copy_view(env, value, "argumentsJson", &input->arguments_json);
    }
    uint32_t count;
    if (napi_get_array_length(env, value, &count) != napi_ok || !count || count > METASK_AGENTCORE_MAX_RUN_INPUT_PARTS_V1)
        return 0;
    session->parts = calloc(count, sizeof(*session->parts));
    if (!session->parts) return 0;
    input->kind_code = METASK_AGENTCORE_RUN_INPUT_MULTIMODAL;
    input->parts = session->parts;
    input->part_count = count;
    for (uint32_t i = 0; i < count; i++) {
        napi_value item;
        metask_agentcore_run_input_part_v1 *part = &session->parts[i];
        part->struct_size = sizeof(*part);
        if (napi_get_element(env, value, i, &item) != napi_ok || !get_property_u32(env, item, "kind", &part->kind_code) ||
            !copy_view(env, item, "text", &part->text) || !copy_view(env, item, "mediaType", &part->media_type) ||
            !copy_view(env, item, "data", &part->data)) return 0;
    }
    return 1;
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
    uint32_t status = g_api->session->abort(session->handle, session->run_id, METASK_AGENTCORE_ABORT_USER_REQUEST, diagnostic);
    if (status == METASK_AGENTCORE_STATUS_OK || status == METASK_AGENTCORE_STATUS_STALE_RUN ||
        status == METASK_AGENTCORE_STATUS_TOO_LATE) session->cancel_requested = 1;
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

static void compact_fields(napi_env env, napi_value result, const metask_agentcore_compact_result_v1 *compact) {
    napi_value outcome, usage;
    napi_create_uint32(env, compact->outcome_code, &outcome);
    node_set_field(env, result, "outcomeCode", outcome);
    node_set_field(env, result, "beforeContextTokens", node_unsigned(env, compact->before_context_tokens));
    node_set_field(env, result, "afterContextTokens", node_unsigned(env, compact->after_context_tokens));
    napi_create_object(env, &usage);
    node_set_field(env, usage, "input_tokens", node_unsigned(env, compact->input_tokens));
    node_set_field(env, usage, "output_tokens", node_unsigned(env, compact->output_tokens));
    node_set_field(env, usage, "cache_read_input_tokens", node_unsigned(env, compact->cache_read_input_tokens));
    node_set_field(env, usage, "cache_creation_input_tokens", node_unsigned(env, compact->cache_creation_input_tokens));
    node_set_field(env, result, "usage", usage);
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
        if (message->kind == MSG_COMPACT) {
            session->compact_id = 0;
            compact_fields(env, result, &message->compact);
        } else {
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
        }
        napi_set_named_property(env, result, "diagnostic", make_string(env, &message->data));
        napi_create_string_utf8(env, message->kind == MSG_COMPACT ? "compact" : "done", NAPI_AUTO_LENGTH, &argv[0]);
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
        if (session->compact_id) g_api->session_control->abort_compact(session->handle, session->compact_id, &diagnostic);
        else request_abort(session, &diagnostic);
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

typedef struct {
    metask_agentcore_prompt_section_v1 sections[METASK_AGENTCORE_MAX_PROMPT_PROFILE_SECTIONS_V1];
    metask_agentcore_prompt_profile_v1 profile;
} profile_t;

static int buffer_view(napi_env env, napi_value item, const char *key, metask_agentcore_bytes_view_v1 *view) {
    napi_value value;
    void *bytes;
    size_t length;
    if (napi_get_named_property(env, item, key, &value) != napi_ok ||
        napi_get_buffer_info(env, value, &bytes, &length) != napi_ok) return 0;
    view->ptr = length ? bytes : NULL;
    view->len = length;
    return 1;
}

typedef struct {
    runtime_t *runtime;
    metask_agentcore_skill_catalog *handle;
} catalog_t;

static void catalog_finalize(napi_env env, void *data, void *hint) {
    catalog_t *catalog = data;
    if (catalog->handle) {
        metask_agentcore_owned_bytes_v1 diagnostic = {0};
        g_api->skill->release_catalog(catalog->handle, &diagnostic);
        g_api->buffer_release(&diagnostic);
    }
    release_runtime(catalog->runtime);
    free(catalog);
}

static int read_catalog_query(napi_env env, napi_value cfg, metask_agentcore_skill_catalog_query_v1 *query,
                              metask_agentcore_skill_source_v1 *sources) {
    napi_value array;
    uint32_t count;
    if (!buffer_view(env, cfg, "workspace", &query->workspace_root) ||
        !buffer_view(env, cfg, "workspaceHome", &query->workspace_home) ||
        !buffer_view(env, cfg, "workspaceEpoch", &query->workspace_epoch) ||
        !get_property_i32(env, cfg, "defaultUserSourcePriority", &query->default_user_source_priority) ||
        !get_property_i32(env, cfg, "defaultWorkspaceSourcePriority", &query->default_workspace_source_priority) ||
        napi_get_named_property(env, cfg, "sources", &array) != napi_ok ||
        napi_get_array_length(env, array, &count) != napi_ok || count > METASK_AGENTCORE_MAX_SKILL_SOURCES_V1) return 0;
    for (uint32_t i = 0; i < count; i++) {
        napi_value item;
        sources[i].struct_size = sizeof(sources[i]);
        if (napi_get_element(env, array, i, &item) != napi_ok ||
            !get_property_u32(env, item, "scope", &sources[i].scope_code) ||
            !buffer_view(env, item, "root", &sources[i].root) ||
            !buffer_view(env, item, "id", &sources[i].source_instance_id) ||
            !get_property_i32(env, item, "priority", &sources[i].priority)) return 0;
    }
    query->additional_sources = count ? sources : NULL;
    query->additional_source_count = count;
    return 1;
}

static napi_value resolve_catalog(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2], result, external, json;
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    runtime_t *runtime = get_runtime(env, argv[0]);
    if (!runtime) return NULL;
    metask_agentcore_skill_source_v1 sources[METASK_AGENTCORE_MAX_SKILL_SOURCES_V1] = {0};
    metask_agentcore_skill_catalog_query_v1 query = {.struct_size = sizeof(query)};
    if (argc != 2 || !read_catalog_query(env, argv[1], &query, sources)) {
        napi_throw_type_error(env, NULL, "invalid catalog query");
        return NULL;
    }
    catalog_t *catalog = calloc(1, sizeof(*catalog));
    if (!catalog) {
        napi_throw_error(env, NULL, "out of memory");
        return NULL;
    }
    metask_agentcore_owned_bytes_v1 descriptor = {0}, diagnostic = {0};
    uint32_t status = g_api->skill->resolve_catalog(runtime->handle, &query, &catalog->handle, &descriptor, &diagnostic);
    if (status) {
        free(catalog);
        g_api->buffer_release(&descriptor);
        throw_status(env, "skill.resolve_catalog", status, &diagnostic);
        return NULL;
    }
    g_api->buffer_release(&diagnostic);
    catalog->runtime = runtime;
    atomic_fetch_add(&runtime->refs, 1);
    napi_status created = napi_create_string_utf8(env, (const char *)descriptor.ptr, descriptor.len, &json);
    g_api->buffer_release(&descriptor);
    if (created != napi_ok || napi_create_object(env, &result) != napi_ok ||
        napi_create_external(env, catalog, catalog_finalize, NULL, &external) != napi_ok) {
        catalog_finalize(env, catalog, NULL);
        napi_throw_error(env, NULL, "cannot create skill catalog");
        return NULL;
    }
    if (!node_set_field(env, result, "handle", external) || !node_set_field(env, result, "json", json)) {
        napi_throw_error(env, NULL, "cannot return skill catalog");
        return NULL;
    }
    return result;
}

static catalog_t *get_catalog(napi_env env, napi_value value) {
    void *data = NULL;
    if (napi_get_value_external(env, value, &data) != napi_ok || !data || !((catalog_t *)data)->handle) {
        napi_throw_type_error(env, NULL, "expected a live skill catalog");
        return NULL;
    }
    return data;
}

static napi_value release_catalog(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    catalog_t *catalog = get_catalog(env, argv[0]);
    if (!catalog) return NULL;
    metask_agentcore_owned_bytes_v1 diagnostic = {0};
    uint32_t status = g_api->skill->release_catalog(catalog->handle, &diagnostic);
    if (status) throw_status(env, "skill.release_catalog", status, &diagnostic);
    else {
        g_api->buffer_release(&diagnostic);
        catalog->handle = NULL;
    }
    return NULL;
}

static int read_skill_binding(napi_env env, napi_value cfg, string_list_t *grants,
                              metask_agentcore_skill_policy_v1 *policy, metask_agentcore_skill_catalog **handle) {
    napi_value value;
    napi_valuetype type;
    if (napi_get_named_property(env, cfg, "catalog", &value) != napi_ok || napi_typeof(env, value, &type) != napi_ok) return 0;
    if (!get_string_list(env, cfg, "grants", grants)) return 0;
    policy->struct_size = sizeof(*policy);
    policy->granted_skill_ids = grants->views;
    policy->granted_skill_id_count = grants->count;
    if (type != napi_null) {
        catalog_t *catalog = get_catalog(env, value);
        if (!catalog) return 0;
        *handle = catalog->handle;
    }
    return 1;
}

static napi_value bind_policy(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (!session) return NULL;
    string_list_t grants = {0};
    metask_agentcore_skill_policy_v1 policy = {0};
    metask_agentcore_skill_catalog *catalog = NULL;
    if (read_skill_binding(env, argv[1], &grants, &policy, &catalog)) {
        metask_agentcore_owned_bytes_v1 diagnostic = {0};
        uint32_t status = g_api->skill->bind_policy(session->handle, catalog, &policy, &diagnostic);
        if (status) throw_status(env, "skill.bind_policy", status, &diagnostic);
        else g_api->buffer_release(&diagnostic);
    }
    free_list(&grants);
    return NULL;
}

static int read_profile(napi_env env, napi_value array, profile_t *out) {
    uint32_t count;
    if (napi_get_array_length(env, array, &count) != napi_ok || count > METASK_AGENTCORE_MAX_PROMPT_PROFILE_SECTIONS_V1) return 0;
    out->profile.struct_size = sizeof(out->profile);
    out->profile.section_count = count;
    out->profile.sections = count ? out->sections : NULL;
    for (uint32_t i = 0; i < count; i++) {
        napi_value item, order;
        bool lossless;
        metask_agentcore_prompt_section_v1 *section = &out->sections[i];
        section->struct_size = sizeof(*section);
        if (napi_get_element(env, array, i, &item) != napi_ok ||
            !get_property_u32(env, item, "op", &section->op_code) || !buffer_view(env, item, "id", &section->id) ||
            !buffer_view(env, item, "text", &section->text) || !get_property_u32(env, item, "interpolate", &section->interpolate) ||
            napi_get_named_property(env, item, "order", &order) != napi_ok ||
            napi_get_value_bigint_int64(env, order, &section->order, &lossless) != napi_ok || !lossless) return 0;
    }
    return 1;
}

typedef struct {
    metask_agentcore_model_capability_v1 models[METASK_AGENTCORE_MAX_MODEL_CAPABILITIES_V1];
    metask_agentcore_model_profile_v1 profiles[METASK_AGENTCORE_MAX_MODEL_CAPABILITIES_V1];
    metask_agentcore_durable_budget_profile_v1 budget;
    metask_agentcore_team_config_v1 team;
    metask_agentcore_mcp_selection_v1 selection;
} host_options_t;

static int read_selection(napi_env env, napi_value array, metask_agentcore_mcp_selection_v1 *selection) {
    uint32_t count;
    if (napi_get_array_length(env, array, &count) != napi_ok || count > METASK_AGENTCORE_MAX_MCP_TOOLS_V1) return 0;
    selection->struct_size = sizeof(*selection);
    if (!count) return 1;
    metask_agentcore_mcp_selector_v1 *selectors = calloc(count, sizeof(*selectors));
    if (!selectors) return 0;
    selection->selectors = selectors;
    selection->selector_count = count;
    for (uint32_t i = 0; i < count; i++) {
        napi_value item = node_element(env, array, i);
        selectors[i].struct_size = sizeof(*selectors);
        if (!read_identity(env, item, "identity", selectors[i].server_binding_identity) ||
            !buffer_view(env, item, "name", &selectors[i].tool_name)) return 0;
    }
    return 1;
}

static int read_host_options(napi_env env, napi_value cfg, host_options_t *storage, metask_agentcore_session_host_config_v1 *host) {
    napi_value array, budget;
    napi_valuetype type;
    uint32_t count;
    napi_value team = node_field(env, cfg, "team"), selection = node_field(env, cfg, "mcpSelection");
    if (napi_typeof(env, team, &type) != napi_ok) return 0;
    if (type == napi_object) {
        metask_agentcore_team_config_v1 *t = &storage->team;
        t->struct_size = sizeof(*t);
        if (!get_property_u32(env, team, "role", &t->role_code) || !buffer_view(env, team, "teamName", &t->team_name) ||
            !buffer_view(env, team, "memberName", &t->member_name) || !buffer_view(env, team, "leadSessionId", &t->lead_session_id) ||
            !buffer_view(env, team, "memberLease", &t->member_lease)) return 0;
        host->team = t;
    }
    if (napi_typeof(env, selection, &type) != napi_ok) return 0;
    if (type == napi_object) {
        if (!read_selection(env, selection, &storage->selection)) return 0;
        host->mcp_selection = &storage->selection;
    }
    if (!get_property_u32(env, cfg, "runJournalMode", &host->run_journal_mode_code) ||
        napi_get_named_property(env, cfg, "modelCapabilities", &array) != napi_ok ||
        napi_get_array_length(env, array, &count) != napi_ok || count > METASK_AGENTCORE_MAX_MODEL_CAPABILITIES_V1) return 0;
    for (uint32_t i = 0; i < count; i++) {
        napi_value item;
        metask_agentcore_model_capability_v1 *model = &storage->models[i];
        uint32_t input, output;
        model->struct_size = sizeof(*model);
        if (napi_get_element(env, array, i, &item) != napi_ok || !buffer_view(env, item, "model", &model->model) ||
            !get_property_u32(env, item, "imageInput", &model->image_input_code) ||
            !get_property_u32(env, item, "maxInputTokens", &input) ||
            !get_property_u32(env, item, "maxTokens", &output)) return 0;
        if (input || output) {
            metask_agentcore_model_profile_v1 *profile = &storage->profiles[i];
            profile->struct_size = sizeof(*profile);
            profile->max_input_tokens = input;
            profile->max_tokens = output;
            model->profile = profile;
        }
    }
    host->model_capabilities = count ? storage->models : NULL;
    host->model_capability_count = count;
    if (napi_get_named_property(env, cfg, "durableBudget", &budget) != napi_ok || napi_typeof(env, budget, &type) != napi_ok) return 0;
    if (type == napi_null) return 1;
    metask_agentcore_durable_budget_profile_v1 *b = &storage->budget;
    b->struct_size = sizeof(*b);
    const struct { const char *name; uint64_t *field; } fields[] = {
        {"hardBytes", &b->hard_bytes}, {"softBytes", &b->soft_bytes}, {"inputCapBytes", &b->input_cap_bytes},
        {"providerRequestCapBytes", &b->provider_request_cap_bytes}, {"providerResultCapBytes", &b->provider_result_cap_bytes},
        {"toolResultCapBytes", &b->tool_result_cap_bytes}, {"mcpResultCapBytes", &b->mcp_result_cap_bytes},
        {"auditReserveBytes", &b->audit_reserve_bytes}, {"terminalReserveBytes", &b->terminal_reserve_bytes},
    };
    for (size_t i = 0; i < sizeof(fields)/sizeof(fields[0]); i++) {
        napi_value value;
        bool lossless;
        if (napi_get_named_property(env, budget, fields[i].name, &value) != napi_ok ||
            napi_get_value_bigint_uint64(env, value, fields[i].field, &lossless) != napi_ok || !lossless) return 0;
    }
    host->durable_budget = b;
    return 1;
}

typedef struct {
    string_list_t allow, ask, deny;
    metask_agentcore_permission_rule_set_v1 rules;
} permission_rules_t;

static int read_rules(napi_env env, napi_value value, permission_rules_t *out) {
    if (!get_string_list(env, value, "allow", &out->allow) ||
        !get_string_list(env, value, "ask", &out->ask) || !get_string_list(env, value, "deny", &out->deny)) return 0;
    out->rules = (metask_agentcore_permission_rule_set_v1){
        .struct_size = sizeof(out->rules),
        .allow = out->allow.views, .allow_count = out->allow.count,
        .ask = out->ask.views, .ask_count = out->ask.count,
        .deny = out->deny.views, .deny_count = out->deny.count,
    };
    return 1;
}

static void free_rules(permission_rules_t *rules) {
    free_list(&rules->allow);
    free_list(&rules->ask);
    free_list(&rules->deny);
}

static napi_value session_create(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    runtime_t *runtime = get_runtime(env, argv[0]);
    if (runtime == NULL) return NULL;
    napi_value cfg = argv[1];

    owned_t api_key = {0}, base_url = {0}, workspace_root = {0}, workspace_home = {0}, model = {0};
    string_list_t tools = {0};
    permission_rules_t rules = {0};
    profile_t profile = {0};
    host_options_t host_options = {0};
    metask_agentcore_skill_policy_v1 skill_policy = {0};
    string_list_t grants = {0};
    napi_value sections;
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
        !read_rules(env, cfg, &rules))
        goto done;

    host.api_key = view_of(&api_key);
    host.base_url = view_of(&base_url);
    host.workspace_root = view_of(&workspace_root);
    host.workspace_home = view_of(&workspace_home);
    host.allowed_tools = tools.views;
    host.allowed_tool_count = tools.count;
    if (!read_host_options(env, cfg, &host_options, &host) ||
        napi_get_named_property(env, cfg, "promptProfile", &sections) != napi_ok || !read_profile(env, sections, &profile)) {
        napi_throw_type_error(env, NULL, "invalid session options");
        goto done;
    }
    if (!read_skill_binding(env, cfg, &grants, &skill_policy, &host.skill_catalog)) goto done;
    if (host.skill_catalog) host.skill_policy = &skill_policy;
    if (rules.allow.count || rules.ask.count || rules.deny.count) host.permission_rules = &rules.rules;
    metask_agentcore_session_create_config_v1 config;
    memset(&config, 0, sizeof(config));
    config.struct_size = (uint32_t)sizeof(config);
    config.host = &host;
    config.model = view_of(&model);
    config.prompt_profile = profile.profile.section_count ? &profile.profile : NULL;

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
    free((void *)host_options.selection.selectors);
    free(api_key.ptr);
    free(base_url.ptr);
    free(workspace_root.ptr);
    free(workspace_home.ptr);
    free(model.ptr);
    free_list(&tools);
    free_rules(&rules);
    free_list(&grants);
    return external;
}

static THREAD_RESULT session_thread(void *arg) {
    session_t *session = arg;
    message_t *message = session->completion;
    metask_agentcore_owned_bytes_v1 diagnostic = {0};
    if (session->compact_id) {
        message->kind = MSG_COMPACT;
        message->compact.struct_size = sizeof(message->compact);
        message->status = g_api->session_control->compact(session->handle, session->compact_id, &message->compact, &diagnostic);
    } else {
        message->kind = MSG_DONE;
        message->result.struct_size = sizeof(message->result);
        message->status = g_api->session->run_input(session->handle, session->run_id, &session->input,
            &session->options, &message->result, &diagnostic);
    }
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

static napi_value start_thread(napi_env env, session_t *session) {
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
    int failed = spawn_thread(session_thread, session);
    if (failed) {
        free(session->completion);
        session->native_running = 0;
        session->running = 0;
        napi_unref_threadsafe_function(env, session->tsfn);
        release_input(session);
        napi_throw_error(env, NULL, "cannot start the session thread");
    }
    return NULL;
}

static bool read_time_context(napi_env env, napi_value cfg, metask_agentcore_run_options_v1 *options) {
    napi_value value;
    double offset;
    if (!get_property_u32(env, cfg, "timeCode", &options->time_context_code) ||
        napi_get_named_property(env, cfg, "utcOffsetMinutes", &value) != napi_ok ||
        napi_get_value_double(env, value, &offset) != napi_ok ||
        !(offset >= METASK_AGENTCORE_MIN_UTC_OFFSET_MINUTES_V1 && offset <= METASK_AGENTCORE_MAX_UTC_OFFSET_MINUTES_V1) ||
        (int32_t)offset != offset || (offset != 0 && options->time_context_code != METASK_AGENTCORE_TIME_CONTEXT_UTC_OFFSET)) {
        napi_throw_range_error(env, NULL, "invalid utcOffsetMinutes for timeContext");
        return false;
    }
    options->utc_offset_minutes = (int32_t)offset;
    return true;
}

static napi_value session_run(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4], blocks;
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (session == NULL) return NULL;
    if (session->running) {
        napi_throw_error(env, "BUSY", "a Run is already active on this session");
        return NULL;
    }
    uint64_t run_id = 0;
    metask_agentcore_run_options_v1 options = {.struct_size = sizeof(options)};
    if (argc != 4 || !get_id(env, argv[1], &run_id) ||
        !get_property_u32(env, argv[3], "turns", &options.max_turns) ||
        !get_property_u32(env, argv[3], "budget", &options.stream_retry_budget) ||
        !read_time_context(env, argv[3], &options) ||
        napi_get_named_property(env, argv[3], "blocks", &blocks) != napi_ok) {
        bool pending = false;
        napi_is_exception_pending(env, &pending);
        if (!pending) napi_throw_type_error(env, NULL, "invalid Run arguments");
        return NULL;
    }
    session->compact_id = 0;
    session->run_id = (uint64_t)run_id;
    if (!copy_input(env, session, argv[2]) || !copy_blocks(env, session, blocks)) {
        release_input(session);
        napi_throw_error(env, NULL, "cannot copy Run input");
        return NULL;
    }
    options.context_blocks = session->blocks;
    options.context_block_count = session->block_count;
    session->options = options;
    return start_thread(env, session);
}

static napi_value session_compact(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (!session) return NULL;
    if (session->running) {
        napi_throw_error(env, "BUSY", "session is busy");
        return NULL;
    }
    if (!get_id(env, argv[1], &session->compact_id)) return NULL;
    return start_thread(env, session);
}

static napi_value session_abort_compact(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    uint64_t id;
    if (!session || !get_id(env, argv[1], &id)) return NULL;
    metask_agentcore_owned_bytes_v1 diagnostic = {0};
    uint32_t status = g_api->session_control->abort_compact(session->handle, id, &diagnostic);
    if (status) throw_status(env, "session.abort_compact", status, &diagnostic);
    else g_api->buffer_release(&diagnostic);
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

enum session_doc { DOC_SESSION, DOC_GOAL, DOC_TEAM, DOC_INBOX };
static napi_value session_document(napi_env env, napi_callback_info info, enum session_doc kind) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (session == NULL) return NULL;
    metask_agentcore_owned_bytes_v1 output = {NULL, 0}, diagnostic = {NULL, 0};
    uint32_t status;
    const char *op;
    switch (kind) {
    case DOC_GOAL: op = "goal.get"; status = g_api->goal->get(session->handle, &output, &diagnostic); break;
    case DOC_TEAM: op = "team.describe"; status = g_api->team->describe(session->handle, &output, &diagnostic); break;
    case DOC_INBOX: op = "team.poll"; status = g_api->team->poll(session->handle, &output, &diagnostic); break;
    default: op = "session.describe"; status = g_api->session_control->describe(session->handle, &output, &diagnostic); break;
    }
    if (status != METASK_AGENTCORE_STATUS_OK) {
        g_api->buffer_release(&output);
        throw_status(env, op, status, &diagnostic);
        return NULL;
    }
    g_api->buffer_release(&diagnostic);
    napi_value value;
    napi_create_string_utf8(env, output.ptr ? (const char *)output.ptr : "", (size_t)output.len, &value);
    g_api->buffer_release(&output);
    return value;
}

static napi_value session_describe(napi_env env, napi_callback_info info) {
    return session_document(env, info, DOC_SESSION);
}

static napi_value get_goal(napi_env env, napi_callback_info info) {
    return session_document(env, info, DOC_GOAL);
}

static napi_value describe_team(napi_env env, napi_callback_info info) { return session_document(env, info, DOC_TEAM); }
static napi_value poll_team(napi_env env, napi_callback_info info) { return session_document(env, info, DOC_INBOX); }

static napi_value update_mcp_selection(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (!session) return NULL;
    metask_agentcore_mcp_selection_v1 selection = {0};
    if (argc != 2 || !read_selection(env, argv[1], &selection)) {
        free((void *)selection.selectors);
        napi_throw_type_error(env, NULL, "invalid MCP selection");
        return NULL;
    }
    metask_agentcore_owned_bytes_v1 diagnostic = {0};
    uint32_t status = g_api->mcp->update_selection(session->handle, &selection, &diagnostic);
    free((void *)selection.selectors);
    if (status) throw_status(env, "mcp.update_selection", status, &diagnostic);
    else g_api->buffer_release(&diagnostic);
    return NULL;
}

static bool read_goal_values(napi_env env, napi_value cfg, metask_agentcore_bytes_view_v1 *objective, uint64_t *budget) {
    napi_value value;
    bool lossless;
    if (buffer_view(env, cfg, "objective", objective) &&
        napi_get_named_property(env, cfg, "tokenBudget", &value) == napi_ok &&
        napi_get_value_bigint_uint64(env, value, budget, &lossless) == napi_ok && lossless) return true;
    napi_throw_type_error(env, NULL, "invalid goal fields");
    return false;
}

static napi_value set_goal(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    metask_agentcore_goal_set_v1 goal = {.struct_size = sizeof(goal)};
    if (!session || !read_goal_values(env, argv[1], &goal.objective, &goal.token_budget)) return NULL;
    metask_agentcore_owned_bytes_v1 diagnostic = {0};
    uint32_t status = g_api->goal->set(session->handle, &goal, &diagnostic);
    if (status) throw_status(env, "goal.set", status, &diagnostic);
    else g_api->buffer_release(&diagnostic);
    return NULL;
}

static napi_value update_goal(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    metask_agentcore_goal_update_v1 update = {.struct_size = sizeof(update)};
    if (!session || !read_goal_values(env, argv[1], &update.objective, &update.token_budget) ||
        !get_property_u32(env, argv[1], "fields", &update.fields) ||
        !get_property_u32(env, argv[1], "action", &update.action_code)) return NULL;
    metask_agentcore_owned_bytes_v1 diagnostic = {0};
    uint32_t status = g_api->goal->update(session->handle, &update, &diagnostic);
    if (status) throw_status(env, "goal.update", status, &diagnostic);
    else g_api->buffer_release(&diagnostic);
    return NULL;
}

static napi_value clear_goal(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (!session) return NULL;
    metask_agentcore_owned_bytes_v1 diagnostic = {0};
    uint32_t status = g_api->goal->clear(session->handle, &diagnostic);
    if (status) throw_status(env, "goal.clear", status, &diagnostic);
    else g_api->buffer_release(&diagnostic);
    return NULL;
}

static napi_value session_set_profile(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (!session) return NULL;
    profile_t profile = {0};
    if (!read_profile(env, argv[1], &profile)) {
        napi_throw_type_error(env, NULL, "invalid prompt profile");
        return NULL;
    }
    metask_agentcore_owned_bytes_v1 diagnostic = {0};
    uint32_t status = g_api->session_control->set_prompt_profile(session->handle,
        profile.profile.section_count ? &profile.profile : NULL, &diagnostic);
    if (status) throw_status(env, "session.set_prompt_profile", status, &diagnostic);
    else g_api->buffer_release(&diagnostic);
    return NULL;
}

static napi_value session_update_rules(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (!session) return NULL;
    permission_rules_t rules = {0};
    if (read_rules(env, argv[1], &rules)) {
        metask_agentcore_owned_bytes_v1 diagnostic = {0};
        uint32_t status = g_api->session_control->update_permission_rules(session->handle, &rules.rules, &diagnostic);
        if (status) throw_status(env, "session.update_permission_rules", status, &diagnostic);
        else g_api->buffer_release(&diagnostic);
    }
    free_rules(&rules);
    return NULL;
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
        napi_throw_error(env, "BUSY", "cannot close a session while a Run or compaction is active");
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

typedef struct {
    path_lock_t lock;
    char *path;
    int held;
} held_lock_t;

static void release_held_lock(held_lock_t *held) {
    if (!held->held) return;
    held->held = 0;
    unlock_path(held->lock, held->path);
}

static void held_lock_finalize(napi_env env, void *data, void *hint) {
    held_lock_t *held = data;
    release_held_lock(held);
    free(held->path);
    free(held);
}

static napi_value lock_file(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    owned_t path;
    if (argc != 1 || !get_string(env, argv[0], &path)) return NULL;
    if (!path.ptr) {
        napi_throw_type_error(env, NULL, "lock path required");
        return NULL;
    }
    held_lock_t *held = calloc(1, sizeof(*held));
    if (!held) {
        free(path.ptr);
        napi_throw_error(env, NULL, "out of memory");
        return NULL;
    }
    held->path = (char *)path.ptr;
    int error = 0;
    int status = lock_path(held->path, &held->lock, &error);
    if (status) {
        free(held->path);
        free(held);
        if (status > 0) {
            napi_throw_error(env, "EBUSY", "the lock is held by another writer");
        } else {
            char message[64];
            snprintf(message, sizeof(message), "cannot acquire the lock (system error %d)", error);
            napi_throw_error(env, "LOCK_FAILED", message);
        }
        return NULL;
    }
    held->held = 1;
    napi_value external;
    if (napi_create_external(env, held, held_lock_finalize, NULL, &external) != napi_ok) {
        held_lock_finalize(env, held, NULL);
        napi_throw_error(env, NULL, "cannot create the lock handle");
        return NULL;
    }
    return external;
}

static napi_value unlock_file(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    void *data = NULL;
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (argc != 1 || napi_get_value_external(env, argv[0], &data) != napi_ok || !data) {
        napi_throw_type_error(env, NULL, "expected a lock handle");
        return NULL;
    }
    release_held_lock(data);
    return NULL;
}

static napi_value load_locked(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (g_api == NULL) {
        owned_t rg = {0};
        if (argc == 2 && !get_string(env, argv[1], &rg)) return NULL;
        if (rg.ptr) {
#ifdef _WIN32
            int failed = _putenv_s("RG_BIN", (const char *)rg.ptr);
#else
            int failed = setenv("RG_BIN", (const char *)rg.ptr, 1);
#endif
            free(rg.ptr);
            if (failed) {
                napi_throw_error(env, "LOAD_FAILED", "cannot configure bundled ripgrep");
                return NULL;
            }
        }
    }
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
    if (g_api == NULL) {
        g_api = api;
    } else {
        int different = g_api != api;
        close_library(library);
        if (different) {
            napi_throw_error(env, "ABI_MISMATCH", "another AgentCore library is already loaded in this process");
            return NULL;
        }
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
    mcp_environment_t *owner = calloc(1, sizeof(*owner));
    if (!owner) { napi_throw_error(env, NULL, "out of memory"); return NULL; }
    atomic_init(&owner->refs, 1);
    atomic_init(&owner->stopping, false);
    if (napi_set_instance_data(env, owner, release_mcp_environment, NULL) != napi_ok) { free(owner); return NULL; }
    if (napi_add_env_cleanup_hook(env, stop_mcp_environment, owner) != napi_ok) return NULL;
    EXPORT("load", load_library);
    EXPORT("project", project_protocol);
    EXPORT("runtimeCreate", runtime_create);
    EXPORT("runtimeDestroy", runtime_destroy);
    EXPORT("mcpReply", mcp_reply);
    EXPORT("applyMcp", apply_mcp);
    EXPORT("describeMcp", describe_mcp);
    EXPORT("refreshMcp", refresh_mcp);
    EXPORT("updateMcpSelection", update_mcp_selection);
    EXPORT("describeTeam", describe_team);
    EXPORT("pollTeam", poll_team);
    EXPORT("resolveCatalog", resolve_catalog);
    EXPORT("releaseCatalog", release_catalog);
    EXPORT("bindPolicy", bind_policy);
    EXPORT("sessionCreate", session_create);
    EXPORT("sessionExport", session_export);
    EXPORT("sessionRun", session_run);
    EXPORT("sessionCompact", session_compact);
    EXPORT("sessionAbortCompact", session_abort_compact);
    EXPORT("sessionAbort", session_abort);
    EXPORT("sessionSubmit", session_submit);
    EXPORT("sessionUpdateCredential", session_update_credential);
    EXPORT("sessionDescribe", session_describe);
    EXPORT("getGoal", get_goal);
    EXPORT("setGoal", set_goal);
    EXPORT("updateGoal", update_goal);
    EXPORT("clearGoal", clear_goal);
    EXPORT("sessionSetPromptProfile", session_set_profile);
    EXPORT("sessionUpdatePermissionRules", session_update_rules);
    EXPORT("sessionSetModel", session_set_model);
    EXPORT("sessionSetPermissionMode", session_set_permission_mode);
    EXPORT("sessionRewindToUserMessage", session_rewind_to_user_message);
    EXPORT("sessionDestroy", session_destroy);
    EXPORT("completeCall", complete_call);
    EXPORT("lockPath", lock_file);
    EXPORT("unlockPath", unlock_file);
    napi_value revision;
    napi_create_uint32(env, METASK_AGENTCORE_ABI_REVISION, &revision);
    napi_set_named_property(env, exports, "abiRevision", revision);
    return exports;
}
