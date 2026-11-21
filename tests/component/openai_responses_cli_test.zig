//! CLI flags and terminal diagnostics for the Responses protocol.
const std = @import("std");
const cc = @import("metacodes-core").test_support;
const failure_fixture = @import("../_harness/openai_responses_failure.zig");

// ── flag/env 面:--openai-protocol 解析(声明=接线)────────────────────────────

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
