# Contributor instructions

These rules apply to the entire repository.

## Engineering contract

- Use the Zig version declared by `build.zig.zon` and CI. Verify unfamiliar
  standard-library APIs against the installed toolchain instead of relying on
  memory from another Zig release.
- Develop type first: define the state model and signatures, then let the compiler
  drive the implementation.
- Make illegal states unrepresentable. Prefer tagged unions, distinct ID types,
  explicit error sets, and compile-time validation over optional-field protocols.
- Every allocation has an owner. Name allocators by lifetime (`gpa`, `arena`,
  `scratch`) and place `defer` immediately after successful resource acquisition.
- Path-taking file operations go through `src/platform/fs.zig` (`open`,
  `openZ`, `mkdir`, `rmdir`, `chdir`, `chmod`, `fopen`, `unlinkPath`,
  `renameReplace`, `exists`, `realpath`, `finalPath`, `getCwd`) and the
  environment/cwd through `platform.paths`/`util.fs`, never through the
  `std.c.*` spellings: on Windows those are the narrow CRT entry points, which
  decode UTF-8 paths with the ANSI code page and reach a different file than
  the wide-character checks do (POSIX-only code and fixed ASCII device paths
  such as `/dev/null` are the only exceptions). `realpath` is lexical on
  Windows; use `finalPath` when you need the physical path. Read errno through
  `pfs.lastErrnoIs`/`pfs.errnoTag`, not a bare `@enumFromInt` or
  `std.posix.errno`.
- Create every `std.Io.Threaded` through `platform.signal.threadedIo`, never
  `std.Io.Threaded.init`: std's init replaces the ignored SIGPIPE with a
  handler, and a delivered SIGPIPE turns any thread's blocked syscall into
  EINTR (`zig build test:io-threaded` enforces it).
- Spawn production threads through `platform.thread.spawn(stack, ...)`, never
  `std.Thread.spawn`: std's 16 MiB default stack is a 16 MiB commit per thread
  on Windows. Pick the `Stack` class by what the thread runs; outside test
  blocks `zig build test:thread-stack` enforces it.
- In permission prompts, preserve interrupted-read
  handling and write terminal output through `pfs.writeAll`.
  `zig build test:terminal-io` checks the relevant sources.
- Session state leaves the machine for a service only where the user named it.
  No built-in destination that is on by default is a non-loopback `http://`
  URL, and the CLI takes no built-in System-One advisor (`jev.BUILTIN_DEFAULT`
  is for a host that sets `Config.jev_builtin_default`, none here): name a
  service in `config.json` or the environment, or use https
  (`zig build test:builtin-egress` enforces it, #474).
- Agents do not write comments, doc comments or docstrings. Let names, types
  and structure carry the meaning, and put the reasoning behind a change in
  its commit message or PR description. The exceptions are what this file or
  a check requires (`// no EINTR: <reason>`, the stated reason for a listed
  terminal write), tool directives (`# shellcheck disable=...`, `# noqa`,
  `# type: ignore`) and shebangs. Leave existing comments alone unless the
  code they describe changes; then correct or delete them.
- Preserve the kernel boundaries: plugins cannot replace the AgentLoop or bypass
  permission, sandbox, budget, formal verdicts, TinyKG admission, or artifact CAS.
- Provider-visible bytes are a cache contract. Runtime generation, plugin paths,
  journals, timestamps, and equivalent configuration churn must not enter prompts.
- TinyKG is a separately built external binary dependency. The repository owns one
  manually reviewed cross-platform binary bundle, selected by target and pinned
  by SHA-256. Never add TinyKG source vendoring, download-on-build, `PATH` search,
  sibling-checkout discovery, or stale build-output fallback.

## Preview features

Every preview feature has its own field. Source embedders set these fields in
`RuntimeConfig.preview` ([doc/API.md](doc/API.md#preview-features)). When you
add a preview feature:

- Add its name to `PreviewFeature` and a field of the same name to
  `PreviewFeatures` in `src/types.zig`, shrinking `_unused` by one bit; `all`,
  `has`, `with` and `max_arg_len` derive from the enum, and a field without a
  matching name fails to compile. The name is what users type, so use
  `snake_case`.
- Gate the feature on its own field and nothing else: `opts.preview.<name>`,
  `ctx.preview.<name>`, or `.preview_feature = .<name>` on a tool's registry
  entry. Never gate on another feature's field, on "any feature enabled", or on
  a new `bool`. Features with dedicated settings, such as HarnessMM and RSI,
  are selected by those settings alone.
- Pass the existing `preview.Features` value through; do not add a parallel
  field. Child agents, Teamwork seats and teammate processes already inherit
  the resolved set.
- Prove with a Core integration test that selecting the feature enables it
  and selecting only a different feature leaves it disabled.
- Document it in the same change: the feature table in
  [doc/API.md](doc/API.md#preview-features) and `CHANGELOG.md`.
- The AgentCore ABI has no per-feature selection: `RuntimeConfigV1.preview = 1`
  enables every feature. Adding one there is an ABI revision.

## Definition of done

Declaration = wiring = L2 evidence. A schema/config/API field is not implemented
until a component or integration test proves input X changes the real downstream
request, child process, durable state, or host-visible result Y. Silent no-ops are
not accepted.

Before submitting:

```sh
zig build gate:static
zig build test:lib -Doptimize=ReleaseSafe
zig build test
scripts/test_coverage_audit.sh
python3 scripts/check_doc_links.py
python3 scripts/check_doc_facts.py
git diff --check
```

`zig build gate:static` runs only the guards that read the source:
`zig fmt --check build.zig src tests`, the scans of `http-status:gate` and
`subsystem:boundary` (their self-tests run in `test:units`), the
`scripts/tests/test_*_discipline.py` scans and `git diff --check`. It takes seconds, and it comes first because the build
runner has no fail-fast: inside the full gate a failed guard is reported
only when everything else has finished (#587).

`zig build gate:pr` runs the local checklist, with the core suite in
ReleaseSafe and the full suite at `-Doptimize` (Debug by default).
`zig build test` aggregates `test:units`, `test:integration` and `test:product`.
The fork's CI builds SDK archives on pull requests and pushes to `main`.
The Release workflow builds the platform matrix on fork tags.
Document deletions/moves use link and protocol-reference checks;
release-document changes use `release:docs:check`, which shares the release
copy steps without compiling the product.
Run the full suite with `-Doptimize=ReleaseSafe` as well when a change touches
unsafe code or an ABI.

The Python steps need Python >= 3.9 and PyYAML (`requirements-dev.txt`).

The native bundled TinyKG is wired into tests by default. Supply
`-Dtinykg-bin` and `-Dtinykg-sha256` together only to audit an explicit override.
Do not run paid or provider-backed benchmarks without explicit user authorization.

Judge a build by its exit code and `Build Summary`, never by the presence of
`failed command:`. The Zig 0.16 build runner routes every step that wrote to
stderr through the failure printer, so a passing step is tagged ` w` and
followed by `failed command: <cmd> --listen=-` while the build still exits 0
(`master` renames that tag to ` stderr` but keeps the wording). Suites whose
subject logs diagnostics on expected error paths trip this on every run;
`agentcore-abi-contract` does so through its HTTP 529 and connection-drop tests.

## Repository hygiene

- Keep secrets, personal paths, generated evaluation runs, binaries, and local
  TinyKG stores out of Git. The manifest-pinned release assets under
  `vendor/tinykg/bin/` and `vendor/ripgrep/bin/` are the only binary
  exceptions; both are manually reviewed upstream artifacts pinned by SHA-256
  and inventoried by their verify scripts.
- Use `rg`/`rg --files` for discovery and `apply_patch` for source edits.
- Do not overwrite unrelated worktree changes. Destructive Git commands require
  explicit authorization.
- Public API changes must update `doc/API.md`, the normative protocol document,
  SDK fixtures, and an end-to-end consumer test in the same change.
