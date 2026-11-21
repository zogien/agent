//! L2 coverage for goal accounting through the headless host.

const std = @import("std");
const cc = @import("cc");
const harness = @import("harness");
const ppaths = @import("platform").paths;

const EnvGuard = struct {
    allocator: std.mem.Allocator,
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(allocator: std.mem.Allocator, name: [*:0]const u8, value: [*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try allocator.dupeZ(u8, std.mem.span(raw)) else null;
        ppaths.setEnv(name, value);
        return .{ .allocator = allocator, .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            self.allocator.free(previous);
        } else {
            ppaths.unsetEnv(self.name);
        }
        self.* = undefined;
    }
};

/// 真 App fixture(对齐 plugin_runtime_test 惯例):tmp HOME + NO_PROBE,arena 生命周期。
const AppFixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    io_rt: std.Io.Threaded,
    home_guard: EnvGuard,
    probe_guard: EnvGuard,
    app: *cc.app_module.App,

    /// **in-place** 初始化(self 必须是 caller 栈上的最终地址):arena.allocator()/io_rt.io()
    /// 捕获 &self.arena/&self.io_rt——按值返回会悬垂(App 持着搬走前的旧地址)。
    fn setup(self: *AppFixture) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = try self.tmp.dir.realPath(std.testing.io, &root_buffer);
        const root = root_buffer[0..len];

        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer self.arena.deinit();
        const allocator = self.arena.allocator();

        const home_z = try allocator.dupeZ(u8, root);
        self.home_guard = try EnvGuard.set(std.testing.allocator, "HOME", home_z.ptr);
        errdefer self.home_guard.restore();
        self.probe_guard = try EnvGuard.set(std.testing.allocator, "METACODES_NO_PROBE", "1");
        errdefer self.probe_guard.restore();

        const argv = [_][*:0]const u8{ "metacodes", "--permission", "bypassPermissions" };
        const config = cc.parseArgsForTest(&argv, allocator);
        try std.testing.expect(config.parse_error == null);

        self.io_rt = @import("platform").signal.threadedIo(allocator, .{});
        errdefer self.io_rt.deinit();
        self.app = try cc.app_module.App.init(allocator, self.io_rt.io(), config, "test-key");
    }

    fn deinit(self: *AppFixture) void {
        self.app.deinit();
        self.io_rt.deinit();
        self.probe_guard.restore();
        self.home_guard.restore();
        self.arena.deinit();
        self.tmp.cleanup();
    }
};

const GOAL_FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":7,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

test "L2 goal (issue #277): every CLI Run charges the App's goal and goal.json follows" {
    const a = std.testing.allocator;
    var fx: AppFixture = undefined;
    try fx.setup();
    defer fx.deinit();
    const app = fx.app;
    const meter = if (app.goal_meter) |*m| m else return error.MissingGoalMeter;

    const headless = cc.repl_headless.buildOptions(app, null, null, null, false, null, null, null);
    try std.testing.expect(headless.goal_meter == meter);
    try std.testing.expect(headless.time_announcer != null);

    try app.goal_state.setNew("ship it", null);
    app.persistGoal();
    var srv = try harness.MockServer.startCassette(&.{GOAL_FINAL_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    // The Run's records join the App's Conversation.
    var client = cc.client_mod.Client.initWithBaseUrl(app.allocator, fx.io_rt.io(), "key", "model", url);
    defer client.deinit();
    try app.conversation.appendText(.user, "work on the goal");
    var render = cc.writer_backend.WriterBackend.initNull();
    const be = render.backend();
    var options = headless;
    options.max_turns = 1;
    const result = try cc.agent_loop.run(&app.conversation, client.provider(), &.{}, &app.permission_ctx, options, &be, app.allocator);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    const charged = app.goal_state.current.?.tokens_used;
    try std.testing.expect(charged > 0);

    // The Meter's observer wrote goal.json when the Run settled.
    var loaded = cc.core_goal.State.init(a);
    defer loaded.deinit();
    try loaded.loadFromDir(app.sessionDir() orelse return error.NoSessionDir);
    try std.testing.expectEqual(charged, loaded.current.?.tokens_used);
}
