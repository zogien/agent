//! Shared process lifecycle and Git worktree operations for teammates.

const std = @import("std");
const builtin = @import("builtin");
const mailbox = @import("mailbox.zig");
const team_mod = @import("team.zig");
const swarm_ctx = @import("context.zig");
const util_time = @import("../util/time.zig");
const log = @import("../util/log.zig");
const pfs = @import("platform").fs;
const process_mod = @import("platform").process;
const SessionId = @import("../core/session_id.zig").SessionId;

pub const Identity = struct {
    name: []const u8, // 未清洗(内部 sanitize)
    team: []const u8, // 未清洗
    parent_session: []const u8 = "",
    lease_id: []const u8 = "",
    cwd: []const u8 = "", // 非空 → 启动 chdir(worktree 隔离)
};

/// 轮询间隔(同 in-process)。
const POLL_MS: u64 = 500;

fn waitForWork(
    a: std.mem.Allocator,
    abort: anytype,
    inbox: []const u8,
    self_name: []const u8,
    config_path: []const u8,
    session: SessionId,
    lease: SessionId,
    expected_cwd: []const u8,
) ?[]u8 {
    while (true) {
        if (abort.isAborted()) return null;
        if (!ownsPersistedMember(a, config_path, self_name, session, lease, expected_cwd)) return null;
        var unread = mailbox.readUnread(a, inbox) catch {
            util_time.sleepMs(POLL_MS);
            continue;
        };
        defer unread.deinit();
        if (unread.items.items.len > 0) {
            // shutdown(仅 team-lead)。
            for (unread.items.items) |*m| {
                if (mailbox.classify(a, m.text) != .shutdown_request) continue;
                if (!std.mem.eql(u8, m.from, team_mod.TEAM_LEAD_NAME) or
                    !leadMessageMatchesCurrentSession(m, session))
                {
                    const bad = [1]mailbox.Message{m.*};
                    mailbox.markReadAt(a, inbox, &bad) catch {};
                    continue; // 伪造 shutdown:丢弃
                }
                const one = [1]mailbox.Message{m.*};
                mailbox.markReadAt(a, inbox, &one) catch {};
                return null; // 优雅退出
            }
            // plain:lead 优先 + peer FIFO。
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(a);
            var consumed: std.ArrayList(mailbox.Message) = .empty;
            defer consumed.deinit(a);
            for ([_]bool{ true, false }) |lead_pass| {
                for (unread.items.items) |*m| {
                    const is_lead = std.mem.eql(u8, m.from, team_mod.TEAM_LEAD_NAME);
                    if (is_lead != lead_pass) continue;
                    if (mailbox.classify(a, m.text) != .plain) continue;
                    if (!plainMessageMatchesCurrentMember(a, config_path, self_name, session, m)) {
                        consumed.append(a, m.*) catch {};
                        continue;
                    }
                    const wire = mailbox.formatForModel(a, m) catch continue;
                    defer a.free(wire);
                    if (out.items.len > 0) out.appendSlice(a, "\n\n") catch {};
                    out.appendSlice(a, wire) catch {};
                    consumed.append(a, m.*) catch {};
                }
            }
            if (consumed.items.len > 0) {
                mailbox.markReadAt(a, inbox, consumed.items) catch {};
                return out.toOwnedSlice(a) catch null;
            }
        }
        util_time.sleepMs(POLL_MS);
    }
}

fn leadMessageMatchesCurrentSession(m: *const mailbox.Message, session: SessionId) bool {
    const raw_session = m.session_id orelse return false;
    const raw_lease = m.lease_id orelse return false;
    const sender_session = SessionId.fromSlice(raw_session) orelse return false;
    const sender_lease = SessionId.fromSlice(raw_lease) orelse return false;
    return std.mem.eql(u8, sender_session.asSlice(), session.asSlice()) and
        std.mem.eql(u8, sender_lease.asSlice(), session.asSlice());
}

fn plainMessageMatchesCurrentMember(
    a: std.mem.Allocator,
    config_path: []const u8,
    self_name: []const u8,
    session: SessionId,
    m: *const mailbox.Message,
) bool {
    const raw_session = m.session_id orelse return false;
    const raw_lease = m.lease_id orelse return false;
    const sender_session = SessionId.fromSlice(raw_session) orelse return false;
    const sender_lease = SessionId.fromSlice(raw_lease) orelse return false;
    if (!std.mem.eql(u8, sender_session.asSlice(), session.asSlice())) return false;
    var name_buf: [64]u8 = undefined;
    const sender = team_mod.sanitizeAgentName(m.from, &name_buf);
    if (std.mem.eql(u8, sender, team_mod.TEAM_LEAD_NAME)) {
        return std.mem.eql(u8, sender_lease.asSlice(), session.asSlice());
    }
    if (std.mem.eql(u8, sender, self_name)) return false;
    var tf = team_mod.load(a, config_path) orelse return false;
    defer tf.deinit();
    const member = tf.findMember(sender) orelse return false;
    const member_session = member.session_id orelse return false;
    const member_lease = member.lease_id orelse return false;
    return std.mem.eql(u8, member_session, sender_session.asSlice()) and
        std.mem.eql(u8, member_lease, sender_lease.asSlice());
}

fn sendNotice(
    a: std.mem.Allocator,
    lead_inbox: []const u8,
    name: []const u8,
    session: SessionId,
    lease: SessionId,
    reason: []const u8,
    detail: ?[]const u8,
) void {
    var ts_buf: [40]u8 = undefined;
    const ts = mailbox.formatIso8601(@divTrunc(util_time.nowWallNs(), 1_000_000), &ts_buf);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    out.writer.writeAll("{\"type\":\"idle_notification\",\"from\":") catch return;
    @import("../util/json.zig").writeJsonString(&out.writer, name) catch return;
    out.writer.writeAll(",\"session_id\":") catch return;
    @import("../util/json.zig").writeJsonString(&out.writer, session.asSlice()) catch return;
    out.writer.writeAll(",\"lease_id\":") catch return;
    @import("../util/json.zig").writeJsonString(&out.writer, lease.asSlice()) catch return;
    out.writer.writeAll(",\"timestamp\":") catch return;
    @import("../util/json.zig").writeJsonString(&out.writer, ts) catch return;
    out.writer.writeAll(",\"idleReason\":") catch return;
    @import("../util/json.zig").writeJsonString(&out.writer, reason) catch return;
    if (detail) |d| {
        if (std.mem.eql(u8, reason, "failed")) {
            out.writer.writeAll(",\"failureReason\":") catch return;
            @import("../util/json.zig").writeJsonString(&out.writer, d) catch return;
        } else {
            out.writer.writeAll(",\"stopReason\":") catch return;
            @import("../util/json.zig").writeJsonString(&out.writer, d) catch return;
        }
    }
    out.writer.writeByte('}') catch return;
    const body = out.toOwnedSlice() catch return;
    defer a.free(body);
    mailbox.deliverWithIdentity(
        a,
        lead_inbox,
        name,
        body,
        null,
        null,
        session.asSlice(),
        lease.asSlice(),
    ) catch {};
}

const ActiveCtx = struct { name: []const u8, lead_session: []const u8, lease: []const u8, active: bool };
fn setActiveMutate(c: ActiveCtx, tf: *team_mod.TeamFile) anyerror!void {
    const lead = tf.lead_session_id orelse return error.SessionMismatch;
    if (!std.mem.eql(u8, lead, c.lead_session)) return error.SessionMismatch;
    const m = tf.findMember(c.name) orelse return error.MemberNotFound;
    if (m.session_id == null or !std.mem.eql(u8, m.session_id.?, c.lead_session)) return error.SessionMismatch;
    if (m.lease_id == null or !std.mem.eql(u8, m.lease_id.?, c.lease)) return error.SessionMismatch;
    m.is_active = c.active;
}
fn setMemberActive(a: std.mem.Allocator, config_path: []const u8, name: []const u8, session: SessionId, lease: SessionId, active: bool) bool {
    if (config_path.len == 0) return false;
    team_mod.updateTeam(a, config_path, ActiveCtx{ .name = name, .lead_session = session.asSlice(), .lease = lease.asSlice(), .active = active }, setActiveMutate) catch return false;
    return true;
}

fn ownsPersistedMember(a: std.mem.Allocator, config_path: []const u8, name: []const u8, session: SessionId, lease: SessionId, expected_cwd: []const u8) bool {
    var tf = team_mod.load(a, config_path) orelse return false;
    defer tf.deinit();
    const lead = tf.lead_session_id orelse return false;
    if (!std.mem.eql(u8, lead, session.asSlice())) return false;
    const member = tf.findMember(name) orelse return false;
    const member_session = member.session_id orelse return false;
    const member_lease = member.lease_id orelse return false;
    if (!std.mem.eql(u8, member_session, session.asSlice()) or
        !std.mem.eql(u8, member_lease, lease.asSlice())) return false;
    if (!std.mem.eql(u8, member.cwd, expected_cwd)) return false;
    if (member.worktree_path) |worktree| if (!std.mem.eql(u8, worktree, expected_cwd)) return false;
    return true;
}

// ============================================================================
// Lead 侧:spawn 进程外 teammate(fork+exec metacodes --teammate)+ worktree 隔离
// ============================================================================

pub const SpawnProcessParams = struct {
    name: []const u8, // sanitized
    team: []const u8, // sanitized
    parent_session: []const u8 = "",
    lease_id: []const u8 = "",
    /// worktree/cwd 目录(非空 → teammate 进程 chdir 进去;lead 应已 git worktree add)。
    cwd: []const u8 = "",
    /// The lead's state root, passed as the child's leading `--state-dir`: a
    /// lead started with `--state-dir` must not have its teammate resolve
    /// another root (team config, transcripts, KG). No default on purpose.
    state_root: []const u8,
    /// 额外 CLI flag 透传(如 --agent-teams --model X);借用。
    extra_flags: []const []const u8 = &.{},
};

/// 构造 teammate 子进程 argv(可测)。exe = 自身可执行文件;身份 + cwd + 透传 flag。
/// 返回 owned `[]?[*:0]const u8`(execve 格式,末尾 null);字符串挂 allocator,caller free(freeArgv)。
pub fn buildTeammateArgv(a: std.mem.Allocator, exe: []const u8, p: SpawnProcessParams) ![]?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    errdefer freeArgv(a, list.items);
    try list.append(a, (try a.dupeZ(u8, exe)).ptr);
    if (p.state_root.len > 0) {
        try list.append(a, (try a.dupeZ(u8, "--state-dir")).ptr);
        try list.append(a, (try a.dupeZ(u8, p.state_root)).ptr);
    }
    try list.append(a, (try a.dupeZ(u8, "--teammate")).ptr);
    try list.append(a, (try a.dupeZ(u8, "--agent-name")).ptr);
    try list.append(a, (try a.dupeZ(u8, p.name)).ptr);
    try list.append(a, (try a.dupeZ(u8, "--team-name")).ptr);
    try list.append(a, (try a.dupeZ(u8, p.team)).ptr);
    if (p.parent_session.len > 0) {
        try list.append(a, (try a.dupeZ(u8, "--parent-session-id")).ptr);
        try list.append(a, (try a.dupeZ(u8, p.parent_session)).ptr);
    }
    if (p.lease_id.len > 0) {
        try list.append(a, (try a.dupeZ(u8, "--teammate-lease-id")).ptr);
        try list.append(a, (try a.dupeZ(u8, p.lease_id)).ptr);
    }
    if (p.cwd.len > 0) {
        try list.append(a, (try a.dupeZ(u8, "--teammate-cwd")).ptr);
        try list.append(a, (try a.dupeZ(u8, p.cwd)).ptr);
    }
    for (p.extra_flags) |f| try list.append(a, (try a.dupeZ(u8, f)).ptr);
    try list.append(a, null);
    return list.toOwnedSlice(a);
}

pub fn freeArgv(a: std.mem.Allocator, argv: []?[*:0]const u8) void {
    for (argv) |item| {
        if (item) |s| a.free(std.mem.span(s));
    }
    a.free(argv);
}

/// 自身可执行文件路径(fork+exec teammate 用)。写进 buf,返回 slice;失败 null。
/// 实现收敛在 platform.paths(KgClient 等共用,三 OS 一份)。
pub fn selfExePath(buf: []u8) ?[]const u8 {
    return @import("platform").paths.selfExePath(buf);
}

/// git worktree add <path> -b <branch> <base>,在 repo 里执行(Linus SW6 MED-2:用 `git -C <repo>`
/// 显式指定 repo,不依赖多线程 lead 的进程全局 cwd)。repo 为空则退回进程 cwd(测试自 chdir)。
/// best-effort:失败返回 error(调用方降级为无 worktree,共享 cwd)。
pub fn createWorktree(a: std.mem.Allocator, wt_path: []const u8, branch: []const u8, base: []const u8, repo: []const u8, abort: anytype) !void {
    const common = @import("../tools/common.zig");
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer freeGitArgv(a, &argv);
    try appendZ(a, &argv, "/usr/bin/env");
    try appendZ(a, &argv, "git");
    if (repo.len > 0) {
        try appendZ(a, &argv, "-C");
        try appendZ(a, &argv, repo);
    }
    for ([_][]const u8{ "worktree", "add", "-b", branch, wt_path, base }) |w| try appendZ(a, &argv, w);
    try argv.append(a, null);
    const out = try common.spawnCaptureWithStderrTimed(argv.items, a, abort, 30_000, null, common.MAX_SPAWN_CAPTURE_BYTES, null);
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    if (out.exit_code != 0) return error.WorktreeAddFailed;
}

fn appendZ(a: std.mem.Allocator, argv: *std.ArrayList(?[*:0]const u8), s: []const u8) !void {
    try argv.append(a, (try a.dupeZ(u8, s)).ptr);
}
fn freeGitArgv(a: std.mem.Allocator, argv: *std.ArrayList(?[*:0]const u8)) void {
    for (argv.items) |it| if (it) |s| a.free(std.mem.span(s));
    argv.deinit(a);
}

/// git worktree remove --force <path>(teammate 关闭后 lead 清理)。repo 同款 -C。best-effort。
pub fn removeWorktree(a: std.mem.Allocator, wt_path: []const u8, repo: []const u8, abort: anytype) void {
    removeWorktreeStrict(a, wt_path, repo, abort) catch |err| {
        log.warn("swarm", "removeWorktree({s}) failed: {s}", .{ wt_path, @errorName(err) });
    };
}

/// Strict variant for callers that publish cleanup state. Returning success
/// means both git accepted the removal and the worktree path is confirmed
/// absent. Swarm teardown intentionally keeps the best-effort wrapper above;
/// AgentDef isolation uses this result to avoid reporting a false cleanup.
pub fn removeWorktreeStrict(a: std.mem.Allocator, wt_path: []const u8, repo: []const u8, abort: anytype) !void {
    const common = @import("../tools/common.zig");
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer freeGitArgv(a, &argv);
    try appendZ(a, &argv, "/usr/bin/env");
    try appendZ(a, &argv, "git");
    if (repo.len > 0) {
        try appendZ(a, &argv, "-C");
        try appendZ(a, &argv, repo);
    }
    for ([_][]const u8{ "worktree", "remove", "--force", wt_path }) |w| try appendZ(a, &argv, w);
    try argv.append(a, null);
    const out = try common.spawnCaptureWithStderrTimed(argv.items, a, abort, 30_000, null, common.MAX_SPAWN_CAPTURE_BYTES, null);
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    if (out.exit_code != 0) return error.WorktreeRemoveFailed;
    const path_z = try a.dupeZ(u8, wt_path);
    defer a.free(path_z);
    if (pfs.exists(path_z.ptr)) return error.WorktreeStillExists;
}

/// spawn 函数签名(DI):生产 = forkExecTeammate;测试注入 mock(不真 fork)验证接线。
pub const SpawnFn = *const fn (a: std.mem.Allocator, p: SpawnProcessParams) anyerror!i64;

/// **lead 侧:spawn 一个进程外 teammate**(C1 接线)。步骤:
///   ① 有 worktree_base → createWorktree(隔离 cwd);② 登记 config 成员(backend_type=process +
///   worktree_path);③ spawn_fn fork+exec 子进程;④ 记录 {pid,name,worktree} 进 sw.process_teammates
///   供关闭时 kill+removeWorktree。spawn_fn 默认 forkExecTeammate(生产);测试注入 mock。
///   前置:team config.json 已存在(TeamCreate 先行)。返回子 pid。
pub fn spawnTeammateProcess(
    sw: *swarm_ctx.SwarmContext,
    name_raw: []const u8,
    worktree_path: []const u8, // 空 = 无 worktree(共享 cwd)
    worktree_base: []const u8, // 非空且 worktree_path 非空 → createWorktree(git 起点,如 HEAD)
    repo: []const u8, // git repo 根(git -C;lead 的 project_dir)。空退回进程 cwd
    parent_session: []const u8,
    abort: anytype,
    spawn_fn: SpawnFn,
    /// lead 的 LSP 是否在位。false → 给子进程带上 `--no-lsp`。LSP 默认开之后不带就等于
    /// "lead 关了、teammate 照样起 rust-analyzer",逃生口在进程边界上漏掉。
    lsp_enabled: bool,
) !i64 {
    const a = sw.allocator;
    const parent_id = SessionId.fromSlice(parent_session) orelse return error.InvalidSession;
    const lease_id = @import("../core/session_id.zig").gen();
    if (!std.mem.eql(u8, parent_id.asSlice(), sw.session.asSlice()))
        return error.SessionMismatch;
    var name_buf: [64]u8 = undefined;
    const name_s = team_mod.sanitizeAgentName(name_raw[0..@min(name_raw.len, 64)], &name_buf);
    if (name_s.len == 0) return error.BadName;
    if (std.ascii.eqlIgnoreCase(name_s, team_mod.TEAM_LEAD_NAME)) return error.ReservedName;
    if (!sw.hasTeam()) return error.NoActiveTeam;

    // ① worktree(best-effort:失败降级为无隔离)。
    var effective_wt = worktree_path;
    if (worktree_path.len > 0 and worktree_base.len > 0) {
        var br_buf: [96]u8 = undefined;
        const branch = std.fmt.bufPrint(&br_buf, "teammate-{s}", .{name_s}) catch name_s;
        createWorktree(a, worktree_path, branch, worktree_base, repo, abort) catch {
            log.warn("swarm", "createWorktree({s}) failed; teammate {s} shares cwd", .{ worktree_path, name_s });
            effective_wt = ""; // 降级
        };
    }
    errdefer if (effective_wt.len > 0 and worktree_base.len > 0) removeWorktree(a, effective_wt, repo, abort);

    // ② 登记 config 成员(backend_type=process + worktree_path)。
    var cfg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cfg = sw.configPath(&cfg_buf);
    var id_buf: [96]u8 = undefined;
    const agent_id = team_mod.formatAgentId(name_s, sw.team_sanitized, &id_buf) orelse return error.BadName;
    const AddCtx = struct { agent_id: []const u8, name: []const u8, cwd: []const u8, wt: []const u8, session: []const u8, lease: []const u8 };
    const addFn = struct {
        fn f(c: AddCtx, tf: *team_mod.TeamFile) anyerror!void {
            const lead_session = tf.lead_session_id orelse return error.SessionMismatch;
            if (!std.mem.eql(u8, lead_session, c.session)) return error.SessionMismatch;
            if (tf.findMember(c.name) != null) return error.DuplicateTeammateName;
            try tf.addMember(.{
                .agent_id = c.agent_id,
                .name = c.name,
                .cwd = c.cwd,
                .session_id = c.session,
                .lease_id = c.lease,
                .worktree_path = if (c.wt.len > 0) c.wt else null,
                .backend_type = "process",
                .is_active = true,
            });
        }
    }.f;
    try team_mod.updateTeam(a, cfg, AddCtx{ .agent_id = agent_id, .name = name_s, .cwd = effective_wt, .wt = effective_wt, .session = parent_id.asSlice(), .lease = lease_id.asSlice() }, addFn);
    errdefer {
        const RmCtx = struct { name: []const u8, session: []const u8, lease: []const u8 };
        const rmFn = struct {
            fn f(c: RmCtx, tf: *team_mod.TeamFile) anyerror!void {
                const lead_session = tf.lead_session_id orelse return error.SessionMismatch;
                if (!std.mem.eql(u8, lead_session, c.session)) return error.SessionMismatch;
                const member = tf.findMember(c.name) orelse return error.MemberNotFound;
                const member_session = member.session_id orelse return error.SessionMismatch;
                const member_lease = member.lease_id orelse return error.SessionMismatch;
                if (!std.mem.eql(u8, member_session, c.session) or
                    !std.mem.eql(u8, member_lease, c.lease)) return error.SessionMismatch;
                _ = tf.removeMember(c.name);
            }
        }.f;
        team_mod.updateTeam(a, cfg, RmCtx{ .name = name_s, .session = parent_id.asSlice(), .lease = lease_id.asSlice() }, rmFn) catch {};
    }

    // ③ fork+exec(或 mock)。
    var flags: [3][]const u8 = undefined;
    var preview_arg: [@import("../preview.zig").Features.max_arg_len]u8 = undefined;
    var flag_count: usize = 0;
    if (!lsp_enabled) {
        flags[flag_count] = "--no-lsp";
        flag_count += 1;
    }
    flags[flag_count] = "--no-preview";
    flag_count += 1;
    if (!sw.preview.eql(.none)) {
        flags[flag_count] = sw.preview.enableArg(&preview_arg);
        flag_count += 1;
    }
    const pid = try spawn_fn(a, .{
        .name = name_s,
        .team = sw.team_sanitized,
        .parent_session = parent_session,
        .lease_id = lease_id.asSlice(),
        .cwd = effective_wt,
        .state_root = sw.state_root,
        .extra_flags = flags[0..flag_count],
    });
    // The child is live but not yet owned by process_teammates. Any
    // allocation/append failure below must terminate and reap it before the
    // config rollback removes its membership.
    // `forkExecTeammate` is POSIX-only and returns an integer pid.  The
    // injected spawn seam is still compiled on Windows for ABI/component
    // tests, where the platform process handle is a pointer.  Keep the
    // cleanup branch compile-time eliminated there instead of attempting an
    // invalid integer cast (and keep Windows ownership cleanup in
    // `terminateProcessTeammates`).
    errdefer {
        if (comptime builtin.os.tag != .windows) {
            process_mod.killJob(@intCast(pid));
            process_mod.reapBlocking(@intCast(pid));
        }
    }

    // ④ 记录供关闭清理。
    const name_owned = try a.dupe(u8, name_s);
    errdefer a.free(name_owned);
    const wt_owned = try a.dupe(u8, effective_wt);
    errdefer a.free(wt_owned);
    const repo_owned = try a.dupe(u8, repo);
    errdefer a.free(repo_owned);
    try sw.process_teammates.append(a, .{ .pid = pid, .session = parent_id, .lease = lease_id, .name = name_owned, .worktree_path = wt_owned, .repo = repo_owned });
    log.info("swarm", "spawned out-of-process teammate {s} pid={d} worktree={s}", .{ agent_id, pid, effective_wt });
    return pid;
}

/// fork+exec 一个 detached teammate 子进程。返回子 pid(>0)。失败返回 error。
/// setsid 脱离控制终端(不被 lead 的 Ctrl+C 直杀;lead 经 mailbox shutdown 优雅关);
/// stdin/out/err 重定向 /dev/null(headless teammate 绝不碰终端)。
pub fn forkExecTeammate(a: std.mem.Allocator, p: SpawnProcessParams) !i64 {
    // 进程外 teammate 是 POSIX-only(fork/setsid/execve)。Windows 不支持(要 CreateProcessW,
    // 完全不同)——comptime gate 让下方 POSIX 分支在 Windows 编译时被剔除,swarm 进程外后端
    // 在 Windows 降级不可用(--teammate-mode process 报 Unsupported)。in-process teammate 仍可用。
    if (@import("builtin").os.tag == .windows) return error.Unsupported;
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = selfExePath(&exe_buf) orelse return error.NoSelfExe;
    // **全部分配在 fork 之前**(Linus SW6:fork 与 execve 之间只允许 async-signal-safe 调用,
    // 分配器加锁非 async-signal-safe,子进程里 dupeZ 可能死锁)。argv[0] 已是 exe 的 [*:0],
    // execve 直接用它,子进程不再分配。
    const argv = try buildTeammateArgv(a, exe, p);
    defer freeArgv(a, argv);
    const exe_path_z: [*:0]const u8 = argv[0].?; // argv[0] = dupeZ(exe),NUL 结尾

    // 与 platform/process 的 spawn 共用 fork 串行锁:这个 fork 不能落在别处"建了 pipe
    // 还没关子进程侧"的窗口里,否则那条 pipe 会跟着进 teammate 进程,对方永远等不到 EOF。
    process_mod.forkSerialLock();
    const pid = std.c.fork();
    if (pid < 0) {
        process_mod.forkSerialUnlock();
        return error.ForkFailed;
    }
    if (pid == 0) {
        // 子进程:只用 async-signal-safe 调用(setsid/open/dup2/close/execve),不分配。
        _ = std.c.setsid();
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR }, @as(std.c.mode_t, 0));
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 0);
            _ = std.c.dup2(devnull, 1);
            _ = std.c.dup2(devnull, 2);
            if (devnull > 2) _ = std.c.close(devnull);
        }
        @import("platform").signal.defaultBrokenPipeInChild();
        _ = std.c.execve(exe_path_z, @ptrCast(argv.ptr), @ptrCast(std.c.environ));
        std.c._exit(127); // execve 失败
    }
    process_mod.forkSerialUnlock();
    return @intCast(pid); // 父进程:返回子 pid(i64 平台中立)
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Identity sanitize + reserved-name guard 语义" {
    var buf: [64]u8 = undefined;
    const s = team_mod.sanitizeAgentName("Worker_1", &buf);
    try testing.expectEqualStrings("Worker_1", s);
    try testing.expect(std.ascii.eqlIgnoreCase("team-lead", "Team-Lead"));
}

test "buildTeammateArgv: 身份 + cwd + 透传 flag 全在 argv" {
    const a = testing.allocator;
    const argv = try buildTeammateArgv(a, "/usr/local/bin/metacodes", .{
        .name = "bob",
        .team = "proj",
        .parent_session = "sess1",
        .lease_id = "lease1",
        .cwd = "/tmp/wt",
        .state_root = "/srv/state",
        .extra_flags = &.{ "--agent-teams", "--model", "x" },
    });
    // The lead's state root is the child's leading global option.
    try testing.expectEqualStrings("--state-dir", std.mem.span(argv[1].?));
    try testing.expectEqualStrings("/srv/state", std.mem.span(argv[2].?));
    defer freeArgv(a, argv);
    // 收集成字符串集合断言。
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(a);
    for (argv) |item| {
        if (item) |s| {
            try joined.appendSlice(a, std.mem.span(s));
            try joined.append(a, '\n');
        }
    }
    const all = joined.items;
    try testing.expect(std.mem.indexOf(u8, all, "/usr/local/bin/metacodes\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "--teammate\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "--agent-name\nbob\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "--team-name\nproj\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "--parent-session-id\nsess1\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "--teammate-lease-id\nlease1\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "--teammate-cwd\n/tmp/wt\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "--agent-teams\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "--model\nx\n") != null);
    try testing.expect(argv[argv.len - 1] == null); // execve null 结尾
}

test "buildTeammateArgv: 无 parent/cwd 时省略对应 flag" {
    const a = testing.allocator;
    const argv = try buildTeammateArgv(a, "metacodes", .{ .name = "x", .team = "t", .state_root = "" });
    defer freeArgv(a, argv);
    var found_parent = false;
    var found_cwd = false;
    var found_state = false;
    for (argv) |item| {
        if (item) |s| {
            const sp = std.mem.span(s);
            if (std.mem.eql(u8, sp, "--parent-session-id")) found_parent = true;
            if (std.mem.eql(u8, sp, "--teammate-cwd")) found_cwd = true;
            if (std.mem.eql(u8, sp, "--state-dir")) found_state = true;
        }
    }
    try testing.expect(!found_parent and !found_cwd and !found_state);
}

test "process ownership requires lead session and per-spawn lease" {
    const a = testing.allocator;
    const session = SessionId.fromSlice("0123456789abcdef01234567").?;
    const lease = SessionId.fromSlice("fedcba987654321001234567").?;
    const other_lease = SessionId.fromSlice("aaaaaaaaaaaaaaaaaaaaaaaa").?;
    var home_buf: [256]u8 = undefined;
    const home = @import("../util/fs.zig").testing.uniqueDir(&home_buf, "cc-zig-process-owner");
    defer @import("../util/fs.zig").testing.rmrfBestEffort(home);
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    try @import("../util/fs.zig").mkdirParents(team_mod.teamDirPath(home, "proj", &dir_buf));
    var tf = team_mod.TeamFile{
        .allocator = a,
        .name = try a.dupe(u8, "proj"),
        .lead_agent_id = try a.dupe(u8, "team-lead@proj"),
        .lead_session_id = try a.dupe(u8, session.asSlice()),
    };
    defer tf.deinit();
    try tf.addMember(.{ .agent_id = "worker@proj", .name = "worker", .session_id = session.asSlice(), .lease_id = lease.asSlice() });
    var cfg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cfg = team_mod.configPath(home, "proj", &cfg_buf);
    try team_mod.save(a, &tf, cfg);
    try testing.expect(ownsPersistedMember(a, cfg, "worker", session, lease, ""));
    try testing.expect(!ownsPersistedMember(a, cfg, "worker", session, other_lease, ""));
    try testing.expect(!ownsPersistedMember(a, cfg, "worker", other_lease, lease, ""));
    try testing.expect(!ownsPersistedMember(a, cfg, "worker", session, lease, "/wrong-worktree"));
}

test "selfExePath 返回非空(macos/linux/windows)" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = selfExePath(&buf);
    try testing.expect(p != null);
    try testing.expect(p.?.len > 0);
}
