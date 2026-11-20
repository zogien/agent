//! L2: a capability declaration (doc/WIRE_PROTOCOL.md §2) changes what a
//! frontend is asked. A real AgentSession against a mock provider exercises
//! AskUserQuestion and Write permission through HostedSession.
//!
//! Every request is shown both ways: announced and answered while the
//! frontend renders it (or never declared), and `ui_request_unavailable`
//! with no announcement, no round trip and the tool's own fallback once the
//! declaration leaves it out. The tool results the provider receives are
//! checked word for word: a request the frontend cannot render reads as
//! that, never as the user's refusal, and a real refusal keeps its wording.

const std = @import("std");
const harness = @import("harness");
const core = @import("metacodes-core");
const pfs = @import("platform").fs;

const EventJournal = core.event_journal.EventJournal;

// ── journal helpers ──────────────────────────────────────────────────────────

/// Waits until `needle` occurs in at least `count` journal lines.
fn waitFor(journal: *EventJournal, needle: []const u8, count: usize) !void {
    var waited: u64 = 0;
    while (waited < 10_000) : (waited += 20) {
        if (try countLines(journal, needle) >= count) return;
        core.util_time.sleepMs(20);
    }
    std.debug.print("journal never showed {d}x {s}\n", .{ count, needle });
    return error.JournalTimeout;
}

fn countLines(journal: *EventJournal, needle: []const u8) !usize {
    const a = std.testing.allocator;
    const lines = (try journal.waitSince(a, 0, 1)) orelse return 0;
    defer {
        for (lines) |line| a.free(line);
        a.free(lines);
    }
    var seen: usize = 0;
    for (lines) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) seen += 1;
    }
    return seen;
}

const ASK_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_a\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":7,\"output_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_ask\",\"name\":\"AskUserQuestion\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"questions\\\":[{\\\"question\\\":\\\"Favorite color?\\\",\\\"header\\\":\\\"Color\\\",\\\"options\\\":[{\\\"label\\\":\\\"Red\\\",\\\"description\\\":\\\"r\\\"},{\\\"label\\\":\\\"Blue\\\",\\\"description\\\":\\\"b\\\"}],\\\"multiSelect\\\":false}]}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":3}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const DONE_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_t\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn writeToolSse(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_w\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_w\",\"name\":\"Write\",\"input\":{{}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"file_path\\\":\\\"{s}\\\",\\\"content\\\":\\\"host\\\"}}\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
        "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
        "data: {{\"type\":\"message_stop\"}}\n\n", .{path});
}

fn subdir(tmp: *std.testing.TmpDir, name: []const u8, buffer: []u8) ![]const u8 {
    try tmp.dir.createDirPath(std.testing.io, name);
    var sub = try tmp.dir.openDir(std.testing.io, name, .{});
    defer sub.close(std.testing.io);
    const len = try sub.realPath(std.testing.io, buffer);
    for (buffer[0..len]) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return buffer[0..len];
}

fn exists(dir: []const u8, name: []const u8) !bool {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name });
    return pfs.exists(path.ptr);
}

/// The newest tool_result the provider received in request `index`, as the
/// model reads it (earlier turns' results ride along before it).
fn newestToolResult(server: *harness.MockServer, index: usize) ![]const u8 {
    const body = (server.requestAt(index) orelse return error.NoRequestCaptured).body();
    const at = std.mem.lastIndexOf(u8, body, "\"tool_result\"") orelse return error.NoToolResult;
    return body[at..];
}

fn toolResultIsError(server: *harness.MockServer, index: usize) !bool {
    return std.mem.indexOf(u8, try newestToolResult(server, index), "\"is_error\":true") != null;
}

/// Whether the model read `text` in the newest tool_result of request `index`.
fn modelRead(server: *harness.MockServer, index: usize, text: []const u8) !bool {
    return std.mem.indexOf(u8, try newestToolResult(server, index), text) != null;
}

const UNRENDERABLE_PERMISSION = "'Write' was denied without asking: the frontend connected to this session cannot render permission prompts";

test "L2 SessionHost: AskUserQuestion and permission prompts are routed by the declared capabilities" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ws_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = try subdir(&tmp, "workspace", &ws_buf);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try subdir(&tmp, "home", &home_buf);
    const denied_path = try std.fmt.allocPrint(a, "{s}/denied.txt", .{workspace});
    defer a.free(denied_path);
    const allowed_path = try std.fmt.allocPrint(a, "{s}/allowed.txt", .{workspace});
    defer a.free(allowed_path);
    const write_denied = try writeToolSse(a, denied_path);
    defer a.free(write_denied);
    const write_allowed = try writeToolSse(a, allowed_path);
    defer a.free(write_allowed);
    const declined_path = try std.fmt.allocPrint(a, "{s}/declined.txt", .{workspace});
    defer a.free(declined_path);
    const write_declined = try writeToolSse(a, declined_path);
    defer a.free(write_declined);

    // Provider requests, in order: 0-1 ask (undeclared), 2-3 ask (declared
    // without ask_question), 4-5 write (declared nothing), 6-7 write
    // (declared permission, granted), 8-9 write (declared, user declines).
    const bodies = [_][]const u8{ ASK_SSE, DONE_SSE, ASK_SSE, DONE_SSE, write_denied, DONE_SSE, write_allowed, DONE_SSE, write_declined, DONE_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const tools = [_][]const u8{ "AskUserQuestion", "Write" };
    const runtime = try core.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &tools });
    defer runtime.destroy() catch unreachable;
    var host = core.session_host.SessionHost.init(a, runtime, .{});
    defer host.deinit();
    const hosted = try host.open(.{ .config = .{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .default,
        .workspace = .{ .root = workspace, .home = home },
        .allowed_tools = &tools,
    } });
    defer host.release(hosted);
    const journal = &hosted.journal;

    // Undeclared: the question is announced and answered.
    try hosted.submit(.{ .text = "ask while undeclared" });
    try waitFor(journal, "\"type\":\"ui_request\",\"id\":1,\"kind\":\"ask_question\"", 1);
    try hosted.respond(1, "{\"answers\":[\"Red\"]}");
    try waitFor(journal, "\"type\":\"run_done\"", 1);
    try std.testing.expect(!try toolResultIsError(server, 1));
    try std.testing.expect(std.mem.indexOf(u8, server.requestAt(1).?.body(), "Red") != null);

    // A refused frame leaves the Session undeclared.
    try std.testing.expectError(error.SchemaVersionMismatch, hosted.declareCapabilities(a, "{\"type\":\"capabilities\",\"ui_requests\":[]}"));

    // Declared without ask_question: AskUserQuestion fails at once, nothing
    // is announced, the Run still ends.
    const ack = try hosted.declareCapabilities(a, "{\"v\":1,\"type\":\"capabilities\",\"ui_requests\":[\"permission\"]}");
    defer a.free(ack);
    try std.testing.expectEqualStrings("{\"v\":1,\"type\":\"capabilities_accepted\",\"ui_requests\":[\"permission\"],\"custom\":[],\"events\":null,\"ignored\":{\"ui_requests\":[],\"events\":[]}}", ack);
    try std.testing.expectEqual(@as(usize, 1), try countLines(journal, ack));
    try hosted.submit(.{ .text = "ask while declared without questions" });
    try waitFor(journal, "\"type\":\"run_done\"", 2);
    try std.testing.expectEqual(@as(usize, 1), try countLines(journal, "{\"v\":1,\"type\":\"ui_request_unavailable\",\"kind\":\"ask_question\",\"reason\":\"kind_not_declared\"}"));
    try std.testing.expectEqual(@as(usize, 1), try countLines(journal, "\"type\":\"ui_request\","));
    // The model is told the truth: no one saw the question.
    try std.testing.expect(try toolResultIsError(server, 3));
    try std.testing.expect(try modelRead(server, 3, "AskUserQuestion was not shown: the frontend connected to this session cannot render questions"));
    try std.testing.expect(try modelRead(server, 3, "This is not an answer or a refusal from the user."));
    try std.testing.expect(try modelRead(server, 3, "capability_unsupported"));
    try std.testing.expect(!try modelRead(server, 3, "NotATty"));

    // Declared nothing: the Write permission prompt is unrenderable, which
    // the gate answers as a denial. The file is never written, and the model
    // is not told the user declined.
    const nothing = try hosted.declareCapabilities(a, "{\"v\":1,\"type\":\"capabilities\",\"ui_requests\":[]}");
    defer a.free(nothing);
    try hosted.submit(.{ .text = "write while declared nothing" });
    try waitFor(journal, "\"type\":\"run_done\"", 3);
    try std.testing.expectEqual(@as(usize, 1), try countLines(journal, "{\"v\":1,\"type\":\"ui_request_unavailable\",\"kind\":\"permission\",\"reason\":\"kind_not_declared\"}"));
    try std.testing.expectEqual(@as(usize, 1), try countLines(journal, "\"type\":\"ui_request\","));
    try std.testing.expect(!try exists(workspace, "denied.txt"));
    try std.testing.expect(try toolResultIsError(server, 5));
    try std.testing.expect(try modelRead(server, 5, UNRENDERABLE_PERMISSION));
    try std.testing.expect(try modelRead(server, 5, "This is not the user's decision; the user never saw the request."));
    try std.testing.expect(try modelRead(server, 5, "permission_denied"));
    try std.testing.expect(!try modelRead(server, 5, "user declined"));

    // Declared permission again: the same prompt is announced and granted.
    const permission = try hosted.declareCapabilities(a, "{\"v\":1,\"type\":\"capabilities\",\"ui_requests\":[\"permission\",\"ask_question\"]}");
    defer a.free(permission);
    try hosted.submit(.{ .text = "write while declared permission" });
    try waitFor(journal, "\"type\":\"ui_request\",\"id\":2,\"kind\":\"permission\"", 1);
    try hosted.respond(2, "{\"choice\":\"allow_once\"}");
    try waitFor(journal, "\"type\":\"run_done\"", 4);
    try std.testing.expect(try exists(workspace, "allowed.txt"));
    try std.testing.expect(!try toolResultIsError(server, 7));

    // A real decline still reads as the user's decline, word for word.
    try hosted.submit(.{ .text = "write and decline" });
    try waitFor(journal, "\"type\":\"ui_request\",\"id\":3,\"kind\":\"permission\"", 1);
    try hosted.respond(3, "{\"choice\":\"deny_once\"}");
    try waitFor(journal, "\"type\":\"run_done\"", 5);
    try std.testing.expect(!try exists(workspace, "declined.txt"));
    try std.testing.expect(try modelRead(server, 9, "user declined 'Write' via prompt"));
    try std.testing.expect(!try modelRead(server, 9, "without asking"));
    try std.testing.expectEqual(@as(usize, 3), try countLines(journal, "\"type\":\"capabilities_accepted\""));
}
