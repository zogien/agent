const std = @import("std");

// 包清单是版本声明的仓库层权威;代码侧唯一拷贝在 src/version.zig。两者一致性由
// runtime_arm_smoke 的 --expected-version 在 `zig build test` 中用真实二进制强制。
const manifest = @import("build.zig.zon");

// highlight-zig 轻量高亮库(Y2:已取代 tree-sitter 做 diff 高亮)。纯 Zig + 嵌入 rules_blob.zlib,
// 零 C 依赖,200+ 语言。作为 git submodule 位于 lib/highlight-zig(独立 repo
// github.com/shuzuan-org/highlight-zig),纯 Zig 模块方式消费其源(每个 root 各按自身
// optimize 编译;未用的 import 零成本)。tree-sitter 已于 2026-07-13 整体移除。
var g_hl_mod: ?*std.Build.Module = null;
var g_code_mod: ?*std.Build.Module = null;
var g_formal_kernel_sha256: ?[]const u8 = null;
var g_project_kernel_sha256: ?[]const u8 = null;
var g_sandbox_helper_install: ?*std.Build.Step = null;
var g_sandbox_helper_path: ?[]const u8 = null;
fn addHl(b: *std.Build, mod: *std.Build.Module) void {
    addHlWithProjectHarnessActuation(b, mod, false);
}

/// Project-Harness actuation is an artifact property, never a runtime switch.
/// Every ordinary product/test/library root is compiled enforced.  The sole
/// shadow artifact is wired explicitly below and is not part of `install`.
fn addHlWithProjectHarnessActuation(
    b: *std.Build,
    mod: *std.Build.Module,
    evaluation_shadow: bool,
) void {
    if (g_hl_mod == null) {
        g_hl_mod = b.createModule(.{ .root_source_file = b.path("lib/highlight-zig/src/lib.zig") });
    }
    mod.addImport("hl", g_hl_mod.?);
    if (g_code_mod == null) {
        const code = b.createModule(.{ .root_source_file = b.path("src/code/runtime.zig"), .link_libc = true });
        // vendor/quickjs holds upstream bytes plus patches/*.patch; the engine
        // is compiled from the verified, patched tree the stage script writes.
        const quickjs = stageQuickJsSources(b);
        code.addIncludePath(quickjs);
        code.addIncludePath(b.path("src/code"));
        // Searched after the libc headers: only fills <sys/time.h> where the
        // C runtime lacks it (Windows MSVC).
        code.addAfterIncludePath(b.path("src/code/compat"));
        // The embedded engine and bridge are private implementation details;
        // AgentCore shared libraries export only their declared public ABI.
        const code_flags: []const []const u8 = &.{ "-std=gnu11", "-D_GNU_SOURCE", "-DCONFIG_VERSION=\"2025-09-13\"", "-DMETACODES_NO_ATOMICS", "-fwrapv", "-fvisibility=hidden", "-include", b.pathFromRoot("src/code/quickjs_port.h") };
        code.addCSourceFiles(.{
            .root = quickjs,
            .files = &.{ "quickjs.c", "cutils.c", "dtoa.c", "libregexp.c", "libunicode.c" },
            .flags = code_flags,
        });
        code.addCSourceFile(.{ .file = b.path("src/code/bridge.c"), .flags = code_flags });
        g_code_mod = code;
    }
    mod.addImport("code_runtime", g_code_mod.?);
    addPlatform(b, mod); // platform 底座与 hl 同套模块（凡编译 app 代码者都需要）
    const project_harness_options = b.addOptions();
    project_harness_options.addOption(bool, "evaluation_shadow", evaluation_shadow);
    project_harness_options.addOption(?[]const u8, "formal_kernel_expected_sha256", g_formal_kernel_sha256);
    project_harness_options.addOption(?[]const u8, "project_kernel_expected_sha256", g_project_kernel_sha256);
    mod.addOptions("project_harness_build_options", project_harness_options);
}

// platform —— 可移植系统抽象层(sync/process/fs/signal/rng/paths)。作为命名模块暴露,
// 让 test:lsp 隔离模块(根在 src/lsp/,无法相对 import 上层 ../platform/)也能用。
var g_platform_mod: ?*std.Build.Module = null;
fn addPlatform(b: *std.Build, mod: *std.Build.Module) void {
    if (g_platform_mod == null) {
        g_platform_mod = b.createModule(.{ .root_source_file = b.path("src/platform/platform.zig") });
    }
    mod.addImport("platform", g_platform_mod.?);
}

/// Every Zig test executable that can run on Windows shares the same legacy
/// `/tmp` compatibility prerequisite. Keep that policy at test-run creation so
/// new isolated suites cannot silently forget it.
fn addTestRunArtifact(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(artifact);
    // A test gate must execute on every invocation; a warm build cache may
    // skip recompilation but never test execution. Zig 0.16 re-runs .zig_test
    // steps regardless, but state the doctrine here so a future caching change
    // cannot silently turn cached test binaries into stale green evidence.
    run.has_side_effects = true;
    if (g_sandbox_helper_install) |install| {
        run.step.dependOn(install);
        run.setEnvironmentVariable("METACODES_SANDBOX_HELPER", g_sandbox_helper_path.?);
    }
    return run;
}

/// A nested `zig build` is part of the caller's build graph, so it must honor
/// the caller-selected local and global caches instead of creating an implicit
/// second cache under the consumer fixture.
fn addNestedBuildCacheArgs(b: *std.Build, run: *std.Build.Step.Run) void {
    run.addArgs(&.{
        "--cache-dir",
        b.cache_root.path orelse ".",
        "--global-cache-dir",
        b.graph.global_cache_root.path orelse ".",
    });
}

const TinyKgBinaryInput = union(enum) {
    disabled,
    unavailable,
    bundled: BundledTinyKg,
    explicit: struct {
        path: []const u8,
        sha256: []const u8,
    },
};

const BundledTinyKg = struct {
    key: []const u8,
    path: []const u8,
    sha256: []const u8,
    target_family: []const u8,
};

const BundleTableEntry = struct {
    key: []const u8,
    role: []const u8,
    path: []const u8,
    sha256: []const u8,
    targets: []const []const u8,
};

/// The second, independently committed copy of the bundle digests.
/// `tinykg:stage` hands the digest below to `scripts/stage_tinykg_binary.py`,
/// which compares it with `vendor/tinykg/manifest.json` before staging a byte,
/// so editing the manifest alone cannot change what a build installs. Reading
/// the digest out of that same manifest would make the comparison attest to
/// itself. `scripts/build_tinykg_bundle.py` regenerates everything between the
/// markers, which must stay on their own lines.
// tinykg-bundle-table:begin
const tinykg_bundle_table = [_]BundleTableEntry{
    .{ .key = "macos-universal", .role = "cli", .path = "vendor/tinykg/bin/tinykg-macos-universal", .sha256 = "dd53db2aa5219e899daac3caac2332648ac392550fa6f431b5900a1d495688e1", .targets = &.{ "aarch64-macos", "x86_64-macos" } },
    .{ .key = "macos-universal-daemon", .role = "daemon", .path = "vendor/tinykg/bin/tinykgd-macos-universal", .sha256 = "f1dd9f9a472bb58fa7dcd749a2a4df1a03d63c6dc7093054096beeb3b205722f", .targets = &.{ "aarch64-macos", "x86_64-macos" } },
    .{ .key = "linux-x86_64", .role = "cli", .path = "vendor/tinykg/bin/tinykg-linux-x86_64", .sha256 = "6ff8346aa0c5e9a9cf10cfa3357bfa2767699bf4735c8fd2e12d39cc12ee1521", .targets = &.{"x86_64-linux"} },
    .{ .key = "linux-x86_64-daemon", .role = "daemon", .path = "vendor/tinykg/bin/tinykgd-linux-x86_64", .sha256 = "5d8f11e3bfe96a3845aa6d1166ac9341a59b622f355dc5de1c27675f0c5e5614", .targets = &.{"x86_64-linux"} },
    .{ .key = "linux-aarch64", .role = "cli", .path = "vendor/tinykg/bin/tinykg-linux-aarch64", .sha256 = "2f601a8d27eba6956f61e87da84f83ad3a247db111233de0d74031bbff87fca0", .targets = &.{"aarch64-linux"} },
    .{ .key = "linux-aarch64-daemon", .role = "daemon", .path = "vendor/tinykg/bin/tinykgd-linux-aarch64", .sha256 = "a5132e77776c607328b5dd7b59b7af643fd406b0ae031dff062d144ac774a3eb", .targets = &.{"aarch64-linux"} },
    .{ .key = "windows-x86_64", .role = "cli", .path = "vendor/tinykg/bin/tinykg-windows-x86_64.exe", .sha256 = "61b9281880dda0eaadadf051e16191ee46b8c454771e4639171dd90aed5e8044", .targets = &.{"x86_64-windows"} },
    .{ .key = "windows-x86_64-daemon", .role = "daemon", .path = "vendor/tinykg/bin/tinykgd-windows-x86_64.exe", .sha256 = "aca73b00590df898c65d0a2741dafd6e7805a78ff3fd4ec6ce7a7495a6481281", .targets = &.{"x86_64-windows"} },
};
// tinykg-bundle-table:end

fn bundledTinyKgForTarget(b: *std.Build, target: std.Target, role: []const u8) ?BundledTinyKg {
    const family = b.fmt("{s}-{s}", .{ @tagName(target.cpu.arch), @tagName(target.os.tag) });
    var selected: ?BundledTinyKg = null;
    for (tinykg_bundle_table) |entry| {
        if (!std.mem.eql(u8, entry.role, role)) continue;
        for (entry.targets) |candidate| {
            if (!std.mem.eql(u8, candidate, family)) continue;
            if (selected != null) @panic("duplicate TinyKG target/role ownership");
            if (!isLowerSha256(entry.sha256)) @panic("invalid TinyKG bundle table SHA-256");
            selected = .{
                .key = entry.key,
                .path = entry.path,
                .sha256 = entry.sha256,
                .target_family = candidate,
            };
        }
    }
    return selected;
}

fn isLowerSha256(value: []const u8) bool {
    return isLowerHex(value, 64);
}

fn isLowerHex(value: []const u8, len: usize) bool {
    if (value.len != len) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

const RipgrepBundleInfo = struct {
    version: []const u8,
    revision: []const u8,
    sha256: ?[]const u8,
    /// Repository-relative path of the vendored binary for this target.
    path: ?[]const u8,
};

/// Hands the repository-pinned ripgrep to a test process: the tests that must
/// run against exactly the manifest-pinned binary (Grep's argv contract, #460)
/// read it from here instead of whatever `rg` is on PATH, and check the digest
/// before using it. A target without a vendored binary says so explicitly
/// (`unavailable`, not an empty value Windows may drop), so a test can tell a
/// missing pin from missing wiring.
fn wirePinnedRipgrepTestInput(b: *std.Build, run: *std.Build.Step.Run, ripgrep: RipgrepBundleInfo) void {
    const path = ripgrep.path orelse {
        run.setEnvironmentVariable("METACODES_TEST_PINNED_RG", "unavailable");
        return;
    };
    run.setEnvironmentVariable("METACODES_TEST_PINNED_RG", b.pathFromRoot(b.fmt("vendor/ripgrep/{s}", .{path})));
    run.setEnvironmentVariable("METACODES_TEST_PINNED_RG_SHA256", ripgrep.sha256.?);
}

/// `vendor/ripgrep/manifest.json` names the upstream release and, per target,
/// the vendored binary's digest; a target without one resolves rg from the
/// environment and carries no expectation.
fn ripgrepBundleInfo(b: *std.Build, target: std.Target) RipgrepBundleInfo {
    const Manifest = struct {
        artifacts: []const struct { sha256: []const u8, path: []const u8, targets: []const []const u8 },
        upstream_release: []const u8,
        upstream_revision: []const u8,
    };
    const parsed = parseJsonFile(b, Manifest, "vendor/ripgrep/manifest.json");
    const family = b.fmt("{s}-{s}", .{ @tagName(target.cpu.arch), @tagName(target.os.tag) });
    var sha256: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    for (parsed.artifacts) |artifact| {
        for (artifact.targets) |candidate| {
            if (std.mem.eql(u8, candidate, family)) {
                sha256 = artifact.sha256;
                path = artifact.path;
            }
        }
    }
    return .{ .version = parsed.upstream_release, .revision = parsed.upstream_revision, .sha256 = sha256, .path = path };
}

const TinyKgContractInfo = struct { version: []const u8, source_commit: []const u8 };

fn tinyKgContractInfo(b: *std.Build) TinyKgContractInfo {
    const contract = parseJsonFile(b, struct { tinykg_version: []const u8 }, "deps/tinykg.json");
    const bundle = parseJsonFile(b, struct { source_commit: []const u8 }, "vendor/tinykg/manifest.json");
    return .{ .version = contract.tinykg_version, .source_commit = bundle.source_commit };
}

/// Configure-time read of a repository JSON document into `T`; the strings
/// stay alive in the build allocator. Unknown fields are ignored so a manifest
/// can grow without touching the build identity.
/// Verifies `vendor/quickjs` against its manifest and writes the patched engine
/// tree (`scripts/stage_quickjs_sources.py`). Every manifest-pinned file is an
/// input, so editing a source or a patch re-runs the stage.
fn stageQuickJsSources(b: *std.Build) std.Build.LazyPath {
    const Pinned = struct { path: []const u8 };
    const pinned = parseJsonFile(b, struct { files: []const Pinned, patches: []const Pinned }, "vendor/quickjs/manifest.json");
    const stage = b.addSystemCommand(&.{ if (@import("builtin").os.tag == .windows) "python" else "python3", "scripts/stage_quickjs_sources.py", "--out" });
    stage.setCwd(b.path("."));
    const out = stage.addOutputDirectoryArg("quickjs");
    stage.addFileInput(b.path("scripts/stage_quickjs_sources.py"));
    stage.addFileInput(b.path("vendor/quickjs/manifest.json"));
    for (pinned.files) |item| stage.addFileInput(b.path(b.fmt("vendor/quickjs/{s}", .{item.path})));
    for (pinned.patches) |item| stage.addFileInput(b.path(b.fmt("vendor/quickjs/{s}", .{item.path})));
    return out;
}

fn parseJsonFile(b: *std.Build, comptime T: type, path: []const u8) T {
    const bytes = b.build_root.handle.readFileAlloc(b.graph.io, path, b.allocator, .limited(1024 * 1024)) catch |err|
        std.debug.panic("cannot read {s}: {t}", .{ path, err });
    return std.json.parseFromSliceLeaky(T, b.allocator, bytes, .{ .ignore_unknown_fields = true }) catch |err|
        std.debug.panic("invalid {s}: {t}", .{ path, err });
}

/// TinyKG is an external, manually maintained native artifact. Normal builds
/// select one manifest-pinned repository asset; an explicit override still
/// requires path and operator-observed digest together. Ambient binaries and
/// stale checkouts remain unrepresentable in the build graph.
fn tinyKgBinaryInput(b: *std.Build, target: std.Target) TinyKgBinaryInput {
    const legacy = b.option(bool, "tinykg", "Deprecated compatibility flag; only false is accepted");
    if (legacy == true) @panic("-Dtinykg=true was removed; use -Dtinykg-bin=<absolute path> and -Dtinykg-sha256=<digest>");

    const bundled_option = b.option(bool, "tinykg-bundled", "Install the checked-in target-specific TinyKG binary (default true)");
    if (legacy != null and bundled_option != null) @panic("-Dtinykg and -Dtinykg-bundled cannot be combined");

    const path = b.option([]const u8, "tinykg-bin", "Absolute path to a maintainer-supplied TinyKG CLI override (CLI-only)");
    const sha256 = b.option([]const u8, "tinykg-sha256", "Observed SHA-256 of the TinyKG CLI override (CLI-only)");
    if (path == null and sha256 == null) {
        const enabled = bundled_option orelse if (legacy) |value| value else true;
        if (!enabled) return .disabled;
        return if (bundledTinyKgForTarget(b, target, "cli")) |bundle| .{ .bundled = bundle } else .unavailable;
    }
    const resolved_path = path orelse @panic("-Dtinykg-bin and -Dtinykg-sha256 must be supplied together");
    const resolved_sha256 = sha256 orelse @panic("-Dtinykg-bin and -Dtinykg-sha256 must be supplied together");
    if (!std.fs.path.isAbsolute(resolved_path)) @panic("-Dtinykg-bin must be an absolute path");
    if (!isLowerSha256(resolved_sha256)) @panic("-Dtinykg-sha256 must be 64 lowercase hex characters");
    return .{ .explicit = .{ .path = resolved_path, .sha256 = resolved_sha256 } };
}

const StagedTinyKg = struct {
    install_step: *std.Build.Step,
    artifact: std.Build.LazyPath,
    installed_path: []const u8,
    source_sha256: []const u8,
};

const StagedTinyKgd = struct {
    install_step: *std.Build.Step,
    /// `vendor/tinykg/tinykgd.provenance.json`, which the release unit ships.
    receipt_install_step: *std.Build.Step,
    artifact: std.Build.LazyPath,
    installed_path: []const u8,
    source_sha256: []const u8,
};

fn wireTinyKgTestInput(run: *std.Build.Step.Run, staged: ?StagedTinyKg) void {
    const tinykg = staged orelse return;
    run.step.dependOn(tinykg.install_step);
    run.setEnvironmentVariable("METACODES_TEST_TINYKG_BIN", tinykg.installed_path);
}

fn wireTinyKgdTestInput(run: *std.Build.Step.Run, staged: ?StagedTinyKgd) void {
    const daemon = staged orelse return;
    run.step.dependOn(daemon.install_step);
    run.setEnvironmentVariable("METACODES_TEST_TINYKGD_BIN", daemon.installed_path);
}

/// `-Dlean-kernels`: whether this build compiles the two Lean governance
/// kernels from this checkout and installs them into `<prefix>/libexec/metacodes`.
/// `auto` does so whenever a native Lean toolchain (`lake`) is found, so a
/// machine with elan runs every kernel-gated test with no configuration; `on`
/// fails the build instead of skipping when it is not; `off` never builds them.
const LeanKernelsMode = enum { auto, on, off };

const StagedLeanKernel = struct {
    install_step: *std.Build.Step,
    installed_path: []const u8,
    /// The test-only variable that hands the kernel to the test process; the
    /// digest comes from the provenance sidecar installed beside it
    /// (src/formal/test_kernel.zig).
    path_variable: []const u8,
};

const StagedLeanKernels = struct {
    formal: ?StagedLeanKernel = null,
    project: ?StagedLeanKernel = null,
};

fn wireLeanKernelTestInputs(run: *std.Build.Step.Run, staged: StagedLeanKernels) void {
    for ([_]?StagedLeanKernel{ staged.formal, staged.project }) |maybe| {
        const kernel = maybe orelse continue;
        run.step.dependOn(kernel.install_step);
        run.setEnvironmentVariable(kernel.path_variable, kernel.installed_path);
    }
}

/// The `lake` the kernel scripts run: `$LAKE`, else PATH, else elan's default
/// `~/.elan/bin` (`%USERPROFILE%\.elan\bin` on Windows, where cmd and
/// PowerShell set no HOME). The toolchain is the only shared input; every
/// kernel it builds lands in this build's own prefix.
fn findLake(b: *std.Build) ?[]const u8 {
    const env = &b.graph.environ_map;
    if (env.get("LAKE")) |lake| if (lake.len != 0) return lake;
    const home = env.get("HOME") orelse
        (if (b.graph.host.result.os.tag == .windows) env.get("USERPROFILE") else null) orelse
        return b.findProgram(&.{"lake"}, &.{}) catch null;
    return b.findProgram(&.{"lake"}, &.{b.pathJoin(&.{ home, ".elan", "bin" })}) catch null;
}

/// The pinned toolchain's own `lake` behind elan's proxy: `elan which lake`
/// inside control-plane/lean resolves its lean-toolchain pin. The native
/// project-Harness suites pin every artifact they run by digest and refuse a
/// multi-link file, which the proxy is. Null when `lake` is not elan's (a
/// `$LAKE` or PATH lake is used as found) or elan cannot answer.
fn toolchainLake(b: *std.Build, lake: []const u8) ?[]const u8 {
    const dir = std.fs.path.dirname(lake) orelse return null;
    const elan_name = if (b.graph.host.result.os.tag == .windows) "elan.exe" else "elan";
    const elan = b.pathJoin(&.{ dir, elan_name });
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ elan, "which", "lake" },
        .cwd = .{ .path = b.pathFromRoot("control-plane/lean") },
    }) catch return null;
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const path = std.mem.trim(u8, result.stdout, " \t\r\n");
    return if (path.len == 0) null else path;
}

/// The bash the kernel scripts run under. On Windows it must be Git Bash
/// (MSYS2): the scripts take Windows paths and build a Windows kernel, but the
/// `bash` cmd finds first is often WSL's launcher (System32\bash.exe or the
/// WindowsApps alias), whose Linux shell can do neither. The first other
/// bash.exe on PATH wins, else the one Git for Windows ships beside `git`.
fn findBash(b: *std.Build) ?[]const u8 {
    if (b.graph.host.result.os.tag != .windows) return "bash";
    const io = b.graph.io;
    if (b.graph.environ_map.get("PATH")) |path| {
        var dirs = std.mem.tokenizeScalar(u8, path, ';');
        while (dirs.next()) |raw_dir| {
            const dir = std.mem.trimEnd(u8, raw_dir, "\\/");
            const base = std.fs.path.basenameWindows(dir);
            if (std.ascii.eqlIgnoreCase(base, "System32") or std.ascii.eqlIgnoreCase(base, "WindowsApps")) continue;
            const candidate = b.pathJoin(&.{ dir, "bash.exe" });
            std.Io.Dir.accessAbsolute(io, candidate, .{}) catch continue;
            return candidate;
        }
    }
    // Git for Windows: <root>\cmd\git.exe or <root>\mingw64\bin\git.exe, with
    // the bash launcher at <root>\bin\bash.exe.
    const git = b.findProgram(&.{"git"}, &.{}) catch return null;
    var root = std.fs.path.dirnameWindows(git);
    for (0..3) |_| {
        const dir = root orelse return null;
        const candidate = b.pathJoin(&.{ dir, "bin", "bash.exe" });
        if (std.Io.Dir.accessAbsolute(io, candidate, .{})) |_| return candidate else |_| {}
        root = std.fs.path.dirnameWindows(dir);
    }
    return null;
}

/// `<bash> <script> --lake <lake>`, with an empty pipe for stdin. A Run step
/// with output-file arguments gets stdin and stdout "ignored", which Zig 0.16
/// realises on Windows as one shared \Device\Null handle in both slots; the
/// MSYS runtime behind Git Bash makes stderr distinct from stdout but not
/// stdin. The first `$(...)` then closes the shared handle, and every native
/// program started in a later command substitution inherits a dead or reused
/// stdin: the elan `lake` proxy failed with "The handle is invalid (os error
/// 6)" or "The request is not supported (os error 50)", and MSYS tools with
/// EBADF (#180).
fn addKernelScript(b: *std.Build, bash: []const u8, name: []const u8, script: []const u8, lake: []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{bash});
    run.setName(name);
    run.setStdIn(.{ .bytes = "" });
    run.addFileArg(b.path(script));
    // An argument, not setEnvironmentVariable: setting one variable copies the
    // whole environment into the cache key, and the kernels (with their
    // timestamped receipt) would rebuild whenever any variable changed.
    run.addArgs(&.{ "--lake", lake });
    return run;
}

/// Every source the kernels are built from, so the cached build reruns exactly
/// when one of them changes. `.lake` holds Lake's own products and is skipped.
fn addLeanSourceInputs(b: *std.Build, run: *std.Build.Step.Run) void {
    run.addFileInput(b.path("scripts/check_kernel_self_contained.py"));
    const root = "control-plane/lean";
    var dir = b.build_root.handle.openDir(b.graph.io, root, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| std.debug.panic("cannot scan {s}: {t}", .{ root, err });
    defer dir.close(b.graph.io);
    var walker = dir.walkSelectively(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(b.graph.io) catch |err|
        std.debug.panic("cannot enumerate {s}: {t}", .{ root, err })) |entry|
    {
        switch (entry.kind) {
            .directory => if (!std.mem.eql(u8, entry.basename, ".lake"))
                walker.enter(b.graph.io, entry) catch |err|
                    std.debug.panic("cannot enter {s}/{s}: {t}", .{ root, entry.path, err }),
            .file => run.addFileInput(b.path(b.fmt("{s}/{s}", .{ root, entry.path }))),
            else => {},
        }
    }
}

/// Builds both kernels with their own scripts (axiom audit + native smoke +
/// provenance sidecar) into cached outputs and installs them, sidecars
/// included, at `<prefix>/libexec/metacodes` — the layout the executable
/// resolves adjacent kernels from. A kernel the operator already supplies via
/// `METACODES_TEST_<KIND>_KERNEL_PATH` is left to that variable.
fn stageLeanKernels(
    b: *std.Build,
    mode: LeanKernelsMode,
    target: std.Build.ResolvedTarget,
    stage_step: *std.Build.Step,
) StagedLeanKernels {
    if (mode == .off) {
        stage_step.dependOn(&b.addFail("kernels:stage is disabled by -Dlean-kernels=off").step);
        return .{};
    }
    const host = b.graph.host.result;
    const unavailable: ?[]const u8 = if (target.result.os.tag != host.os.tag or target.result.cpu.arch != host.cpu.arch)
        "Lean kernels are native host executables; this build targets another platform"
    else if (findLake(b) == null)
        "no Lean toolchain: set LAKE, put lake on PATH, or install elan (~/.elan/bin/lake)"
    else if (findBash(b) == null)
        "no Git Bash: the kernel scripts need Git for Windows' bash.exe on PATH or beside git (WSL's bash cannot build a Windows kernel)"
    else
        null;
    if (unavailable) |reason| {
        const fail = &b.addFail(b.fmt("kernels:stage: {s}", .{reason})).step;
        stage_step.dependOn(fail);
        if (mode == .auto) return .{};
        // -Dlean-kernels=on: every wired test run that would have needed a
        // staged kernel inherits the failure instead of skipping.
        const env = &b.graph.environ_map;
        return .{
            .formal = if (env.get("METACODES_TEST_FORMAL_KERNEL_PATH") != null) null else .{
                .install_step = fail,
                .installed_path = "",
                .path_variable = "METACODES_TEST_FORMAL_KERNEL_PATH",
            },
            .project = if (env.get("METACODES_TEST_PROJECT_KERNEL_PATH") != null) null else .{
                .install_step = fail,
                .installed_path = "",
                .path_variable = "METACODES_TEST_PROJECT_KERNEL_PATH",
            },
        };
    }
    const lake = findLake(b).?;
    const bash = findBash(b).?;
    const dir: std.Build.InstallDir = .{ .custom = "libexec/metacodes" };
    // The executable resolves `<prefix>/libexec/metacodes/<kernel>[.exe]`
    // (src/util/toolchain.zig); the scripts run under Git Bash on Windows.
    const exe_suffix = if (target.result.os.tag == .windows) ".exe" else "";
    const formal_name = b.fmt("metacodes-formal-kernel{s}", .{exe_suffix});
    const project_name = b.fmt("metacodes-project-kernel{s}", .{exe_suffix});

    const formal = addKernelScript(b, bash, "build formal kernel", "scripts/build-formal-kernel.sh", lake);
    const formal_bin = formal.addOutputFileArg(formal_name);
    const formal_provenance = formal.addOutputFileArg(b.fmt("{s}.provenance.json", .{formal_name}));
    const formal_receipt = formal.addOutputFileArg(b.fmt("{s}.build-receipt.json", .{formal_name}));
    addLeanSourceInputs(b, formal);

    const project = addKernelScript(b, bash, "build project kernel", "scripts/build-project-harness-kernel.sh", lake);
    const project_bin = project.addOutputFileArg(project_name);
    const project_provenance = project.addOutputFileArg(b.fmt("{s}.provenance.json", .{project_name}));
    addLeanSourceInputs(b, project);
    // Both scripts drive Lake in the same control-plane/lean/.lake.
    project.step.dependOn(&formal.step);

    const install_formal = b.addInstallFileWithDir(formal_bin, dir, formal_name);
    const install_formal_provenance = b.addInstallFileWithDir(formal_provenance, dir, b.fmt("{s}.provenance.json", .{formal_name}));
    const install_formal_receipt = b.addInstallFileWithDir(formal_receipt, dir, b.fmt("{s}.build-receipt.json", .{formal_name}));
    install_formal.step.dependOn(&install_formal_provenance.step);
    install_formal.step.dependOn(&install_formal_receipt.step);
    const install_project = b.addInstallFileWithDir(project_bin, dir, project_name);
    const install_project_provenance = b.addInstallFileWithDir(project_provenance, dir, b.fmt("{s}.provenance.json", .{project_name}));
    install_project.step.dependOn(&install_project_provenance.step);
    stage_step.dependOn(&install_formal.step);
    stage_step.dependOn(&install_project.step);

    const env = &b.graph.environ_map;
    return .{
        .formal = if (env.get("METACODES_TEST_FORMAL_KERNEL_PATH") != null) null else .{
            .install_step = &install_formal.step,
            .installed_path = b.getInstallPath(dir, formal_name),
            .path_variable = "METACODES_TEST_FORMAL_KERNEL_PATH",
        },
        .project = if (env.get("METACODES_TEST_PROJECT_KERNEL_PATH") != null) null else .{
            .install_step = &install_project.step,
            .installed_path = b.getInstallPath(dir, project_name),
            .path_variable = "METACODES_TEST_PROJECT_KERNEL_PATH",
        },
    };
}

const aggregate_test_exclusions = [_][]const u8{
    // Has a dedicated ABI artifact/consumer gate with a different module graph.
    "component/agentcore_abi_test.zig",
    // Consumes AgentCore wrapper modules (session_budget/mcp_session/
    // model_skill_tool) through metacodes-core (lib.zig root). The aggregate
    // suite imports cc (main.zig root); one compilation cannot own the same
    // src files under both roots, so this file gets its own module graph.
    "component/tool_dispatcher_metadata_test.zig",
};

fn isAggregateTestExclusion(path: []const u8) bool {
    for (aggregate_test_exclusions) |excluded| {
        if (std.mem.eql(u8, path, excluded)) return true;
    }
    return false;
}

fn countAggregateImport(source: []const u8, expected_line: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), expected_line)) {
            count = std.math.add(usize, count, 1) catch @panic("integration inventory count overflow");
        }
    }
    return count;
}

/// Fail during build-graph construction if a new component/integration test
/// is not wired into the aggregate suite. The old one-artifact-per-file graph
/// discovered new files implicitly; aggregation is much faster, but needs this
/// explicit guard so the speedup can never silently reduce coverage.
fn validateAggregateTestInventory(b: *std.Build) void {
    const suite = b.build_root.handle.readFileAlloc(
        b.graph.io,
        "tests/integration_suite.zig",
        b.allocator,
        .limited(1024 * 1024),
    ) catch |err| std.debug.panic("cannot read aggregate test inventory: {t}", .{err});

    const roots = [_]struct { dir: []const u8, prefix: []const u8 }{
        .{ .dir = "tests/component", .prefix = "component" },
        .{ .dir = "tests/integration", .prefix = "integration" },
    };
    for (roots) |root| {
        var dir = b.build_root.handle.openDir(b.graph.io, root.dir, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| std.debug.panic("cannot scan {s}: {t}", .{ root.dir, err });
        defer dir.close(b.graph.io);
        var walker = dir.walk(b.allocator) catch |err|
            std.debug.panic("cannot walk {s}: {t}", .{ root.dir, err });
        defer walker.deinit();

        while (walker.next(b.graph.io) catch |err|
            std.debug.panic("cannot enumerate {s}: {t}", .{ root.dir, err })) |entry|
        {
            const kind = if (entry.kind == .unknown)
                (entry.dir.statFile(b.graph.io, entry.basename, .{ .follow_symlinks = false }) catch |err|
                    std.debug.panic("cannot stat {s}/{s}: {t}", .{ root.dir, entry.path, err })).kind
            else
                entry.kind;
            if (kind != .file or !std.mem.endsWith(u8, entry.basename, "_test.zig")) continue;
            const path = b.fmt("{s}/{s}", .{ root.prefix, entry.path });
            std.mem.replaceScalar(u8, path, '\\', '/');
            const expected_line = b.fmt("_ = @import(\"{s}\");", .{path});
            const occurrences = countAggregateImport(suite, expected_line);
            if (isAggregateTestExclusion(path)) {
                if (occurrences != 0) std.debug.panic(
                    "dedicated test {s} must not also appear in tests/integration_suite.zig",
                    .{path},
                );
            } else if (occurrences != 1) {
                std.debug.panic(
                    "aggregate test inventory requires exactly one @import for {s}; found {}",
                    .{ path, occurrences },
                );
            }
        }
    }
    for (aggregate_test_exclusions) |excluded| {
        const path = b.fmt("tests/{s}", .{excluded});
        const stat = b.build_root.handle.statFile(b.graph.io, path, .{
            .follow_symlinks = false,
        }) catch |err| std.debug.panic("dedicated test exclusion is missing: {s}: {t}", .{ path, err });
        if (stat.kind != .file) std.debug.panic("dedicated test exclusion is not a regular file: {s}", .{path});
    }
}

fn agentcoreRustTarget(target: std.Target) ?[]const u8 {
    if (target.os.tag == .windows) {
        if (target.cpu.arch == .x86_64) return switch (target.abi) {
            .msvc => "x86_64-pc-windows-msvc",
            .gnu => "x86_64-pc-windows-gnu",
            else => null,
        };
        if (target.cpu.arch == .aarch64) return switch (target.abi) {
            .msvc => "aarch64-pc-windows-msvc",
            .gnu => "aarch64-pc-windows-gnullvm",
            else => null,
        };
    }
    if (target.cpu.arch == .x86_64 and target.os.tag == .linux and target.abi == .gnu)
        return "x86_64-unknown-linux-gnu";
    if (target.cpu.arch == .aarch64 and target.os.tag == .linux and target.abi == .gnu)
        return "aarch64-unknown-linux-gnu";
    if (target.cpu.arch == .x86_64 and target.os.tag == .macos) return "x86_64-apple-darwin";
    if (target.cpu.arch == .aarch64 and target.os.tag == .macos) return "aarch64-apple-darwin";
    return null;
}

const AgentCoreAbiModuleOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
    core_mod: *std.Build.Module,
    types_mod: *std.Build.Module,
    protocol_mod: *std.Build.Module,
};

/// Create a fresh AgentCore ABI module for one artifact policy. Tests and the
/// distributable library deliberately use distinct module instances: strip is
/// a delivery concern and must never leak into in-tree test executables.
fn createAgentCoreAbiModule(b: *std.Build, options: AgentCoreAbiModuleOptions) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/agentcore/abi_v1.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .strip = options.strip,
        .link_libc = true,
    });
    addHl(b, mod);
    mod.addImport("metacodes-core", options.core_mod);
    mod.addImport("metask_agentcore_types", options.types_mod);
    mod.addImport("metask_agentcore_protocol", options.protocol_mod);
    if (options.target.result.os.tag == .windows)
        mod.linkSystemLibrary("advapi32", .{ .use_pkg_config = .no });
    if (options.target.result.os.tag == .windows and options.target.result.abi == .msvc)
        mod.addCSourceFile(.{ .file = b.path("src/agentcore/windows_msvc_crt_shims.c"), .flags = &.{"-std=c11"} });
    if (options.target.result.os.tag == .windows and options.target.result.abi == .gnu)
        mod.addCSourceFile(.{ .file = b.path("src/agentcore/windows_gnu_crt_shims.c"), .flags = &.{"-std=c11"} });
    return mod;
}

/// src/lib.zig, the whole metacodes-core graph. Its suite compiles every
/// declaration (`refAllDecls`), so a green build also proves that the library
/// never reaches the UI layer.
fn createCoreModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addHl(b, mod);
    return mod;
}

fn createIntegrationModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    harness: *std.Build.Module,
    implementation: *std.Build.Module,
    mock_mcp_server: std.Build.LazyPath,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("tests/integration_suite.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const options = b.addOptions();
    options.addOptionPath("mock_mcp_server", mock_mcp_server);
    options.addOptionPath("mock_mcp_http_script", b.path("tests/_harness/mock_mcp_http_server.py"));
    options.addOptionPath("mock_mcp_auth_script", b.path("tests/_harness/mock_mcp_auth_server.py"));
    mod.addOptions("integration_options", options);
    mod.addImport("harness", harness);
    mod.addImport("metacodes-core", implementation);
    addPlatform(b, mod);
    return mod;
}

/// The complete metacodes-core suite as one test executable whose tests
/// scripts/sharded_test_runner.zig partitions deterministically. `test:lib`
/// builds it at the invocation's -Doptimize and `gate:pr` at ReleaseSafe; both
/// come from here, so at equal optimize they are one compilation.
fn addCoreSuite(
    b: *std.Build,
    root_module: *std.Build.Module,
    tfilter: ?[]const u8,
) *std.Build.Step.Compile {
    return b.addTest(.{
        .name = "metacodes-core-test",
        .root_module = root_module,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
        .test_runner = .{
            .path = b.path("scripts/sharded_test_runner.zig"),
            .mode = .simple,
        },
    });
}

/// Runs `suite` as `shards` processes that each execute only their own
/// partition. The returned step is the reporter, which accepts the captured
/// reports only when together they cover exactly the compiled test inventory.
fn addCoreSuiteRun(
    b: *std.Build,
    suite: *std.Build.Step.Compile,
    shards: u8,
    reporter: *std.Build.Step.Compile,
    lean_kernels: StagedLeanKernels,
) *std.Build.Step {
    const reports = b.allocator.alloc(std.Build.LazyPath, shards) catch @panic("OOM");
    for (reports, 0..) |*report, shard_index| {
        const run_shard = addTestRunArtifact(b, suite);
        // captureStdOut would otherwise make the Run step cacheable. A test
        // gate must execute on every invocation; cached reports are evidence
        // from an earlier repository/environment state, not current feedback.
        run_shard.has_side_effects = true;
        run_shard.setEnvironmentVariable("METACODES_TEST_SHARD_COUNT", b.fmt("{}", .{shards}));
        run_shard.setEnvironmentVariable("METACODES_TEST_SHARD_INDEX", b.fmt("{}", .{shard_index}));
        run_shard.expectExitCode(0);
        wireLeanKernelTestInputs(run_shard, lean_kernels);
        report.* = run_shard.captureStdOut(.{
            .basename = b.fmt("{s}-shard-{}.txt", .{ suite.name, shard_index }),
        });
    }
    const run_reporter = b.addRunArtifact(reporter);
    for (reports) |report| run_reporter.addFileArg(report);
    return &run_reporter.step;
}

pub fn build(b: *std.Build) void {
    validateAggregateTestInventory(b);
    // The System-One advisor is on only where a service is named (#474: the CLI
    // no longer takes a built-in one), and a developer's shell may name one.
    // Every step this build runs — test binaries, the product they spawn, the
    // Python suites — must not consult it: its answers would steer recall from
    // a machine outside the test, and the test's state would leave it. Run
    // steps without their own environment use this map, and
    // setEnvironmentVariable starts from a copy of it, so one entry covers
    // all; set before any step copies it.
    // `off`, not an empty value: Windows cannot be relied on to pass one.
    b.graph.environ_map.put("METACODES_JEV_URL", "off") catch @panic("OOM");
    // Tests isolate the product with a temporary HOME, but `CODEX_HOME` names
    // an absolute directory that a temporary HOME does not move: left in place,
    // every App a test builds would load the developer's Codex Skills and start
    // the MCP servers in its config.toml (doc/SKILLS_AND_MCP.md).
    _ = b.graph.environ_map.orderedRemove("CODEX_HOME");
    const target = b.standardTargetOptions(.{
        .default_target = if (b.graph.host.result.os.tag == .windows)
            .{ .os_tag = .windows, .abi = .msvc }
        else
            .{},
    });
    const target_was_explicit = b.user_input_options.contains("target");
    const optimize = b.standardOptimizeOption(.{});
    g_formal_kernel_sha256 = b.option([]const u8, "formal-kernel-sha256", "SHA-256 of the adjacent formal governance kernel");
    if (g_formal_kernel_sha256) |value| if (!isLowerSha256(value))
        @panic("-Dformal-kernel-sha256 must be 64 lowercase hex characters");
    g_project_kernel_sha256 = b.option([]const u8, "project-kernel-sha256", "SHA-256 of the adjacent project governance kernel");
    if (g_project_kernel_sha256) |value| if (!isLowerSha256(value))
        @panic("-Dproject-kernel-sha256 must be 64 lowercase hex characters");
    // TinyKG source remains outside the Metacodes graph. Normal builds select a
    // checked-in, manifest-pinned target binary. A maintainer may override it
    // with an absolute path plus digest. Native staging validates version and a
    // fresh store; cross staging validates digest, format, arch, and version bytes.
    const tinykg_input = tinyKgBinaryInput(b, target.result);
    const tfilter = b.option([]const u8, "tfilter", "test filter");
    const lib_test_shards = b.option(u8, "lib-test-shards", "Parallel metacodes-core test shards (1-64)") orelse 4;
    if (lib_test_shards == 0 or lib_test_shards > 64) @panic("-Dlib-test-shards must be between 1 and 64");
    const integration_test_shards = b.option(u8, "integration-test-shards", "Parallel component/integration test shards (1-64)") orelse 8;
    if (integration_test_shards == 0 or integration_test_shards > 64) @panic("-Dintegration-test-shards must be between 1 and 64");
    const agentcore_strip = b.option(bool, "agentcore-strip", "Strip AgentCore library debug information") orelse (optimize != .Debug);

    // A small trusted executor opens native tool files inside the platform
    // sandbox and passes the resulting fd back. Library hosts receive the
    // same helper in their bundle; neither path depends on Python or PATH.
    const sandbox_helper_mod = b.createModule(.{
        .root_source_file = b.path("src/sandbox_helper_root.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    addPlatform(b, sandbox_helper_mod);
    const sandbox_helper_exe = b.addExecutable(.{
        .name = "metacodes-fs-helper",
        .root_module = sandbox_helper_mod,
    });
    const install_sandbox_helper = b.addInstallArtifact(sandbox_helper_exe, .{ .pdb_dir = .disabled });
    g_sandbox_helper_install = &install_sandbox_helper.step;
    g_sandbox_helper_path = b.getInstallPath(.bin, sandbox_helper_exe.out_filename);
    const sandbox_helper_step = b.step("sandbox:helper", "Build and install the native filesystem sandbox helper");
    sandbox_helper_step.dependOn(&install_sandbox_helper.step);

    var staged_tinykg: ?StagedTinyKg = null;
    var staged_tinykgd: ?StagedTinyKgd = null;
    const tinykg_stage_step = b.step("tinykg:stage", "Validate and install the selected TinyKG binary");
    switch (tinykg_input) {
        .disabled => tinykg_stage_step.dependOn(&b.addFail(
            "tinykg:stage is disabled by -Dtinykg-bundled=false or legacy -Dtinykg=false",
        ).step),
        .unavailable => tinykg_stage_step.dependOn(&b.addFail(
            "the checked-in TinyKG bundle does not support this target; use a native explicit -Dtinykg-bin/-Dtinykg-sha256 override",
        ).step),
        .bundled => |input| {
            const python = if (@import("builtin").os.tag == .windows) "python" else "python3";
            const stage = b.addSystemCommand(&.{ python, "scripts/stage_tinykg_binary.py", "bundled", "--binary" });
            stage.addFileArg(b.path(input.path));
            stage.addArgs(&.{"--manifest"});
            stage.addFileArg(b.path("vendor/tinykg/manifest.json"));
            stage.addArgs(&.{
                "--bundle-key",
                input.key,
                "--expected-sha256",
                input.sha256,
                "--target-family",
                input.target_family,
            });
            const host_bundle = bundledTinyKgForTarget(b, b.graph.host.result, "cli");
            if (host_bundle != null and std.mem.eql(u8, host_bundle.?.key, input.key)) {
                stage.addArg("--runtime-probe");
            }
            stage.addArgs(&.{"--contract"});
            stage.addFileArg(b.path("deps/tinykg.json"));
            stage.addArgs(&.{
                "--target",
                target.result.zigTriple(b.allocator) catch @panic("OOM"),
                "--output",
            });
            const bin_name = if (target.result.os.tag == .windows) "tinykg.exe" else "tinykg";
            const staged_binary = stage.addOutputFileArg(bin_name);
            stage.addArg("--receipt");
            const staged_receipt = stage.addOutputFileArg("tinykg.provenance.json");
            const install_binary = b.addInstallFileWithDir(
                staged_binary,
                .{ .custom = "vendor/tinykg" },
                bin_name,
            );
            const install_receipt = b.addInstallFileWithDir(
                staged_receipt,
                .{ .custom = "vendor/tinykg" },
                "tinykg.provenance.json",
            );
            tinykg_stage_step.dependOn(&install_binary.step);
            tinykg_stage_step.dependOn(&install_receipt.step);
            staged_tinykg = .{
                .install_step = &install_binary.step,
                .artifact = staged_binary,
                .installed_path = b.getInstallPath(.{ .custom = "vendor/tinykg" }, bin_name),
                .source_sha256 = input.sha256,
            };
            if (bundledTinyKgForTarget(b, target.result, "daemon")) |daemon| {
                const daemon_stage = b.addSystemCommand(&.{ python, "scripts/stage_tinykg_binary.py", "bundled", "--binary" });
                const daemon_path = b.path(daemon.path);
                daemon_stage.addFileArg(daemon_path);
                daemon_stage.addArgs(&.{"--manifest"});
                daemon_stage.addFileArg(b.path("vendor/tinykg/manifest.json"));
                daemon_stage.addArgs(&.{ "--bundle-key", daemon.key, "--expected-sha256", daemon.sha256, "--target-family", daemon.target_family, "--role", "daemon" });
                if (bundledTinyKgForTarget(b, b.graph.host.result, "daemon")) |host_daemon| if (std.mem.eql(u8, host_daemon.key, daemon.key)) daemon_stage.addArg("--runtime-probe");
                daemon_stage.addArg("--contract");
                daemon_stage.addFileArg(b.path("deps/tinykg.json"));
                daemon_stage.addArgs(&.{ "--target", target.result.zigTriple(b.allocator) catch @panic("OOM"), "--output" });
                const daemon_name = if (target.result.os.tag == .windows) "tinykgd.exe" else "tinykgd";
                const staged_daemon = daemon_stage.addOutputFileArg(daemon_name);
                daemon_stage.addArg("--receipt");
                const staged_daemon_receipt = daemon_stage.addOutputFileArg("tinykgd.provenance.json");
                const install_daemon = b.addInstallFileWithDir(staged_daemon, .{ .custom = "vendor/tinykg" }, daemon_name);
                const install_daemon_receipt = b.addInstallFileWithDir(staged_daemon_receipt, .{ .custom = "vendor/tinykg" }, "tinykgd.provenance.json");
                // Not part of the default (development) install step; the
                // release layout ships it (`release:stage`, manifest v2), and
                // `tinykg:stage` plus the test wiring stage it everywhere else.
                tinykg_stage_step.dependOn(&install_daemon.step);
                tinykg_stage_step.dependOn(&install_daemon_receipt.step);
                staged_tinykgd = .{ .install_step = &install_daemon.step, .receipt_install_step = &install_daemon_receipt.step, .artifact = staged_daemon, .installed_path = b.getInstallPath(.{ .custom = "vendor/tinykg" }, daemon_name), .source_sha256 = daemon.sha256 };
            }
        },
        .explicit => |input| {
            if (target.result.os.tag != b.graph.host.result.os.tag or
                target.result.cpu.arch != b.graph.host.result.cpu.arch or
                target.result.abi != b.graph.host.result.abi)
            {
                @panic("a TinyKG binary can only be staged on its native target runner");
            }
            const python = if (@import("builtin").os.tag == .windows) "python" else "python3";
            const stage = b.addSystemCommand(&.{ python, "scripts/stage_tinykg_binary.py", "explicit", "--binary" });
            stage.addFileArg(.{ .cwd_relative = input.path });
            stage.addArgs(&.{ "--expected-sha256", input.sha256, "--contract" });
            stage.addFileArg(b.path("deps/tinykg.json"));
            stage.addArgs(&.{
                "--target",
                target.result.zigTriple(b.allocator) catch @panic("OOM"),
                "--output",
            });
            const bin_name = if (target.result.os.tag == .windows) "tinykg.exe" else "tinykg";
            const staged_binary = stage.addOutputFileArg(bin_name);
            stage.addArg("--receipt");
            const staged_receipt = stage.addOutputFileArg("tinykg.provenance.json");
            const install_binary = b.addInstallFileWithDir(
                staged_binary,
                .{ .custom = "vendor/tinykg" },
                bin_name,
            );
            const install_receipt = b.addInstallFileWithDir(
                staged_receipt,
                .{ .custom = "vendor/tinykg" },
                "tinykg.provenance.json",
            );
            tinykg_stage_step.dependOn(&install_binary.step);
            tinykg_stage_step.dependOn(&install_receipt.step);
            staged_tinykg = .{
                .install_step = &install_binary.step,
                .artifact = staged_binary,
                .installed_path = b.getInstallPath(.{ .custom = "vendor/tinykg" }, bin_name),
                .source_sha256 = input.sha256,
            };
        },
    }

    // ── Lean governance kernels (scripts/install.sh, kernel-gated tests) ───
    // Built from this checkout's own control-plane/lean, so an install and the
    // kernels it runs are always the same version. The release layout still
    // ships none (release/LAYOUT.md); `kernels:stage` is what scripts/install.sh
    // and the test steps below use.
    const lean_kernels_mode = b.option(
        LeanKernelsMode,
        "lean-kernels",
        "Build and install the Lean governance kernels for tests and scripts/install.sh: auto (when lake is found, default), on (fail without lake), off",
    ) orelse .auto;
    const kernels_stage_step = b.step(
        "kernels:stage",
        "Build both Lean kernels from this checkout and install them into <prefix>/libexec/metacodes",
    );
    const staged_lean_kernels = stageLeanKernels(b, lean_kernels_mode, target, kernels_stage_step);

    const ripgrep_bundle = ripgrepBundleInfo(b, target.result);
    const release_documents = parseJsonFile(b, struct {
        schema: []const u8,
        files: []const struct { source: []const u8, destination: []const u8 },
    }, "release/documents.json");
    if (!std.mem.eql(u8, release_documents.schema, "metacodes.release-documents/v1"))
        @panic("unsupported release documents manifest");
    const release_docs_step = b.step("release:docs", "Stage only release documents and licences, without compiling the product");
    for (release_documents.files) |document| {
        const destination = std.mem.replaceOwned(u8, b.allocator, document.destination, "{version}", manifest.version) catch @panic("OOM");
        const install_document = b.addInstallFileWithDir(b.path(document.source), .prefix, destination);
        release_docs_step.dependOn(&install_document.step);
    }
    const test_harness_mod = b.createModule(.{
        .root_source_file = b.path("tests/_harness/mock_sse_server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addPlatform(b, test_harness_mod); // harness socket 层走 platform/net(POSIX+Winsock 双后端)

    // mock MCP server 二进制：测试专用，只装这个 artifact 即可运行 aggregate
    // integration；测试不应依赖全局 install step，否则会顺带冷编译 release/debug/replay。
    const mock_mcp_mod = b.createModule(.{
        .root_source_file = b.path("tests/_harness/mock_mcp_server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addPlatform(b, mock_mcp_mod);
    // Keep the calibrated MCP fixture byte-identical. The MSVC helper
    // needs the same POSIX CRT aliases as the native SDK.
    if (target.result.os.tag == .windows and target.result.abi == .msvc) {
        mock_mcp_mod.addCSourceFile(.{ .file = b.path("src/agentcore/windows_msvc_crt_shims.c"), .flags = &.{"-std=c11"} });
    }
    const mock_mcp_exe = b.addExecutable(.{
        .name = "mock_mcp_server",
        .root_module = mock_mcp_mod,
    });
    const install_mock_mcp = b.addInstallArtifact(mock_mcp_exe, .{});

    // selfexe_probe 二进制:相邻产物解析的进程级探针(adjacent_symlink_test 把它复制成
    // <prefix>/bin/metacodes 后经 symlink 启动)。只链 platform + toolchain,不拖整个 app 图。
    const toolchain_probe_mod = b.createModule(.{
        .root_source_file = b.path("src/util/toolchain.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addPlatform(b, toolchain_probe_mod);
    const selfexe_probe_mod = b.createModule(.{
        .root_source_file = b.path("tests/_harness/selfexe_probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addPlatform(b, selfexe_probe_mod);
    selfexe_probe_mod.addImport("toolchain", toolchain_probe_mod);
    const selfexe_probe_exe = b.addExecutable(.{
        .name = "selfexe_probe",
        .root_module = selfexe_probe_mod,
    });
    const install_selfexe_probe = b.addInstallArtifact(selfexe_probe_exe, .{});

    // replay_server 二进制(Stage 7):从 cassette 起 mock,供 e2e replay。测试专用。
    // 三端可编:曾经的三个 Windows blocker 已清(socket server→platform/net、
    // args→iterateAllocator、cassette 文件 IO→pfs)。TTY ui_tools 用例依赖它。
    const replay_mod = b.createModule(.{
        .root_source_file = b.path("tests/_harness/replay_server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    replay_mod.addImport("harness", test_harness_mod); // 共享模块(perf,见上)
    const replay_cassette_mod = b.createModule(.{
        .root_source_file = b.path("tests/_harness/cassette.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addPlatform(b, replay_cassette_mod); // 文件 IO 走 pfs
    replay_mod.addImport("cassette", replay_cassette_mod);
    addPlatform(b, replay_mod); // stdout/stderr 走可移植 pfs
    const replay_exe = b.addExecutable(.{
        .name = "replay_server",
        .root_module = replay_mod,
    });
    const install_replay = b.addInstallArtifact(replay_exe, .{});
    const test_harness_step = b.step("test:harness", "Install the test harness binaries: mock_mcp_server, replay_server and selfexe_probe");
    test_harness_step.dependOn(&install_mock_mcp.step);
    test_harness_step.dependOn(&install_replay.step);
    test_harness_step.dependOn(&install_selfexe_probe.step);

    // ── metacodes-core 可复用库 module(root=src/lib.zig,UI 图不可达)──────────
    // 供其他 Zig 项目经 build.zig.zon 依赖 `@import("metacodes-core")`。
    // 经 tools/* 用 highlight-zig 高亮 module → 必须 addHl。
    const core_mod = b.addModule("metacodes-core", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addHl(b, core_mod);

    // HTTP status is an open wire value. This host-native syntax gate keeps the
    // std.http.Status interpretation authority in src/api/http_status.zig.
    const http_status_gate_mod = b.createModule(.{
        .root_source_file = b.path("scripts/http_status_boundary_gate.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const http_status_gate_exe = b.addExecutable(.{
        .name = "http-status-boundary-gate",
        .root_module = http_status_gate_mod,
    });
    const http_status_gate_run = b.addRunArtifact(http_status_gate_exe);
    http_status_gate_run.setCwd(b.path("."));
    http_status_gate_run.addArg(".");
    const http_status_gate_unit = b.addTest(.{
        .name = "http-status-boundary-gate-unit",
        .root_module = http_status_gate_mod,
    });
    const http_status_gate_step = b.step(
        "http-status:gate",
        "Enforce the unique HTTP response status boundary",
    );
    http_status_gate_step.dependOn(&http_status_gate_run.step);
    http_status_gate_step.dependOn(&addTestRunArtifact(b, http_status_gate_unit).step);

    // One-shot paid feasibility probe for the isolated rule-author adapter.
    // It is intentionally absent from the default install graph; the Python
    // budget runner builds it before acquiring durable request authorization.
    const rule_author_trial_mod = b.createModule(.{
        .root_source_file = b.path("scripts/eval/rule_author_feasibility.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    rule_author_trial_mod.addImport("metacodes-core", core_mod);
    addPlatform(b, rule_author_trial_mod);
    const rule_author_trial_exe = b.addExecutable(.{
        .name = "rule-author-feasibility",
        .root_module = rule_author_trial_mod,
    });
    const install_rule_author_trial = b.addInstallArtifact(rule_author_trial_exe, .{});
    const rule_author_trial_step = b.step(
        "eval:rule-author-build",
        "Build the isolated rule-author feasibility probe (no provider call)",
    );
    rule_author_trial_step.dependOn(&install_rule_author_trial.step);

    // Host-native, zero-paid vertical slice. The Python parent supplies only
    // loopback services; the Zig child starts at the production KgClient
    // daemon-config boundary and completes ontology snapshot -> rule author ->
    // source re-observation -> candidate binding verification.
    const project_rule_mac_pilot_mod = b.createModule(.{
        .root_source_file = b.path("scripts/eval/project_rule_evolution_mac_pilot.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    project_rule_mac_pilot_mod.addImport("metacodes-core", core_mod);
    addPlatform(b, project_rule_mac_pilot_mod);
    const project_rule_mac_pilot_exe = b.addExecutable(.{
        .name = "metacodes-project-rule-evolution-mac-pilot",
        .root_module = project_rule_mac_pilot_mod,
    });
    const project_rule_mac_pilot_run = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "scripts/eval/run_project_rule_evolution_mac_pilot.py",
        "--probe",
    });
    project_rule_mac_pilot_run.addArtifactArg(project_rule_mac_pilot_exe);
    const project_rule_mac_pilot_step = b.step(
        "eval:project-rule-mac-pilot",
        "Run the zero-paid Mac TinyKG-daemon to governed-rule host chain",
    );
    project_rule_mac_pilot_step.dependOn(&project_rule_mac_pilot_run.step);

    const agentcore_types_mod = b.createModule(.{
        .root_source_file = b.path("sdk/zig/types.zig"),
        .target = target,
        .optimize = optimize,
    });
    const agentcore_protocol_mod = b.createModule(.{
        .root_source_file = b.path("sdk/zig/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    const agentcore_sdk_mod = b.createModule(.{
        .root_source_file = b.path("sdk/zig/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    agentcore_sdk_mod.addImport("metask_agentcore_types", agentcore_types_mod);
    agentcore_sdk_mod.addImport("metask_agentcore_protocol", agentcore_protocol_mod);
    const agentcore_abi_test_mod = createAgentCoreAbiModule(b, .{
        .target = target,
        .optimize = optimize,
        .strip = false,
        .core_mod = core_mod,
        .types_mod = agentcore_types_mod,
        .protocol_mod = agentcore_protocol_mod,
    });
    const agentcore_abi_bundle_mod = createAgentCoreAbiModule(b, .{
        .target = target,
        .optimize = optimize,
        .strip = agentcore_strip,
        .core_mod = core_mod,
        .types_mod = agentcore_types_mod,
        .protocol_mod = agentcore_protocol_mod,
    });

    const agentcore_test_step = b.step("agentcore:test", "Run AgentCore binary ABI v1 tests");
    agentcore_test_step.dependOn(http_status_gate_step);
    const agentcore_abi_test = b.addTest(.{
        .name = "agentcore-abi-unit",
        .root_module = agentcore_abi_test_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    agentcore_test_step.dependOn(&addTestRunArtifact(b, agentcore_abi_test).step);
    const agentcore_types_test = b.addTest(.{
        .name = "agentcore-types-unit",
        .root_module = agentcore_types_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    agentcore_test_step.dependOn(&addTestRunArtifact(b, agentcore_types_test).step);
    const agentcore_protocol_test = b.addTest(.{
        .name = "agentcore-protocol-unit",
        .root_module = agentcore_protocol_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    agentcore_test_step.dependOn(&addTestRunArtifact(b, agentcore_protocol_test).step);
    const agentcore_sdk_test = b.addTest(.{
        .name = "agentcore-sdk-unit",
        .root_module = agentcore_sdk_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    agentcore_test_step.dependOn(&addTestRunArtifact(b, agentcore_sdk_test).step);
    const agentcore_zig_package_build_test_mod = b.createModule(.{
        .root_source_file = b.path("sdk/zig/build.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const agentcore_zig_package_build_test = b.addTest(.{
        .name = "agentcore-zig-package-build-unit",
        .root_module = agentcore_zig_package_build_test_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    agentcore_test_step.dependOn(&addTestRunArtifact(b, agentcore_zig_package_build_test).step);
    const agentcore_manifest_contract_mod = b.createModule(.{
        .root_source_file = b.path("tests/agentcore_artifact_consumer/manifest_contract.zig"),
        .target = target,
        .optimize = optimize,
    });
    const agentcore_manifest_contract_test = b.addTest(.{
        .name = "agentcore-manifest-contract",
        .root_module = agentcore_manifest_contract_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    agentcore_test_step.dependOn(&addTestRunArtifact(b, agentcore_manifest_contract_test).step);
    const agentcore_manifest_tool_mod = b.createModule(.{
        .root_source_file = b.path("scripts/agentcore_manifest.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const agentcore_manifest_types_mod = b.createModule(.{
        .root_source_file = b.path("sdk/zig/types.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    agentcore_manifest_tool_mod.addImport("metask_agentcore_types", agentcore_manifest_types_mod);
    const agentcore_manifest_tool = b.addExecutable(.{
        .name = "agentcore-manifest",
        .root_module = agentcore_manifest_tool_mod,
    });
    const agentcore_manifest_tool_test = b.addTest(.{
        .name = "agentcore-manifest-unit",
        .root_module = agentcore_manifest_tool_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    agentcore_test_step.dependOn(&addTestRunArtifact(b, agentcore_manifest_tool_test).step);

    const agentcore_symbol_gate_mod = b.createModule(.{
        .root_source_file = b.path("scripts/agentcore_symbol_gate.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const agentcore_symbol_gate_tool = b.addExecutable(.{
        .name = "agentcore-symbol-gate",
        .root_module = agentcore_symbol_gate_mod,
    });
    const agentcore_symbol_gate_test = b.addTest(.{
        .name = "agentcore-symbol-gate-unit",
        .root_module = agentcore_symbol_gate_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    agentcore_test_step.dependOn(&addTestRunArtifact(b, agentcore_symbol_gate_test).step);
    // header 可编译性检查:走 zig 构建系统原生 C 对象(不 install,只编译)。
    // 不用系统 cc(Windows 没有),也不用 `zig cc -fsyntax-only`(zig 0.16 Windows 实测
    // 对任何输入报 FileNotFound;`-c` 正常)。对象编译 = 语法+类型检查,跨平台等价。
    const agentcore_header_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agentcore_header_mod.addCSourceFile(.{
        .file = b.path("tests/agentcore_header_compile.c"),
        .flags = &.{"-std=c11"},
    });
    agentcore_header_mod.addIncludePath(b.path("sdk"));
    const agentcore_header_obj = b.addObject(.{ .name = "agentcore-header-compile", .root_module = agentcore_header_mod });
    agentcore_test_step.dependOn(&agentcore_header_obj.step);
    const agentcore_cpp_header_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agentcore_cpp_header_mod.addCSourceFile(.{
        .file = b.path("tests/agentcore_artifact_consumer/link_probe.cpp"),
        .flags = &.{"-std=c++17"},
    });
    agentcore_cpp_header_mod.addIncludePath(b.path("sdk"));
    const agentcore_cpp_header_obj = b.addObject(.{ .name = "agentcore-cpp-header-compile", .root_module = agentcore_cpp_header_mod });
    agentcore_test_step.dependOn(&agentcore_cpp_header_obj.step);
    const agentcore_contract_mod = b.createModule(.{
        .root_source_file = b.path("tests/component/agentcore_abi_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agentcore_contract_mod.addImport("harness", test_harness_mod); // 共享模块(perf,见 debug exe 后注释)
    agentcore_contract_mod.addImport("agentcore-abi", agentcore_abi_test_mod);
    agentcore_contract_mod.addImport("agentcore-sdk", agentcore_sdk_mod);
    agentcore_contract_mod.addImport("metacodes-core", core_mod);
    addPlatform(b, agentcore_contract_mod);
    const agentcore_contract_test = b.addTest(.{
        .name = "agentcore-abi-contract",
        .root_module = agentcore_contract_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    agentcore_test_step.dependOn(&addTestRunArtifact(b, agentcore_contract_test).step);

    const agentcore_lib = b.addLibrary(.{
        .name = "metask_agentcore",
        .linkage = .static,
        .root_module = agentcore_abi_bundle_mod,
    });
    // Non-Zig consumers do not implicitly link Zig's compiler_rt builtins.
    agentcore_lib.bundle_compiler_rt = true;
    const agentcore_symbol_gate_cmd = b.addRunArtifact(agentcore_symbol_gate_tool);
    agentcore_symbol_gate_cmd.addFileArg(agentcore_lib.getEmittedBin());
    agentcore_test_step.dependOn(&agentcore_symbol_gate_cmd.step);
    // The same module as a shared library for Hosts that can only load one
    // (ctypes, Node FFI, JNA, P/Invoke; #182). It exports only the discovery
    // entry point: ELF through a version script, Mach-O and PE because only
    // Zig `export` declarations are exported there. macOS keeps Zig's
    // default install name, @rpath/libmetask_agentcore.dylib.
    const agentcore_shared_lib = b.addLibrary(.{
        .name = "metask_agentcore",
        .linkage = .dynamic,
        .root_module = agentcore_abi_bundle_mod,
        // The self-hosted x86_64 ELF linker (Debug) ignores the version
        // script and exported the UBSan runtime; LLD honors it in every
        // mode. LLD does not link Mach-O, where Zig's own linker is used.
        .use_llvm = true,
        .use_lld = target.result.ofmt != .macho,
    });
    if (target.result.ofmt == .elf)
        agentcore_shared_lib.setVersionScript(b.path("src/agentcore/shared_exports.map"));
    const agentcore_shared_gate_cmd = b.addRunArtifact(agentcore_symbol_gate_tool);
    agentcore_shared_gate_cmd.addArg("--shared");
    agentcore_shared_gate_cmd.addFileArg(agentcore_shared_lib.getEmittedBin());
    if (target.result.os.tag == .windows and target.result.abi == .msvc)
        agentcore_shared_gate_cmd.addArg("--msvc-runtime");
    agentcore_test_step.dependOn(&agentcore_shared_gate_cmd.step);
    const resolved_agentcore_target = target.result.zigTriple(b.allocator) catch @panic("OOM");
    const agentcore_architecture = @tagName(target.result.cpu.arch);
    const agentcore_os = @tagName(target.result.os.tag);
    const agentcore_abi = @tagName(target.result.abi);
    const agentcore_library_file = agentcore_lib.out_filename;
    const agentcore_bundle_rel = b.fmt("agentcore/{s}", .{resolved_agentcore_target});
    const agentcore_lib_rel = b.fmt("{s}/lib", .{agentcore_bundle_rel});
    const agentcore_install_root = b.getInstallPath(.prefix, agentcore_bundle_rel);
    const agentcore_install_root_abs = b.pathFromRoot(agentcore_install_root);
    const install_agentcore_lib = b.addInstallArtifact(agentcore_lib, .{
        .dest_dir = .{ .override = .{ .custom = agentcore_lib_rel } },
    });
    const installed_agentcore_library = b.fmt(
        "{s}/lib/{s}",
        .{ agentcore_install_root, agentcore_library_file },
    );
    var installed_agentcore_lib_ready: *std.Build.Step = &install_agentcore_lib.step;
    if (target.result.os.tag == .macos) {
        if (b.graph.host.result.os.tag != .macos) {
            installed_agentcore_lib_ready = &b.addFail(
                "AgentCore macOS archives require Apple ar/libtool repacking on a macOS build host",
            ).step;
        } else {
            const repack_agentcore_archive = b.addSystemCommand(&.{
                "sh",
                "scripts/repack_agentcore_macos_archive.sh",
                installed_agentcore_library,
            });
            repack_agentcore_archive.setCwd(b.path("."));
            repack_agentcore_archive.step.dependOn(&install_agentcore_lib.step);
            const installed_symbol_gate = b.addRunArtifact(agentcore_symbol_gate_tool);
            installed_symbol_gate.addArg(installed_agentcore_library);
            installed_symbol_gate.step.dependOn(&repack_agentcore_archive.step);
            installed_agentcore_lib_ready = &installed_symbol_gate.step;
        }
    }
    // lib/libmetask_agentcore.{so,dylib} or lib/metask_agentcore.dll. No
    // import library (on MSVC it would collide with the static
    // metask_agentcore.lib), PDB, header or version symlinks: an FFI Host
    // loads this one file.
    const agentcore_shared_file = agentcore_shared_lib.out_filename;
    const install_agentcore_shared = b.addInstallArtifact(agentcore_shared_lib, .{
        .dest_dir = .{ .override = .{ .custom = agentcore_lib_rel } },
        .pdb_dir = .disabled,
        .h_dir = .disabled,
        .implib_dir = .disabled,
        .dylib_symlinks = false,
    });
    const install_debug = b.addInstallArtifact(agentcore_shared_lib, .{
        .dest_dir = .{ .override = .{ .custom = b.fmt("agentcore-dev/{s}/lib", .{resolved_agentcore_target}) } },
        .pdb_dir = .disabled,
        .h_dir = .disabled,
        .implib_dir = .disabled,
        .dylib_symlinks = false,
    });
    const dev_requires_debug = b.addFail("AgentCore development builds require -Doptimize=Debug");
    const dev_step = b.step("dev", "Install the Debug AgentCore shared library for local iteration");
    if (optimize == .Debug) {
        dev_step.dependOn(&install_debug.step);
    } else {
        dev_step.dependOn(&dev_requires_debug.step);
    }
    const dev_full_step = b.step("dev:full", "Install the Debug AgentCore shared library and stage TinyKG");
    if (optimize == .Debug) {
        dev_full_step.dependOn(&install_debug.step);
        dev_full_step.dependOn(tinykg_stage_step);
    } else {
        dev_full_step.dependOn(&dev_requires_debug.step);
    }
    const install_agentcore_sandbox_helper = b.addInstallArtifact(sandbox_helper_exe, .{
        .dest_dir = .{ .override = .{ .custom = b.fmt("{s}/bin", .{agentcore_bundle_rel}) } },
        .pdb_dir = .disabled,
    });
    const install_agentcore_header = b.addInstallFileWithDir(
        b.path("sdk/metask/agentcore.h"),
        .prefix,
        b.fmt("{s}/include/metask/agentcore.h", .{agentcore_bundle_rel}),
    );
    const install_agentcore_sdk = b.addInstallFileWithDir(
        b.path("sdk/zig/root.zig"),
        .prefix,
        b.fmt("{s}/bindings/zig/src/root.zig", .{agentcore_bundle_rel}),
    );
    const install_agentcore_protocol = b.addInstallFileWithDir(
        b.path("sdk/zig/protocol.zig"),
        .prefix,
        b.fmt("{s}/bindings/zig/src/protocol.zig", .{agentcore_bundle_rel}),
    );
    const install_agentcore_types = b.addInstallFileWithDir(
        b.path("sdk/zig/types.zig"),
        .prefix,
        b.fmt("{s}/bindings/zig/src/types.zig", .{agentcore_bundle_rel}),
    );
    const install_agentcore_zig_build = b.addInstallFileWithDir(
        b.path("sdk/zig/build.zig"),
        .prefix,
        b.fmt("{s}/bindings/zig/build.zig", .{agentcore_bundle_rel}),
    );
    const install_agentcore_rust_build = b.addInstallFileWithDir(
        b.path("sdk/rust/build.rs"),
        .prefix,
        b.fmt("{s}/bindings/rust/build.rs", .{agentcore_bundle_rel}),
    );
    const install_agentcore_rust_lib = b.addInstallFileWithDir(
        b.path("sdk/rust/src/lib.rs"),
        .prefix,
        b.fmt("{s}/bindings/rust/src/lib.rs", .{agentcore_bundle_rel}),
    );
    const install_agentcore_rust_raw = b.addInstallFileWithDir(
        b.path("sdk/rust/src/raw.rs"),
        .prefix,
        b.fmt("{s}/bindings/rust/src/raw.rs", .{agentcore_bundle_rel}),
    );
    const install_agentcore_rust_link_probe = b.addInstallFileWithDir(
        b.path("sdk/rust/examples/link_probe.rs"),
        .prefix,
        b.fmt("{s}/bindings/rust/examples/link_probe.rs", .{agentcore_bundle_rel}),
    );
    // rg 是再分发的 MIT OR Unlicense 上游二进制:许可文本随资产同行。
    const install_agentcore_ripgrep_license = b.addInstallFileWithDir(
        b.path("vendor/ripgrep/LICENSE-MIT"),
        .prefix,
        b.fmt("{s}/bin/ripgrep-LICENSE-MIT", .{agentcore_bundle_rel}),
    );
    // Glob/Grep 的运行期依赖随包分发:按 target 从 vendor/ripgrep manifest 选
    // 二进制,SHA-256 校验后 staging 为 bundle 内 bin/rg[.exe],再进 manifest
    // 的 files allowlist 与 runtime_assets 声明。无对应 vendored 二进制的
    // target 在此 fail-closed,而不是发一个 Glob/Grep 无法执行的 bundle。
    const agentcore_stage_python = if (@import("builtin").os.tag == .windows) "python" else "python3";
    const stage_agentcore_ripgrep = b.addSystemCommand(&.{
        agentcore_stage_python,
        "scripts/stage_ripgrep_binary.py",
        agentcore_architecture,
        agentcore_os,
        b.getInstallPath(.prefix, b.fmt("{s}/bin", .{agentcore_bundle_rel})),
    });
    stage_agentcore_ripgrep.setCwd(b.path("."));
    const missing_agentcore_target = if (target_was_explicit)
        null
    else
        b.addFail("This AgentCore build step requires explicit -Dtarget=<triple>");
    const manifest_cmd = b.addRunArtifact(agentcore_manifest_tool);
    const install_agentcore_quickjs_license = b.addInstallFileWithDir(
        b.path("vendor/quickjs/LICENSE"),
        .prefix,
        b.fmt("{s}/licenses/quickjs-LICENSE", .{agentcore_bundle_rel}),
    );
    manifest_cmd.step.dependOn(&install_agentcore_quickjs_license.step);
    manifest_cmd.addArgs(&.{
        agentcore_install_root,
        resolved_agentcore_target,
        agentcore_architecture,
        agentcore_os,
        agentcore_abi,
        @tagName(optimize),
        if (agentcore_strip) "true" else "false",
        agentcore_library_file,
        agentcore_shared_file,
    });
    manifest_cmd.setCwd(b.path("."));
    manifest_cmd.step.dependOn(&agentcore_symbol_gate_cmd.step);
    manifest_cmd.step.dependOn(&agentcore_shared_gate_cmd.step);
    manifest_cmd.step.dependOn(installed_agentcore_lib_ready);
    manifest_cmd.step.dependOn(&install_agentcore_shared.step);
    manifest_cmd.step.dependOn(&install_agentcore_sandbox_helper.step);
    manifest_cmd.step.dependOn(&install_agentcore_header.step);
    manifest_cmd.step.dependOn(&install_agentcore_sdk.step);
    manifest_cmd.step.dependOn(&install_agentcore_protocol.step);
    manifest_cmd.step.dependOn(&install_agentcore_types.step);
    manifest_cmd.step.dependOn(&install_agentcore_zig_build.step);
    manifest_cmd.step.dependOn(&install_agentcore_rust_build.step);
    manifest_cmd.step.dependOn(&install_agentcore_rust_lib.step);
    manifest_cmd.step.dependOn(&install_agentcore_rust_raw.step);
    manifest_cmd.step.dependOn(&install_agentcore_rust_link_probe.step);
    manifest_cmd.step.dependOn(&stage_agentcore_ripgrep.step);
    manifest_cmd.step.dependOn(&install_agentcore_ripgrep_license.step);
    const consumer_link_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    addNestedBuildCacheArgs(b, consumer_link_cmd);
    consumer_link_cmd.addArgs(&.{
        "--build-file",
        "tests/agentcore_artifact_consumer/build.zig",
        "link",
        b.fmt("-Doptimize={s}", .{@tagName(optimize)}),
        b.fmt("-Dtarget={s}", .{resolved_agentcore_target}),
        b.fmt("-Dbundle-root={s}", .{agentcore_install_root}),
        b.fmt("-Dlibrary-file={s}", .{agentcore_library_file}),
        b.fmt("-Dshared-library-file={s}", .{agentcore_shared_file}),
        b.fmt("-Dexpected-strip={s}", .{if (agentcore_strip) "true" else "false"}),
    });
    consumer_link_cmd.setCwd(b.path("."));
    consumer_link_cmd.step.dependOn(&manifest_cmd.step);
    const zig_package_check_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    addNestedBuildCacheArgs(b, zig_package_check_cmd);
    zig_package_check_cmd.addArgs(&.{
        "--build-file",
        b.fmt("{s}/bindings/zig/build.zig", .{agentcore_install_root}),
        "check",
        b.fmt("-Doptimize={s}", .{@tagName(optimize)}),
        b.fmt("-Dtarget={s}", .{resolved_agentcore_target}),
    });
    zig_package_check_cmd.setCwd(b.path("."));
    zig_package_check_cmd.step.dependOn(&manifest_cmd.step);
    const agentcore_rust_step = b.step("agentcore:rust", "Build the bundled metask-agentcore-sys crate for the selected target");
    if (missing_agentcore_target) |failure| {
        agentcore_rust_step.dependOn(&failure.step);
    } else if (agentcoreRustTarget(target.result)) |rust_target| {
        const rust_manifest_path = b.fmt("{s}/bindings/rust/Cargo.toml", .{agentcore_install_root});
        const rust_target_dir = b.getInstallPath(.prefix, b.fmt(".cargo-agentcore/{s}", .{resolved_agentcore_target}));
        const rust_check_cmd = b.addSystemCommand(&.{ "cargo", "build", "--locked", "--example", "link_probe" });
        rust_check_cmd.addArgs(&.{
            "--manifest-path",
            rust_manifest_path,
            "--target",
            rust_target,
            "--target-dir",
            rust_target_dir,
        });
        rust_check_cmd.setEnvironmentVariable("METASK_AGENTCORE_BUNDLE_DIR", agentcore_install_root_abs);
        rust_check_cmd.setCwd(b.path("."));
        rust_check_cmd.step.dependOn(&manifest_cmd.step);
        agentcore_rust_step.dependOn(&rust_check_cmd.step);
    } else {
        agentcore_rust_step.dependOn(&b.addFail("selected target has no supported AgentCore Rust triple").step);
    }

    const bindgen_path = b.option([]const u8, "agentcore-bindgen", "bindgen 0.72.1 executable for the AgentCore Rust regen gate") orelse "bindgen";
    const rust_bindgen_cmd = if (b.graph.host.result.os.tag == .windows) blk: {
        const command = b.addSystemCommand(&.{ "powershell", "-NoProfile", "-File", "scripts/check_agentcore_rust_bindings.ps1" });
        command.addArgs(&.{ "-Bindgen", bindgen_path });
        break :blk command;
    } else blk: {
        const command = b.addSystemCommand(&.{ "sh", "scripts/check_agentcore_rust_bindings.sh" });
        command.setEnvironmentVariable("BINDGEN", bindgen_path);
        break :blk command;
    };
    rust_bindgen_cmd.setCwd(b.path("."));
    const agentcore_rust_bindgen_step = b.step("agentcore:rust-bindgen-check", "Regenerate Rust raw bindings with bindgen 0.72.1 and require no diff");
    agentcore_rust_bindgen_step.dependOn(&rust_bindgen_cmd.step);
    const agentcore_bundle_step = b.step("agentcore:bundle", "Build and link-check the AgentCore SDK bundle");
    agentcore_bundle_step.dependOn(&consumer_link_cmd.step);
    agentcore_bundle_step.dependOn(&zig_package_check_cmd.step);
    b.getInstallStep().dependOn(agentcore_bundle_step);

    const agentcore_python = if (@import("builtin").os.tag == .windows) "python" else "python3";
    const agentcore_archive_dir = b.option(
        []const u8,
        "agentcore-archive-dir",
        "Output directory for immutable AgentCore archives",
    ) orelse b.getInstallPath(.prefix, "agentcore-archives");
    const agentcore_archive_test_cmd = b.addSystemCommand(&.{
        agentcore_python,
        "scripts/package_agentcore.py",
        "--self-test",
    });
    agentcore_archive_test_cmd.setCwd(b.path("."));
    const agentcore_archive_cmd = b.addSystemCommand(&.{
        agentcore_python,
        "scripts/package_agentcore.py",
        agentcore_install_root,
        agentcore_archive_dir,
    });
    agentcore_archive_cmd.setCwd(b.path("."));
    agentcore_archive_cmd.step.dependOn(&consumer_link_cmd.step);
    agentcore_archive_cmd.step.dependOn(&zig_package_check_cmd.step);
    agentcore_archive_cmd.step.dependOn(&agentcore_archive_test_cmd.step);
    const agentcore_archive_step = b.step("archive", "Create an immutable AgentCore zip or tar.gz plus SHA-256");
    if (missing_agentcore_target) |failure| {
        agentcore_archive_step.dependOn(&failure.step);
    } else {
        agentcore_archive_step.dependOn(&agentcore_archive_cmd.step);
    }

    const consumer_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    addNestedBuildCacheArgs(b, consumer_cmd);
    consumer_cmd.addArgs(&.{
        "--build-file",
        "tests/agentcore_artifact_consumer/build.zig",
        "test",
        b.fmt("-Doptimize={s}", .{@tagName(optimize)}),
        b.fmt("-Dtarget={s}", .{resolved_agentcore_target}),
        b.fmt("-Dbundle-root={s}", .{agentcore_install_root}),
        b.fmt("-Dlibrary-file={s}", .{agentcore_library_file}),
        b.fmt("-Dshared-library-file={s}", .{agentcore_shared_file}),
        b.fmt("-Dexpected-strip={s}", .{if (agentcore_strip) "true" else "false"}),
    });
    consumer_cmd.setCwd(b.path("."));
    consumer_cmd.step.dependOn(&manifest_cmd.step);
    const agentcore_consumer_step = b.step("agentcore:consumer", "Run the AgentCore bundle consumer (source-free linking proven by agentcore:bundle's link probes)");
    const host_agentcore_target = b.graph.host.result;
    const agentcore_cpu_is_native = switch (target.query.cpu_model) {
        .baseline, .determined_by_arch_os, .native => true,
        .explicit => host_agentcore_target.cpu.features.isSuperSetOf(target.result.cpu.features),
    } and host_agentcore_target.cpu.features.isSuperSetOf(target.query.cpu_features_add);
    const agentcore_target_is_native = target.result.cpu.arch == host_agentcore_target.cpu.arch and
        target.result.os.tag == host_agentcore_target.os.tag and
        target.result.abi == host_agentcore_target.abi and
        agentcore_cpu_is_native;
    const agentcore_bundle_target_is_native = agentcore_target_is_native or
        (target.result.cpu.arch == host_agentcore_target.cpu.arch and
            target.result.os.tag == .windows and host_agentcore_target.os.tag == .windows and
            agentcore_cpu_is_native);
    const host_agentcore_triple = host_agentcore_target.zigTriple(b.allocator) catch @panic("OOM");
    const native_agentcore_failure = if (!target_was_explicit)
        b.addFail("AgentCore native execution requires explicit -Dtarget=<triple>")
    else if (!agentcore_bundle_target_is_native)
        b.addFail(b.fmt(
            "AgentCore native gate cannot run target {s} on host {s}; use agentcore:bundle for cross-target validation",
            .{ resolved_agentcore_target, host_agentcore_triple },
        ))
    else
        null;
    if (native_agentcore_failure) |failure|
        agentcore_consumer_step.dependOn(&failure.step)
    else {
        agentcore_consumer_step.dependOn(&consumer_cmd.step);
        agentcore_consumer_step.dependOn(&zig_package_check_cmd.step);
    }

    const agentcore_gate_step = b.step("agentcore:gate", "Build, link and run the native source-free AgentCore delivery gate");
    if (native_agentcore_failure) |failure| {
        agentcore_gate_step.dependOn(&failure.step);
    } else {
        agentcore_gate_step.dependOn(agentcore_test_step);
        agentcore_gate_step.dependOn(&consumer_cmd.step);
        agentcore_gate_step.dependOn(&zig_package_check_cmd.step);
        if (agentcoreRustTarget(target.result)) |rust_target| {
            const rust_native_cmd = b.addSystemCommand(&.{ "cargo", "run", "--locked", "--example", "link_probe" });
            rust_native_cmd.addArgs(&.{
                "--manifest-path",
                b.fmt("{s}/bindings/rust/Cargo.toml", .{agentcore_install_root}),
                "--target",
                rust_target,
                "--target-dir",
                b.getInstallPath(.prefix, b.fmt(".cargo-agentcore-native/{s}", .{resolved_agentcore_target})),
            });
            rust_native_cmd.setEnvironmentVariable("METASK_AGENTCORE_BUNDLE_DIR", agentcore_install_root_abs);
            rust_native_cmd.setCwd(b.path("."));
            rust_native_cmd.step.dependOn(&manifest_cmd.step);
            agentcore_gate_step.dependOn(&rust_native_cmd.step);
            const rust_test_cmd = b.addSystemCommand(&.{ "cargo", "test", "--locked" });
            rust_test_cmd.addArgs(&.{
                "--manifest-path",
                b.fmt("{s}/bindings/rust/Cargo.toml", .{agentcore_install_root}),
                "--target",
                rust_target,
                "--target-dir",
                b.getInstallPath(.prefix, b.fmt(".cargo-agentcore-test/{s}", .{resolved_agentcore_target})),
            });
            rust_test_cmd.setEnvironmentVariable("METASK_AGENTCORE_BUNDLE_DIR", agentcore_install_root_abs);
            rust_test_cmd.setCwd(b.path("."));
            rust_test_cmd.step.dependOn(&manifest_cmd.step);
            agentcore_gate_step.dependOn(&rust_test_cmd.step);
        } else {
            agentcore_gate_step.dependOn(&b.addFail("selected target has no supported AgentCore Rust triple").step);
        }
    }
    if (tfilter != null) agentcore_gate_step.dependOn(&b.addFail(
        "agentcore:gate does not accept -Dtfilter; use agentcore:test for filtered diagnostics",
    ).step);

    // test:lib —— 编译库全图(refAllDeclsRecursive),绿即证库与 UI 物理隔离。
    const core_test_mod = createCoreModule(b, target, optimize);
    const project_harness_eval_driver_mod = b.createModule(.{
        .root_source_file = b.path("scripts/project_harness_eval_driver.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    project_harness_eval_driver_mod.addImport("cc", core_test_mod);
    const project_harness_eval_driver = b.addExecutable(.{
        .name = "metacodes-project-harness-eval",
        .root_module = project_harness_eval_driver_mod,
    });
    const install_project_harness_eval_driver = b.addInstallArtifact(
        project_harness_eval_driver,
        .{},
    );
    const project_harness_eval_driver_step = b.step(
        "eval:project-harness-driver",
        "Build the zero-provider project-Harness causal calibration driver",
    );
    project_harness_eval_driver_step.dependOn(&install_project_harness_eval_driver.step);
    const jev_recall_eval_driver_mod = b.createModule(.{
        .root_source_file = b.path("scripts/jev_recall_eval_driver.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    jev_recall_eval_driver_mod.addImport("cc", core_test_mod);
    const jev_recall_eval_driver = b.addExecutable(.{
        .name = "metacodes-jev-recall-eval",
        .root_module = jev_recall_eval_driver_mod,
    });
    const jev_recall_eval_driver_step = b.step(
        "eval:jev-recall-driver",
        "Build the zero-provider System-One scoped-recall evaluation driver",
    );
    jev_recall_eval_driver_step.dependOn(&b.addInstallArtifact(jev_recall_eval_driver, .{}).step);
    const project_harness_lifecycle_driver_mod = b.createModule(.{
        .root_source_file = b.path("scripts/project_harness_lifecycle_driver.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    project_harness_lifecycle_driver_mod.addImport("cc", core_test_mod);
    const project_harness_lifecycle_driver = b.addExecutable(.{
        .name = "metacodes-project-harness-lifecycle",
        .root_module = project_harness_lifecycle_driver_mod,
    });
    const install_project_harness_lifecycle_driver = b.addInstallArtifact(
        project_harness_lifecycle_driver,
        .{},
    );
    const project_harness_lifecycle_driver_step = b.step(
        "eval:project-harness-lifecycle-driver",
        "Build the zero-provider real correction-to-promotion lifecycle driver",
    );
    project_harness_lifecycle_driver_step.dependOn(
        &install_project_harness_lifecycle_driver.step,
    );
    const rule_impact_driver_mod = b.createModule(.{
        .root_source_file = b.path("scripts/rule_impact_driver.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    rule_impact_driver_mod.addImport("cc", core_test_mod);
    const rule_impact_driver = b.addExecutable(.{
        .name = "metacodes-rule-impact-driver",
        .root_module = rule_impact_driver_mod,
    });
    const install_rule_impact_driver = b.addInstallArtifact(rule_impact_driver, .{});
    const rule_impact_driver_step = b.step(
        "eval:rule-impact-driver",
        "Build the zero-provider authenticated RuleImpact evaluation bridge",
    );
    rule_impact_driver_step.dependOn(&install_rule_impact_driver.step);
    const project_harness_kernel_cmd = b.addSystemCommand(&.{
        "bash",
        "scripts/build-project-harness-kernel.sh",
    });
    const project_harness_python = if (@import("builtin").os.tag == .windows) "python" else "python3";
    const rule_impact_driver_l2_cmd = b.addSystemCommand(&.{project_harness_python});
    rule_impact_driver_l2_cmd.addFileArg(b.path("scripts/eval/rule_impact_driver_l2.py"));
    rule_impact_driver_l2_cmd.addArg("--eval-driver");
    rule_impact_driver_l2_cmd.addArtifactArg(project_harness_eval_driver);
    rule_impact_driver_l2_cmd.addArg("--impact-driver");
    rule_impact_driver_l2_cmd.addArtifactArg(rule_impact_driver);
    rule_impact_driver_l2_cmd.addArgs(&.{
        "--kernel",
        b.pathFromRoot("zig-out/libexec/metacodes/metacodes-project-kernel"),
    });
    rule_impact_driver_l2_cmd.step.dependOn(&project_harness_kernel_cmd.step);
    const rule_impact_driver_l2_step = b.step(
        "test:rule-impact-driver-l2",
        "Run the zero-provider journal-to-receipt-to-Lean RuleImpact L2",
    );
    rule_impact_driver_l2_step.dependOn(&rule_impact_driver_l2_cmd.step);
    const core_test = addCoreSuite(b, core_test_mod, tfilter);
    const core_shard_reporter = b.addExecutable(.{
        .name = "metacodes-core-shard-reporter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/sharded_test_reporter.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const core_test_step = b.step("test:lib", "Run the complete metacodes-core suite in checked deterministic shards");
    core_test_step.dependOn(addCoreSuiteRun(b, core_test, lib_test_shards, core_shard_reporter, staged_lean_kernels));

    const core_monolithic_run = addTestRunArtifact(b, core_test);
    core_monolithic_run.setEnvironmentVariable("METACODES_TEST_SHARD_COUNT", "1");
    core_monolithic_run.setEnvironmentVariable("METACODES_TEST_SHARD_INDEX", "0");
    wireLeanKernelTestInputs(core_monolithic_run, staged_lean_kernels);
    const core_test_monolithic_step = b.step("test:lib-monolithic", "Run the complete metacodes-core suite in one diagnostic process");
    core_test_monolithic_step.dependOn(&core_monolithic_run.step);

    const shard_runner_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/sharded_test_runner.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const shard_reporter_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/sharded_test_reporter.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const core_shard_harness_step = b.step("test:lib-shard-harness", "Test core shard partition and aggregate fail-closed checks");
    core_shard_harness_step.dependOn(&b.addRunArtifact(shard_runner_tests).step);
    core_shard_harness_step.dependOn(&b.addRunArtifact(shard_reporter_tests).step);

    // Diagnostic companion to test:lib. It runs the identical test graph and
    // semantics, but emits per-test timings plus slow-test buckets/top-N so
    // performance work is driven by evidence instead of guessed timeouts.
    const core_timed_test = b.addTest(.{
        .name = "metacodes-core-test-times",
        .root_module = core_test_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
        .test_runner = .{
            .path = b.path("scripts/time_test_runner.zig"),
            .mode = .simple,
        },
    });
    const core_test_times_step = b.step("test:lib-times", "Run metacodes-core tests with per-test timing diagnostics");
    const core_timed_run = addTestRunArtifact(b, core_timed_test);
    wireLeanKernelTestInputs(core_timed_run, staged_lean_kernels);
    core_test_times_step.dependOn(&core_timed_run.step);
    core_test_step.dependOn(http_status_gate_step);

    // test:lsp —— LSP 子系统(Y2 Step2:被动诊断)隔离测试。
    // 根在 src/ 层(而非 src/lsp/lsp.zig):service.zig 相对引 ../util/time.zig,
    // 根在 src/lsp/ 会越出 module path(见 src/lsp_test_root.zig 顶部说明)。
    // 测试本身也在主套件里跑;`test` 依赖它是为了这份独立编译证明,与 test:provider 同理。
    const lsp_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lsp_test_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addPlatform(b, lsp_test_mod); // lsp/ 依赖 platform（sync/process），隔离测试也需
    const lsp_test = b.addTest(.{ .name = "lsp-test", .root_module = lsp_test_mod });
    const lsp_test_step = b.step("test:lsp", "Test the LSP subsystem in isolation (Y2 Step2)");
    lsp_test_step.dependOn(&addTestRunArtifact(b, lsp_test).step);

    // test:mcp —— #405: the shared MCP client alone, with no CLI, AgentCore or
    // AgentLoop in its graph. Same shape and reason as test:provider below; its
    // tests also run in the main suites, this is the proof of independence.
    const mcp_test_mod = b.createModule(.{
        .root_source_file = b.path("src/mcp_test_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addPlatform(b, mcp_test_mod);
    const mcp_test = b.addTest(.{
        .name = "mcp-test",
        .root_module = mcp_test_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    const mcp_test_step = b.step("test:mcp", "Test the shared MCP client in isolation (#405)");
    mcp_test_step.dependOn(&addTestRunArtifact(b, mcp_test).step);

    // test:provider —— issue #16 provider offer kernel, in isolation.
    // Compiles the subsystem from a narrow root, which proves it *builds*
    // standalone. It does not enforce the import boundary — the module root is
    // `src/`, so any file under it is importable — that is
    // `subsystem:boundary`'s job. `test` runs it: left to be run by hand, this
    // root and the picker's came to compile the whole application, then
    // stopped compiling, and nothing noticed. It is also the only root that
    // reaches `provider/capability_matrix_test.zig`.
    const provider_test_mod = b.createModule(.{
        .root_source_file = b.path("src/provider_test_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addPlatform(b, provider_test_mod); // control_plane guards its state with platform/sync
    const provider_test = b.addTest(.{ .name = "provider-test", .root_module = provider_test_mod });
    const provider_test_step = b.step("test:provider", "Test the provider offer kernel in isolation (issue #16)");
    provider_test_step.dependOn(&addTestRunArtifact(b, provider_test).step);

    // subsystem:boundary —— the provider kernel, the picker and the MCP client
    // may import only what their doc comments say, and so may every file they
    // reach; nothing metacodes-core reaches from `src/lib.zig` may import the
    // application side beyond a baseline that only shrinks (#448), and no
    // file under `src/daemon/` or `src/web/` may import the AgentLoop beyond
    // another such baseline (#445). The
    // compile-from-a-narrow-root gates and `test:lib` cannot enforce it: their
    // module root is `src/`, so any file under it is importable, and lazy
    // analysis skips imports in code nothing calls. This checks the rule where
    // the rule lives, in the source.
    const subsystem_boundary_mod = b.createModule(.{
        .root_source_file = b.path("scripts/subsystem_boundary_gate.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const subsystem_boundary_exe = b.addExecutable(.{
        .name = "subsystem-boundary-gate",
        .root_module = subsystem_boundary_mod,
    });
    const subsystem_boundary_run = b.addRunArtifact(subsystem_boundary_exe);
    subsystem_boundary_run.setCwd(b.path("."));
    subsystem_boundary_run.addArg(".");
    const subsystem_boundary_unit = b.addTest(.{
        .name = "subsystem-boundary-gate-unit",
        .root_module = subsystem_boundary_mod,
    });
    const subsystem_boundary_step = b.step(
        "subsystem:boundary",
        "Enforce the provider, picker, MCP client, metacodes-core and host import boundaries (#16, #405, #445, #448)",
    );
    subsystem_boundary_step.dependOn(&subsystem_boundary_run.step);
    subsystem_boundary_step.dependOn(&addTestRunArtifact(b, subsystem_boundary_unit).step);

    // test:platform —— 可移植抽象层(sync/process/fs/signal/rng/paths)。platform 成独立命名模块后
    // 其测试不再聚合进 cc-test，故独立入口，并由 `test` 依赖。fork 真子进程的测试需
    // METACODES_PROC_TEST=1,`test` 里不设 —— 并行的 build runner 下 fork 会崩(见 process.zig
    // `procSpawnTestsEnabled`);它们由 CI 的 "Native platform modules" 用独立 `zig test` 跑。
    const platform_test_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/platform.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const platform_test = b.addTest(.{ .name = "platform-test", .root_module = platform_test_mod });
    const platform_test_step = b.step("test:platform", "Test the portable platform abstraction layer");
    const platform_test_run = addTestRunArtifact(b, platform_test);
    platform_test_step.dependOn(&platform_test_run.step);

    // example —— 独立消费者,经 module 用库跑一轮 agent loop(见 example/main.zig)。
    const example_mod = b.createModule(.{
        .root_source_file = b.path("example/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_mod.addImport("metacodes-core", core_mod);
    // 注:不在 example_mod 上 addHl —— hl module 随 core_mod 传入,无需重复接。
    const example_exe = b.addExecutable(.{ .name = "example", .root_module = example_mod });
    const example_step = b.step("example", "Build & run the metacodes-core example");
    example_step.dependOn(&b.addRunArtifact(example_exe).step);

    // Zero-provider paired microbenchmark for the once-per-generation plugin
    // snapshot/inventory cost. This is a performance regression gate, not
    // coding-quality evidence (see doc/PLUGIN_EVALUATION.md).
    const plugin_bench_mod = b.createModule(.{
        .root_source_file = b.path("scripts/plugin_snapshot_bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    plugin_bench_mod.addImport("metacodes-core", core_mod);
    const plugin_bench_exe = b.addExecutable(.{
        .name = "plugin-snapshot-bench",
        .root_module = plugin_bench_mod,
    });
    const plugin_bench_step = b.step(
        "plugin:bench",
        "Run the zero-provider immutable plugin snapshot regression benchmark",
    );
    plugin_bench_step.dependOn(&b.addRunArtifact(plugin_bench_exe).step);

    // Load benchmark for the sealed gateway (doc/SEALED_GATEWAY_SCALE_DESIGN.md
    // §10): in-process mock model, N concurrent clients, Steps per second and
    // gateway overhead percentiles. No provider is called.
    const sealed_bench_mod = b.createModule(.{
        .root_source_file = b.path("scripts/sealed_gateway_bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sealed_bench_mod.addImport("metacodes-core", core_mod);
    addPlatform(b, sealed_bench_mod);
    const sealed_bench_exe = b.addExecutable(.{
        .name = "sealed-gateway-bench",
        .root_module = sealed_bench_mod,
    });
    const sealed_bench_run = b.addRunArtifact(sealed_bench_exe);
    if (b.args) |args| sealed_bench_run.addArgs(args);
    const sealed_bench_step = b.step(
        "sealed:bench",
        "Run the sealed gateway load benchmark (mock model; --concurrency/--runs/--steps/--latency-ms)",
    );
    sealed_bench_step.dependOn(&sealed_bench_run.step);

    // `test` is exactly its three parts; nothing else is wired into it
    // (scripts/tests/test_gate_manifest.py checks this). CI runs the parts on
    // separate runners, so a check wired straight into `test` would run on no
    // CI runner at all (doc/CI_DESIGN.md §4).
    // `test:units` is the unit and component test binaries and the
    // repository's script unit suites; `test:integration` is the integration
    // suite (in its shards) and the spikes; `test:product` drives the built product end to end (the evaluation
    // harness, the smokes, the daemon and the TinyKG transport).
    const test_step = b.step("test", "Run tests");
    const units_test_step = b.step("test:units", "Run the unit and component test binaries and the script unit suites (part of `test`)");
    const integration_test_step = b.step("test:integration", "Run Core integration tests and standalone harnesses (part of `test`)");
    const product_test_step = b.step("test:product", "Run the built product end to end: evaluation harness, smokes, daemon (part of `test`)");
    test_step.dependOn(units_test_step);
    test_step.dependOn(integration_test_step);
    test_step.dependOn(product_test_step);
    // Built by nothing else in the suite; compiling it here keeps it in step
    // with the runtime API it calls.
    product_test_step.dependOn(&jev_recall_eval_driver.step);
    // The same holds for the rule-author probe and the project-rule pilot:
    // left to their eval steps, both stopped compiling when the state root
    // became an explicit parameter and nothing noticed. Check-only compiles
    // (no binary is requested, so no code generation). The pilot is zero-paid
    // and hermetic, so macOS also runs it: a drifted TinyKG daemon or provider
    // contract fails here rather than on the next manual run.
    if (@import("builtin").os.tag != .windows) {
        product_test_step.dependOn(&b.addExecutable(.{
            .name = "rule-author-feasibility-check",
            .root_module = rule_author_trial_mod,
        }).step);
        product_test_step.dependOn(&b.addExecutable(.{
            .name = "project-rule-mac-pilot-check",
            .root_module = project_rule_mac_pilot_mod,
        }).step);
    }
    if (@import("builtin").os.tag == .macos) product_test_step.dependOn(&project_rule_mac_pilot_run.step);
    units_test_step.dependOn(&agentcore_archive_test_cmd.step);
    units_test_step.dependOn(http_status_gate_step);
    units_test_step.dependOn(subsystem_boundary_step);
    units_test_step.dependOn(provider_test_step);
    units_test_step.dependOn(mcp_test_step);
    units_test_step.dependOn(lsp_test_step);
    units_test_step.dependOn(platform_test_step);
    const tinykg_contract_test_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "-m",
        "unittest",
        "scripts.tests.test_stage_tinykg_binary",
        "scripts.tests.test_build_tinykg_bundle",
        "-v",
    });
    const tinykg_contract_test_step = b.step(
        "test:tinykg-binary",
        "Test the bundled and explicit manually maintained TinyKG boundary",
    );
    tinykg_contract_test_step.dependOn(&tinykg_contract_test_cmd.step);
    units_test_step.dependOn(&tinykg_contract_test_cmd.step);

    // QuickJS is upstream bytes plus patches/*.patch: the verifier fails on a
    // drifted, undeclared or edited file and on a patch that no longer applies.
    const quickjs_sources_test_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "-m",
        "unittest",
        "scripts.tests.test_stage_quickjs_sources",
        "-v",
    });
    const quickjs_sources_test_step = b.step(
        "test:quickjs-sources",
        "Verify the vendored QuickJS sources, patches and manifest",
    );
    quickjs_sources_test_step.dependOn(&quickjs_sources_test_cmd.step);
    units_test_step.dependOn(&quickjs_sources_test_cmd.step);

    // The trajectory audit itself only runs against a real ~/.metacodes, which
    // CI does not have - but its parsing does not need one, and two defects in
    // it were caught by these tests rather than by the real data (which
    // happened not to exercise them).
    const audit_test_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "-m",
        "unittest",
        "scripts.tests.test_audit_trajectories",
        "-v",
    });
    const audit_test_step = b.step(
        "test:trajectory-audit",
        "Test the session-transcript audit (parsing, pairing, privacy)",
    );
    audit_test_step.dependOn(&audit_test_cmd.step);
    units_test_step.dependOn(&audit_test_cmd.step);
    const doc_check_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "scripts/check_doc_links.py",
    });
    const doc_facts_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "scripts/check_doc_facts.py",
    });
    // A version without `-dev` is legal only on its tagged commit or on a
    // `release/<version>` head: closes the window between a release PR merging
    // and the reopen PR (doc/RELEASE_AUTOMATION_DESIGN.md stage D).
    const version_state_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "scripts/check_version_state.py",
    });
    const doc_check_step = b.step("doc:check", "Check documentation links, facts and the version state");
    doc_check_step.dependOn(&doc_check_cmd.step);
    doc_check_step.dependOn(&doc_facts_cmd.step);
    doc_check_step.dependOn(&version_state_cmd.step);
    const doc_references_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "scripts/eval/plugin_release_gate.py",
        "--validate-only",
    });
    const doc_references_step = b.step("doc:references", "Validate protocol paths and pins without running the product or providers");
    doc_references_step.dependOn(&doc_references_cmd.step);
    doc_check_step.dependOn(doc_references_step);
    const release_docs_sources_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "scripts/check_release_docs.py",
    });
    doc_check_step.dependOn(&release_docs_sources_cmd.step);
    const notices_cmd = b.addSystemCommand(&.{ if (@import("builtin").os.tag == .windows) "python" else "python3", "scripts/gen_third_party_notices.py", "--check" });
    const notices_step = b.step("release:notices", "Check generated third-party notices");
    notices_step.dependOn(&notices_cmd.step);
    doc_check_step.dependOn(notices_step);
    const release_docs_check_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "scripts/check_release_docs.py",
        "--prefix",
        b.getInstallPath(.prefix, ""),
    });
    release_docs_check_cmd.step.dependOn(release_docs_step);
    release_docs_check_cmd.step.dependOn(notices_step);
    const release_docs_check_step = b.step("release:docs:check", "Stage and verify only release documents, licences and generated notices");
    release_docs_check_step.dependOn(&release_docs_check_cmd.step);
    const release_docs_test_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "-m",
        "unittest",
        "scripts.tests.test_check_release_docs",
        "-v",
    });
    units_test_step.dependOn(&release_docs_test_cmd.step);
    const doc_facts_test_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "-m",
        "unittest",
        "scripts.tests.test_check_doc_facts",
        "-v",
    });
    const doc_facts_test_step = b.step("test:doc-facts", "Test documentation fact checks");
    doc_facts_test_step.dependOn(&doc_facts_test_cmd.step);
    units_test_step.dependOn(&doc_facts_test_cmd.step);
    // Every std.Io.Threaded goes through platform.signal.threadedIo (SIGPIPE
    // must stay ignored; see src/platform/signal.zig).
    const io_threaded_test_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "-m",
        "unittest",
        "scripts.tests.test_io_threaded_discipline",
        "-v",
    });
    const io_threaded_test_step = b.step("test:io-threaded", "Test that std.Io.Threaded is created only through platform.signal.threadedIo");
    io_threaded_test_step.dependOn(&io_threaded_test_cmd.step);
    units_test_step.dependOn(&io_threaded_test_cmd.step);
    // Production threads state their stack through platform.thread.spawn: std's
    // 16 MiB default is a 16 MiB commit per thread on Windows (#503).
    const thread_stack_test_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "-m",
        "unittest",
        "scripts.tests.test_thread_stack_discipline",
        "-v",
    });
    const thread_stack_test_step = b.step("test:thread-stack", "Test that production threads spawn through platform.thread.spawn with a stated stack");
    thread_stack_test_step.dependOn(&thread_stack_test_cmd.step);
    units_test_step.dependOn(&thread_stack_test_cmd.step);
    // The REPL's SIGWINCH handler has no SA_RESTART: its terminal reads retry
    // EINTR and its terminal writes go through pfs.writeAll (#340).
    const terminal_io_test_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "-m",
        "unittest",
        "scripts.tests.test_terminal_io_discipline",
        "-v",
    });
    const terminal_io_test_step = b.step("test:terminal-io", "Test that REPL terminal reads retry EINTR and writes go through pfs.writeAll");
    terminal_io_test_step.dependOn(&terminal_io_test_cmd.step);
    units_test_step.dependOn(&terminal_io_test_cmd.step);
    // No built-in destination that is on by default is cleartext to a public
    // host (#474): the product's `http://` literals name loopback only, except
    // the Jev default no host takes, and the CLI's decision stays off.
    const builtin_egress_test_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "-m",
        "unittest",
        "scripts.tests.test_builtin_egress_discipline",
        "-v",
    });
    const builtin_egress_test_step = b.step("test:builtin-egress", "Test that no default-on built-in destination is cleartext to a public host");
    builtin_egress_test_step.dependOn(&builtin_egress_test_cmd.step);
    units_test_step.dependOn(&builtin_egress_test_cmd.step);
    const gate_manifest_test_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "-m",
        "unittest",
        "scripts.tests.test_gate_manifest",
        "-v",
    });
    const gate_manifest_test_step = b.step("test:gate-manifest", "Test the AGENTS.md and CI gate manifest");
    gate_manifest_test_step.dependOn(&gate_manifest_test_cmd.step);
    units_test_step.dependOn(&gate_manifest_test_cmd.step);
    const pr_loop_test_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "-m",
        "unittest",
        "scripts.tests.test_pr_loop",
        "scripts.tests.test_pr_policy",
        "scripts.tests.test_ci_evidence",
        "-v",
    });
    const pr_loop_test_step = b.step("test:pr-loop", "Test PR review, repair, exact-head merging and CI evidence");
    pr_loop_test_step.dependOn(&pr_loop_test_cmd.step);
    units_test_step.dependOn(&pr_loop_test_cmd.step);
    const release_cut_test_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "-m",
        "unittest",
        "scripts.tests.test_release_cut",
        "-v",
    });
    const release_cut_test_step = b.step("test:release-cut", "Test the release cut / reopen rules and the version-state gate");
    release_cut_test_step.dependOn(&release_cut_test_cmd.step);
    units_test_step.dependOn(&release_cut_test_cmd.step);
    // The rule-control sensors read source text, so moving the code a sensor
    // reads turns its rule red without failing any product test. Only the
    // dispatch-only rule-control workflow ran them, and three drifted
    // unnoticed. The suite observes every rule on the checked-in tree, which
    // fails the drift in the change that causes it; the Lean decision and
    // replayed feedback stay in `rule-check`.
    const rule_control_test_cmd = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "-m",
        "unittest",
        "scripts.tests.test_rule_control",
        "-v",
    });
    const rule_control_test_step = b.step("test:rule-control", "Test the rule-control sensors on fixtures and on the checked-in tree");
    rule_control_test_step.dependOn(&rule_control_test_cmd.step);
    units_test_step.dependOn(&rule_control_test_cmd.step);
    const gate_fmt = b.addFmt(.{ .paths = &.{ "build.zig", "src", "tests" }, .check = true });
    const gate_coverage = if (@import("builtin").os.tag == .windows)
        b.addSystemCommand(&.{ "cmd", "/C", "echo scripts/test_coverage_audit.sh is bash-only; skipped on Windows" })
    else
        b.addSystemCommand(&.{"scripts/test_coverage_audit.sh"});
    // The checklist ends with `git diff --check`; the aggregate gate runs it too,
    // so the one advertised command really is the whole list.
    const gate_diff_check = b.addSystemCommand(&.{ "git", "diff", "--check" });
    // The checklist runs `zig build test` and `zig build test:lib
    // -Doptimize=ReleaseSafe`, but one invocation has one -Doptimize. So the
    // full suite runs at the invocation's (Debug by default) while the gate owns
    // a ReleaseSafe build of the core suite: the same compilation as that
    // checklist command, so either warms the cache for the other, and none extra
    // when the invocation already is ReleaseSafe.
    const gate_core_suite = if (optimize == .ReleaseSafe) core_test_step else addCoreSuiteRun(
        b,
        addCoreSuite(b, createCoreModule(b, target, .ReleaseSafe), tfilter),
        lib_test_shards,
        core_shard_reporter,
        staged_lean_kernels,
    );
    // gate:static —— the guards that only read the source (#587). Inside
    // gate:pr they ran beside every compile and test step, and the build
    // runner has no fail-fast, so a guard that fails in seconds on its own was
    // reported only at the end of the whole gate. The checklist and every CI
    // gate leg run this first; gate:pr still includes it.
    const gate_static_step = b.step("gate:static", "Run the source-level guards alone: fmt, the boundary gates, the discipline scans, git diff --check");
    gate_static_step.dependOn(&gate_fmt.step);
    // The boundary gates' scans only: their self-tests are test binaries,
    // which bring in the fs-helper install (`addTestRunArtifact`), and run
    // in `test:units` with the rest of the suite.
    gate_static_step.dependOn(&http_status_gate_run.step);
    gate_static_step.dependOn(&subsystem_boundary_run.step);
    gate_static_step.dependOn(&io_threaded_test_cmd.step);
    gate_static_step.dependOn(&thread_stack_test_cmd.step);
    gate_static_step.dependOn(&terminal_io_test_cmd.step);
    gate_static_step.dependOn(&builtin_egress_test_cmd.step);
    gate_static_step.dependOn(&gate_diff_check.step);
    const gate_pr_step = b.step("gate:pr", "Run the AGENTS.md pre-submit checklist");
    gate_pr_step.dependOn(gate_static_step);
    gate_pr_step.dependOn(test_step);
    gate_pr_step.dependOn(gate_core_suite);
    gate_pr_step.dependOn(&gate_coverage.step);
    gate_pr_step.dependOn(doc_check_step);
    units_test_step.dependOn(core_test_step);

    // Two independent Metacodes processes share one authenticated StoreActor.
    // This is the runtime actuator for the daemon transport control plane.
    const kg_transport_probe_mod = b.createModule(.{
        .root_source_file = b.path("tests/helpers/kg_daemon_transport_probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    kg_transport_probe_mod.addImport("metacodes-core", core_mod);
    addPlatform(b, kg_transport_probe_mod);
    const kg_transport_probe = b.addExecutable(.{
        .name = "kg-daemon-transport-probe",
        .root_module = kg_transport_probe_mod,
    });
    const kg_transport_runtime = b.addSystemCommand(&.{
        if (@import("builtin").os.tag == .windows) "python" else "python3",
        "scripts/test_kg_daemon_transport.py",
        "--probe",
    });
    kg_transport_runtime.addArtifactArg(kg_transport_probe);
    const kg_transport_step = b.step("test:kg-daemon-transport", "Run authenticated shared-Store daemon transport L2");
    kg_transport_step.dependOn(&kg_transport_runtime.step);
    product_test_step.dependOn(&kg_transport_runtime.step);

    // test:eval —— harness 评估控制面（suite/readiness/rollout/judgement/
    // compare/gate）。Python 合同测试 + 同宿主原生零付费 smoke；不访问真实模型，
    // 默认 test 也执行，避免评估器或 native 接线漂移后继续给出看似可信的分数。
    const eval_test_step = b.step("test:eval", "Test the harness evaluation framework");
    const eval_python_exe = if (@import("builtin").os.tag == .windows) "python" else "python3";
    // The suite runs as shards (scripts/eval/tests/run_shard.py: every N-th
    // module), each with its output captured. As one process inheriting the
    // terminal it ran after every smoke, since the build runner runs such
    // commands one at a time, and it was the longest of them
    // (doc/CI_DESIGN.md §4). Captured, the shards run beside the smokes and
    // each other; the build runner prints a shard's output when it ends.
    const eval_test_shards = 3;
    var eval_test_cmds: [eval_test_shards]*std.Build.Step.Run = undefined;
    for (&eval_test_cmds, 1..) |*slot, shard| {
        const eval_test_cmd = b.addSystemCommand(&.{
            eval_python_exe,
            "scripts/eval/tests/run_shard.py",
            b.fmt("{d}/{d}", .{ shard, eval_test_shards }),
            "-v",
        });
        eval_test_cmd.expectExitCode(0);
        eval_test_step.dependOn(&eval_test_cmd.step);
        product_test_step.dependOn(&eval_test_cmd.step);
        slot.* = eval_test_cmd;
    }
    const runtime_tests_can_execute_target =
        target.result.os.tag == @import("builtin").os.tag and
        target.result.cpu.arch == @import("builtin").cpu.arch;
    if (runtime_tests_can_execute_target) {
        if (staged_tinykg) |tinykg| {
            // Native Python cases discover the installed TinyKG by path.  On
            // a clean checkout they must wait for installation; otherwise
            // test discovery races the build and silently turns coverage into
            // machine-state-dependent skips.
            for (eval_test_cmds) |eval_test_cmd| {
                eval_test_cmd.step.dependOn(tinykg.install_step);
                eval_test_cmd.setEnvironmentVariable("METACODES_TEST_TINYKG_BIN", tinykg.installed_path);
                eval_test_cmd.setEnvironmentVariable("METACODES_TEST_TINYKG_SHA256", tinykg.source_sha256);
                if (staged_tinykgd) |daemon| {
                    eval_test_cmd.step.dependOn(daemon.install_step);
                    eval_test_cmd.setEnvironmentVariable("METACODES_TEST_TINYKGD_BIN", daemon.installed_path);
                }
            }
        }
        const rule_sandbox_available = switch (@import("builtin").os.tag) {
            .windows => false,
            .linux => if (b.findProgram(&.{"bwrap"}, &.{})) |_| true else |_| false,
            else => true,
        };
        if (rule_sandbox_available) if (staged_lean_kernels.project != null) for (eval_test_cmds) |eval_test_cmd| {
            wireLeanKernelTestInputs(eval_test_cmd, staged_lean_kernels);
            eval_test_cmd.step.dependOn(&install_project_harness_eval_driver.step);
            eval_test_cmd.step.dependOn(&install_project_harness_lifecycle_driver.step);
            eval_test_cmd.setEnvironmentVariable(
                "METACODES_TEST_PROJECT_HARNESS_DRIVER",
                b.getInstallPath(.bin, project_harness_eval_driver.out_filename),
            );
            eval_test_cmd.setEnvironmentVariable(
                "METACODES_TEST_PROJECT_HARNESS_LIFECYCLE_DRIVER",
                b.getInstallPath(.bin, project_harness_lifecycle_driver.out_filename),
            );
            // A staged project kernel means a lake built control-plane/lean,
            // so the compiled SDK is there: its absence is a failure, not a
            // reason to skip. With -Dlean-kernels=on and no toolchain the
            // kernel is a failing step this run already depends on.
            if (findLake(b)) |lake|
                eval_test_cmd.setEnvironmentVariable("METACODES_TEST_PROJECT_LAKE_PATH", toolchainLake(b, lake) orelse lake);
            eval_test_cmd.setEnvironmentVariable("METACODES_TEST_REQUIRE_LEAN_SDK", "1");
        };
    }

    // ------------------------------------------------------------------
    // Extra test step: spike / standalone harness files under tests/
    // Each file is compiled as an independent test artifact so main src
    // stays clean. Add new files here as they land.
    // ------------------------------------------------------------------
    const spike_step = b.step("test:spike", "Run spike / harness tests");
    const spike_files = [_][]const u8{
        "tests/unit/stream_reader_spike.zig",
        "tests/unit/termios_spike.zig", // POSIX-only(termios)——Windows 目标下面跳过
        "tests/_harness/mock_sse_server.zig",
    };
    for (spike_files) |f| {
        if (target.result.os.tag == .windows and std.mem.endsWith(u8, f, "termios_spike.zig")) continue;
        // mock_sse_server 复用共享 harness 模块做 root(它就是同一份编译);其余 spike 各自建。
        const shared_harness = std.mem.endsWith(u8, f, "mock_sse_server.zig");
        const m = if (shared_harness) test_harness_mod else b.createModule(.{
            .root_source_file = b.path(f),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        if (!shared_harness) addPlatform(b, m);
        const t = b.addTest(.{
            .name = "spike",
            .root_module = m,
            .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
        });
        const run_t = addTestRunArtifact(b, t);
        spike_step.dependOn(&run_t.step);
    }

    const integration_suite_mod = createIntegrationModule(b, target, optimize, test_harness_mod, core_mod, mock_mcp_exe.getEmittedBin());
    const integration_suite_test = b.addTest(.{
        .name = "integration-suite",
        .root_module = integration_suite_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
        .test_runner = .{
            .path = b.path("scripts/sharded_test_runner.zig"),
            .mode = .simple,
        },
    });
    const integration_reports = b.allocator.alloc(std.Build.LazyPath, integration_test_shards) catch @panic("OOM");
    for (0..integration_test_shards) |shard_index| {
        const run_shard = addTestRunArtifact(b, integration_suite_test);
        run_shard.has_side_effects = true;
        run_shard.setEnvironmentVariable("METACODES_TEST_SHARD_COUNT", b.fmt("{}", .{integration_test_shards}));
        run_shard.setEnvironmentVariable("METACODES_TEST_SHARD_INDEX", b.fmt("{}", .{shard_index}));
        run_shard.expectExitCode(0);
        run_shard.step.dependOn(&install_mock_mcp.step);
        run_shard.step.dependOn(&install_selfexe_probe.step);
        wireTinyKgTestInput(run_shard, staged_tinykg);
        wireTinyKgdTestInput(run_shard, staged_tinykgd);
        wireLeanKernelTestInputs(run_shard, staged_lean_kernels);
        wirePinnedRipgrepTestInput(b, run_shard, ripgrep_bundle);
        integration_reports[shard_index] = run_shard.captureStdOut(.{
            .basename = b.fmt("integration-test-shard-{}.txt", .{shard_index}),
        });
    }
    const run_integration_reporter = b.addRunArtifact(core_shard_reporter);
    for (integration_reports) |report| run_integration_reporter.addFileArg(report);
    spike_step.dependOn(&run_integration_reporter.step);

    const integration_monolithic_run = addTestRunArtifact(b, integration_suite_test);
    integration_monolithic_run.setEnvironmentVariable("METACODES_TEST_SHARD_COUNT", "1");
    integration_monolithic_run.setEnvironmentVariable("METACODES_TEST_SHARD_INDEX", "0");
    integration_monolithic_run.step.dependOn(&install_mock_mcp.step);
    integration_monolithic_run.step.dependOn(&install_selfexe_probe.step);
    wireTinyKgTestInput(integration_monolithic_run, staged_tinykg);
    wireTinyKgdTestInput(integration_monolithic_run, staged_tinykgd);
    wireLeanKernelTestInputs(integration_monolithic_run, staged_lean_kernels);
    wirePinnedRipgrepTestInput(b, integration_monolithic_run, ripgrep_bundle);
    const integration_monolithic_step = b.step("test:integration-monolithic", "Run the Core integration suite in one process");
    integration_monolithic_step.dependOn(&integration_monolithic_run.step);

    const integration_timed_test = b.addTest(.{
        .name = "integration-suite-times",
        .root_module = integration_suite_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
        .test_runner = .{
            .path = b.path("scripts/time_test_runner.zig"),
            .mode = .simple,
        },
    });
    const integration_timed_run = addTestRunArtifact(b, integration_timed_test);
    integration_timed_run.step.dependOn(&install_mock_mcp.step);
    integration_timed_run.step.dependOn(&install_selfexe_probe.step);
    wireTinyKgTestInput(integration_timed_run, staged_tinykg);
    wireTinyKgdTestInput(integration_timed_run, staged_tinykgd);
    wireLeanKernelTestInputs(integration_timed_run, staged_lean_kernels);
    wirePinnedRipgrepTestInput(b, integration_timed_run, ripgrep_bundle);
    const integration_times_step = b.step("test:integration-times", "Run aggregate component/integration tests with per-test timings");
    integration_times_step.dependOn(&integration_timed_run.step);

    const core_integration_step = b.step("test:core-integration", "Run Core integration tests against the library");
    core_integration_step.dependOn(&run_integration_reporter.step);

    // ToolDispatcher metadata 验收(issue #5):直接消费 AgentCore 包装层
    // (session_budget/mcp_session/model_skill_tool)与 metacodes-core 目录的
    // 组合。cc(main.zig 根)与 metacodes-core(lib.zig 根)不能共存于同一个
    // 编译图,故此文件从 aggregate 套件排除(见 aggregate_test_exclusions),
    // 走独立 artifact 并挂进主 test gate。
    const dispatcher_metadata_mod = b.createModule(.{
        .root_source_file = b.path("tests/component/tool_dispatcher_metadata_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dispatcher_metadata_mod.addImport("harness", test_harness_mod);
    dispatcher_metadata_mod.addImport("metacodes-core", core_mod);
    dispatcher_metadata_mod.addImport("agentcore-abi", agentcore_abi_test_mod);
    addPlatform(b, dispatcher_metadata_mod);
    const dispatcher_metadata_test = b.addTest(.{
        .name = "tool-dispatcher-metadata",
        .root_module = dispatcher_metadata_mod,
        .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
    });
    const dispatcher_metadata_run = addTestRunArtifact(b, dispatcher_metadata_test);
    const dispatcher_metadata_step = b.step("test:dispatcher-metadata", "Run the ToolDispatcher metadata acceptance suite");
    dispatcher_metadata_step.dependOn(&dispatcher_metadata_run.step);
    units_test_step.dependOn(&dispatcher_metadata_run.step);

    // Focused Skill Runtime gate. Keep this work independently
    // runnable instead of forcing every unrelated spike/component artifact
    // through the broad `test` graph.
    const skill_runtime_step = b.step(
        "test:skill-runtime",
        "Run the Skill Runtime integration tests",
    );
    const skill_runtime_files = [_][]const u8{
        "tests/integration/skills_e2e_test.zig",
        "tests/component/skill_fork_test.zig",
    };
    for (skill_runtime_files) |f| {
        const m = b.createModule(.{
            .root_source_file = b.path(f),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        m.addImport("harness", test_harness_mod);
        m.addImport("metacodes-core", core_mod);
        addPlatform(b, m);
        const t = b.addTest(.{
            .name = "skill-runtime",
            .root_module = m,
            .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
        });
        const run_t = addTestRunArtifact(b, t);
        skill_runtime_step.dependOn(&run_t.step);
    }
    const skill_runtime_unit_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addHl(b, skill_runtime_unit_mod);
    const skill_runtime_unit = b.addTest(.{
        .name = "skill-runtime-unit",
        .root_module = skill_runtime_unit_mod,
        .filters = &.{
            "skills.runtime",
            "skills.active",
            "skills.skill",
            "skills.tool_pool_filter",
        },
    });
    skill_runtime_step.dependOn(
        &addTestRunArtifact(
            b,
            skill_runtime_unit,
        ).step,
    );

    integration_test_step.dependOn(spike_step);

    const new_step = b.step("test:new", "Run focused Core integration tests (use -Dtfilter)");
    const focused_test_files = [_][]const u8{
        "tests/component/add_dir_test.zig",
        "tests/component/agent_background_test.zig",
        "tests/component/agent_session_host_tools_test.zig",
        "tests/component/agent_session_tools_test.zig",
        "tests/component/agent_session_ui_test.zig",
        "tests/component/answer_queue_test.zig",
        "tests/component/auth_test.zig",
        "tests/component/auto_compact_request_test.zig",
        "tests/component/background_main_test.zig",
        "tests/component/base_url_flag_test.zig",
        "tests/component/cache_break_test.zig",
        "tests/component/capability_gate_test.zig",
        "tests/component/compact_summary_test.zig",
        "tests/component/compound_perm_test.zig",
        "tests/component/connection_keepalive_test.zig",
        "tests/component/diagnostics_test.zig",
        "tests/component/dialect_matrix_test.zig",
        "tests/component/execute_code_test.zig",
        "tests/component/gemini_provider_test.zig",
        "tests/component/goal_state_test.zig",
        "tests/component/harnessmm_test.zig",
        "tests/component/http_error_test.zig",
        "tests/component/kg_task_projection_test.zig",
        "tests/component/microcompact_test.zig",
        "tests/component/openai_provider_test.zig",
        "tests/component/plugin_process_test.zig",
        "tests/component/plugin_runtime_test.zig",
        "tests/component/prompt_override_test.zig",
        "tests/component/protected_skill_inject_test.zig",
        "tests/component/provider_vtable_test.zig",
        "tests/component/read_state_test.zig",
        "tests/component/recovery_allowance_test.zig",
        "tests/component/rule_author_test.zig",
        "tests/component/schema_validation_test.zig",
        "tests/component/sealed_publication_test.zig",
        "tests/component/self_evolution_test.zig",
        "tests/component/skill_fileref_test.zig",
        "tests/component/stream_retry_test.zig",
        "tests/component/subagent_agentdef_fields_test.zig",
        "tests/component/suspend_resume_test.zig",
        "tests/component/swarm_dag_test.zig",
        "tests/component/swarm_process_test.zig",
        "tests/component/swarm_security_test.zig",
        "tests/component/swarm_tools_test.zig",
        "tests/component/task_batch_test.zig",
        "tests/component/task_error_test.zig",
        "tests/component/teammate_runtime_test.zig",
        "tests/component/tool_concurrency_test.zig",
        "tests/component/tool_loop_breaker_test.zig",
        "tests/component/tool_result_storage_test.zig",
        "tests/component/tool_schema_coverage_test.zig",
        "tests/component/tool_smoke_test.zig",
        "tests/component/transcript_roundtrip_test.zig",
        "tests/component/ui_backend_test.zig",
        "tests/component/ui_multifrontend_test.zig",
        "tests/component/user_context_inject_test.zig",
        "tests/component/weak_model_test.zig",
    };
    for (focused_test_files) |path| {
        const module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        module.addImport("harness", test_harness_mod);
        module.addImport("metacodes-core", core_mod);
        addPlatform(b, module);
        const focused_test = b.addTest(.{
            .name = "core-l2",
            .root_module = module,
            .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
        });
        new_step.dependOn(&addTestRunArtifact(b, focused_test).step);
    }

    // 五个 AgentDef 运行字段的聚焦门；开发时无需编译整套 component artifacts。
    const agentdef_fields_step = b.step("test:agentdef-fields", "Run AgentDef runtime field L2/L3 tests");
    {
        const m = b.createModule(.{
            .root_source_file = b.path("tests/component/subagent_agentdef_fields_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        m.addImport("harness", test_harness_mod);
        m.addImport("metacodes-core", core_mod);
        addPlatform(b, m);
        const t = b.addTest(.{
            .name = "agentdef-fields",
            .root_module = m,
            .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
        });
        agentdef_fields_step.dependOn(&addTestRunArtifact(b, t).step);
    }

    // test:mem —— 记忆系统 L2 组件测试(隔离 artifact,绕开主套件 integration 挂起)。
    // 通道 A:user_context_inject;通道 B:memdir_inject。MockServer 断言端到端进请求体。
    const mem_step = b.step("test:mem", "Run memory-system L2 component tests (isolated)");
    {
        const mem_files = [_][]const u8{
            "tests/component/user_context_inject_test.zig",
            "tests/component/memdir_inject_test.zig",
        };
        for (mem_files) |f| {
            const m = b.createModule(.{
                .root_source_file = b.path(f),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            m.addImport("harness", test_harness_mod); // 共享模块(见 integ 循环前注释:perf)
            m.addImport("metacodes-core", core_mod);
            addPlatform(b, m); // 测试文件用 platform 的可移植 env/net 封装
            const t = b.addTest(.{
                .name = "mem-l2",
                .root_module = m,
                .filters = if (tfilter) |filter_text| &.{filter_text} else &.{},
            });
            mem_step.dependOn(&addTestRunArtifact(b, t).step);
        }
    }

    // 专用的知识治理闭环反馈门：只编译 Kg 自动召回、真实 API prompt 和真 TinyKG
    // KgContext 纵切，避免 rule-control 为三个测试冷编译整个 test:spike 图。
    const kg_governance_step = b.step("test:kg-governance", "Run TinyKG evidence/freshness governance L2 tests");
    {
        const m = b.createModule(.{
            .root_source_file = b.path("tests/component/kg_integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        m.addImport("harness", test_harness_mod);
        m.addImport("metacodes-core", core_mod);
        addPlatform(b, m);
        const t = b.addTest(.{
            .name = "kg-governance-l2",
            .root_module = m,
            .filters = if (tfilter) |filter_text| &.{filter_text} else &.{"L2 KG governance:"},
        });
        const run_t = addTestRunArtifact(b, t);
        wireTinyKgTestInput(run_t, staged_tinykg);
        wireTinyKgdTestInput(run_t, staged_tinykgd);
        kg_governance_step.dependOn(&run_t.step);
    }

    // Focused feedback actuator for the execution-grounded ontology loop. The
    // rule controller observes this exact production L2 instead of accepting a
    // manifest or prompt claim as proof of runtime wiring.
    const kg_ontology_feedback_step = b.step("test:kg-ontology-feedback", "Run host-execution to TinyKG ontology feedback L2");
    {
        const m = b.createModule(.{
            .root_source_file = b.path("tests/component/kg_integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        m.addImport("harness", test_harness_mod);
        m.addImport("metacodes-core", core_mod);
        addPlatform(b, m);
        const t = b.addTest(.{
            .name = "kg-ontology-feedback-l2",
            .root_module = m,
            .filters = if (tfilter) |filter_text| &.{filter_text} else &.{"L2 KG ontology feedback:"},
        });
        const run_t = addTestRunArtifact(b, t);
        wireTinyKgTestInput(run_t, staged_tinykg);
        wireTinyKgdTestInput(run_t, staged_tinykgd);
        kg_ontology_feedback_step.dependOn(&run_t.step);
    }

    // Focused feedback actuator for the read side of the ontology loop: a new
    // task claim must receive verified, execution-grounded history before the
    // next model request can perform work.
    const kg_experience_feedback_step = b.step("test:kg-experience-feedback", "Run TinyKG prior-execution decision feedback L2");
    {
        const m = b.createModule(.{
            .root_source_file = b.path("tests/component/kg_integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        m.addImport("harness", test_harness_mod);
        m.addImport("metacodes-core", core_mod);
        addPlatform(b, m);
        const t = b.addTest(.{
            .name = "kg-experience-feedback-l2",
            .root_module = m,
            .filters = if (tfilter) |filter_text| &.{filter_text} else &.{"L2 KG experience feedback:"},
        });
        const run_t = addTestRunArtifact(b, t);
        wireTinyKgTestInput(run_t, staged_tinykg);
        wireTinyKgdTestInput(run_t, staged_tinykgd);
        kg_experience_feedback_step.dependOn(&run_t.step);
    }

    const windows_gate_step = b.step("windows:gate", "Run Windows platform and native AgentCore tests");
    if (target.result.os.tag == .windows) {
        windows_gate_step.dependOn(platform_test_step);
        windows_gate_step.dependOn(lsp_test_step);
        windows_gate_step.dependOn(agentcore_gate_step);
    } else {
        windows_gate_step.dependOn(&b.addFail("windows:gate requires a Windows target").step);
    }

    _ = b.addFmt(.{
        .paths = &.{"src/"},
        .exclude_paths = &.{},
    });
}
