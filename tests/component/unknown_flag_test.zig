//! Unknown CLI arguments and out-of-vocabulary flag VALUES must be rejected,
//! never silently ignored or silently defaulted.
//!
//! Harness review 2026-08-17 finding #1 (and re-review #3): the arg loop had
//! no terminal else, so `metacodes --definitely-not-a-real-flag --help`
//! exited 0, and value flags swallowed bad values (`--permission BOGUS`
//! silently landed in .default) — either way a paid evaluation arm degrades
//! to control while the launch contract records configured:true. The flag
//! surface is an external contract; skew must fail closed (声明=接线=测试).

const std = @import("std");
const cc = @import("cc");

fn parseErr(config: anytype, needle: []const u8) !void {
    try std.testing.expect(config.parse_error != null);
    try std.testing.expect(std.mem.indexOf(u8, config.parse_error.?, needle) != null);
}

fn freeErr(a: std.mem.Allocator, config: anytype) void {
    if (config.parse_error) |e| a.free(e);
}

test "unknown --flag is rejected with a message naming it" {
    const a = std.testing.allocator;
    const argv = [_][*:0]const u8{ "metacodes", "--definitely-not-a-real-flag" };
    const config = cc.parseArgsForTest(&argv, a);
    defer freeErr(a, config);
    try parseErr(config, "unknown flag '--definitely-not-a-real-flag'");
}

test "unknown positional word is rejected too" {
    const a = std.testing.allocator;
    const argv = [_][*:0]const u8{ "metacodes", "strayword" };
    const config = cc.parseArgsForTest(&argv, a);
    defer freeErr(a, config);
    try parseErr(config, "unexpected positional argument 'strayword'");
}

test "parse stops at the first unknown argument" {
    const a = std.testing.allocator;
    // --verbose comes AFTER the bad flag: parsing must have stopped, so it
    // stays false and the recorded offender is the first unknown arg.
    const argv = [_][*:0]const u8{ "metacodes", "--bogus", "--verbose" };
    const config = cc.parseArgsForTest(&argv, a);
    defer freeErr(a, config);
    try parseErr(config, "'--bogus'");
    try std.testing.expect(!config.verbose);
}

test "--version parses cleanly and requests the version exit path" {
    const a = std.testing.allocator;
    const argv = [_][*:0]const u8{ "metacodes", "--version" };
    const config = cc.parseArgsForTest(&argv, a);
    defer freeErr(a, config);
    try std.testing.expect(config.parse_error == null);
    try std.testing.expect(config.show_version);
}

test "every known evaluation treatment flag still parses cleanly" {
    const a = std.testing.allocator;
    // The exact boolean flag set the WorkBuddy overlay passes
    // (metacodes_agent.py). A Zig-side rename fails here, not in a paid run.
    const argv = [_][*:0]const u8{
        "metacodes",
        "--verification-checkpoint",
        "--verification-final-gate",
        "--verification-final-observe",
        "--requirement-ledger",
        "--requirement-ledger-observe",
        "--no-theme",
    };
    const config = cc.parseArgsForTest(&argv, a);
    defer freeErr(a, config);
    try std.testing.expect(config.parse_error == null);
    try std.testing.expect(config.verification_final_gate);
    try std.testing.expect(config.requirement_ledger);
}

test "every overlay VALUE flag parses with a legitimate value" {
    const a = std.testing.allocator;
    // The value flags metacodes_agent.py emits: --model, --model-display-name,
    // --permission, --disallowed-tools, --max-tokens, --reasoning-effort. Pins
    // vocabulary AND that the strict value parsing accepts the exact values the
    // overlay sends. (`-`, the stdin prompt, is read during parsing; the
    // adapter's L2 runs it against the installed binary instead.)
    const argv = [_][*:0]const u8{
        "metacodes",
        "--model",
        "glm-5.2",
        "--model-display-name",
        "glm-5.2",
        "--permission",
        "bypassPermissions",
        "--disallowed-tools",
        "WebFetch,WebSearch",
        "--max-tokens",
        "32768",
        "--reasoning-effort",
        "high",
    };
    const config = cc.parseArgsForTest(&argv, a);
    try std.testing.expect(config.parse_error == null);
    try std.testing.expectEqual(@as(?u32, 32768), config.max_tokens);
    try std.testing.expectEqual(@as(?cc.types_mod.ReasoningEffort, .high), config.reasoning_effort);
    try std.testing.expectEqual(cc.types_mod.PermissionMode.bypass_permissions, config.permission_mode);
    a.free(config.model);
    a.free(config.model_display_name.?);
    a.free(config.disallowed_tools.?);
}

test "out-of-vocabulary flag values fail closed" {
    const a = std.testing.allocator;
    const cases = [_]struct { argv: [3][*:0]const u8, needle: []const u8 }{
        .{ .argv = .{ "metacodes", "--permission", "TOTALLY-BOGUS" }, .needle = "invalid permission mode 'TOTALLY-BOGUS'" },
        .{ .argv = .{ "metacodes", "--max-tokens", "notanumber" }, .needle = "invalid value 'notanumber' for --max-tokens" },
        .{ .argv = .{ "metacodes", "--reasoning-effort", "bogus" }, .needle = "invalid value 'bogus'" },
        .{ .argv = .{ "metacodes", "--teammate-mode", "bogus" }, .needle = "invalid value 'bogus' for --teammate-mode" },
        .{ .argv = .{ "metacodes", "--temperature", "warm" }, .needle = "invalid value 'warm' for --temperature" },
        .{ .argv = .{ "metacodes", "--web", "70000" }, .needle = "invalid port '70000'" },
    };
    for (cases) |case| {
        const config = cc.parseArgsForTest(&case.argv, a);
        defer freeErr(a, config);
        try parseErr(config, case.needle);
    }
}

test "missing value for a value-required flag fails closed" {
    const a = std.testing.allocator;
    const argv = [_][*:0]const u8{ "metacodes", "--max-tokens" };
    const config = cc.parseArgsForTest(&argv, a);
    defer freeErr(a, config);
    try parseErr(config, "missing value for --max-tokens");
}

test "teammate-mode accepts its documented vocabulary" {
    const a = std.testing.allocator;
    const process_argv = [_][*:0]const u8{ "metacodes", "--teammate-mode", "process" };
    var config = cc.parseArgsForTest(&process_argv, a);
    try std.testing.expect(config.parse_error == null);
    try std.testing.expect(config.teammate_out_of_process);
    // "thread" is the in-process name documented in --help.
    const thread_argv = [_][*:0]const u8{ "metacodes", "--teammate-mode", "thread" };
    config = cc.parseArgsForTest(&thread_argv, a);
    try std.testing.expect(config.parse_error == null);
    try std.testing.expect(!config.teammate_out_of_process);
}

test "in-range optional web port still parses" {
    const a = std.testing.allocator;
    const argv = [_][*:0]const u8{ "metacodes", "--web", "8080" };
    const config = cc.parseArgsForTest(&argv, a);
    try std.testing.expect(config.parse_error == null);
    try std.testing.expectEqual(@as(?u16, 8080), config.web_port);
}

test "U8: --resume-response 解析进 config.resume_response(内联 + @file)" {
    const a = std.testing.allocator;
    {
        // 内联 JSON 直接进 config。
        const argv = [_][*:0]const u8{ "metacodes", "--resume-response", "{\"choice\":\"Red\"}" };
        const cfg = cc.parseArgsForTest(&argv, a);
        defer if (cfg.resume_response) |r| a.free(r); // owned dupe,须释放(否则泄漏)
        try std.testing.expect(cfg.resume_response != null);
        try std.testing.expectEqualStrings("{\"choice\":\"Red\"}", cfg.resume_response.?);
    }
    {
        // @file:从文件读。写临时文件后解析。
        // 文件 IO 走 platform.fs + 路径走 paths.tempDir:std.c.open 的 `O` 在 Windows 是 void
        // (编不过),"/tmp" 在 Windows 不存在。所有测试模块现已接 platform dep(build.zig)。
        const ppaths = @import("platform").paths;
        const pfs = @import("platform").fs;
        var pbuf: [512]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&pbuf, "{s}/cc-zig-u8-resume-resp.json", .{ppaths.tempDir()});
        const fd = try pfs.openZ(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
        const content = "{\"answer\":42}";
        _ = pfs.write(fd, content);
        pfs.close(fd);
        defer @import("platform").fs.unlinkPath(path.ptr) catch {};
        var argbuf: [600]u8 = undefined;
        const at_arg = try std.fmt.bufPrintZ(&argbuf, "@{s}", .{path});
        const argv = [_][*:0]const u8{ "metacodes", "--resume-response", at_arg.ptr };
        const cfg = cc.parseArgsForTest(&argv, a);
        defer if (cfg.resume_response) |r| a.free(r); // owned(readFileAll dupe),须释放
        try std.testing.expect(cfg.resume_response != null);
        try std.testing.expectEqualStrings(content, cfg.resume_response.?);
    }
    {
        // 无 flag → null(不启用 resume)。
        const argv = [_][*:0]const u8{"metacodes"};
        try std.testing.expectEqual(@as(?[]const u8, null), cc.parseArgsForTest(&argv, a).resume_response);
    }
}

test "argv0 alone yields a clean default config" {
    const a = std.testing.allocator;
    const argv = [_][*:0]const u8{"metacodes"};
    const config = cc.parseArgsForTest(&argv, a);
    try std.testing.expect(config.parse_error == null);
}

test "--image collects repeatable paths with -p (issue #10 flag wiring)" {
    // arena:appendNulList 累加时丢弃旧串不回收(parse 是进程一次性路径),
    // 逐项 free 抓不全,用 arena 整体回收。
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = [_][*:0]const u8{ "metacodes", "--image", "a.png", "--image", "b.jpg", "-p", "hi" };
    const config = cc.parseArgsForTest(&argv, a);
    try std.testing.expect(config.parse_error == null);
    // \x00 分隔累加(appendNulList 约定),顺序保持。
    try std.testing.expectEqualStrings("a.png\x00b.jpg", config.images.?);
    try std.testing.expectEqualStrings("hi", config.prompt.?);
}

test "--image without a value is rejected" {
    const a = std.testing.allocator;
    const argv = [_][*:0]const u8{ "metacodes", "--image" };
    const config = cc.parseArgsForTest(&argv, a);
    defer freeErr(a, config);
    try parseErr(config, "missing value for --image");
}

test "--image without -p/--print fails closed (no silent drop into TUI/serve)" {
    const a = std.testing.allocator;
    const argv = [_][*:0]const u8{ "metacodes", "--image", "a.png" };
    const config = cc.parseArgsForTest(&argv, a);
    defer freeErr(a, config);
    defer if (config.images) |imgs| a.free(imgs);
    try parseErr(config, "--image requires -p/--print");
}
