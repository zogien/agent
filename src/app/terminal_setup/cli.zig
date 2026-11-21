//! Restore key bindings installed by a previous version of metacodes.

const std = @import("std");
const pfs = @import("platform").fs;
const util_fs = @import("../../util/fs.zig");
const util_time = @import("../../util/time.zig");
const setup = @import("setup.zig");
const vscode = @import("vscode.zig");
const apple = @import("apple_terminal.zig");

pub const usage =
    \\usage: metacodes terminal-setup --restore
    \\           [--terminal apple-terminal|vscode|vscode-insiders|cursor|windsurf|vscodium]
    \\           [--keybindings <keybindings.json>]
    \\
    \\Restores all recorded key bindings, or only the selected terminal or file.
    \\
;

fn stdoutWrite(bytes: []const u8) void {
    _ = pfs.writeAll(1, bytes);
}

/// `--terminal <name>` as a target.
fn parseTerminal(name: []const u8) ?setup.Target {
    const table = [_]struct { []const u8, setup.Target }{
        .{ "apple-terminal", .apple_terminal },
        .{ "vscode", .{ .vscode = vscode.vscode } },
        .{ "vscode-insiders", .{ .vscode = vscode.vscode_insiders } },
        .{ "cursor", .{ .vscode = vscode.cursor } },
        .{ "windsurf", .{ .vscode = vscode.windsurf } },
        .{ "vscodium", .{ .vscode = vscode.vscodium } },
    };
    for (table) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    return null;
}

pub const Parsed = union(enum) {
    run: setup.Request,
    help,
    usage_error: []const u8,
};

pub fn parse(arena: std.mem.Allocator, args: []const []const u8) error{OutOfMemory}!Parsed {
    var req: setup.Request = .{ .action = .restore };
    var restore_requested = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .help;
        if (std.mem.eql(u8, arg, "--restore")) {
            restore_requested = true;
        } else if (std.mem.eql(u8, arg, "--terminal")) {
            i += 1;
            if (i == args.len) return .{ .usage_error = "--terminal needs a name" };
            if (req.target != null) return .{ .usage_error = "name one terminal: --terminal or --keybindings" };
            req.target = parseTerminal(args[i]) orelse return .{ .usage_error = try std.fmt.allocPrint(arena, "unknown terminal '{s}'", .{args[i]}) };
        } else if (std.mem.eql(u8, arg, "--keybindings")) {
            i += 1;
            if (i == args.len) return .{ .usage_error = "--keybindings needs a file" };
            if (req.target != null) return .{ .usage_error = "name one terminal: --terminal or --keybindings" };
            req.target = .{ .keybindings = args[i] };
        } else {
            return .{ .usage_error = try std.fmt.allocPrint(arena, "unknown terminal-setup argument '{s}'", .{arg}) };
        }
    }
    if (!restore_requested) return .{ .usage_error = "terminal-setup requires --restore" };
    return .{ .run = req };
}

/// Return 0 on restoration or when nothing is recorded, 1 on failure, and 2 on usage errors.
pub fn run(args: *std.process.Args.Iterator, gpa: std.mem.Allocator, io: std.Io, state_root: []const u8) u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var list: std.ArrayList([]const u8) = .empty;
    while (args.next()) |arg| list.append(arena, arg) catch return 1;
    const parsed = parse(arena, list.items) catch return 1;
    var req = switch (parsed) {
        .help => {
            stdoutWrite(usage);
            return 0;
        },
        .usage_error => |why| {
            std.debug.print("error: {s}\n{s}", .{ why, usage });
            return 2;
        },
        .run => |r| r,
    };
    if (req.target) |t| if (t == .keybindings and !std.fs.path.isAbsolute(t.keybindings)) {
        const cwd = util_fs.getCwd(arena) catch {
            std.debug.print("error: cannot read the current directory to resolve {s}\n", .{t.keybindings});
            return 1;
        };
        req.target = .{ .keybindings = std.fs.path.join(arena, &.{ cwd, t.keybindings }) catch return 1 };
    };
    const env = setup.Env.fromProcess(arena) catch return 1;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const report = setup.run(gpa, .{
        .env = env,
        .state_root = state_root,
        .now_unix = util_time.nowUnix(),
        .terminal_pid = apple.runningTerminalPid(arena, io),
    }, req, &out.writer);
    stdoutWrite(out.written());
    return switch (report.outcome) {
        .changed, .unchanged => 0,
        .refused, .failed => 1,
    };
}

const testing = std.testing;

test "parse: actions, targets, and what is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect(try parse(arena, &.{}) == .usage_error);
    try testing.expect(try parse(arena, &.{"--dry-run"}) == .usage_error);
    const all = try parse(arena, &.{"--restore"});
    try testing.expectEqual(setup.Action.restore, all.run.action);
    try testing.expect(all.run.target == null);
    const undo = try parse(arena, &.{ "--restore", "--terminal", "apple-terminal" });
    try testing.expectEqual(setup.Action.restore, undo.run.action);
    try testing.expect(undo.run.target.? == .apple_terminal);
    try testing.expectEqualStrings("k.json", (try parse(arena, &.{ "--restore", "--keybindings", "k.json" })).run.target.?.keybindings);
    try testing.expect(try parse(arena, &.{"-h"}) == .help);
    try testing.expect(try parse(arena, &.{ "--dry-run", "--restore" }) == .usage_error);
    try testing.expect(try parse(arena, &.{ "--terminal", "kitty" }) == .usage_error);
    try testing.expect(try parse(arena, &.{"--terminal"}) == .usage_error);
    try testing.expect(try parse(arena, &.{ "--terminal", "vscode", "--keybindings", "k.json" }) == .usage_error);
    try testing.expect(try parse(arena, &.{"--yes"}) == .usage_error);
}
