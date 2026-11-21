//! L2: a credential rotated while a request waits at the internal provider connection gate.
const std = @import("std");
const harness = @import("harness");
const cc = @import("metacodes-core").test_support;
const fixture = @import("../_harness/agent_session_fixture.zig");

const CredentialRun = fixture.CredentialRun(cc, cc.ui_event);
const FINAL_SSE = fixture.final_sse;
const subdir = fixture.subdir;
const expectBearer = fixture.expectBearer;

test "L2 a request that waits for a connection slot carries the credential published while it waited" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var workspace_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = try subdir(&tmp, "workspace", &workspace_buf);
    const bodies = [_][]const u8{FINAL_SSE};
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "slot-initial",
        .model = "test-model",
        .base_url = url,
        .workspace = .{ .root = workspace },
        .allowed_tools = &.{},
    });
    defer session.destroy() catch unreachable;
    var sink_state: u8 = 0;
    const sink: cc.agent_session.EventSink = .{ .ctx = &sink_state, .emit = CredentialRun.emit };

    // Hold every process connection slot, so the Run's request queues at the
    // gate: it is admitted and serialized, not sent.
    const gate = cc.api_connection_gate;
    var leases: std.ArrayList(gate.Lease) = .empty;
    defer {
        for (leases.items) |*lease| lease.release();
        leases.deinit(a);
    }
    for (0..gate.processLimit()) |_| try leases.append(a, try gate.acquire(null));
    var held = CredentialRun{ .session = session, .sink = sink };
    const run_thread = try std.Thread.spawn(.{}, CredentialRun.go, .{&held});
    var waited: usize = 0;
    while (gate.processWaiting() == 0) : (waited += 1) {
        if (waited == 2000) {
            for (leases.items) |*lease| lease.release();
            run_thread.join();
            return error.RequestNeverQueued;
        }
        @import("platform").sync.sleepMs(5);
    }
    try std.testing.expectEqual(@as(usize, 0), server.requestCount());

    // The update returns while the request is still queued: the request is
    // sent afterwards, so it carries the new credential.
    _ = try session.updateCredential("slot-updated");
    for (leases.items) |*lease| lease.release();
    run_thread.join();
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, held.stop_reason.?);
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
    try expectBearer(server, 0, "slot-updated");
}
