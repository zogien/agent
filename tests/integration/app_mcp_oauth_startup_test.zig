//! The App connects configured SSE and HTTP MCP servers using a stored login.
const std = @import("std");
const cc = @import("cc");
const fixture = @import("../_harness/mcp_http_fixture.zig");

test "MCP OAuth: configuration reaches the wire — startup connects an sse server and a logged-in http server" {
    var mock = try fixture.Server.start(fixture.auth_script);
    defer mock.stop();
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const state_root = try fixture.tmpRoot(&tmp, &root_buffer);
    var sse_buffer: [128]u8 = undefined;
    const sse_url = try mock.url(&sse_buffer, "sse-oauth");
    var http_buffer: [128]u8 = undefined;
    const http_url = try mock.url(&http_buffer, "oauth-mcp");

    // Log in to both: the SSE server discovers through a GET probe of its
    // stream.
    for ([_]struct { name: []const u8, url: []const u8, wire: cc.mcp_config.HttpWire }{
        .{ .name = "linear", .url = sse_url, .wire = .legacy_sse },
        .{ .name = "authd", .url = http_url, .wire = .streamable },
    }) |server| {
        var browser: fixture.Browser = .{};
        var result = cc.mcp_oauth.login(a, std.testing.io, state_root, .{
            .name = server.name,
            .target = .{ .url = server.url, .wire = server.wire },
        }, .{ .open_browser = false, .open_url = .{ .ctx = &browser, .open = fixture.Browser.open } }) catch |err| {
            browser.finish();
            return err;
        };
        browser.finish();
        result.deinit(a);
    }

    const config = try std.fmt.allocPrint(a,
        \\{{"mcpServers":{{"linear":{{"type":"sse","url":"{s}"}},"authd":{{"type":"http","url":"{s}"}}}}}}
    , .{ sse_url, http_url });
    defer a.free(config);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.json", .data = config });

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var status: cc.app_mcp_startup.Status = .{};
    const startup = try cc.app_mcp_startup.Startup.begin(arena.allocator(), &status, .{
        .io = std.testing.io,
        .state_root = state_root,
        .home = state_root,
        .cwd = state_root,
        .workspace_root = "",
        .codex_home = state_root,
    });
    startup.join();
    defer startup.cancelAndJoin();
    try std.testing.expectEqual(@as(usize, 2), startup.jobs.len);
    for (startup.jobs) |*job| {
        switch (job.result) {
            .connected => |connected| try std.testing.expect(std.mem.indexOf(u8, connected.tools_json, "\"whoami\"") != null),
            .failed => |err| {
                std.debug.print("server {s} failed: {s}\n", .{ job.server.name, @errorName(err) });
                return error.TestUnexpectedResult;
            },
            .pending => unreachable,
        }
    }
    for (startup.jobs) |*job| {
        const wire: std.meta.Tag(cc.mcp_transport.Transport) = if (std.mem.eql(u8, job.server.name, "linear")) .sse else .http;
        try std.testing.expectEqual(wire, std.meta.activeTag(job.result.connected.client.transport));
    }
    // The stream GET carried the stored token.
    const streams = try mock.seen(arena.allocator(), "/sse-oauth");
    const last = streams[streams.len - 1];
    try std.testing.expect(std.mem.startsWith(u8, fixture.field(last, &.{ "headers", "authorization" }).?, "Bearer at-"));
}
