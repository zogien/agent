//! L2: permission memory belongs to the Session that answered the prompt.
//!
//! A Host shows the permission prompt through its UiRequester. "Allow always"
//! must then hold for the rest of that Session and nowhere else: not for a
//! second Session of the same Runtime and workspace, and not on disk. Before
//! the fix the library path also appended a whole-tool grant to
//! `<workspace>/.claude/settings.local.json`, a file no AgentSession reads but
//! the next CLI started in that workspace does.
//!
//! Cross-module: agent_session + agent_loop + permission (decision, prompt,
//! session_rules) + Write tool.

const std = @import("std");
const harness = @import("harness");
const core = @import("metacodes-core");
const fixture = @import("../_harness/agent_session_fixture.zig");

const AllowAlways = fixture.AllowAlways(core, core.protocol.ui_request);
const subdir = fixture.subdir;
const existsUnder = fixture.existsUnder;

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_final\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn writeToolSse(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_w\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_w\",\"name\":\"Write\",\"input\":{{}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"file_path\\\":\\\"{s}\\\",\\\"content\\\":\\\"scoped\\\"}}\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
        "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
        "data: {{\"type\":\"message_stop\"}}\n\n", .{path});
}

const Sink = struct {
    fn emit(_: *anyopaque, _: core.session_id.SessionId, _: u64, _: core.protocol.ui_event.CoreEvent) bool {
        return true;
    }
};

test "L2 AgentSession allow_always holds for its Session only and writes no settings file" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var workspace_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = try subdir(&tmp, "workspace", &workspace_buf);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try subdir(&tmp, "home", &home_buf);

    const first_a = try std.fmt.allocPrint(a, "{s}/first-a.txt", .{workspace});
    defer a.free(first_a);
    const first_b = try std.fmt.allocPrint(a, "{s}/first-b.txt", .{workspace});
    defer a.free(first_b);
    const second = try std.fmt.allocPrint(a, "{s}/second.txt", .{workspace});
    defer a.free(second);
    const sse_a = try writeToolSse(a, first_a);
    defer a.free(sse_a);
    const sse_b = try writeToolSse(a, first_b);
    defer a.free(sse_b);
    const sse_second = try writeToolSse(a, second);
    defer a.free(sse_second);
    // Session one: two Writes then a final answer. Session two: one Write.
    const bodies = [_][]const u8{ sse_a, sse_b, FINAL_SSE, sse_second, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const runtime = try core.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{"Write"} });
    defer runtime.destroy() catch unreachable;
    var ui = AllowAlways{};
    const config: core.agent_session.SessionConfig = .{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .default,
        .workspace = .{ .root = workspace, .home = home },
        .allowed_tools = &.{"Write"},
        .ui_requester = ui.requester(),
    };

    var sink_state: u8 = 0;
    {
        const session = try runtime.createSession(config);
        defer session.destroy() catch unreachable;
        const result = try session.runText(1, "write two files", 6, .{ .ctx = &sink_state, .emit = Sink.emit });
        try std.testing.expectEqual(core.agent_loop.StopReason.end_turn, result.stop_reason);
        try std.testing.expectEqual(@as(u32, 2), result.tool_calls);
    }
    // The second Write of the same Session was not asked about again.
    try std.testing.expectEqual(@as(usize, 1), ui.prompts);
    try std.testing.expect(try existsUnder(workspace, "first-a.txt"));
    try std.testing.expect(try existsUnder(workspace, "first-b.txt"));

    {
        const session = try runtime.createSession(config);
        defer session.destroy() catch unreachable;
        const result = try session.runText(1, "write one file", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
        try std.testing.expectEqual(core.agent_loop.StopReason.end_turn, result.stop_reason);
    }
    // A new Session of the same Runtime and workspace starts without the grant.
    try std.testing.expectEqual(@as(usize, 2), ui.prompts);
    try std.testing.expect(try existsUnder(workspace, "second.txt"));

    // Nothing left the Sessions: neither settings file the CLI would load.
    try std.testing.expect(!try existsUnder(workspace, ".claude/settings.local.json"));
    try std.testing.expect(!try existsUnder(workspace, ".claude/settings.json"));
    try std.testing.expect(!try existsUnder(home, ".claude/settings.json"));
}
