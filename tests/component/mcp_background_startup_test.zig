//! MCP startup covers headless registration, deferred joins, and authentication failures.

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");
const pfs = @import("platform").fs;
const ppaths = @import("platform").paths;
const psync = @import("platform").sync;
const process = @import("platform").process;

const REPLY_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const MOCK_MCP = "zig-out/bin/mock_mcp_server";
/// A tool the mock lists; it reaches the provider as `mcp__gate__echo`.
const GATE_TOOL = "mcp__gate__echo";
const PROMPT = "hello from the prompt\n";

const EnvGuard = struct {
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(name: [*:0]const u8, value: ?[*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try std.testing.allocator.dupeZ(u8, std.mem.span(raw)) else null;
        if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
        return .{ .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            std.testing.allocator.free(previous);
        } else ppaths.unsetEnv(self.name);
    }
};

/// A temporary HOME with the environment a test session needs (no catalog
/// probe, no TinyKG service, no host Codex configuration). Initialized in
/// place: the guards restore the environment in `deinit`.
const Workspace = struct {
    tmp: std.testing.TmpDir,
    root_buffer: [std.fs.max_path_bytes]u8,
    root: []const u8,
    guards: [4]EnvGuard,

    fn init(self: *Workspace) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const len = try self.tmp.dir.realPath(std.testing.io, &self.root_buffer);
        self.root = self.root_buffer[0..len];
        try self.tmp.dir.createDirPath(std.testing.io, ".metacodes");
        const home_z = try std.testing.allocator.dupeZ(u8, self.root);
        defer std.testing.allocator.free(home_z);
        self.guards = .{
            try EnvGuard.set("HOME", home_z.ptr),
            try EnvGuard.set("METACODES_NO_PROBE", "1"),
            try EnvGuard.set("METACODES_KG_AUTOSTART", "0"),
            try EnvGuard.set("CODEX_HOME", null),
        };
    }

    fn deinit(self: *Workspace) void {
        var i = self.guards.len;
        while (i > 0) {
            i -= 1;
            self.guards[i].restore();
        }
        self.tmp.cleanup();
    }

    fn path(self: *const Workspace, a: std.mem.Allocator, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ self.root, name }, 0);
    }

    fn writeConfig(self: *Workspace, servers_json: []const u8) !void {
        const a = std.testing.allocator;
        const config = try std.fmt.allocPrint(a, "{{\"mcpServers\":{s}}}", .{servers_json});
        defer a.free(config);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".metacodes/config.json", .data = config });
    }

    /// One stdio server, `gate`: a shell that writes its pid to `server.pid`,
    /// waits until `gate` exists in the workspace, then becomes the mock.
    fn writeGateServer(self: *Workspace) !void {
        const a = std.testing.allocator;
        var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = pfs.getCwd(&cwd_buffer) orelse return error.NoCwd;
        const servers = try std.fmt.allocPrint(
            a,
            "{{\"gate\":{{\"command\":\"/bin/sh\",\"args\":[\"-c\",\"echo $$ > '{s}/server.pid'; while [ ! -e '{s}/gate' ]; do sleep 0.01; done; exec '{s}/{s}'\"]}}}}",
            .{ self.root, self.root, cwd, MOCK_MCP },
        );
        defer a.free(servers);
        try self.writeConfig(servers);
    }

    fn openGate(self: *Workspace) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gate", .data = "" });
    }
};

/// An App as main.zig builds it, against `base_url`. Arena-backed, as the
/// REPL fixtures elsewhere: App-lifetime strings are not freed one by one.
const Session = struct {
    arena: std.heap.ArenaAllocator,
    io_rt: std.Io.Threaded,
    app: *cc.app_module.App,

    fn init(self: *Session, base_url: []const u8, mode: cc.types_mod.McpConnect, model: ?[]const u8) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        const url = try a.dupeZ(u8, base_url);
        var argv_buffer: [8][*:0]const u8 = undefined;
        var argv: std.ArrayList([*:0]const u8) = .initBuffer(&argv_buffer);
        argv.appendSliceAssumeCapacity(&.{ "metacodes", "--permission", "bypassPermissions", "--base-url", url.ptr });
        if (model) |m| argv.appendSliceAssumeCapacity(&.{ "--model", (try a.dupeZ(u8, m)).ptr });
        var config = cc.parseArgsForTest(argv.items, a);
        try std.testing.expect(config.parse_error == null);
        config.mcp_connect = mode;
        self.io_rt = @import("platform").signal.threadedIo(a, .{});
        errdefer self.io_rt.deinit();
        self.app = try cc.app_module.App.init(a, self.io_rt.io(), config, "test-key");
    }

    fn deinit(self: *Session) void {
        self.app.deinit();
        self.io_rt.deinit();
        self.arena.deinit();
    }
};

fn readPid(ws: *Workspace) !?i32 {
    var buffer: [32]u8 = undefined;
    const bytes = ws.tmp.dir.readFile(std.testing.io, "server.pid", &buffer) catch return null;
    return std.fmt.parseInt(i32, std.mem.trim(u8, bytes, " \n"), 10) catch null;
}

test "headless and every other frontend: App.init returns with every MCP server registered" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // /bin/sh gate
    if (!pfs.exists(MOCK_MCP)) return error.SkipZigTest;
    const a = std.testing.allocator;
    var ws: Workspace = undefined;
    try ws.init();
    defer ws.deinit();
    try ws.writeGateServer();
    try ws.openGate();

    var srv = try harness.MockServer.startCassette(&.{REPLY_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var session: Session = undefined;
    try session.init(url, .app_init, null);
    defer session.deinit();
    const app = session.app;
    try std.testing.expect(app.toolSurfaceReady());
    try std.testing.expectEqual(.connected, app.mcp_report.servers[0].state);

    const code = try cc.repl_headless.run(app, session.arena.allocator(), "hello headless", null, false, null);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
    try std.testing.expect(std.mem.indexOf(u8, srv.lastRequest().?.body(), GATE_TOOL) != null);
}

test "a model switch before the join is what the system prompt names, as after a synchronous start" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // /bin/sh gate
    if (!pfs.exists(MOCK_MCP)) return error.SkipZigTest;
    var ws: Workspace = undefined;
    try ws.init();
    defer ws.deinit();
    try ws.writeGateServer();
    const switched = "claude-opus-4-1-20250805";

    var background: Session = undefined;
    try background.init("http://127.0.0.1:1/v1/messages", .first_request, null);
    defer background.deinit();
    try std.testing.expect(!background.app.toolSurfaceReady());
    try background.app.switchModel(switched);
    try ws.openGate();
    try background.app.publishMcpServers();
    const deferred_prompt = background.app.system_prompt orelse return error.NoSystemPrompt;
    try std.testing.expect(std.mem.indexOf(u8, deferred_prompt, switched) != null);

    var synchronous: Session = undefined;
    try synchronous.init("http://127.0.0.1:1/v1/messages", .app_init, null);
    defer synchronous.deinit();
    try synchronous.app.switchModel(switched);
    try std.testing.expectEqualStrings(synchronous.app.system_prompt.?, deferred_prompt);
    try std.testing.expectEqual(synchronous.app.tool_defs.len, background.app.tool_defs.len);
}

test "leaving while an MCP server connects interrupts the handshake and reaps the server" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // kill(pid, 0)
    if (!pfs.exists(MOCK_MCP)) return error.SkipZigTest;
    var ws: Workspace = undefined;
    try ws.init();
    defer ws.deinit();
    try ws.writeGateServer(); // the gate never opens: the server never answers

    var session: Session = undefined;
    try session.init("http://127.0.0.1:1/v1/messages", .first_request, null);
    var waited: usize = 0;
    const pid = while (waited < 500) : (waited += 1) {
        if (try readPid(&ws)) |pid| break pid;
        psync.sleepMs(10);
    } else return error.ServerNeverStarted;
    try std.testing.expect(!session.app.mcpStartupSettled());

    const started = cc.util_time.nowMs();
    session.deinit();
    const elapsed_ms = cc.util_time.nowMs() - started;
    // The handshake polls its interrupt every 100 ms; without it the join
    // would wait out the 10 s probe bound and then the startup timeout.
    try std.testing.expect(elapsed_ms < 5_000);
    // Reaped, not orphaned.
    try std.testing.expect(std.c.kill(pid, @enumFromInt(0)) != 0);
}

test "an MCP server that answers 401 is reported as needing authentication" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // shebang mock
    const MOCK_HTTP = "tests/_harness/mock_mcp_http_server.py";
    if (std.c.access(MOCK_HTTP, 1) != 0) return error.SkipZigTest;
    const argv = [_]?[*:0]const u8{ MOCK_HTTP, null };
    var child = process.spawnPipes(&argv, true, null) catch return error.SkipZigTest;
    defer {
        child.closeStdin();
        child.closeStdout();
        child.terminate();
    }
    var port_buffer: [16]u8 = undefined;
    var length: usize = 0;
    while (length < port_buffer.len) {
        var byte: [1]u8 = undefined;
        if (!child.pollReadable(5000) or child.read(&byte) != 1 or byte[0] == '\n') break;
        port_buffer[length] = byte[0];
        length += 1;
    }
    const port = std.fmt.parseInt(u16, port_buffer[0..length], 10) catch return error.SkipZigTest;

    var ws: Workspace = undefined;
    try ws.init();
    defer ws.deinit();
    var servers_buffer: [160]u8 = undefined;
    try ws.writeConfig(try std.fmt.bufPrint(&servers_buffer, "{{\"locked\":{{\"type\":\"http\",\"url\":\"http://127.0.0.1:{d}/auth\"}}}}", .{port}));

    var session: Session = undefined;
    try session.init("http://127.0.0.1:1/v1/messages", .first_request, null);
    defer session.deinit();
    const app = session.app;
    var waited: usize = 0;
    while (!app.mcpStartupSettled() and waited < 1000) : (waited += 1) psync.sleepMs(10);
    try std.testing.expect(app.mcpStartupSettled());
    // The footer counts it before anything is published.
    var notice_buffer: [96]u8 = undefined;
    const notice = cc.app_mcp_startup.notice(app.mcp_status.snapshot(), &notice_buffer).?;
    try std.testing.expectEqualStrings("1 MCP server needs auth · /mcp", notice.text);
    try app.publishMcpServers();
    try std.testing.expectEqual(.needs_auth, app.mcp_report.servers[0].state);
    // Looking at /mcp (or starting a turn) retires the notice.
    app.mcp_status.acknowledged.store(true, .release);
    try std.testing.expect(cc.app_mcp_startup.notice(app.mcp_status.snapshot(), &notice_buffer) == null);
}
