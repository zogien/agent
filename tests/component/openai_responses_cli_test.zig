//! CLI flags and terminal diagnostics for the Responses protocol.
const std = @import("std");
const cc = @import("cc");
const failure_fixture = @import("../_harness/openai_responses_failure.zig");

// ── flag/env 面:--openai-protocol 解析(声明=接线)────────────────────────────

test "Responses(flag): --openai-protocol responses 解析进 Config;词表外 fail-closed" {
    const a = std.testing.allocator;
    {
        const argv = [_][*:0]const u8{ "metacodes", "--openai-protocol", "responses" };
        const config = cc.parseArgsForTest(&argv, a);
        try std.testing.expect(config.parse_error == null);
        try std.testing.expectEqual(cc.types_mod.OpenAIProtocol.responses, config.openai_protocol);
    }
    {
        // 别名 "chat" 与默认值等价。
        const argv = [_][*:0]const u8{ "metacodes", "--openai-protocol", "chat" };
        const config = cc.parseArgsForTest(&argv, a);
        try std.testing.expect(config.parse_error == null);
        try std.testing.expectEqual(cc.types_mod.OpenAIProtocol.chat_completions, config.openai_protocol);
    }
    {
        // 拼错 → parse error(main 打印后 exit 2),绝不静默落默认端点。
        const argv = [_][*:0]const u8{ "metacodes", "--openai-protocol", "response" };
        const config = cc.parseArgsForTest(&argv, a);
        try std.testing.expect(config.parse_error != null);
        a.free(config.parse_error.?);
    }
}

test "Responses(TUI): the terminal error summary retains the provider failure frame" {
    for (failure_fixture.cases) |failure| {
        var last: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined;
        _ = cc.api_last_error.take(&last);
        try failure_fixture.expectApiError(cc.api_openai.OpenAIClient, cc.types_mod.ApiMessage, failure.sse);
        const detail = cc.api_last_error.take(&last) orelse return error.TestExpectedLastError;
        try std.testing.expect(std.mem.startsWith(u8, detail, "API 错误帧: "));
        try std.testing.expect(std.mem.indexOf(u8, detail, failure.message) != null);
    }
}
