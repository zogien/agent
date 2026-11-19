//! Shared fixtures for the AgentSession and CLI permission and credential tests.
const std = @import("std");
const harness = @import("harness");
const pfs = @import("platform").fs;

/// Forward-slash absolute path of a fresh subdirectory of `tmp` (it is spliced
/// into JSON string literals, where a Windows backslash is an escape).
pub fn subdir(tmp: *std.testing.TmpDir, name: []const u8, buffer: []u8) ![]const u8 {
    try tmp.dir.createDirPath(std.testing.io, name);
    var sub = try tmp.dir.openDir(std.testing.io, name, .{});
    defer sub.close(std.testing.io);
    const len = try sub.realPath(std.testing.io, buffer);
    for (buffer[0..len]) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return buffer[0..len];
}

pub fn existsUnder(root: []const u8, relative: []const u8) !bool {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ root, relative });
    return pfs.exists(path.ptr);
}

/// Counts prompts and answers each Write permission request with allow_always.
pub fn AllowAlways(comptime api: type, comptime ui_request: type) type {
    return struct {
        const Self = @This();

        prompts: usize = 0,

        fn request(
            raw: *anyopaque,
            _: api.session_id.SessionId,
            _: std.mem.Allocator,
            req: *const ui_request.UiRequest,
            out: *ui_request.UiResponse,
        ) anyerror!ui_request.RequestOutcome {
            const self: *Self = @ptrCast(@alignCast(raw));
            switch (req.*) {
                .permission => |prompt| {
                    try std.testing.expectEqualStrings("Write", prompt.tool);
                    self.prompts += 1;
                    out.* = .{ .permission = .allow_always };
                    return .answered;
                },
                else => return error.UnexpectedUiRequest,
            }
        }

        pub fn requester(self: *Self) api.agent_session.UiRequester {
            return .{ .ctx = self, .requestFn = request };
        }
    };
}

pub const final_sse =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_final\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// The value of the authorization header the provider received in request
/// `index`.
fn authorization(server: *harness.MockServer, index: usize) ![]const u8 {
    const captured = server.requestAt(index) orelse return error.NoRequestCaptured;
    const head_end = std.mem.indexOf(u8, captured.raw, "\r\n\r\n") orelse return error.MalformedRequest;
    var lines = std.mem.splitSequence(u8, captured.raw[0..head_end], "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "authorization"))
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return error.MissingAuthorization;
}

pub fn expectBearer(server: *harness.MockServer, index: usize, credential: []const u8) !void {
    const value = try authorization(server, index);
    try std.testing.expect(std.mem.startsWith(u8, value, "Bearer "));
    try std.testing.expectEqualStrings(credential, value["Bearer ".len..]);
}

pub fn CredentialRun(comptime api: type, comptime ui_event: type) type {
    return struct {
        const Self = @This();

        session: *api.agent_session.AgentSession,
        sink: api.agent_session.EventSink,
        stop_reason: ?api.agent_loop.StopReason = null,

        pub fn go(self: *Self) void {
            const result = self.session.runText(1, "hold", 2, self.sink) catch return;
            self.stop_reason = result.stop_reason;
        }

        pub fn emit(_: *anyopaque, _: api.session_id.SessionId, _: u64, _: ui_event.CoreEvent) bool {
            return true;
        }
    };
}
