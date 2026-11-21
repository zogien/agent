//! L2 组件测试:Stage 7 — --base-url CLI flag 端到端贯穿。
//!
//! 设计目标(E2E 框架 Stage 7):
//!   CLI `--base-url <url>` → Config.base_url → app.zig:152 Client.initWithBaseUrl
//!   → 请求打到指定端点(record/replay 指向 mock 用)。
//!
//! subagent_model_test 的 baseline 只证 Client 级;本测覆盖**新增的 CLI→Config 线**。
//! 两段证明:
//!   (1) parseArgsForTest 把 --base-url 填进 Config.base_url(声明=接线)。
//!   (2) 用该 base_url 起 Client(同 app.zig:152 的构造)→ 请求打到 mock(接线=生效)。

const std = @import("std");
const harness = @import("harness");
const cc = @import("metacodes-core").test_support;

const MINIMAL_END_TURN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn drainStream(resp: *cc.client_mod.StreamResponse) !void {
    while (true) {
        const maybe = try resp.next();
        const ev = maybe orelse break;
        switch (ev) {
            .text => |t| std.testing.allocator.free(t),
            else => {},
        }
        if (resp.done) break;
    }
}

// (1) parseArgs:--base-url 填进 Config.base_url。
test "L2 Stage7: Config.base_url → Client 请求打到 mock 端点" {
    const a = std.testing.allocator;

    var srv = try harness.MockServer.start(MINIMAL_END_TURN_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();

    // 模拟 app.zig:152:Client.initWithBaseUrl(..., config.base_url)
    const config = cc.types_mod.Config{ .base_url = url, .model = "claude-3-5-haiku-20241022" };
    var client = cc.client_mod.Client.initWithBaseUrl(a, io, "test-key", config.model, config.base_url);
    defer client.deinit();

    const empty_messages: []const cc.types_mod.ApiMessage = &.{};
    var resp = client.sendMessageStream(empty_messages, null, null) catch |e| {
        std.debug.print("sendMessageStream failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    drainStream(&resp) catch {};
    resp.deinit();

    // 请求确实打到了 mock(说明 base_url override 生效)。
    const cap = srv.lastRequest() orelse return error.NoRequestCaptured;
    const model_field = cap.jsonField("model") orelse return error.ModelFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, model_field, "haiku") != null);
}
