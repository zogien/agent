//! L2: the CLI App persists an allow-always answer in its project settings.
const std = @import("std");
const cc = @import("cc");
const fixture = @import("../_harness/agent_session_fixture.zig");

const AllowAlways = fixture.AllowAlways(cc, cc.ui_request);
const subdir = fixture.subdir;
const existsUnder = fixture.existsUnder;

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

test "L2 App answers allow_always into the project settings file its loader reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var project_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project = try subdir(&tmp, "project", &project_buf);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try subdir(&tmp, "home", &home_buf);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var home_guard = try EnvGuard.set(std.testing.allocator, "HOME", (try allocator.dupeZ(u8, home)).ptr);
    defer home_guard.restore();
    var probe_guard = try EnvGuard.set(std.testing.allocator, "METACODES_NO_PROBE", "1");
    defer probe_guard.restore();

    const argv = [_][*:0]const u8{"metacodes"};
    const config = cc.parseArgsForTest(&argv, allocator);
    try std.testing.expect(config.parse_error == null);
    var io_rt = @import("platform").signal.threadedIo(allocator, .{});
    defer io_rt.deinit();
    const app = try cc.app_module.App.init(allocator, io_rt.io(), config, "test-key");
    defer app.deinit();

    // The App opted in; point its project at the scratch directory instead of
    // the test process cwd before answering a prompt through the real path.
    try std.testing.expectEqual(cc.permission.AlwaysAllowScope.settings_file, app.permission_ctx.always_allow);
    app.permission_ctx.match_ctx.project_root = project;
    var ui = AllowAlways{};
    app.permission_ctx.ui_requester = ui.requester();
    try std.testing.expect(try cc.permission.promptUser(&app.permission_ctx, "Write", "{\"file_path\":\"x\"}"));
    try std.testing.expectEqual(@as(usize, 1), ui.prompts);
    try std.testing.expect(app.session_rules.isAllowed("Write"));
    try std.testing.expect(try existsUnder(project, ".claude/settings.local.json"));
}
