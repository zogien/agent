//! HTTP+SSE transport, Streamable HTTP resumption and MCP OAuth against
//! tests/_harness/mock_mcp_auth_server.py:
//!
//! - `type: "sse"` opens the event stream, POSTs to the `endpoint` it names
//!   and reads every answer from the stream; an endpoint on another origin
//!   is refused, and a URL that is not an event stream says so.
//! - A Streamable HTTP SSE response that drops before its answer is resumed
//!   with `Last-Event-ID`.
//! - `mcp_oauth.login` discovers (WWW-Authenticate → RFC 9728 → RFC 8414),
//!   registers (RFC 7591), authorizes with PKCE S256 and `resource`, and
//!   stores the token; a session sends it, and after the server stops
//!   accepting it the transport refreshes (rotating the stored refresh
//!   token) and retries the call.

const std = @import("std");
const core = @import("metacodes-core");
const fixture = @import("../_harness/mcp_http_fixture.zig");

test "MCP SSE: the endpoint event names where to POST; answers arrive on the stream" {
    var mock = try fixture.Server.start(fixture.auth_script);
    defer mock.stop();
    const a = std.testing.allocator;
    var buffer: [128]u8 = undefined;
    {
        var client = try core.mcp_client.McpClient.connectHttp(a, .{
            .io = std.testing.io,
            .url = try mock.url(&buffer, "sse"),
            .headers = &.{.{ .name = "X-Team", .value = "t1" }},
            .wire = .legacy_sse,
        }, .{ .spawn = undefined, .startup_timeout_ms = 10_000 });
        defer client.close();
        try std.testing.expectEqualStrings("2024-11-05", client.protocol_version);
        const tools = try client.listTools();
        defer a.free(tools);
        try std.testing.expect(std.mem.indexOf(u8, tools, "\"whoami\"") != null);
        const called = try client.callTool("whoami", "{}");
        defer a.free(called);
        try std.testing.expect(std.mem.indexOf(u8, called, "called:whoami") != null);
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const posts = try mock.seen(arena.allocator(), "/sse/messages");
    // initialize, notifications/initialized, tools/list, tools/call — every
    // one on the endpoint, with the configured header and, after the
    // handshake, the negotiated revision.
    try std.testing.expectEqual(@as(usize, 4), posts.len);
    for (posts) |entry| try std.testing.expectEqualStrings("t1", fixture.field(entry, &.{ "headers", "x-team" }).?);
    try std.testing.expectEqualStrings("2024-11-05", fixture.field(posts[3], &.{ "headers", "mcp-protocol-version" }).?);
}

test "MCP SSE: an endpoint on another origin is refused; a non-stream URL says so" {
    var mock = try fixture.Server.start(fixture.auth_script);
    defer mock.stop();
    var buffer: [128]u8 = undefined;
    try std.testing.expectError(error.McpEndpointOriginMismatch, core.mcp_client.McpClient.connectHttp(std.testing.allocator, .{
        .io = std.testing.io,
        .url = try mock.url(&buffer, "sse-foreign"),
        .wire = .legacy_sse,
    }, .{ .spawn = undefined, .startup_timeout_ms = 5_000 }));
    try std.testing.expectError(error.McpNotEventStream, core.mcp_client.McpClient.connectHttp(std.testing.allocator, .{
        .io = std.testing.io,
        .url = try mock.url(&buffer, "resume"),
        .wire = .legacy_sse,
    }, .{ .spawn = undefined, .startup_timeout_ms = 5_000 }));
}

test "MCP HTTP: an SSE response dropped before its answer resumes with Last-Event-ID" {
    var mock = try fixture.Server.start(fixture.auth_script);
    defer mock.stop();
    const a = std.testing.allocator;
    var buffer: [128]u8 = undefined;
    {
        var client = try core.mcp_client.McpClient.connectHttp(a, .{
            .io = std.testing.io,
            .url = try mock.url(&buffer, "resume"),
        }, .{ .spawn = undefined, .startup_timeout_ms = 10_000 });
        defer client.close();
        client.transport.setDeadline(core.util_time.nowMs() + 10_000);
        const called = try client.callTool("whoami", "{}");
        defer a.free(called);
        try std.testing.expect(std.mem.indexOf(u8, called, "called:whoami") != null);
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var resumed: usize = 0;
    for (try mock.seen(arena.allocator(), "/resume")) |entry| {
        if (!std.mem.eql(u8, fixture.field(entry, &.{"method"}) orelse "", "GET")) continue;
        resumed += 1;
        try std.testing.expectEqualStrings("e1", fixture.field(entry, &.{"last_event_id"}).?);
        try std.testing.expectEqualStrings("resume-1", fixture.field(entry, &.{"session"}).?);
    }
    try std.testing.expectEqual(@as(usize, 1), resumed);
}

test "MCP OAuth: login discovers, registers, authorizes with PKCE; sessions send and refresh the token" {
    var mock = try fixture.Server.start(fixture.auth_script);
    defer mock.stop();
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const state_root = try fixture.tmpRoot(&tmp, &root_buffer);
    var url_buffer: [128]u8 = undefined;
    const url = try mock.url(&url_buffer, "oauth-mcp");

    // Without a login the server's 401 is an authorization error.
    try std.testing.expectError(error.McpAuthRequired, core.mcp_client.McpClient.connectHttp(a, .{
        .io = std.testing.io,
        .url = url,
    }, .{ .spawn = undefined, .startup_timeout_ms = 5_000 }));

    var browser: fixture.Browser = .{};
    var result = core.mcp_oauth.login(a, std.testing.io, state_root, .{
        .name = "authd",
        .target = .{ .url = url, .wire = .streamable },
    }, .{ .open_browser = false, .open_url = .{ .ctx = &browser, .open = fixture.Browser.open } }) catch |err| {
        browser.finish();
        return err;
    };
    browser.finish();
    defer result.deinit(a);
    var base_buffer: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buffer, "http://127.0.0.1:{d}", .{mock.port});
    try std.testing.expect(std.mem.startsWith(u8, result.issuer, base) and std.mem.endsWith(u8, result.issuer, "/as"));

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    // Dynamic registration of a loopback redirect on Claude Code's path.
    const register = (try mock.seen(aa, "/as/register"))[0];
    const redirect_uris = register.get("body").?.object.get("redirect_uris").?.array.items;
    try std.testing.expect(std.mem.startsWith(u8, redirect_uris[0].string, "http://localhost:"));
    try std.testing.expect(std.mem.endsWith(u8, redirect_uris[0].string, "/callback"));
    // The scope the challenge named, the RFC 8707 resource, PKCE S256.
    const authorize = (try mock.seen(aa, "/as/authorize"))[0];
    try std.testing.expectEqualStrings("mcp:tools", fixture.field(authorize, &.{ "query", "scope" }).?);
    try std.testing.expectEqualStrings(url, fixture.field(authorize, &.{ "query", "resource" }).?);
    try std.testing.expectEqualStrings("S256", fixture.field(authorize, &.{ "query", "code_challenge_method" }).?);
    // The mock checked code_verifier against the challenge and the resource.
    const token_requests = try mock.seen(aa, "/as/token");
    try std.testing.expectEqualStrings("authorization_code", fixture.field(token_requests[0], &.{ "form", "grant_type" }).?);

    {
        // Two sessions share the stored login.
        var client = try core.mcp_client.McpClient.connectHttp(a, .{
            .io = std.testing.io,
            .url = url,
            .auth = (try core.mcp_oauth.TokenSource.load(a, std.testing.io, state_root, "authd", url)).?,
        }, .{ .spawn = undefined, .startup_timeout_ms = 10_000 });
        defer client.close();
        var other = try core.mcp_client.McpClient.connectHttp(a, .{
            .io = std.testing.io,
            .url = url,
            .auth = (try core.mcp_oauth.TokenSource.load(a, std.testing.io, state_root, "authd", url)).?,
        }, .{ .spawn = undefined, .startup_timeout_ms = 10_000 });
        defer other.close();
        const first = try client.callTool("whoami", "{}");
        defer a.free(first);
        try std.testing.expect(std.mem.indexOf(u8, first, "token:at-1") != null);

        // The server stops accepting the token: the 401 is answered with one
        // refresh and the call is retried with the new token.
        try mock.post("control/revoke");
        const second = try client.callTool("whoami", "{}");
        defer a.free(second);
        try std.testing.expect(std.mem.indexOf(u8, second, "token:at-2") != null);

        // The other session's 401 adopts the token the first one stored
        // instead of spending the refresh token that rotation killed.
        const third = try other.callTool("whoami", "{}");
        defer a.free(third);
        try std.testing.expect(std.mem.indexOf(u8, third, "token:at-2") != null);
    }
    const refreshes = try mock.seen(aa, "/as/token");
    try std.testing.expectEqual(@as(usize, 2), refreshes.len);
    try std.testing.expectEqualStrings("refresh_token", fixture.field(refreshes[1], &.{ "form", "grant_type" }).?);
    try std.testing.expectEqualStrings("rt-1", fixture.field(refreshes[1], &.{ "form", "refresh_token" }).?);
    try std.testing.expectEqualStrings(url, fixture.field(refreshes[1], &.{ "form", "resource" }).?);
    // The rotated refresh token is what the store holds now.
    var record = (try core.mcp_oauth.loadRecord(a, result.path, url)).?;
    defer record.deinit(a);
    try std.testing.expectEqualStrings("rt-2", record.refresh_token.?);
    try std.testing.expectEqualStrings("at-2", record.access_token);
}
