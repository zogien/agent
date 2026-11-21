//! Core event backend contracts for mock and plain-text writers.

const std = @import("std");
const testing = std.testing;
const cc = @import("cc");

const ui_event = cc.ui_event;
const ui_backend = cc.ui_backend;
const abort = cc.util_abort;

const CoreEvent = ui_event.CoreEvent;
const UiEvent = ui_event.UiEvent;
const UiBackend = ui_backend.UiBackend;
const SessionId = ui_backend.SessionId;

// ---------------------------------------------------------------------------
// Part 1:Mock backend —— 收 CoreEvent 进 ArrayList,证明 vtable 契约可换实现。
// ---------------------------------------------------------------------------

const MockBackend = struct {
    events: std.ArrayList(CoreEvent) = .empty,
    allocator: std.mem.Allocator,
    /// poll 预置事件队列(测 UI→core 方向)。
    pending: std.ArrayList(UiEvent) = .empty,
    poll_idx: usize = 0,

    fn init(allocator: std.mem.Allocator) MockBackend {
        return .{ .allocator = allocator };
    }
    fn deinit(self: *MockBackend) void {
        self.events.deinit(self.allocator);
        self.pending.deinit(self.allocator);
    }

    fn backend(self: *MockBackend) UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emitThunk, .poll = pollThunk };
    }

    fn emitThunk(ctx: *anyopaque, _: SessionId, ev: CoreEvent) void {
        const self: *MockBackend = @ptrCast(@alignCast(ctx));
        // 注:mock 直接存 CoreEvent(含 borrow slice)。测试里 slice 指向静态字面量,
        // 生命周期覆盖整个测试,安全。真实后端必须同步拷贝。
        self.events.append(self.allocator, ev) catch unreachable;
    }
    fn pollThunk(ctx: *anyopaque, _: SessionId) ?UiEvent {
        const self: *MockBackend = @ptrCast(@alignCast(ctx));
        if (self.poll_idx >= self.pending.items.len) return null;
        defer self.poll_idx += 1;
        return self.pending.items[self.poll_idx];
    }
};

/// 测试用的占位 session(N=1,所有调用都用它)。
const S: SessionId = SessionId.single;

test "mock backend: emit 序列被完整记录" {
    var mb = MockBackend.init(testing.allocator);
    defer mb.deinit();
    const be = mb.backend();

    be.emitEvent(S, .{ .text_chunk = "hi" });
    be.emitEvent(S, .{ .tool_start = .{ .id = "t1", .name = "Bash", .input = "{}" } });
    be.emitEvent(S, .{ .tool_progress = .{ .id = "t1", .text = "running" } });
    be.emitEvent(S, .{ .tool_result = .{ .id = "t1", .name = "Bash", .input = "{}", .content = "ok", .is_error = false } });
    be.emitEvent(S, .stream_done);

    try testing.expectEqual(@as(usize, 5), mb.events.items.len);
    try testing.expectEqualStrings("hi", mb.events.items[0].text_chunk);
    try testing.expectEqualStrings("Bash", mb.events.items[1].tool_start.name);
    try testing.expectEqualStrings("running", mb.events.items[2].tool_progress.text);
    try testing.expect(!mb.events.items[3].tool_result.is_error);
    try testing.expectEqual(CoreEvent.stream_done, mb.events.items[4]);
}

test "mock backend: poll 按序产出 UiEvent" {
    var mb = MockBackend.init(testing.allocator);
    defer mb.deinit();
    try mb.pending.append(testing.allocator, .{ .interrupt = .user_ctrl_c });
    try mb.pending.append(testing.allocator, .{ .queue_message = "next" });
    const be = mb.backend();

    const e1 = be.pollEvent(S) orelse return error.NoEvent;
    try testing.expectEqual(abort.Reason.user_ctrl_c, e1.interrupt);
    const e2 = be.pollEvent(S) orelse return error.NoEvent;
    try testing.expectEqualStrings("next", e2.queue_message);
    try testing.expect(be.pollEvent(S) == null); // 耗尽返 null
}

const writer_backend = cc.writer_backend;

const CaptureSink = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    fn init(a: std.mem.Allocator) CaptureSink {
        return .{ .allocator = a };
    }
    fn deinit(self: *CaptureSink) void {
        self.buf.deinit(self.allocator);
    }
    fn sink(ctx: *anyopaque, bytes: []const u8) void {
        const self: *CaptureSink = @ptrCast(@alignCast(ctx));
        self.buf.appendSlice(self.allocator, bytes) catch unreachable;
    }
};

test "WriterBackend 字节锁: stream_begin/text/stream_done(colorize) == legacy 括号" {
    var cap = CaptureSink.init(testing.allocator);
    defer cap.deinit();
    var wb = writer_backend.WriterBackend{ .sink_ctx = @ptrCast(&cap), .sink = CaptureSink.sink, .colorize = true };
    const be = wb.backend();

    be.emitEvent(S, .stream_begin);
    be.emitEvent(S, .{ .text_chunk = "hello world" });
    be.emitEvent(S, .stream_done);
    // legacy:print("\x1b[32m") + print("{s}",text) + print("\x1b[0m\n")
    try testing.expectEqualStrings("\x1b[32mhello world\x1b[0m\n", cap.buf.items);
}

test "WriterBackend 字节锁: !colorize → 无括号,stream_done 仍发 \\n" {
    var cap = CaptureSink.init(testing.allocator);
    defer cap.deinit();
    var wb = writer_backend.WriterBackend{ .sink_ctx = @ptrCast(&cap), .sink = CaptureSink.sink, .colorize = false };
    const be = wb.backend();

    be.emitEvent(S, .stream_begin); // 无 colorize → 不发
    be.emitEvent(S, .{ .text_chunk = "abc" });
    be.emitEvent(S, .stream_done); // 仍发 \n(legacy :422)
    try testing.expectEqualStrings("abc\n", cap.buf.items);
}

test "WriterBackend 字节锁: auto_compact == legacy 行" {
    var cap = CaptureSink.init(testing.allocator);
    defer cap.deinit();
    var wb = writer_backend.WriterBackend{ .sink_ctx = @ptrCast(&cap), .sink = CaptureSink.sink };
    const be = wb.backend();

    be.emitEvent(S, .{ .auto_compact = .{ .dropped = 5, .kept = 12 } });
    try testing.expectEqualStrings("\x1b[33m[auto-compacted 5 old messages, kept last 12; cause=trigger]\x1b[0m\n", cap.buf.items);
}

test "WriterBackend 字节锁: context-window recovery is not printed as a compaction" {
    var cap = CaptureSink.init(testing.allocator);
    defer cap.deinit();
    var wb = writer_backend.WriterBackend{ .sink_ctx = @ptrCast(&cap), .sink = CaptureSink.sink };
    const be = wb.backend();

    be.emitEvent(S, .{ .auto_compact = .{ .dropped = 2, .kept = 3344, .cause = "context_window_exceeded_trim" } });
    try testing.expectEqualStrings("\x1b[33m[context-window recovery (context_window_exceeded_trim): dropped 2 oldest messages, kept 3344]\x1b[0m\n", cap.buf.items);
    cap.buf.clearRetainingCapacity();
    be.emitEvent(S, .{ .auto_compact = .{ .dropped = 3300, .kept = 10, .cause = "context_window_exceeded_recovery" } });
    try testing.expectEqualStrings("\x1b[33m[context-window recovery (context_window_exceeded_recovery): dropped 3300 oldest messages, kept 10]\x1b[0m\n", cap.buf.items);
}

test "WriterBackend 字节锁: context_warning visible" {
    var cap = CaptureSink.init(testing.allocator);
    defer cap.deinit();
    var wb = writer_backend.WriterBackend{ .sink_ctx = @ptrCast(&cap), .sink = CaptureSink.sink };
    const be = wb.backend();

    be.emitEvent(S, .{ .context_warning = .{
        .current_tokens = 160_000,
        .warning_threshold = 160_000,
        .auto_compact_threshold = 167_000,
        .blocking_limit = 177_000,
        .level = "medium",
    } });
    try testing.expectEqualStrings("\x1b[33m[context warning: 160000/160000 tokens, auto-compact at 167000, blocking at 177000]\x1b[0m\n", cap.buf.items);
}

test "WriterBackend 字节锁: retry 门控 + legacy 格式" {
    var cap = CaptureSink.init(testing.allocator);
    defer cap.deinit();
    var wb = writer_backend.WriterBackend{ .sink_ctx = @ptrCast(&cap), .sink = CaptureSink.sink, .colorize = true, .show_retry = true };
    const be = wb.backend();

    // attempt < 3 → 隐藏(降噪)
    be.emitEvent(S, .{ .retry_notice = .{ .attempt = 1, .max = 10, .delay_ms = 500 } });
    be.emitEvent(S, .{ .retry_notice = .{ .attempt = 2, .max = 10, .delay_ms = 500 } });
    try testing.expectEqual(@as(usize, 0), cap.buf.items.len);

    // attempt >= 3 → 显示(secs=ceil(2000/1000)=2)
    be.emitEvent(S, .{ .retry_notice = .{ .attempt = 3, .max = 10, .delay_ms = 2000 } });
    try testing.expectEqualStrings("\x1b[2mRetrying in 2s… (attempt 3/10)\x1b[0m\n", cap.buf.items);
}

test "WriterBackend 字节锁: !show_retry → 完全静默" {
    var cap = CaptureSink.init(testing.allocator);
    defer cap.deinit();
    var wb = writer_backend.WriterBackend{ .sink_ctx = @ptrCast(&cap), .sink = CaptureSink.sink, .show_retry = false };
    const be = wb.backend();
    be.emitEvent(S, .{ .retry_notice = .{ .attempt = 5, .max = 10, .delay_ms = 1000 } });
    try testing.expectEqual(@as(usize, 0), cap.buf.items.len);
}

test "WriterBackend 字节锁: verbose tool_start(card=false) == legacy [Tool: name]" {
    var cap = CaptureSink.init(testing.allocator);
    defer cap.deinit();
    var wb = writer_backend.WriterBackend{ .sink_ctx = @ptrCast(&cap), .sink = CaptureSink.sink, .verbose = true };
    const be = wb.backend();
    be.emitEvent(S, .{ .tool_start = .{ .id = "t", .name = "Bash", .input = "{}" } });
    try testing.expectEqualStrings("\n\x1b[35m[Tool: Bash]\x1b[0m", cap.buf.items);
}

test "WriterBackend: 卡/spinner/progress/usage 事件全 no-op(print-only 不收卡字节)" {
    var cap = CaptureSink.init(testing.allocator);
    defer cap.deinit();
    var wb = writer_backend.WriterBackend{ .sink_ctx = @ptrCast(&cap), .sink = CaptureSink.sink, .verbose = false };
    const be = wb.backend();

    be.emitEvent(S, .{ .tool_start = .{ .id = "t", .name = "WebSearch", .input = "{}" } });
    be.emitEvent(S, .{ .set_current_tool = .{ .name = "Bash" } });
    be.emitEvent(S, .{ .tool_progress = .{ .id = "t", .text = "Found 3" } });
    be.emitEvent(S, .clear_current_tool);
    be.emitEvent(S, .{ .tool_result = .{ .id = "t", .name = "Bash", .input = "{}", .content = "ok", .is_error = false, .elapsed_ms = 10 } });
    be.emitEvent(S, .{ .usage = .{ .input_tokens = 5 } });
    // verbose=false tool_start(card=false) 也不发 → 全程零字节。
    try testing.expectEqual(@as(usize, 0), cap.buf.items.len);
}

test "WriterBackend.initNull: 丢弃一切 + poll 恒 null" {
    var wb = writer_backend.WriterBackend.initNull();
    const be = wb.backend();
    be.emitEvent(S, .{ .text_chunk = "discarded" });
    be.emitEvent(S, .stream_done);
    try testing.expect(be.pollEvent(S) == null);
}
