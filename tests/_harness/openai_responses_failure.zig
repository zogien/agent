//! Responses failure frames shared by Core and the terminal summary tests.
const std = @import("std");
const harness = @import("harness");

const RESPONSES_FAILED_SSE =
    "event: response.failed\n" ++
    "data: {\"type\":\"response.failed\",\"response\":{\"id\":\"resp_5\",\"status\":\"failed\",\"error\":{\"code\":\"server_error\",\"message\":\"boom\"}}}\n\n";

const RESPONSES_ERROR_SSE =
    "event: error\n" ++
    "data: {\"type\":\"error\",\"code\":\"rate_limited\",\"message\":\"slow down\",\"param\":null,\"sequence_number\":1}\n\n";

pub const cases = [_]struct { sse: []const u8, message: []const u8 }{
    .{ .sse = RESPONSES_FAILED_SSE, .message = "boom" },
    .{ .sse = RESPONSES_ERROR_SSE, .message = "slow down" },
};

pub fn expectApiError(comptime Client: type, comptime Message: type, sse: []const u8) !void {
    const allocator = std.testing.allocator;
    var server = try harness.MockServer.startCassette(&.{sse}, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    var client = Client.init(allocator, io_runtime.io(), "test-key", "gpt-5.2", url);
    defer client.deinit();
    client.protocol = .responses;

    const messages = [_]Message{.{ .role = .user, .content = &.{.{ .text = "hi" }} }};
    var handle = try client.provider().sendStream(&messages, null, null, null, null, null, "");
    defer handle.deinit();
    try std.testing.expectError(error.ApiError, handle.next());
}
