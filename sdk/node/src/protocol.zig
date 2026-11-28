const std = @import("std");
const protocol = @import("protocol");
pub const panic = std.debug.simple_panic;
const Env = *anyopaque;
const Value = *anyopaque;

extern fn node_field(Env, Value, [*:0]const u8) ?Value;
extern fn node_element(Env, Value, u32) ?Value;
extern fn node_set_field(Env, Value, [*:0]const u8, Value) bool;
extern fn node_set_element(Env, Value, u32, Value) bool;
extern fn node_unsigned(Env, u64) ?Value;
extern fn node_signed(Env, i64) ?Value;

fn hasWide(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => |info| info.bits == 64,
        .optional => |info| hasWide(info.child),
        .pointer => |info| info.size == .slice and hasWide(info.child),
        .@"struct", .@"union" => inline for (std.meta.fields(T)) |field| {
            if (hasWide(field.type)) break true;
        } else false,
        else => false,
    };
}

fn project(env: Env, js: Value, data: anytype) error{NodeValue}!?Value {
    if (comptime !hasWide(@TypeOf(data))) return null;
    switch (@typeInfo(@TypeOf(data))) {
        .int => |info| return (if (info.signedness == .signed) node_signed(env, data) else node_unsigned(env, data)) orelse error.NodeValue,
        .optional => if (data) |value| return project(env, js, value),
        .pointer => for (data, 0..) |value, i| {
            const index: u32 = @intCast(i);
            if (try project(env, node_element(env, js, index) orelse return error.NodeValue, value)) |replacement| {
                if (!node_set_element(env, js, index, replacement)) return error.NodeValue;
            }
        },
        .@"struct" => |info| inline for (info.fields) |field| {
            if (comptime hasWide(field.type)) try projectField(env, js, field.name, @field(data, field.name));
        },
        .@"union" => switch (data) {
            inline else => |value, tag| if (comptime hasWide(@TypeOf(value))) try projectField(env, js, @tagName(tag), value),
        },
        else => unreachable,
    }
    return null;
}

fn projectField(env: Env, js: Value, comptime name: [:0]const u8, data: anytype) !void {
    if (try project(env, node_field(env, js, name) orelse return error.NodeValue, data)) |replacement| {
        if (!node_set_field(env, js, name, replacement)) return error.NodeValue;
    }
}

fn decode(env: Env, kind: u32, bytes: []const u8, js: Value) !void {
    const gpa = std.heap.c_allocator;
    switch (kind) {
        0 => {
            var event = try protocol.decodeCoreEvent(gpa, bytes);
            defer event.deinit();
            if (event.value == .known) _ = try project(env, js, event.value.known);
        },
        1 => {
            var ui = try protocol.decodeUiRequest(gpa, bytes);
            defer ui.deinit();
            if (ui.value == .permission) _ = try project(env, js, ui.value.permission);
        },
        2 => {
            var description = try protocol.decodeSessionDescription(gpa, bytes);
            defer description.deinit();
            _ = try project(env, js, description.value);
        },
        3 => {
            var report = try protocol.decodeRestoreReport(gpa, bytes);
            defer report.deinit();
            _ = try project(env, js, report.value);
        },
        4 => {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const goal = try protocol.decodeGoalDocument(arena.allocator(), bytes);
            _ = try project(env, js, goal);
        },
        5 => {
            var catalog = try protocol.decodeSkillCatalog(gpa, bytes);
            defer catalog.deinit();
            _ = try project(env, js, catalog.value);
        },
        6 => {
            var catalog = try protocol.decodeMcpCatalog(gpa, bytes);
            defer catalog.deinit();
            _ = try project(env, js, catalog.value);
        },
        else => return error.InvalidKind,
    }
}

export fn node_project(env: Env, kind: u32, ptr: [*]const u8, len: usize, js: Value) ?[*:0]const u8 {
    decode(env, kind, ptr[0..len], js) catch |err| return @errorName(err);
    return null;
}
