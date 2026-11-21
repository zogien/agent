//! L2 for #485 and #499 part 2: `/login` and `/logout` switch a session
//! between the Metask account and local configuration, and signing out
//! leaves no Metask credential behind.
//!
//! In process, on a real `App`, against MockServers standing in for the
//! Metask gateway and for a relay `config.json` defines (the provider
//! `.env` configures):
//! - `bindMetaskSession` (what `/login` does once the Metask session is
//!   stored and a model and reasoning level are chosen, #527) moves the
//!   session, unbound or not, onto the sign-in: the next turn reaches the
//!   gateway the session names with the session's access token and that
//!   model;
//! - `signOutOfMetask` (`/logout`) removes both Metask sign-ins, moves a
//!   session on Metask to the `.env` provider, and never sends the Metask key
//!   again; with no `.env` provider the session is unbound and nothing is
//!   sent at all;
//! - `forgetProviderKey` (`/logout <provider>`) removes the stored key and
//!   leaves a session that ran on it without a credential;
//! - `adoptProviderLogin` (`/login <provider>` once it stored a key or a
//!   sign-in, #566) moves a session running on that provider onto it, on the
//!   same route, and leaves any other session where it is;
//! - `applyMetaskSession` (`/login`) revokes the session it replaced, once
//!   the new one is stored and bound, and never when it fails (#560).
//!
//! Through the real CLI (`METACODES_TEST_CLI_BIN`):
//! - `metacodes logout` removes both sign-ins and a Metask default, says
//!   which, and the next start falls back to `.env` instead of failing;
//! - `metacodes login --provider metask` revokes the session it replaced
//!   (#560);
//! - a plain start with only the Metask session signs in with it, at the
//!   gateway it names (#499, #527);
//! - a stored default whose provider has no key is passed over with one
//!   warning (level 2), and is used when it has one;
//! - `--provider` naming a provider without a key stops `-p` with its help.

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("metacodes-core").test_support;
const ppaths = @import("platform").paths;

const testing = std.testing;
const METASK_KEY = "sk-metask-login-key";
const RELAY_KEY = "sk-relay-env-key";
const RELAY_ENV = "HOUSE_RELAY_TOKEN";

const ANTHROPIC_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";
const OPENAI_SSE =
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}\n\n" ++
    "data: [DONE]\n\n";
const GATEWAY_MODELS = "{\"object\":\"list\",\"data\":[{\"id\":\"glm-5\",\"max_input_tokens\":200000,\"max_tokens\":32000},{\"id\":\"glm-5-air\",\"max_input_tokens\":128000,\"max_tokens\":16000}]}";
/// The access tokens of the Metask sessions `/login` stores (#527).
const SESSION_TOKEN = "at-metask-session-one";
const NEW_SESSION_TOKEN = "at-metask-session-two";

/// Sets (or unsets, with null) one variable and puts the old value back.
const EnvGuard = struct {
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(name: [*:0]const u8, value: ?[*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try testing.allocator.dupeZ(u8, std.mem.span(raw)) else null;
        if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
        return .{ .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            testing.allocator.free(previous);
        } else {
            ppaths.unsetEnv(self.name);
        }
    }
};

const cleared = [_][*:0]const u8{
    "METASK_API_KEY",      "OPENAI_API_KEY",           "GEMINI_API_KEY",        "GOOGLE_API_KEY",
    "ZAI_API_KEY",         "GLM_API_KEY",              "Z_AI_API_KEY",          "DEEPSEEK_API_KEY",
    "KIMI_API_KEY",        "MOONSHOT_API_KEY",         "KIMI_CODE_API_KEY",     "DASHSCOPE_API_KEY",
    "MINIMAX_API_KEY",     "AWS_BEARER_TOKEN_BEDROCK", "METACODES_PROVIDER",    "METACODES_MODEL",
    "METACODES_BASE_URL",  "METASK_GATEWAY_URL",       "METACODES_CONFIG_FILE", "METACODES_AUTH_FILE",
    "METACODES_OAUTH_DIR", "METASK_SITE_URL",          "OPENROUTER_API_KEY",    RELAY_ENV,
};

/// A state root, a working directory and a home; keys cleared, no probe, no
/// TinyKG start, no advisor.
const Case = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    state: []const u8,
    work: []const u8,
    home: []const u8,
    guards: [cleared.len + 6]EnvGuard = undefined,
    count: usize = 0,

    fn init(self: *Case) !void {
        self.arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer self.arena_state.deinit();
        const a = self.arena_state.allocator();
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.count = 0;
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root = try a.dupe(u8, root_buf[0..try self.tmp.dir.realPath(testing.io, &root_buf)]);
        for ([_][]const u8{ "state", "state/oauth", "work", "home" }) |dir| try self.tmp.dir.createDirPath(testing.io, dir);
        self.state = try std.fs.path.join(a, &.{ root, "state" });
        self.work = try std.fs.path.join(a, &.{ root, "work" });
        self.home = try std.fs.path.join(a, &.{ root, "home" });
    }

    fn enter(self: *Case) !void {
        const a = self.arena_state.allocator();
        for (cleared) |name| try self.guard(name, null);
        try self.guard("HOME", (try a.dupeZ(u8, self.home)).ptr);
        try self.guard("METACODES_HOME", (try a.dupeZ(u8, self.state)).ptr);
        try self.guard("METACODES_NO_PROBE", "1");
        try self.guard("METACODES_KG_AUTOSTART", "0");
        try self.guard("METACODES_JEV_URL", "off");
        // Sign-out revokes a stored session at the server (#527): a dead
        // port, never Metask's, unless a case points it at its own mock.
        try self.guard("METASK_SITE_URL", "http://127.0.0.1:9");
    }

    fn guard(self: *Case, name: [*:0]const u8, value: ?[*:0]const u8) !void {
        for (self.guards[0..self.count]) |*existing| {
            if (std.mem.orderZ(u8, existing.name, name) == .eq) {
                if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
                return;
            }
        }
        self.guards[self.count] = try EnvGuard.set(name, value);
        self.count += 1;
    }

    fn deinit(self: *Case) void {
        while (self.count > 0) {
            self.count -= 1;
            self.guards[self.count].restore();
        }
        self.tmp.cleanup();
        self.arena_state.deinit();
    }

    fn arena(self: *Case) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn write(self: *Case, sub_path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
    }

    fn exists(self: *Case, sub_path: []const u8) bool {
        self.tmp.dir.access(testing.io, sub_path, .{}) catch return false;
        return true;
    }

    /// The auth.json `metacodes login` leaves.
    fn writeSignedIn(self: *Case) !void {
        try self.write("state/auth.json", try std.fmt.allocPrint(self.arena(),
            \\{{"api_key":"{s}","oauth":{{"access_token":"at-login","refresh_token":"rt-login","token_type":"Bearer","expires_at":{d}}},"selected_model":"glm-5","reasoning_effort":"low"}}
        , .{ METASK_KEY, cc.util_time.nowUnix() + 86_400 }));
        const path = try std.fs.path.joinZ(self.arena(), &.{ self.state, "auth.json" });
        _ = @import("platform").fs.chmod(path.ptr, 0o600);
    }

    /// The Metask session `/login` stores (#527): a token response naming
    /// the gateway at `origin`, imported as `/login` imports it.
    fn tokenJson(self: *Case, origin: []const u8, access: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.arena(),
            \\{{"access_token":"{s}","refresh_token":"mrt-{s}","token_type":"bearer","expires_in":3600,"gateway_url":"{s}","models_url":"{s}/v1/models","scope":"read model:invoke"}}
        , .{ access, access, origin, origin });
    }

    fn storeSession(self: *Case, origin: []const u8, access: []const u8) !void {
        const token_json = try self.tokenJson(origin, access);
        try cc.api_provider_login.importTokenResponse(testing.allocator, self.state, cc.provider_ids.Slug.lit("metask"), token_json, null, null);
    }
};

fn originOf(a: std.mem.Allocator, server: *harness.MockServer) ![]const u8 {
    const url = try server.urlOwned(a);
    return url[0 .. url.len - "/v1/messages".len];
}

fn relayConfig(a: std.mem.Allocator, origin: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\{{"custom_providers": {{"house-relay": {{
        \\  "display_name": "House relay",
        \\  "credential_kinds": ["api_key"],
        \\  "env_aliases": [{{"name": "{s}", "kind": "api_key", "canonical": true}}],
        \\  "channels": [{{"id": "primary", "base_url": "{s}/relay/v1", "protocol": "openai_chat"}}],
        \\  "models": [{{"request_model_id": "relay-model", "display_name": "Relay model"}}]}}}}}}
    , .{ RELAY_ENV, origin });
}

fn requestLine(captured: harness.CapturedRequest) []const u8 {
    const end = std.mem.indexOf(u8, captured.raw, "\r\n") orelse captured.raw.len;
    return captured.raw[0..end];
}

fn headerValue(captured: harness.CapturedRequest, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, captured.raw, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find `{s}` in:\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedResult;
    }
}

fn expectAbsent(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("`{s}` must not appear in:\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedResult;
    }
}

/// No request `server` received carries `secret`.
fn expectNeverSent(server: *harness.MockServer, secret: []const u8) !void {
    for (0..server.requestCount()) |index| {
        const captured = server.requestAt(index) orelse continue;
        if (std.mem.indexOf(u8, captured.raw, secret) != null) {
            std.debug.print("{s} was sent: {s}\n", .{ secret, requestLine(captured) });
            return error.CredentialStillSent;
        }
    }
}

/// The rendered offer id of `provider`'s offer for `model` on `protocol`.
const THIRD_SESSION_TOKEN = "at-metask-session-three";

/// The fake site's answer to a device-code request: the code is confirmed
/// at once, so the first poll gets the token response.
const DEVICE_GRANT = "{\"device_code\":\"dev-560\",\"user_code\":\"CODE-560\",\"verification_uri\":\"http://127.0.0.1:9/device\",\"expires_in\":60,\"interval\":1}";

const ReplacedOutcome = cc.api_metask_oauth.ReplacedOutcome;

/// The refresh token of the Metask session stored now.
fn storedRefreshToken(case: *Case) ![]const u8 {
    var session = try cc.provider_oauth.Session.initHome(testing.allocator, case.state, cc.provider_ids.Slug.lit("metask"));
    defer session.deinit();
    if (!try session.load()) return error.NoSessionStored;
    return case.arena().dupe(u8, session.tokens.?.refresh_token);
}

/// How many requests `server` received whose request line starts so.
fn countRequests(server: *harness.MockServer, line_prefix: []const u8) usize {
    var count: usize = 0;
    for (0..server.requestCount()) |index| {
        const captured = server.requestAt(index) orelse continue;
        if (std.mem.startsWith(u8, requestLine(captured), line_prefix)) count += 1;
    }
    return count;
}

/// Request `index` is a revocation of the session whose access token is
/// `access`: its refresh token, as the metacodes client, and nothing else.
fn expectRevocationOf(server: *harness.MockServer, index: usize, comptime access: []const u8) !void {
    const captured = server.requestAt(index) orelse return error.NoRequestCaptured;
    try testing.expect(std.mem.startsWith(u8, requestLine(captured), "POST /api/oauth/revoke "));
    try testing.expectEqualStrings("token=mrt-" ++ access ++ "&token_type_hint=refresh_token&client_id=metacodes", captured.body());
    try expectAbsent(captured.raw, "Bearer");
}

test "/login metask outside the dialog revokes the session it replaced and says so where it reports (#560)" {
    var case: Case = undefined;
    try case.init();
    defer case.deinit();
    try case.enter();
    const a = case.arena();
    var replies = [_][]const u8{ DEVICE_GRANT, "", "" };
    var site = try harness.MockServer.startCassette(&replies, 0);
    defer site.stop();
    const origin = try originOf(a, site);
    replies[1] = try case.tokenJson(origin, NEW_SESSION_TOKEN);
    try case.guard("METASK_SITE_URL", (try a.dupeZ(u8, origin)).ptr);
    try case.storeSession(origin, SESSION_TOKEN);
    var io_runtime = @import("platform").signal.threadedIo(testing.allocator, .{});
    defer io_runtime.deinit();

    // The line-mode REPL's `/login metask`, and the login list's Metask
    // entry, run this flow; it says what it did through its sink.
    var said: std.Io.Writer.Allocating = .init(testing.allocator);
    defer said.deinit();
    const Sink = struct {
        fn write(ctx: *anyopaque, text: []const u8) void {
            const out: *std.Io.Writer.Allocating = @ptrCast(@alignCast(ctx));
            out.writer.writeAll(text) catch {};
        }
    };
    const prepared: cc.api_provider_login.MetaskPrepared = .{ .options = .{ .state_root = case.state, .open_browser = false } };
    const outcome = try prepared.run(testing.allocator, io_runtime.io(), .{ .ctx = &said, .write = Sink.write }, null);
    try testing.expect(outcome.provider_id.eqlText("metask"));
    try testing.expectEqualStrings("mrt-" ++ NEW_SESSION_TOKEN, try storedRefreshToken(&case));
    try testing.expectEqual(@as(usize, 3), site.requestCount());
    try testing.expect(std.mem.startsWith(u8, requestLine(site.requestAt(1).?), "POST /api/oauth/token "));
    try expectRevocationOf(site, 2, SESSION_TOKEN);
    try expectContains(said.written(), "Metask revoked the previous sign-in.\n");
}

/// A `/v1/models` answer of another account: no glm-5-air.
const OTHER_GATEWAY_MODELS = "{\"object\":\"list\",\"data\":[{\"id\":\"glm-5\",\"max_input_tokens\":200000,\"max_tokens\":32000},{\"id\":\"glm-6\",\"max_input_tokens\":200000,\"max_tokens\":32000}]}";

const Run = struct {
    exit_code: i32,
    stderr: []const u8,
};

fn runCli(case: *Case, cli: []const u8, env: []const []const u8, args: []const []const u8) !Run {
    const a = case.arena();
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    const base = [_][]const u8{
        "/usr/bin/env",
        try std.fmt.allocPrint(a, "HOME={s}", .{case.home}),
        "PATH=/usr/bin:/bin",
        "METACODES_KG_AUTOSTART=0",
        "METACODES_JEV_URL=off",
        "METACODES_NO_PROBE=1",
        // Sign-out revokes a stored session at the server (#527): a dead
        // port, never Metask's, unless a case points it at its own mock.
        "METASK_SITE_URL=http://127.0.0.1:9",
    };
    for (base) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
    for (env) |assignment| try argv.append(a, (try a.dupeZ(u8, assignment)).ptr);
    for ([_][]const u8{ cli, "--state-dir", case.state }) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
    for (args) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
    try argv.append(a, null);
    const out = try cc.tools_common.spawnCaptureWithStderrTimed(argv.items, a, null, 60_000, null, cc.tools_common.MAX_SPAWN_CAPTURE_BYTES, case.work);
    return .{ .exit_code = out.exit_code, .stderr = out.stderr };
}
