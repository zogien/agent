//! L2: configuration written wrong is reported, not silently ineffective.
//!
//! A malformed hook does not fail - it never fires. A Skill without a
//! `description` is listed to the model with its first body line or with
//! nothing; an agent without one is listed to the Task tool with nothing; an
//! agent file that does not parse is skipped. Each of these used to be visible
//! only as a `warn` log line, below the default log level. Loading semantics
//! are unchanged (the broken piece is still skipped or degraded); what is
//! locked here is that every such case reaches the user:
//!   - `App.hook_diagnostics` / the Skill catalog / `AgentSet` hold a typed
//!     record of it after a real `App.init`;
//!   - `/hooks`, `/skills` and `/agents` render it (`writeHooksReport`, ...);
//!   - the startup banner and `/doctor` count it (`formatConfigProblems`);
//!   - the well-formed configuration next to it loads and works as before,
//!     and a well-formed file reports nothing (both sides).
//!
//! Cross-module: app (init, loadSettings, loadHooks) + permission/hooks +
//! permission/loader + skills runtime catalog + cli_adapter + agents/set +
//! agents/def + repl/loop renderers. chdir is process-wide: the fixture
//! restores the process cwd.

const std = @import("std");
const builtin = @import("builtin");
const cc = @import("cc");
const ppaths = @import("platform").paths;
const pfs = @import("platform").fs;

const EnvGuard = struct {
    allocator: std.mem.Allocator,
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(allocator: std.mem.Allocator, name: [*:0]const u8, value: [*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try allocator.dupeZ(u8, std.mem.span(raw)) else null;
        ppaths.setEnv(name, value);
        return .{ .allocator = allocator, .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            self.allocator.free(previous);
        } else {
            ppaths.unsetEnv(self.name);
        }
        self.* = undefined;
    }
};

fn chdirTo(path: []const u8) !void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    if (pfs.chdir(z.ptr) != 0) return error.ChdirFailed;
}

/// A file written below the fixture root before the App starts.
const File = struct { path: []const u8, data: []const u8 };

/// A real App whose HOME is `<tmp>/home` and whose working directory is the
/// repository `<tmp>/repo`. `setup` must run on the caller's final address.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    io_rt: std.Io.Threaded,
    home_guard: EnvGuard,
    codex_guard: EnvGuard,
    probe_guard: EnvGuard,
    autostart_guard: EnvGuard,
    previous_cwd: []u8,
    app: *cc.app_module.App,
    home: []const u8,
    repo: []const u8,

    fn setup(self: *Fixture, files: []const File) !void {
        const a = std.testing.allocator;
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = try self.tmp.dir.realPath(std.testing.io, &root_buffer);

        self.arena = std.heap.ArenaAllocator.init(a);
        errdefer self.arena.deinit();
        const allocator = self.arena.allocator();
        const root = try allocator.dupe(u8, root_buffer[0..len]);
        self.home = try std.fs.path.join(allocator, &.{ root, "home" });
        self.repo = try std.fs.path.join(allocator, &.{ root, "repo" });
        try self.tmp.dir.createDirPath(std.testing.io, "home");
        // A `.git` directory is all `findRepoRoot` needs to make `repo` the project.
        try self.tmp.dir.createDirPath(std.testing.io, "repo/.git");
        for (files) |file| {
            if (std.fs.path.dirname(file.path)) |dir| try self.tmp.dir.createDirPath(std.testing.io, dir);
            try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = file.path, .data = file.data });
        }

        self.home_guard = try EnvGuard.set(a, "HOME", (try allocator.dupeZ(u8, self.home)).ptr);
        errdefer self.home_guard.restore();
        // `$CODEX_HOME` is absolute: left alone it would add the host's Codex Skills.
        const codex_home = try std.fs.path.joinZ(allocator, &.{ self.home, ".codex" });
        self.codex_guard = try EnvGuard.set(a, "CODEX_HOME", codex_home.ptr);
        errdefer self.codex_guard.restore();
        self.probe_guard = try EnvGuard.set(a, "METACODES_NO_PROBE", "1");
        errdefer self.probe_guard.restore();
        self.autostart_guard = try EnvGuard.set(a, "METACODES_KG_AUTOSTART", "0");
        errdefer self.autostart_guard.restore();

        const argv = [_][*:0]const u8{ "metacodes", "--permission", "bypassPermissions" };
        const config = cc.parseArgsForTest(&argv, allocator);
        try std.testing.expect(config.parse_error == null);

        // The App snapshots the process cwd as its session root.
        self.previous_cwd = try cc.util_fs.getCwd(a);
        errdefer a.free(self.previous_cwd);
        try chdirTo(self.repo);
        errdefer chdirTo(self.previous_cwd) catch {};

        self.io_rt = @import("platform").signal.threadedIo(allocator, .{});
        errdefer self.io_rt.deinit();
        self.app = try cc.app_module.App.init(a, self.io_rt.io(), config, "test-key");
    }

    fn deinit(self: *Fixture) void {
        self.app.deinit();
        self.io_rt.deinit();
        chdirTo(self.previous_cwd) catch {};
        std.testing.allocator.free(self.previous_cwd);
        self.autostart_guard.restore();
        self.probe_guard.restore();
        self.codex_guard.restore();
        self.home_guard.restore();
        self.arena.deinit();
        self.tmp.cleanup();
    }

    /// A settings or agent file as the product names it: `App.loadHooks` and
    /// `AgentSet` append `/<rel>` to the directory, so on Windows the name
    /// mixes `\` (from the cwd) with `/`. `std.fs.path.join` would not match.
    fn path(self: *Fixture, base: []const u8, rel: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}/{s}", .{ base, rel });
    }
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("\n--- expected to find ---\n{s}\n--- in ---\n{s}\n", .{ needle, haystack });
        return error.TestExpectedSubstring;
    }
}

const hooks_mod = cc.permission_hooks;

const USER_SETTINGS_WITH_PROBLEMS =
    \\{"hooks":{
    \\  "SessionStart":[{"hooks":[{"type":"command","command":"./boot.sh"}]}],
    \\  "PostToolUSE":[{"matcher":"Edit","hooks":[{"type":"command","command":"./lint.sh"}]}],
    \\  "PreToolUse":[
    \\    "Bash",
    \\    {"matcher":"Bash","hooks":[
    \\      {"type":"command","command":"cat >/dev/null; echo 'blocked by policy' >&2; exit 2","timeout":30},
    \\      {"type":"prompt","prompt":"is this safe?"},
    \\      {"type":"command"},
    \\      {"type":"command","command":"./slow.sh","timeout":"soon"}
    \\    ]},
    \\    {"matcher":"Write"}
    \\  ],
    \\  "Stop":[{"hooks":[{"type":"command","command":"./remember.sh"}]}]
    \\}}
;

test "hooks: every malformed piece is reported; the well-formed hooks load and run" {
    var fx: Fixture = undefined;
    try fx.setup(&.{
        .{ .path = "home/.claude/settings.json", .data = USER_SETTINGS_WITH_PROBLEMS },
        // The project's shared settings are not JSON at all.
        .{ .path = "repo/.claude/settings.json", .data = "{\"hooks\":{\"PreToolUse\":[}" },
        // Hooks in a file metacodes reads only for permissions never run.
        .{ .path = "repo/.claude/settings.local.json", .data = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"command\":\"./local.sh\"}]}]}}" },
    });
    defer fx.deinit();
    const app = fx.app;
    const user_settings = try fx.path(fx.home, ".claude/settings.json");
    const project_settings = try fx.path(fx.repo, ".claude/settings.json");
    const local_settings = try fx.path(fx.repo, ".claude/settings.local.json");

    // The typed record: one problem per skipped piece, each naming its file.
    const diag = &(app.hook_diagnostics orelse return error.NoHookDiagnostics);
    const Expect = struct { kind: hooks_mod.ProblemKind, source: []const u8, location: []const u8 };
    const expected = [_]Expect{
        .{ .kind = .unread_settings_file, .source = local_settings, .location = "hooks" },
        .{ .kind = .invalid_json, .source = project_settings, .location = "" },
        .{ .kind = .unsupported_event, .source = user_settings, .location = "hooks.SessionStart" },
        .{ .kind = .unknown_event, .source = user_settings, .location = "hooks.PostToolUSE" },
        .{ .kind = .entry_not_object, .source = user_settings, .location = "hooks.PreToolUse[0]" },
        .{ .kind = .unsupported_type, .source = user_settings, .location = "hooks.PreToolUse[1].hooks[1].type" },
        .{ .kind = .missing_command, .source = user_settings, .location = "hooks.PreToolUse[1].hooks[2]" },
        .{ .kind = .invalid_timeout, .source = user_settings, .location = "hooks.PreToolUse[1].hooks[3].timeout" },
        .{ .kind = .entry_hooks_not_array, .source = user_settings, .location = "hooks.PreToolUse[2].hooks" },
    };
    const problems = diag.items();
    try std.testing.expectEqual(expected.len, problems.len);
    for (expected, problems) |want, got| {
        try std.testing.expectEqual(want.kind, got.kind);
        try std.testing.expectEqualStrings(want.source, got.source);
        try std.testing.expectEqualStrings(want.location, got.location);
    }
    try expectContains(diag.find(.unknown_event).?.message, "did you mean PostToolUse?");

    // Loading is unchanged: the well-formed hooks are wired into the permission chain.
    const set = &(app.hooks orelse return error.NoHooksLoaded);
    try std.testing.expect(app.permission_ctx.hooks == set);
    try std.testing.expectEqual(@as(usize, 2), set.pre_tool_use.len);
    try std.testing.expectEqualStrings("Bash", set.pre_tool_use[0].matcher);
    try std.testing.expectEqual(@as(usize, 2), set.pre_tool_use[0].commands.len);
    try std.testing.expectEqualStrings("./slow.sh", set.pre_tool_use[0].commands[1]);
    try std.testing.expectEqual(@as(i64, 30_000), set.pre_tool_use[0].timeoutMs(0));
    try std.testing.expectEqual(@as(usize, 0), set.pre_tool_use[1].commands.len);
    try std.testing.expectEqual(@as(usize, 1), set.stop.len);
    try std.testing.expectEqualStrings("./remember.sh", set.stop[0].commands[0]);
    try std.testing.expect(!set.hasPost());

    // ... and the loaded PreToolUse hook really blocks Bash.
    if (builtin.os.tag != .windows) {
        const first_only = [_]hooks_mod.HookEntry{.{ .matcher = "Bash", .commands = set.pre_tool_use[0].commands[0..1] }};
        const probe = hooks_mod.HookSet{ .pre_tool_use = &first_only, .allocator = std.testing.allocator };
        const result = hooks_mod.runPreToolUseFull(&probe, std.testing.allocator, "Bash", "{\"command\":\"ls\"}", null);
        defer if (result.modified_input) |m| std.testing.allocator.free(m);
        try std.testing.expectEqual(hooks_mod.HookDecision.block, result.decision);
    }

    try std.testing.expectEqual(@as(usize, 9), app.configProblems().hooks);
}

test "hooks: well-formed settings report nothing; no settings say where hooks go" {
    {
        var fx: Fixture = undefined;
        try fx.setup(&.{
            .{ .path = "home/.claude/settings.json", .data =
            \\{"permissions":{"allow":["Read"]},"hooks":{
            \\  "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"./check.sh","timeout":5}]}],
            \\  "PostToolUse":[{"matcher":"Write|Edit","hooks":[{"command":"./lint.sh"}]}],
            \\  "PreCompact":[{"hooks":[{"type":"command","command":"./snapshot.sh"}]}]
            \\}}
            },
            .{ .path = "repo/.claude/settings.local.json", .data = "{\"permissions\":{\"deny\":[]}}" },
        });
        defer fx.deinit();
        try std.testing.expectEqual(@as(usize, 0), fx.app.hook_diagnostics.?.items().len);
        const set = &fx.app.hooks.?;
        try std.testing.expectEqualStrings("./check.sh", set.pre_tool_use[0].commands[0]);
        try std.testing.expectEqualStrings("./lint.sh", set.post_tool_use[0].commands[0]);
        try std.testing.expectEqualStrings("./snapshot.sh", set.pre_compact[0].commands[0]);
        try std.testing.expectEqual(@as(usize, 0), fx.app.configProblems().total());
    }
    {
        var fx: Fixture = undefined;
        try fx.setup(&.{});
        defer fx.deinit();
        try std.testing.expect(fx.app.hooks == null);
        try std.testing.expectEqual(@as(usize, 0), fx.app.hook_diagnostics.?.items().len);
    }
}

test "skills: a Skill without a description loads as before and is reported" {
    var fx: Fixture = undefined;
    try fx.setup(&.{
        .{ .path = "home/.claude/skills/described/SKILL.md", .data = "---\nname: described\ndescription: Review the staged diff\n---\nReview it.\n" },
        .{ .path = "home/.claude/skills/fallback/SKILL.md", .data = "---\nname: fallback\n---\n\nSummarize the release notes\nThen post them.\n" },
        .{ .path = "repo/.claude/skills/blank/SKILL.md", .data = "---\nname: blank\n---\n" },
    });
    defer fx.deinit();
    const snapshot = fx.app.skill_runtime.snapshot orelse return error.NoCatalog;

    // Loading is unchanged: all three load; the fallback is Claude Code's.
    const described = snapshot.findByInvocation("described") orelse return error.MissingSkill;
    const fallback = snapshot.findByInvocation("fallback") orelse return error.MissingSkill;
    const blank = snapshot.findByInvocation("blank") orelse return error.MissingSkill;
    try std.testing.expectEqual(cc.skills_runtime.definition.DescriptionSource.frontmatter, described.definition.description_source);
    try std.testing.expectEqual(cc.skills_runtime.definition.DescriptionSource.body_first_line, fallback.definition.description_source);
    try std.testing.expectEqualStrings("Summarize the release notes", fallback.definition.description);
    try std.testing.expectEqual(cc.skills_runtime.definition.DescriptionSource.missing, blank.definition.description_source);
    try std.testing.expectEqualStrings("", blank.definition.description);

    // What the model is shown is what it always was.
    const listing = try cc.skills_runtime.model_tool.buildDescription(std.testing.allocator, snapshot);
    defer std.testing.allocator.free(listing);
    try expectContains(listing, "- fallback: Summarize the release notes\n");
    try expectContains(listing, "- described: Review the staged diff\n");

    try std.testing.expectEqual(@as(usize, 2), fx.app.configProblems().skills);
}

test "skills: described Skills report nothing" {
    var fx: Fixture = undefined;
    try fx.setup(&.{
        .{ .path = "home/.claude/skills/described/SKILL.md", .data = "---\nname: described\ndescription: Review the staged diff\n---\nReview it.\n" },
        .{ .path = "repo/.agents/skills/folded/SKILL.md", .data = "---\nname: folded\ndescription: >\n  Deploy the\n  service\n---\nbody\n" },
    });
    defer fx.deinit();
    const snapshot = fx.app.skill_runtime.snapshot orelse return error.NoCatalog;
    try std.testing.expect(snapshot.findByInvocation("described") != null);
    try std.testing.expect(snapshot.findByInvocation("folded") != null);
    try std.testing.expectEqual(@as(usize, 0), fx.app.configProblems().skills);
}

test "skills: a blank name or description reads as absent, falls back, and is reported (#395)" {
    var fx: Fixture = undefined;
    try fx.setup(&.{
        // The #395 reproduction.
        .{ .path = "repo/.agents/skills/demo/SKILL.md", .data = "---\nname: \"\"\ndescription: \"\"\n---\n\nUse for demonstrating an empty frontmatter.\n" },
        // Whitespace-only, with no body line to fall back to.
        .{ .path = "home/.claude/skills/hollow/SKILL.md", .data = "---\nname: hollow\ndescription: \"   \"\n---\n" },
        .{ .path = "home/.claude/skills/described/SKILL.md", .data = "---\nname: described\ndescription: Review the staged diff\n---\nReview it.\n" },
    });
    defer fx.deinit();
    const snapshot = fx.app.skill_runtime.snapshot orelse return error.NoCatalog;
    const definition = cc.skills_runtime.definition;

    // All three load; the blank fields get the fallbacks an absent one gets.
    try std.testing.expectEqual(@as(usize, 3), snapshot.skills.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.issues.len);
    const demo = snapshot.findByInvocation("demo") orelse return error.MissingSkill;
    try std.testing.expectEqualStrings("demo", demo.definition.name);
    try std.testing.expectEqualStrings("Use for demonstrating an empty frontmatter.", demo.definition.description);
    try std.testing.expectEqual(definition.DescriptionSource.body_first_line, demo.definition.description_source);
    try std.testing.expect(demo.definition.warnings.eql(.init(.{ .blank_name = true, .blank_description = true })));
    const hollow = snapshot.findByInvocation("hollow") orelse return error.MissingSkill;
    try std.testing.expectEqualStrings("", hollow.definition.description);
    try std.testing.expectEqual(definition.DescriptionSource.missing, hollow.definition.description_source);
    try std.testing.expect(hollow.definition.warnings.eql(.init(.{ .blank_description = true })));

    // What `--dump-prompt` prints: the system prompt, then each tool's
    // description. The model now sees the fallback instead of a bare name.
    const prompt = fx.app.system_prompt orelse return error.NoSystemPrompt;
    try expectContains(prompt, "- **demo** — Use for demonstrating an empty frontmatter.\n");
    try expectContains(prompt, "- **hollow**\n");
    try expectContains(prompt, "- **described** — Review the staged diff\n");
    const skill_tool = for (fx.app.tool_defs) |tool| {
        if (std.mem.eql(u8, tool.name, "Skill")) break tool;
    } else return error.NoSkillTool;
    try expectContains(skill_tool.description, "- demo: Use for demonstrating an empty frontmatter.\n");
    try expectContains(skill_tool.description, "- described: Review the staged diff\n");

    // Counted once per Skill, however many fields were blank.
    try std.testing.expectEqual(@as(usize, 2), fx.app.configProblems().skills);
}

test "agents: a broken file and a missing description are reported; the rest load" {
    var fx: Fixture = undefined;
    try fx.setup(&.{
        .{ .path = "home/.claude/agents/reviewer.md", .data = "---\nname: reviewer\ndescription: Review pending changes\n---\nYou review.\n" },
        .{ .path = "home/.claude/agents/silent.md", .data = "---\nname: silent\ntools: Read, Grep\n---\nYou search.\n" },
        .{ .path = "repo/.claude/agents/broken.md", .data = "---\nname: broken\ndescription: d\neffort: turbo\n---\nbody\n" },
    });
    defer fx.deinit();
    const agents = &fx.app.agents;

    // Loading is unchanged: the broken file is skipped, the other two load.
    try std.testing.expect(agents.find("reviewer") != null);
    const silent = agents.find("silent") orelse return error.MissingAgent;
    try std.testing.expect(agents.find("broken") == null);
    try std.testing.expect(cc.agents_set.AgentSet.missingDescription(silent));
    try std.testing.expectEqual(@as(usize, 1), agents.missingDescriptionCount());

    const broken_path = try fx.path(fx.repo, ".claude/agents/broken.md");
    try std.testing.expectEqual(@as(usize, 1), agents.load_failures.items.len);
    try std.testing.expectEqualStrings(broken_path, agents.load_failures.items[0].path);
    try std.testing.expectEqualStrings("InvalidAgentEffort", agents.load_failures.items[0].reason);

    try std.testing.expectEqual(@as(usize, 2), fx.app.configProblems().agents);
}

test "agents: well-formed agents report nothing" {
    var fx: Fixture = undefined;
    try fx.setup(&.{
        .{ .path = "home/.claude/agents/reviewer.md", .data = "---\nname: reviewer\ndescription: Review pending changes\n---\nYou review.\n" },
    });
    defer fx.deinit();
    try std.testing.expect(fx.app.agents.find("reviewer") != null);
    try std.testing.expectEqual(@as(usize, 0), fx.app.agents.load_failures.items.len);
    try std.testing.expectEqual(@as(usize, 0), fx.app.agents.missingDescriptionCount());
    try std.testing.expectEqual(@as(usize, 0), fx.app.configProblems().total());
}
