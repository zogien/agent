//! Loopback Python server and browser fixtures for the MCP HTTP tests.
const std = @import("std");
const builtin = @import("builtin");
const process = @import("platform").process;
const options = @import("integration_options");

pub const http_script: [:0]const u8 = options.mock_mcp_http_script ++ "";
pub const auth_script: [:0]const u8 = options.mock_mcp_auth_script ++ "";

pub const Server = struct {
    child: process.PipeChild,
    port: u16,

    pub fn start(script: [*:0]const u8) !Server {
        if (builtin.os.tag == .windows) return error.SkipZigTest; // POSIX shebang fixtures
        const argv = [_]?[*:0]const u8{ script, null };
        const child = try process.spawnPipes(&argv, true, null);
        errdefer stopChild(child);

        var buffer: [16]u8 = undefined;
        var length: usize = 0;
        while (length < buffer.len) {
            var byte: [1]u8 = undefined;
            if (!child.pollReadable(5000) or child.read(&byte) != 1) return error.MockMcpPortUnavailable;
            if (byte[0] == '\n') break;
            buffer[length] = byte[0];
            length += 1;
        }
        const port = try std.fmt.parseInt(u16, buffer[0..length], 10);
        return .{ .child = child, .port = port };
    }

    pub fn stop(self: *const Server) void {
        stopChild(self.child);
    }

    pub fn url(self: *const Server, buffer: []u8, path: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}/{s}", .{ self.port, path });
    }

    pub fn get(self: *const Server, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        var client: std.http.Client = .{ .allocator = allocator, .io = std.testing.io };
        defer client.deinit();
        var buffer: [128]u8 = undefined;
        const target = try self.url(&buffer, path);
        var body: std.Io.Writer.Allocating = .init(allocator);
        defer body.deinit();
        _ = try client.fetch(.{ .location = .{ .url = target }, .response_writer = &body.writer });
        return body.toOwnedSlice();
    }

    pub fn post(self: *const Server, path: []const u8) !void {
        var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
        defer client.deinit();
        var buffer: [128]u8 = undefined;
        _ = try client.fetch(.{ .location = .{ .url = try self.url(&buffer, path) }, .method = .POST, .payload = "" });
    }

    /// The observations whose `path` is `path`, parsed.
    pub fn seen(self: *const Server, arena: std.mem.Allocator, path: []const u8) ![]std.json.ObjectMap {
        const log = try self.get(arena, "log");
        var out: std.ArrayList(std.json.ObjectMap) = .empty;
        var lines = std.mem.splitScalar(u8, log, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
            if (value != .object) continue;
            const entry_path = value.object.get("path") orelse continue;
            if (entry_path == .string and std.mem.eql(u8, entry_path.string, path)) try out.append(arena, value.object);
        }
        return out.toOwnedSlice(arena);
    }
};

fn stopChild(child: process.PipeChild) void {
    child.closeStdin();
    child.closeStdout();
    child.terminate();
}

pub fn field(object: std.json.ObjectMap, comptime path: []const []const u8) ?[]const u8 {
    var current: std.json.Value = .{ .object = object };
    inline for (path) |key| {
        if (current != .object) return null;
        current = current.object.get(key) orelse return null;
    }
    return if (current == .string) current.string else null;
}

/// Plays the browser: follows the authorization redirect to the loopback
/// callback on a thread of its own (the login is waiting for it).
pub const Browser = struct {
    thread: ?std.Thread = null,
    url: ?[]u8 = null,

    pub fn open(ctx: *anyopaque, url: []const u8) void {
        const self: *Browser = @ptrCast(@alignCast(ctx));
        self.url = std.testing.allocator.dupe(u8, url) catch return;
        self.thread = std.Thread.spawn(.{}, visit, .{self.url.?}) catch null;
    }

    fn visit(url: []const u8) void {
        var client: std.http.Client = .{ .allocator = std.heap.c_allocator, .io = std.testing.io };
        defer client.deinit();
        const uri = std.Uri.parse(url) catch return;
        var request = client.request(.GET, uri, .{ .redirect_behavior = .unhandled }) catch return;
        defer request.deinit();
        request.sendBodiless() catch return;
        var redirect: [4096]u8 = undefined;
        const response = request.receiveHead(&redirect) catch return;
        var location_buffer: [2048]u8 = undefined;
        var headers = response.head.iterateHeaders();
        const location = while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "location") and header.value.len <= location_buffer.len) {
                @memcpy(location_buffer[0..header.value.len], header.value);
                break location_buffer[0..header.value.len];
            }
        } else return;
        // The callback listens on 127.0.0.1; "localhost" is what the
        // authorization server was told.
        var callback_buffer: [2048]u8 = undefined;
        const size = std.mem.replacementSize(u8, location, "//localhost:", "//127.0.0.1:");
        _ = std.mem.replace(u8, location, "//localhost:", "//127.0.0.1:", callback_buffer[0..size]);
        var body: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
        defer body.deinit();
        _ = client.fetch(.{ .location = .{ .url = callback_buffer[0..size] }, .response_writer = &body.writer }) catch {};
    }

    pub fn finish(self: *Browser) void {
        if (self.thread) |thread| thread.join();
        if (self.url) |url| std.testing.allocator.free(url);
        self.* = .{};
    }
};

pub fn tmpRoot(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..len];
}
