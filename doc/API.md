# API overview

Metacodes exposes several host shapes over one kernel. The fixed AgentLoop,
Conversation projection, permission/sandbox chain, budgets, formal verdicts,
artifact store, and TinyKG admission are not replaceable extensions.

Sandbox execution has two boundaries: native filesystem/command tools use
confined executors, while external harness workers run as a whole confined
process tree. Linux combines bubblewrap and seccomp; macOS uses Seatbelt.
Deploy the bundled `bin/metacodes-fs-helper` beside an embedded Host or set
`METACODES_SANDBOX_HELPER` to its absolute path. Enabled native file/worker
sandboxes refuse unavailable backends rather than opening/running on the Host.
The Zig `sandbox_exec` namespace exposes platform discovery; no C ABI fields
or wire layouts change. See [sandbox execution](SANDBOX_DESIGN.md) for the
helper contract and the current network-policy limits.

## Compatibility matrix

| Interface | Entry point | Status | Compatibility rule |
|---|---|---|---|
| CLI | `metacodes-<version>-<target-id>/bin/metacodes` (the release unit, `release/LAYOUT.md`; `zig-out/bin/metacodes` in a development tree) | pre-1.0 | flags may evolve with changelog notice; `manifest.json` records version, commit, target, contract numbers and every file's digest |
| Provider control plane | `src/provider/` kernel API | experimental | schema-versioned documents and revisioned mutations |
| Zig source API | `@import("metacodes-core")` | experimental | pin repository commit and Zig toolchain |
| AgentCore C ABI | `metask_agentcore_get_api(1)` | experimental rev 28 | exact root/child layouts and bundle manifest |
| Python package | `import metacodes` ([sdk/python](../sdk/python/README.md)) | experimental, unpublished | speaks exactly the AgentCore ABI revision it was built for and refuses any other |
| Node package | `require('metacodes')` ([sdk/node](../sdk/node/README.md)) | experimental, unpublished; macOS and Linux | same exact-revision rule; the addon is rebuilt per platform |
| Process plugins | strict manifest + stdio protocol | versioned v1 | reject unknown fields and digest drift |
| Plugin inventory | `--dump-plugins`, Zig | versioned v1 | additive observation fields only where specified |
| TinyKG executable distribution | `vendor/tinykg/manifest.json` | bundle v1 | exact target, format, source commit, and SHA-256 pinning |

Use [SessionHost](#sessionhost-a-multi-session-service-for-network-hosts)
behind your own transport, or use the [AgentCore SDK](#agentcore-binary-embedding)
to embed sessions in an application.

## Provider selection surface

### Metask device OAuth and gateway

`metacodes login --provider metask` performs the Metask JSON device flow:

* `POST $METASK_SITE_URL/api/oauth/device/code` (default site
  `https://www.metask-ai.com`) with `client_id=metacodes` and
  `scope=read model:invoke`;
* polling `POST $METASK_SITE_URL/api/oauth/token` with the device grant and
  `client_id` until approval; and
* atomically storing `access_token`, `refresh_token`, `expires_at`,
  `gateway_url`, `models_url`, and `client_name` in
  `$HOME/.metacodes/oauth/metask.json` (or `METACODES_OAUTH_DIR`).

When Metask sign-in replaces a stored session, the CLI stores the new one
before revoking the old one at `$METASK_SITE_URL/api/oauth/revoke` (#560).
Revocation has a 5-second timeout. A refusal or timeout produces a notice
and the sign-in still succeeds. The CLI skips revocation when the session is
stored again or when the old gateway URL has a different origin from
`$METASK_SITE_URL`.

The refresh grant sends only `grant_type=refresh_token` and the stored refresh
token. Metask rotates refresh tokens; persistence happens before the new access
token is used, and an `invalid_grant` is actionable as “log in again”. The
gateway origin comes from `gateway_url` or `METASK_GATEWAY_URL` (an origin, not
`/v1/messages`) and exposes both `/v1/messages` (Anthropic SSE) and
`/v1/chat/completions` (OpenAI SSE). On a pre-stream `401` whose JSON error code
is `token_expired`, the identical serialized request is replayed once. Invalid
tokens, invalid API keys, balance errors, and model-not-found responses are not
refresh-retried.

Every gateway response captures the case-insensitive `X-Metask-Request-Id`.
Completed and failed requests are appended as one NDJSON record to
`$HOME/.metacodes/ledger/metask.ndjson` (or `METACODES_LEDGER_DIR`), with
server-reported usage only, local/server request ids, HTTP status, retry
attempt, outcome, and elapsed time. `metacodes ledger metask` prints the file.
The schema-1 keys are `ts` (unix milliseconds), `session_id`, `provider_id`,
`protocol`, `model`, `local_request_id`, `server_request_id`, `http_status`,
`outcome`, `retry_attempt`, `input_tokens`, `output_tokens`,
`cache_read_tokens`, `cache_creation_tokens`, and `wall_elapsed_ms`; missing
usage on an error or interrupted stream is recorded as zero.

The historical `METASK_API_KEY`/`--api-key` path remains available only as an
explicit compatibility choice. It is never inferred in place of a stored
device-flow gateway; an explicit `--base-url` or `METASK_GATEWAY_URL` can be
used for deliberate legacy/local testing.

Route selection is provider-owned data, not a model-name convention. See
[Provider offers and control plane](PROVIDER_OFFER_ARCHITECTURE.md) for the
normative model; the entry points are:

| Surface | Contract |
|---|---|
| `--provider <id\|alias>` / `METACODES_PROVIDER` | resolve the route through the provider registry instead of inferring a transport from the model name |
| `METACODES_MODEL` | the model, as `--model` gives it (the flag wins) |
| `--preset <name>` / `METACODES_PRESET` | a named setup from `config.json` `presets` (#489; [LOCAL_CONFIG.md](LOCAL_CONFIG.md#presets)), applied as the flags naming its route would: `--model`, `--channel` and `--reasoning-effort` replace one field for that run, `--provider`/`--offer` set it aside, nothing is written back. Below a preset named at start comes the one `directory_presets` remembers for the working directory (its git worktree root, else the directory), then the stored global default. A name `config.json` does not define stops the CLI with exit 2 and lists the presets |
| `<state root>/.env` | the install's local configuration ([LOCAL_CONFIG.md](LOCAL_CONFIG.md)), read once at start and never `setenv`: a layer below the process environment for the names it may set — every registered profile's `env_aliases`, the variables `config.json` names (`providers.<id>.credentials[].env`, `provider_catalogs.<id>.credential_env`), `METACODES_PROVIDER`, `METACODES_MODEL`, `METACODES_PRESET`; a provider's aliases are read from it only when the environment sets none of them. Request addresses (`METACODES_BASE_URL`, `METASK_GATEWAY_URL`, `METASK_SITE_URL`, `METACODES_KEY_CHECK_URL`, `METACODES_KG_URL`, any `*_URL`) are refused; other names are ignored with one warning listing them. Its `METACODES_PRESET`, else its `METACODES_PROVIDER` (else the one provider whose key it holds), applies only when no flag or environment variable names a provider or a preset, the working directory remembers no preset, no `global_selection` is stored and no Metask sign-in exists (`--api-key`, `METASK_API_KEY`, a key or older sign-in in `auth.json`, the Metask session `oauth/metask.json`); keys of several providers and no name choose none, and the run lists them. A `.env` anywhere else, the working directory included, is never read. `metacodes install` writes `<state root>/.env.example` on every install and upgrade and never touches `.env` |
| no usable credential | the headless command exits non-zero before making a model request. It prints the sign-in hint or the named provider's credential help. An incomplete Metask sign-in also exits before making a request. |
| stored default without a credential | a `global_selection` whose provider has no credential (a Metask one: no Metask session, no Metask key and no key in `auth.json`; a stored Metask route the session authenticates runs at the session's gateway, never at the compiled endpoint with the session's token, #527) is passed over for the levels below it, with one notice: `The default model, <provider> · <model>, has no key or sign-in; this session uses <model> · <origin>.` (on stderr) (#485) |
| `metacodes logout` | revokes the Metask session at `$METASK_SITE_URL/api/oauth/revoke` (bounded; a failure is reported and the local sign-out goes on), removes both Metask sign-ins (`auth.json`, `oauth/metask.json` with its refresh token) and a key stored with `login --provider metask`, forgets a stored default that resolves to Metask, and says which it removed; `METASK_API_KEY` left in the shell or `.env` is named, never removed. `logout --provider metask` is the same (#499) |
| `--channel <id>` | narrow to one endpoint/region/plan/account binding |
| `--offer <offer-id>` | pin one exact reproducible route |
| `--base-url <url>` | validated against the selected profile and route policy before any request URL is built |
| `--check-providers` | validate the configuration and print every route it produces, then exit; no credential is resolved and no request URL is built |
| `METACODES_STREAM_IDLE_TIMEOUT_MS` | stream liveness, **head phase**: a request whose connection stays open but delivers no byte before the response head for this long (default 120000; 0 disables liveness monitoring entirely) is shut down by the client's monitor and retried as a transient network error. Nothing in a blocked socket read notices an abort flag; this is what turns a silent gateway or proxy into a bounded failure instead of a frozen session. Progress is measured per SSE line, not per parsed event: a tool call's `input_json_delta` frames and unknown events keep the request alive, but keepalive lines (`event: ping`, `data: {"type":"ping"}`, `:` comments) do not — they prove the gateway connection is up, not that the model is producing (2026-09-23: a gateway pinged every 15 s for 55 minutes over an upstream that produced nothing) |
| `METACODES_STREAM_BODY_IDLE_TIMEOUT_MS` | stream liveness, **body phase** (response head accepted): unset = automatic, `clamp(max_tokens × 100 ms, 600000, 1800000)` — a gateway may generate an entire tool call before writing a byte of it, so the tolerated silence scales with the response the request allows; an explicit value is a flat limit in ms; 0 disables body-phase monitoring. Past the limit the client shuts down the connection and the turn ends with `StreamStalled`. The headless CLI reports an unsuccessful run. A stall, a stream that ended without a stop report, or a dropped connection before any visible output can be retried once. Independently of this limit, once an endpoint has been seen to send keepalives mid-stream (three pings or SSE comments, each ending a silence of at least 2 s), a streamed body with no byte at all, keepalives included, for max(4 × the longest such interval, 2 minutes) is judged a dead connection and reported as `连接已断: <n> ms 内无任何字节,连 keepalive 也没有…`; 0 here disables that rule as well |
| `metacodes login --provider <id> --oauth-token-json <file>` | import an OAuth token into that provider's own store; refresh, single flight, and rotated-refresh persistence then run themselves |
| `metacodes login --provider <id> [--key-page <page>] [--api-key-stdin] [--no-check]` | for a provider that declares key pages and no sign-in it can run — every built-in vendor but Metask: `openai`, `gemini`, `qwen`, `minimax`, `kimi`, `deepseek`, `zai-coding-plan`, `kimi-code`, `bedrock` (OpenAI's OAuth sign-in runs instead once an OAuth client is configured for it, or with `--client-id`): open the key page (the one for the default channel's region; `--key-page` picks another), read the pasted key with echo off (or from stdin, or `--api-key <key>`), check it with a GET the provider does not bill, the key placed where the provider's requests carry it (Gemini's `x-goog-api-key`), and store it in `<state root>/keys/<id>.json` (0600). A 401/403, or what the provider words as a wrong key (Gemini's 400 `API_KEY_INVALID`), refuses it; nothing is stored then. Only that provider's resolution reads the file, after its environment aliases: when one of them is set in the shell or in `.env`, the login says so by the variable's name (`warning: DASHSCOPE_API_KEY is set in your shell and is used before the stored key: …`); `metacodes logout --provider <id>` removes it. `METACODES_KEY_CHECK_URL` (https, or http to a loopback host) replaces the check URL for a local mock |
| `~/.metacodes/config.json` | `schema_version`, `config_revision`, `providers` (with per-provider `credentials` by environment-variable reference), `custom_providers`, `provider_catalogs`, `aliases`, `global_selection`, `presets` and `directory_presets` (#489), `recent_operation_ids`; written atomically, other keys preserved. The same file declares MCP servers under `"mcpServers"` (Claude Code's schema; the legacy `"mcp_servers":[{"name":"<id>","command":[...]}]` array still works), and Claude Code's `~/.claude.json` / `.mcp.json` and Codex's `config.toml` servers are read too — see [Skills and MCP servers](SKILLS_AND_MCP.md). Each connected server's tools register as deferred `mcp__<id>__<tool>` (listed under the prompt's `# Deferred tools`, activated with `ToolSearch select:mcp__<id>__<tool>`), `ListMcpResourcesTool` fails with `capability_unsupported` when nothing is |
| `<session_dir>/runtime-selection.json` | `session_selection`; a session-scoped choice never reaches `config.json` |
| `src/provider/control_plane.zig` | `model.list`, `model.describe`, `selection.validate`, `selection.resolve`, `selection.commit`, `quote.estimate`, replayable event journal |

A committed route is broadcast on the UI event stream as `config_changed` →
`route`, carrying provider, channel, protocol, wire model id, offer id,
credential *reference*, and scope. The model name alone cannot identify a route,
so a name-only broadcast would announce a change an out-of-process client cannot
tell apart from another; the credential reference travels and the secret does
not.

A newer `config.json` `schema_version` is rejected rather than merged. Sessions
that name no provider keep the historical Metask credential and model-inference
path unchanged.

## Edit and rerun

A host can replace a user message and rerun from that position (#432).
Messages are numbered from 1 across the whole history, including compacted
messages. The conversation becomes `1..n-1` followed by the replacement
text. Rewinding drops the original message and all subsequent messages.

- **Persistence.** Dropping messages rewrites the transcript from the live
  conversation at its next flush so a resumed session has the edited history.
- **Refusals** change nothing and run nothing. Each names its reason
  (`conversation.RewindError`): `PositionOutOfRange` (no message `n`),
  `NotUserMessage` (a reply, a tool result, or text the runtime wrote),
  and `PositionCompacted` (the message is behind the compact boundary, so the
  context before it exists only as a summary and cannot be rerun). A message
  at or after the boundary can be edited; the summary stays its preceding
  context, as in every request since the compaction.
- **Context only.** Files written, commands run and other effects of the
  dropped turns stay. Rewinding clears the must-read-first record because
  the rerun's context no longer shows what was read.
- **Hosts.** The Run's `user_message` line carries the text and `"replaces":n`
  ([Wire lines](#wire-lines-for-out-of-process-hosts)). A Zig Host calls
  `AgentSession.rewindToUserMessage(position)` while idle and then runs the
  edited text; `SessionHost` does both for a submission with `.replaces`
  (see [SessionHost](#sessionhost-a-multi-session-service-for-network-hosts)).
  An AgentCore Host calls `session_control->rewind_to_user_message(session,
  position, out_error)` (revision 27, #441) while idle and then runs the
  edited input: the three refusals are the public statuses
  `MESSAGE_POSITION_OUT_OF_RANGE` (31), `NOT_USER_MESSAGE` (32) and
  `MESSAGE_POSITION_COMPACTED` (33), and a checkpoint exported afterwards
  holds the edited Conversation, so a restored Session continues from it
  (see [Edit and rerun](AGENTCORE_BINARY_ABI.md#edit-and-rerun)).

## CLI surface

> Historical interface of the former Metacodes CLI. This fork delivers the
> [AgentCore SDK](../sdk/README.md).

`metacodes --help` enumerates the current flag set and is the authoritative
pre-1.0 surface; `metacodes --version` prints `metacodes <semver>` as its first
line, then the build identity (commit and dirty state, Zig, target and
optimize mode, AgentCore ABI revision, config schema, the ripgrep and TinyKG
versions with the digests the vendored manifests pin for the target, layout).
`metacodes --version --json` prints that identity as one JSON document:
`{name, version, commit, dirty, zig, target, optimize, release_layout,
contract: {binary_abi_version, binary_abi_revision, config_schema_version},
expected_runtime_assets: [{name, version, sha256}]}`, where `sha256` is null
when the vendored bundle has no artifact for the target. `metacodes doctor
[--json | --plain] [--strict]` reports where ripgrep, TinyKG (CLI and daemon) and the two
Lean governance kernels resolve from (`source`: `env`, `config`, `adjacent`,
`path`, `fallback`), the SHA-256 of each resolved file, the digest the file is
held to (the build's pin, or the environment pair's digest for a kernel named by
`METACODES_<FORMAL|PROJECT>_KERNEL_PATH`/`_SHA256`), `match`, and
`provenance`: for the kernels, whether the sidecar beside the kernel is a valid
manifest for *that* kernel (`formal_kernel`: the v4 manifest plus build
receipt; `project_kernel`: the v6 manifest); for `tinykg`/`tinykgd`, whether
the staging receipt beside the binary (`<name>.provenance.json`,
`metacodes.tinykg-binary-receipt/v2`) describes that file (recorded digest,
role, version line, storage contract, and for a bundled binary its bundle key
and source commit), null when there is no receipt; null for ripgrep. A
`provenance` of false fails `--strict`. At a terminal the report is a readable
summary (one line per component, digests shown only on a mismatch, a closing
verdict; colour unless `NO_COLOR`); `--plain`, and any output that is not a
terminal, keep one `key=value` line per check, which scripts parse; `--json` emits
`{checks: [{name, resolved_path, sha256, expected_sha256, match, source,
provenance}]}` with `name` in `ripgrep`, `tinykg`, `formal_kernel`,
`project_kernel`, `tinykgd`, plus a `kg` object when the TinyKG diagnosis could
be built and a `local_config` object for `<state root>/.env`
(`{path, state, accepted, ignored, malformed_lines, permissions}`: the names a
session reads from it and the names it ignores, never a value; `state` one of
`absent`, `read`, `unreadable`, `not_a_file`, `too_large`, `no_state_root`;
`permissions` the POSIX mode as `"0600"`, null on Windows); the plain form adds
a `local_config` line, and neither affects `--strict`. `--strict` exits 1 when a binary is unresolved or mismatched, when a
resolved kernel's `provenance` is not `true`, or when an environment override
was present but resolved nothing (`source: "env"` with a null `resolved_path`);
an unpinned kernel or daemon may be absent. `metacodes terminal-setup --restore
[--terminal <name>] [--keybindings <file>]` undoes key bindings installed by a
previous version. It exits 0 when restoration succeeds or nothing is recorded,
1 on a restore failure, and 2 for a usage error
([TERMINAL_SETUP.md](TERMINAL_SETUP.md)).
`metacodes mcp login <server> [--no-browser]` runs the MCP OAuth flow for a
configured HTTP or SSE server and stores the token that later sessions send and
refresh; `metacodes mcp logout <server>` forgets it and `metacodes mcp list`
prints each configured server's transport and how it authenticates; they exit
0 on success, 1 when the server is unknown, is not a URL server, already sends
a configured `Authorization`, or the login fails, and 2 for a usage error
([SKILLS_AND_MCP.md](SKILLS_AND_MCP.md#authorization-oauth)).
The flag surface is fail-closed: an unknown flag or positional argument exits with code
2 and names the offender — nothing is silently ignored, because evaluation
harnesses pass treatment configuration through this surface. Headless
automation uses `-p/--print` (or `-` for stdin) with `--json`/`--stream-json`
NDJSON output; introspection uses `--dump-prompt` and `--dump-plugins`.
`metacodes update [--check] [--version X.Y.Z] [--release-base <url>] [--pull]
[--allow-downgrade] [--no-sdk] [--ignore-running] [--json]` brings the install
the executable belongs to up to date from the source its install record names
(doc/UPDATE_DESIGN.md).
- **Exit codes:** 0 when it is done or there is nothing to do, 1 when it is
  refused or fails, 2 for a usage error, and 3 with `--check` when an update
  or repair is available.
- **`--json` result:** one document on stdout,
  `{action, source, from, to, prefix, origin, sdk, checked_only,
  stopped_services, running_sessions, notes}`.
  - `action` is `up_to_date`, `newer_installed`, `upgrade`, `downgrade`,
    `repair` or `rebuild`.
  - `source` is `release` or `checkout`.
  - A failure prints `{action: "refused", error}` instead.
Invoking `metacodes` without arguments prints help. A process that suspends
with `--suspendable` writes its session ID and can be continued by a new process
using `--session <id> --resume-response <json>` with the same state directory.
The response may also be supplied as `@file`. Every
NDJSON line is valid UTF-8: string fields go through the repository's JSON
encoder, which replaces bytes that are not valid UTF-8 (binary tool output,
such as a PDF read with `Read`) with U+FFFD while `content_bytes` and
`input_bytes` keep counting the raw payload; a `text`/`thinking` delta cut
inside a multi-byte character is held back and rejoined with the next delta of
the same kind, and a character the block ends without completing is emitted
as one U+FFFD line rather than dropped. The terminal `type:"result"` line
includes `usage_status:"known"|"unknown"`: `unknown` means the successful
provider response supplied no readable usage object (including a usage tail
lost after a reported stop), so its numeric usage and cost fields are
placeholders rather than a claim of free work. Explicit numeric zero usage is
`known`. Flag removals or semantic changes require a changelog entry.

### System-One memory advisor (optional)

A self-hosted Jev System-One judge can advise four memory decisions (scoped
recall injection, `KgRecall` evidence, `KgRemember` relations, enumeration
intent). It is off until a service is named: by the `jev` object of the
install's `<state root>/config.json`, each field overridable by its
`METACODES_JEV_*` variable. The CLI names none, so `metacodes doctor` of a fresh
install reports `jev_advisor off … source=none` and nothing of a session
reaches a Jev server (#474; until then the CLI fell back to the built-in
service, plain HTTP to a public address). A host that sets
`Config.jev_builtin_default` (no host in this repository does) falls back to
that built-in service — `metask-jev-4b` at `http://58.211.6.133:10420` in
`advisory` mode, advising `scoped_recall` only — when neither names a `url`.
To use that service from the CLI, write its settings down once
(doc/JEV_SYSTEM_ONE.md §7 has the object). The default applies as a whole: a
layer that names its own `url` starts from the plain defaults (`shadow`, no
model pin, every surface), while one that only sets `mode`, `timeout_ms` or
`decisions` tunes the default service, or tunes nothing when the host takes no
default. An `off` or empty `url` from any layer
(`"jev": false`, `"jev": {"url": "off"}`, `METACODES_JEV_URL=off`) turns it
off; the build exports `METACODES_JEV_URL=off` to every step it runs. It is
evidence only: it never gates a tool, a permission, a budget, or a TinyKG
write. Design, failure semantics and evaluation: [JEV_SYSTEM_ONE.md](JEV_SYSTEM_ONE.md).

| `jev` field | Override | Contract |
|---|---|---|
| `url` | `METACODES_JEV_URL` | judge origin (`http(s)://host[:port]`); absent everywhere means no advisor (the built-in default only for a host that sets `Config.jev_builtin_default`; the CLI does not); `off` or blank disables the advisor |
| `mode` | `METACODES_JEV_MODE` | `shadow` (when unset: consult and journal, provider-visible bytes unchanged) or `advisory` (the built-in default; judgments change injections and annotate `KgRemember` results) |
| `timeout_ms` (integer) | `METACODES_JEV_TIMEOUT_MS` | per-consultation deadline, default 2500, 100–30000; a miss falls back to the unadvised path with no retry |
| `model` | `METACODES_JEV_MODEL` | expected model id; a response from any other model, or one that reports a priced tariff, is refused |
| `decisions` (array of names, or a comma-separated string) | `METACODES_JEV_DECISIONS` (comma-separated) | subset of `scoped_recall`, `memory_relation`, `enumeration_intent` (default: all, except `scoped_recall` alone for the built-in default); a surface left out behaves exactly as with no advisor, and an unknown or empty list disables the advisor; the retired `recall_evidence` is skipped with a warning, so a list naming only it is empty |

An unknown key in the `jev` object, a value of the wrong type, or an invalid
value disables the advisor with a warning rather than falling back to a
default. `metacodes doctor` reports the effective state, URL and source
(`jev_advisor <off|shadow|advisory|invalid> url=… source=<none|default|file|env|file_and_env> error=…`;
`"jev"` in `--json`); it never affects `--strict`.

Every consultation emits a `system_one_decision` event
(`schema_version: metacodes-system-one-decision-v1`): decision, question set,
mode, outcome, `actuated`, request SHA-256, model, latency, and
judged/positive/changed counts. The scoped-recall decision goes to the
evaluation event stream; the tool-surface decisions (KgRecall, KgRemember,
enumeration) go to the session's tool-observation journal. A user interrupt
during a consultation surfaces as `Aborted`, never as a fallback.

### Model tiers

Subagent and skill model pins accept tier names — `low`, `mid`,
`high` (legacy aliases `haiku`/`sonnet`/`opus` map to the same tiers) — which
resolve against the current provider's tier table in
`~/.metacodes/config.json`:

```json
"model_tiers": {
  "openai": {
    "low":  {"model": "gpt-5.6-mini", "effort": "medium"},
    "high": {"model": "gpt-5.6-sol",  "effort": "xhigh"}
  }
}
```

The table is keyed by provider kind (`anthropic`/`openai`/`gemini`/`bedrock`;
`bedrock` serves every route on the Bedrock Converse wire, whose tier models
are Bedrock model or inference-profile ids such as
`us.anthropic.claude-haiku-4-5-20251001-v1:0`) so one
user-level file serves any `--provider` session without cross-provider model
injection. An unconfigured tier inherits the session model and effort — there
are no built-in per-provider model IDs. A tier's optional `effort` is the
canonical `none|minimal|low|medium|high|xhigh` scale; each model family's
dialect translates it to its own wire format and level count (OpenAI
`reasoning.effort` full scale; GLM `reasoning_effort` pass-through; Kimi
K2.6/K3 three levels; DeepSeek two levels; MiniMax M3 three states
`disabled|adaptive|enabled` with M2.x always-on; Anthropic adaptive thinking
plus `output_config.effort`, whose vocabulary is `low|medium|high|max` — the
canonical top level `xhigh` is sent as `max` on every Anthropic-compatible
route, including GLM behind the Metask gateway). `--reasoning-effort max`
is accepted as an alias for `xhigh`.
Explicit `effort:` in an agent definition wins over the tier's effort. The
built-in `Explore` agent pins the `low` tier.

### Multimodal image input

User messages can carry first-class image content alongside text. Core
represents a conversation block as `Block.image {media_type, data}` (base64
payload, MIME at least `image/png` and `image/jpeg`), ordered freely between
text blocks; the projection to the provider request preserves that order.
Headless runs attach images with `--image <path>` (repeatable, order kept,
png/jpg/jpeg/gif/webp by extension, 3.75 MB raw per image); the prompt text
plus the images become one multimodal user message.

Each provider dialect translates the neutral image block to its native wire
form (`Dialect.serializeImagePart`): Anthropic emits a base64 `image` source
block, OpenAI-compatible endpoints emit an `image_url` data URL content part
(the Responses protocol emits `input_image`), and Gemini emits an
`inline_data` part. Capability is per-model data
(`ModelProfile.supports_image_input` with `ModelProfile.image_input_source`,
queryable as `Capability.image_input` or, with its source, as
`Provider.imageInput`): a model without vision fails a request carrying an
image in user input with `error.ImageInputUnsupported` before any network
I/O — an image in user input is never silently dropped, OCR'd, or replaced
with placeholder text (an image *tool result* that cannot be sent becomes an
explicit placeholder; see below). The truth has three layers, resolved in each
client's `dialectFor` (Anthropic, OpenAI and Gemini alike) through
`Dialect.declareImageInput`: a Host declaration
(`SessionConfig.model_capabilities`, or `SessionHostConfigV1.model_capabilities`
over the AgentCore ABI) outranks the provider's `/v1/models` catalog
(`capabilities.image_input.supported`, parsed into `api/catalog.zig`
`Entry.image_input`), which outranks the model *family* table
(`model_adapter.familyImageInput`, regardless of wire protocol: a `gpt-5.x`,
`gemini-*`, `qwen*-vl`, `glm-4.Nv` or `MiniMax-M3` name is vision on an
Anthropic-compatible route too, issue #112). The family table answers "no"
only for families it knows to be text-only; a name nothing covers is
`image_input_source == .unknown` and fails closed (issue #273: an unknown
route can drop an image without an error, so it is not sent on a guess).
`Provider.supportsForModel` and `Provider.imageInput` answer the same question
for a subagent's `model_override`. Image blocks round-trip through the JSONL
transcript and the AgentCore checkpoint (block tag 5), so restored sessions
resend the original bytes.

Embedders reach the same capability three ways: source-level hosts build
ordered `message.UserContentPart` slices and call `AgentSession.runUserParts`
(or `AdmittedRun.runUserParts`); AgentCore binary consumers submit
`RUN_INPUT_MULTIMODAL` with a `RunInputPartV1` array through
`session_run_input` (capability preflight status 28 — see
[doc/AGENTCORE_BINARY_ABI.md](AGENTCORE_BINARY_ABI.md)); the headless CLI
keeps `--image`.

Tool results can also carry an image: the `Read` tool returns
`{"type":"image","media_type":...,"data":...}` for image files, and every
protocol family now serializes that form natively instead of passing the raw
base64 JSON through as tool-result text. Only the canonical shape counts as
an image (`dialect.extractImageResult`): one JSON object with exactly those
three keys in any order, `type` equal to `image`, a media type from
`types.SUPPORTED_IMAGE_MEDIA_TYPES` (`image/png`, `image/jpeg`, `image/gif`,
`image/webp`), standard base64 of at most `types.MAX_IMAGE_BYTES` of payload,
and only whitespace after the closing brace. Standard JSON whitespace between
tokens does not matter; extra, duplicate or missing keys, JSON escapes (so a
serializer that writes `image\/png` does not produce an image), or more than
`types.MAX_IMAGE_RESULT_BYTES` of raw content do.
Anything else is ordinary text and is bounded by the tool-result projection
like any other result. A canonical image result is exempt from that
projection, from microcompact clearing while it has not yet been delivered
to the provider (delivery is an explicit per-tool_result watermark, persisted in the
transcript, set by the agent loop once the provider has accepted a request
for streaming, i.e. a
stream handle was returned; a request the provider rejects with an HTTP
error does not deliver, a locally appended assistant message is not
delivery, a resumed transcript restores the persisted flags (records written
before this field restore as undelivered until the next accepted request), and a request through a model without image input, which only
carries the placeholder, does not deliver messages holding an image result —
that decision is the serializer's own, carried back on the accepted stream
handle as the tool_use ids whose picture went out as a placeholder
(`StreamHandle.image_placeholder_ids`; `null` = unknown, treated as all
placeholders) rather than re-derived, so it always matches the bytes sent
and a parallel turn's natively-sent siblings are not pinned by one
placeholder (the flag lives on each tool_result block); messages behind the compact boundary and
orphan image results the normalizer strips are delivered regardless, since no
later request can carry them), from `truncateLargeToolResults`, and from the AgentCore
artifact promotion above the operation's cap (`tool_result_cap_bytes` for
built-in and host tools, `mcp_result_cap_bytes` for external tools), so the
picture itself reaches the provider. Two different units apply: context estimation charges one image at
`types.IMAGE_TOKEN_ESTIMATE` (1,600 tokens); the projection turn budget and
the AgentCore payload cap charge it at `IMAGE_RESULT_BUDGET_BYTES` (6,400
budget bytes, four bytes per token). The AgentCore durable budget is charged
the real bytes. Because images bypass the byte budgets, the bytes they put
on the wire are capped separately at `types.MAX_IMAGE_RESULT_BYTES_PER_REQUEST`
(16 MiB, under every wired provider's inline-image request limit): the
projection spills the largest images of the current turn beyond the cap into
artifact envelopes, and before each request the agent loop stubs the oldest
already-delivered image results until the active history fits
(`agent_loop.Options.image_request_bytes_cap`, also applied as the
projection's per-turn image cap). The total counts first-class user images
too (they are never cleared but consume the allowance) and a fresh tool turn
is projected against what the cap leaves after such non-trimmable images.
Only results whose persisted watermark says the picture was received
natively are ever trimmed; when the non-trimmable remainder still exceeds
the cap the agent loop logs it explicitly and lets the provider decide. On Gemini 3, `image/gif`
results travel as a sibling `inline_data` part rather than inside the
multimodal function response, whose `inlineData` accepts only PNG, JPEG and
WebP. A profile whose cap for that operation kind is below 6,400
rejects images of that kind with `checkpoint_payload_resource_limit`. Anthropic keeps the base64 `image`
source block inside the `tool_result` content array (byte-identical to
before). OpenAI chat/completions sends a short pointer as the tool message
(tool message content officially accepts only text) and attaches the image in
an immediately following user message (`image_url` data URL, one text label
per image naming its `tool_call_id`). The OpenAI Responses protocol sends
`function_call_output.output` as an `input_image` content-part array (official
since 2025-09), pairing by `call_id`. Gemini 3 series uses the official
multimodal function response (`functionResponse.parts[].inlineData`,
`ModelProfile.supports_multimodal_function_response`); older Gemini models
receive the image as a sibling `inline_data` part in the same user turn after
all `functionResponse` parts.

The `Read` tool is gated at execution time: the agent loop passes the run's
effective model and `supportsForModel(.image_input, model_override)` into
`ToolContext` (`active_model`, `image_input_supported`), and reading an image
for a model that cannot receive one returns a structured tool error (code
`capability_unsupported`, recoverable) whose detail names the model, the
models on the route whose catalog entry declares image input
(`Provider.visionModels`), and the non-visual alternatives — nothing is read,
encoded, or written to the transcript. When a host does not populate the gate
(`image_input_supported == null`) the image still enters history as before,
and a serializer that finds an image result it cannot send (a model switch
after the read, a fail-closed dialect) emits the short explicit placeholder
`[image (<MIME>) was read successfully but omitted: this model does not
support image input]` — never the multi-megabyte base64 payload and never a
silently wedged session.

Prompt-cache note: a text-only conversation serializes byte-identically to
builds without this feature (OpenAI `content` stays a plain string unless the
message actually contains an image), so existing cache prefixes are
unaffected. Non-image tool results are also byte-identical to before on all
three protocol families.

An image tool result is exempt from the byte-length spilling that
`core/result_projection.zig` applies to oversized results. The per-result cap
is `clamp(window/8, 8 KB, 64 KB)` while the `Read` tool accepts images up to
3.75 MB, so without the carve-out essentially every real screenshot would be
replaced by an artifact envelope before any dialect could serialize it.
Detection reuses `dialect.extractImageResult` (the same single truth the wire
serializers use). Images stay bounded by `Read`'s `MAX_IMAGE_BYTES`, and the
per-turn budget charges one image at `IMAGE_TOKEN_ESTIMATE` rather than its
base64 length, so a screenshot no longer evicts unrelated tool results.

Both caps now come from one place, `core/result_budget.zig`, derived once per
turn from the provider window and handed to `ToolContext.result_budget` as
well as to `result_projection`. A tool that bounds its own output (Bash, whose
two channels share one allowance by max-min fairness) sizes its preview from
that value rather than from a private constant, and spends it in **encoded**
bytes so JSON escaping cannot double the rendered result. When a result is
spilled, its preview is sized from the same budget instead of a fixed 1536
bytes; when the envelope would be larger than the content it replaces, the
result is left inline. The per-turn budget lowers a single water line across
every oversized result rather than evicting the largest one. A result whose
preview was fixed by the streaming capture path is re-rendered against the
budget before commit, and re-inlined outright when the original fits. Text
results therefore no longer project byte-identically to builds before this
change; committed results are still never re-projected for a later request, so
prompt-cache prefixes are unaffected.

"Encoded" is the unit everywhere, including on the two paths that are exempt
from the spill pass and therefore have no second chance: a committed envelope
re-rendered against the budget, and `ReadArtifact`. Both cut their payload by
what it will cost once escaped, and the encoding chosen while budgeting is
carried to whatever renders it rather than being decided a second time.

The Conversation-level pressure valves bound results that entered under a
different budget - a `/resume`d transcript, or a switch to a smaller window.
Their generic head/tail truncation is a text edit, so an artifact envelope is
first offered to `result_projection.shrinkRecoverableEnvelope`, which
re-renders it in place with a smaller preview and every identity field intact.
Anything else structured — a Bash envelope, a non-recoverable fallback, any
tool's large JSON — keeps its shape by trimming only its string values, at any
depth, with every counter that describes a trimmed string corrected as it is
written (`<channel>_truncated`, `preview_head_bytes`, `preview_tail_bytes`, and
`omitted_bytes`, which has to keep satisfying head + tail + omitted ==
original). The short fields are what make a result actionable and are never
what made it oversized.

A structured result that cannot be shrunk — one whose bulk is not in its
strings — is left oversized rather than mangled, and the generic text
truncation is reserved for content that was never structured. Being one request
too large is recoverable; an unparseable result is not. `clearToolResultAt`
already refuses to erase a result's only recovery capability for the same
reason.

Recovery has two primitives rather than one. `ReadArtifact` returns byte
ranges, which costs one round trip per `MAX_READ_BYTES` and cannot answer a
question about the content; `Grep` therefore accepts `artifact_id` in place of
`path` and searches the stored blob directly. The store path is never exposed:
filename output is suppressed, `files_with_matches` — whose entire output would
be that path — is rejected for artifact searches, and the child's stderr is
scrubbed of it before it can reach a tool error.

`ReadArtifact` remains exempt from result projection, but its recovery cost is
bounded per turn. Before the batch executes, the agent loop walks the turn's
tool calls in slot order and charges each `ReadArtifact` call its upper bound,
`result_budget.recoveryReadCost` (`min(MAX_READ_BYTES, per_result_bytes)`).
Every call past `recoveryAllowanceBytes` (`per_turn_bytes / 2`) is deferred: it
does not run, and its result is the bounded body
`{"error":"recovery_allowance_exhausted","artifact_id":<id or null>,"offset":<n>,
"allowance_bytes":<allowance>,"charged_bytes":<charged before this call>,
"hint":<resume from this offset next turn>}` with `is_error` set, plus a
`policy_decision` event whose source is `recovery_allowance`. On a 200K window
four full chunks are served and the fifth is deferred, where nine used to
exceed the turn budget with nothing projection could trim. The decision is made
in slot order at the upper bound before any thread runs, so which call is
deferred never depends on scheduling and provider-visible bytes stay a pure
function of the request.

No staging path is model-visible from Bash at all - not on a completed
channel, not in the auto-backgrounded snapshot, and not on the explicit
`run_in_background` response. All three handed one back for `Read` until they
were replaced by the `job_id` that `BashOutput` already takes. A capture too
large to publish is therefore genuinely unrecoverable, and
`<channel>_storage_error` says which of the reasons it was rather than implying
a handle exists.

Known gap, recorded rather than implied away: `job_id` is itself generated from
random bytes, so it is a random id by the contract's own definition and a
backgrounded command still does not serialize identically across runs. It
cannot simply become a counter, because the same value names the spool file
under a directory shared between processes, where a counter would collide.
Closing it means separating the file identity from the model-visible handle -
tracked with the JobRegistry ownership work, not here. Removing the paths
narrows the exposure to one short opaque token per backgrounded command and
stops leaking the host temp directory; it does not finish the job.

Every budget derived from the context window resolves the model the request
will actually name, not the Provider's own. A subagent shares its parent's
Provider and differs from it only by `model_override`, so sizing a child's
results — or its auto-compact thresholds — against the parent's window is how a
200K parent hands a 32K child a history that endpoint rejects.

### Provider reasoning continuity (DeepSeek, Kimi, MiniMax, Mistral)

Some models want their earlier reasoning back on later requests. DeepSeek's
thinking mode answers HTTP 400 to a tool turn whose assistant history lacks
`reasoning_content`; Kimi asks for the assistant message back unchanged,
reasoning included; MiniMax M3 and later ask for the full response back to keep
the reasoning chain; Mistral asks for the full assistant message back,
ThinkChunks included. Core projects every `Block.thinking` into the request IR
and lets the dialect decide (issues #421, #437):

- A dialect whose profile sets `ModelProfile.echoes_reasoning_content` gets it
  back: DeepSeek, Kimi and MiniMax M3 and later on the OpenAI chat wire,
  OpenRouter routes, and a route declaring DeepSeek on the Anthropic Messages
  wire. OpenAI chat sends the message's thinking text as `reasoning_content` on
  the assistant message (after `content`, before `tool_calls`); Anthropic
  Messages sends the non-empty `thinking` blocks in their original position.
- The Mistral dialect's reasoning models (Small 2603, Medium 3.5, Large 4,
  Magistral; `ModelProfile.content_chunks = .read_and_echo`) get it back as
  ThinkChunks on the OpenAI chat wire: an assistant message with non-empty
  thinking is sent with a list-typed `content` holding
  `{"type":"thinking","thinking":[{"type":"text","text":…}]}` and
  `{"type":"text","text":…}` chunks in their original order, before
  `tool_calls`. The same dialect reads a streamed list-typed `delta.content` the
  same way. A route that declares another dialect for a Mistral-named model
  does neither.
- Every other model is sent exactly the bytes it was sent before: OpenAI
  native and every other compatible dialect (GLM, Qwen, MiniMax M2, and Mistral
  models without documented reasoning), OpenAI Responses, Gemini, and Claude. Claude in particular never receives a
  thinking block: one sent back must carry the signature it was issued with,
  and the IR keeps none.
- The dialect follows the route's declaration
  ([PROVIDER_OFFER_ARCHITECTURE.md](PROVIDER_OFFER_ARCHITECTURE.md)). On the
  Anthropic wire a model name is never inferred as DeepSeek, so a DeepSeek
  Anthropic endpoint configured as a custom provider gets its thinking back only
  when it declares `"dialect": "deepseek"`; the built-in `deepseek` provider
  declares it.

An assistant message holding nothing but thinking (a reply cut off by
`max_tokens` inside its reasoning) is still left out of the request.

### Provider reasoning continuity (OpenAI Responses)

The Responses protocol is used with `store:false`: the server keeps no copy of
the response, so reasoning context survives only if the client sends the
server's own `reasoning` items back on the next request. Core models one as
`Block.reasoning_item {model, json}` — `json` is the item exactly as the
server emitted it (`id`, `summary`, `encrypted_content`), replayed byte for
byte, and `model` is the model that produced it.

This is not `Block.thinking`. A thinking block is readable assistant
reasoning that the UI displays and that only a model asking for its reasoning
back receives (see the previous section); a reasoning item is opaque provider
state that is never displayed, never enters a compaction summary, and never
becomes assistant text. Every dialect other than OpenAI Responses skips it.

Capture is event-independent: the same item may arrive in
`response.output_item.done`, in the terminal `response.completed`'s
`response.output` array, or in both. Both paths extract it and a per-stream
key (the item `id`) keeps it replayed exactly once. On the next request the
items are emitted first among that message's `input` items, matching the
server's own `output` order (reasoning → message/function_call).

Replay is model-scoped: encrypted reasoning state belongs to the model that
produced it, so after a mid-session model switch the stale items are dropped
rather than sent to a model that would reject them. Reasoning items round-trip
through the JSONL transcript and the AgentCore checkpoint (block tag 6), so a
resumed session keeps the continuity. A conversation with no reasoning items
serializes byte-identically to before.

## Zig source embedding

`src/lib.zig` exports the UI-neutral core. In a consumer, these types are reached
through the module namespaces `mc.agent_session.AgentRuntime`,
`mc.agent_session.RuntimeHost`, and `mc.agent_session.AgentSession` (where
`mc = @import("metacodes-core")`). A host supplies a fixed
provider/workspace/policy configuration, creates sessions, consumes typed events/UI
requests, and destroys sessions before their owning runtime generation.

`RuntimeHost.replace` publishes a fully validated immutable generation for new
sessions. Existing sessions remain pinned to their old generation. Failed staging
does not consume a generation or mutate the active runtime.

Runtime creation validates tool availability, not only tool names: built-ins
that execute through an external binary (`Glob`/`Grep` → ripgrep) fail
creation with `error.ToolDependencyUnavailable` when that executable cannot be
resolved, instead of entering the catalog and failing on their first
invocation. A host can probe the dependency up front with
`mc.util_toolchain.ripgrepPath()` and select a tool set without `Glob`/`Grep`
when it is absent.

The recommended high-level lifecycle is:

```zig
const mc = @import("metacodes-core");

const host = try mc.agent_session.RuntimeHost.create(allocator, .{});
defer host.destroy() catch unreachable; // after all Session defers below
const session = try host.createSession(.{
    .provider_kind = .anthropic,
    .api_key = api_key,
    .model = model,
    .workspace = .{ .root = workspace_root },
    .allowed_tools = &.{ "Read", "Write" },
});
defer session.destroy() catch unreachable;
const result = try session.runText(1, "Summarize the workspace", 4, sink);
_ = result.stop_reason;
```

`EventSink` is a synchronous callback value (`.{ .ctx = ..., .emit = ... }`). Keep
its context, the provider credentials, and `workspace_root` alive until the Session
is destroyed. Use `RuntimeHost.replace` for a staged generation change; do not
mutate a live Session's tool catalog directly.

### Session configuration classes

Each setting belongs to the Session that was configured with it, and changes
in one of five ways:

| Class | Settings | How it changes |
|---|---|---|
| Idle-mutable | model, route (provider kind, endpoint, auth scheme, dialect, credential and model together), permission mode, imported permission rules, prompt profile, reasoning effort, additional directories | `setModel`, `setRoute`, `setPermissionMode`, `updatePermissionRules`, `setPromptProfile`, `setReasoningEffort`, `setAdditionalDirectories`. Only while idle (`error.SessionBusy` otherwise). Input is validated before the Session changes; on error the previous value stays in force. The next Run uses the new value; a Session that inherits this one's permissions (`inheritPermissions`, #445) decides its next tool call with the new rules and directories, and refuses its own `updatePermissionRules`/`setAdditionalDirectories` (`error.PermissionsInherited`). |
| Live-replaceable | API key (the provider credential) | `updateCredential`, idle or during a Run, from any thread or from the Session's own callbacks; never `error.SessionBusy`, and refused only for a poisoned Session or an invalid candidate. Create and restore apply the same rule to `SessionConfig.api_key` (1 to 16 KiB of printable ASCII; `error.InvalidCredentialByte`, `error.EmptyCredential`, `error.CredentialTooLong`). The candidate is validated and copied before anything changes; a refusal keeps the previous credential. A request reads the credential when it is sent (once it holds its connection slot), so every request sent after the call returns uses the new credential, retries, tool providers built earlier and requests still waiting for a connection included; one already sent keeps the old one. See [Credential updates](AGENTCORE_BINARY_ABI.md#credential-updates). |
| Runtime generation | built-in tool set, static and process plugins, provider dialects | `RuntimeHost.replace`. Sessions created afterwards use the new generation; existing Sessions stay on theirs. To move a Session, persist it and restore it with `createRestoredSession` on the new generation. |
| Fixed at create | provider kind, OpenAI protocol, auth scheme, base URL, workspace root/home/state root/shell, artifact store, run journal | Create a new Session, restoring the conversation from a checkpoint or transcript. |

Inherited permission decisions hold the lender lock and read a published rule
header stored with that lock. Replacing the lead's own optional rule header
does not change an in-progress decision; publication completes before the
previous rule allocations are freed.
| Identity | Session ID | Never; a restore reuses it. |

`SessionConfig.reasoning_effort` is carried by every provider request and kept
across `setModel`; a provider without an effort control (Gemini) refuses a
non-null value with `error.AgentEffortUnsupportedProvider`.
`WorkspaceConfig.additional_dirs` widens exactly what the workspace root grants:
`accept_edits` auto-approval of Write/Edit/NotebookEdit and sandboxed shell
writes. It is not named in the system prompt. These two are source-level only;
AgentCore revision 28 does not carry them.

### Permission modes the settings disable

`disableBypassPermissionsMode` and `disableAutoMode`, in any settings layer,
constrain permission modes at startup and during mode changes.

- **Mode switches are refused.** A session that starts in such a mode is
  downgraded to `default` when the settings load.
  `AgentSession.setPermissionMode` returns `error.PermissionModeDisabled` and
  AgentCore `update_permission_mode` returns `INVALID_ARGUMENT` (diagnostic
  `PermissionModeDisabled`); the mode, policy generation and grants stay as
  they were.
- **Spawns do not apply it.** An AgentDef's `permissionMode` (a Task
  subagent, a background job, an in-process teammate) and a forked Skill
  bound to that agent with `agent:` run as `default` instead, and log one
  warning. The Task result carries `"permission_mode_notice": "permissionMode
  bypassPermissions is disabled by settings; the subagent runs as default"`,
  the forked Skill's result opens with the same sentence in brackets, and
  `/agents` marks the mode `(disabled by settings; runs as default)`.
- **Decisions never run under it.** Whatever puts such a mode on a permission
  context, each decision is the one `default` makes
  (`permission/decision.zig` `effectiveMode`), including the ApplyPatch path
  gate and the AgentCore fallback for external Tools.

An `AgentSession`'s settings are only the Host-imported rule layer
(`permission_rules`, `updatePermissionRules`: allow/ask/deny), which has no
way to disable a mode, so the refusal above cannot trigger for a Session today:
the Host owns which modes it offers its users and must not pass one it
forbids. The check is in place for a Session that does carry such settings.

### Wire lines for out-of-process Hosts

A Host that carries a Session over SSE, a WebSocket or a queue serializes
events and UI requests with `mc.protocol.wire` rather than `std.json` over the
kernel structs, so a field renamed inside the kernel shows up as a contract
change instead of silently reaching every client. Each line is one JSON object
with the schema version `v` (currently 1) and a `type`:

```text
{"v":1,"type":"<CoreEvent tag>","data":<payload or null>}
{"v":1,"type":"<CoreEvent tag>","run_id":N,"trace_id":"...","data":...}
{"v":1,"type":"<HostEvent tag>","data":{...}}
{"v":1,"type":"ui_request","id":N,"kind":"permission|ask_question|custom","request":{...}}
{"v":1,"type":"ui_request_closed","id":N,"outcome":"answered|cancelled|malformed"}
{"v":1,"type":"ui_request_unavailable","kind":"...","custom_kind":"...","reason":"..."}
{"v":1,"type":"capabilities_accepted",...}
```

Host events (`user_message`, `run_done`, `command_result`,
`message_rejected`, `session_poisoned`) are what a Host adds around the
kernel's events ([WIRE_PROTOCOL.md](WIRE_PROTOCOL.md#11-host-events)). Runs
are numbered 1, 2, … per Session. A Run's lines run from its `user_message`
to its `run_done`, and every kernel event in between carries its `run_id`
([Runs](WIRE_PROTOCOL.md#12-runs)).

The normative contract, including which changes keep v1 and which bump
`SCHEMA_VERSION`, is [WIRE_PROTOCOL.md](WIRE_PROTOCOL.md).

A frontend may open its channel with a **capability frame** naming the UI
requests it renders (`wire.parseCapabilities`, `wire.acceptCapabilities`):

```json
{"v":1,"type":"capabilities","ui_requests":["permission","ask_question"],"custom":["video_timeline@1"],"events":["text_chunk"]}
```

Custom kinds carry their version (`<name>@<major>`) and match exactly. Once a
frame is installed, a request it leaves out is not announced: the Host
journals `ui_request_unavailable` (reason `kind_not_declared`,
`custom_kind_not_declared` or `custom_kind_unversioned`) and the tool gets
`RequestOutcome.unrenderable` at once: it fails as without a UI
(`AskUserQuestion` fails with `FrontendCannotRender`, `requestUiCustom`
returns `CustomUiUnsupported`, a permission prompt is denied with no terminal
fallback), and the tool result tells the model the frontend cannot render the
request rather than that the user refused it. A Zig Host that switches over
`RequestOutcome` handles the fourth value. A frame of another version, or a malformed one,
is answered `{"v":1,"type":"capabilities_refused","reason":"<RefusalError>"}`
and changes nothing. A frontend that never declares receives every request,
as before; in-process backends (headless and the C ABI) never declare.
`frontend_capabilities.route` is the routing rule and `Slot` the per-Session
holder a Host keeps.

`wire.parseResponse` turns the client's answer (`{"choice":...}`,
`{"answers":[...]}` or `{"result":...}`) back into a `UiResponse`; anything
malformed or of another version fails as a cancellation, never as a
grant, and closes as `malformed` (`wire.closedOnParseError`). An answer that
races an interrupt or close loses: it is refused or discarded and the request
closes as `cancelled`. A request nobody answered fails through
`wire.cancelResponse(request, why)`: a permission prompt with the
`ui_request.Unanswered` error naming the timeout, cancellation or unreadable
answer, so the model reads that nobody answered instead of that the user
declined; a question or a custom UI with `InputAborted`
([WIRE_PROTOCOL.md](WIRE_PROTOCOL.md#14-requests-nobody-answered)). `tests/fixtures/wire/v1` pins one line for every event tag and request
kind, plus capability frames with core's reply to each, and doubles as
conformance vectors for Hosts in other languages.

### SessionHost: a multi-session service for network Hosts

`mc.session_host.SessionHost` is what a Host puts behind its own transport
when Sessions are opened and closed by id at runtime (one container serving
many users, a GUI with many tabs). It composes the pieces above instead of
leaving every Host to rebuild them:

- `open(.{ .config, .id, .mode = .fresh | .resume })` creates a Session, or
  restores one from its transcript (`transcript.sessionDir` under the
  Session's state root). A fresh open under an id that has a transcript
  replaces that transcript at once. `open` and `acquire` return a counted
  reference; `release` gives it back.
- `HostedSession.submit(.{ .text, .trace_id, .replaces, .model, .permission_mode })` queues a Run.
  With `.replaces` (a `conversation.MessagePosition`, from
  `MessagePosition.fromOrdinal(n)`), the text replaces user message `n`: just
  before the Run the driver drops that message and everything after it
  (`AgentSession.rewindToUserMessage`), so the Run sees messages `1..n-1`
  plus the text, and the transcript and a later `open(.resume)` hold that
  history ([Edit and rerun](#edit-and-rerun)). The `user_message` line
  carries `"replaces":n`; a refused position ends the Run with `run_done`
  naming it (`PositionOutOfRange`, `NotUserMessage`, `PositionCompacted`)
  and changes nothing.
- A submission may be typed (#447): `source` (where it came from, such as
  `im:lark`), `kind` (`[a-z0-9][a-z0-9_.-]*`, such as `telemetry`),
  `attributes` (name/value strings) and `idempotency_key`. A field outside
  its bounds (`core/typed_submission.zig`) is refused before anything is
  queued: `error.InvalidSource`, `InvalidKind`, `InvalidAttributes`,
  `InvalidIdempotencyKey`. The four are echoed on the Run's `user_message`
  ([WIRE_PROTOCOL.md](WIRE_PROTOCOL.md#11-host-events)) and reach the
  provider only through the Session's template, `open(.{ ...,
  .submission_template })`: `{{text}}`, `{{source}}`, `{{kind}}` and
  `{{attributes}}` (one JSON object) are substituted, and any other `{{` is
  `error.InvalidSubmissionTemplate`. Without a template the Run's input is
  the text, byte for byte, so the provider-visible bytes, a cache contract,
  are those of an untyped submission.
- One idempotency key is one Run. A delivery whose key is queued, running,
  or whose Run started less than `idempotency_retention_ms` ago (24 h) is
  refused with `error.DuplicateSubmission`: nothing is queued, and the first
  delivery's Run answers for it, so a transport reports it as accepted (an
  HTTP Host: `200` and `"duplicate":true`). The same key on a different
  submission (text, source, kind, attributes or `replaces`) is
  `error.IdempotencyKeyReused`. With `transcripts`, started keys are kept in
  the session directory (`idempotency.jsonl`), so a Host that opens the
  Session again under its id after a restart, resumed or fresh, refuses them
  too. A key is spent when its Run starts, whatever the Run then does, and
  not before: a delivery still queued when the Host stopped may be delivered
  again. A key that cannot be recorded fails its Run
  (`IdempotencyKeyNotRecorded`) and stays unspent. At most
  `idempotency_max_keys` (10 000) started keys are kept; the oldest goes
  first.
- A submission may carry its own `model` and `permission_mode` (#445).
  The driver applies them just before the Run, as `set_model` then
  `set_permission_mode` queued right ahead of it would. It journals each as
  `config_changed` before the Run's `user_message`, also when already in force.
  They stay the
  Session's settings afterwards. The mode is checked first
  (`AgentSession.setPermissionMode`'s check), so when either is refused
  (a mode the settings disable, or a model `Options.models` or the
  Session refuses) nothing is applied, the text stays out of the
  conversation, no Run starts, and `message_rejected` takes the place of
  `user_message`, with the reason in its `message` (such as
  `bypassPermissions is disabled by settings` or `model not available for
  current provider`). Its idempotency key
  is not spent; `model` and `permission_mode` are not part of what a key
  compares.
- With `Options.models` (a `ModelPolicy`), a model name in a submission
  or a `set_model` command is trimmed (`api/model_availability.zig`). A tier
  name (`low`/`mid`/`high`, or `haiku`/`sonnet`/`opus`) becomes the model `tiers`
  `model_tiers.TierTable`) sets for the Session's provider kind, and the
  result must be one that provider takes: listed for it in `catalog`
  (`CatalogModel{ provider, id }`, borrowed), or with an id that names it
  (`claude-`, `gpt`/`o1`/`o3`, `gemini`). Anything else, an unset tier
  included, is `error.ModelUnavailable` (`set_model`'s `error_name`) and
  changes nothing. A tier's reasoning effort is not applied. Without
  `Options.models` the name goes to the Session as it is.
- `SessionHost.setModelCatalog(catalog)` replaces `Options.models`'
  `catalog` while the Host runs (#445). The Host copies `catalog`; from the call on, every
  Session's next `Submission.model` or `set_model` is checked against it
  and no longer against the catalog before (replaced, not merged). The
  model a Session is on stays in force, also when the new catalog no
  longer lists it. Without `Options.models` it is
  `error.ModelPolicyUnset` and nothing is kept.
- The queue holds `max_queued` (64) submissions and commands. Beyond it
  `submit` and `command` refuse with `error.QueueFull` and hold nothing (an
  HTTP Host: `429`); a duplicate is answered as one before the bound is
  checked. `snapshot()` reports `queued` and `max_queued`. Runs the
  driver starts by itself, a cron job's prompt or a team lead's inbox,
  count against the same bound and never take `queued` past it (#493).
- `HostedSession.submit` and `command` (`set_model`, `set_permission_mode`,
  `set_reasoning_effort`, `set_additional_directories`, `set_prompt_profile`,
  `update_permission_rules`, `compact`, `cancel_cron_job`,
  `cancel_all_cron_jobs`, `set_route`) share one FIFO run by the Session's
  driver thread, so configuration changes apply between Runs in the order
  they were queued. Each command is answered by `command_result`. An accepted
  `set_model`, `set_permission_mode` or `set_reasoning_effort` is first journaled
  as `config_changed`
  (`{"model":...}` as resolved, `{"mode":...}`, `{"reasoning":...}`, `null`
  when the effort was cleared), also when the value was already in force,
  and `set_additional_directories` journals `{"dirs":...}` for each
  directory in force afterwards that was not before, as its resolved path
  (a directory taken away has no line). A refused command journals none.
  The permission mode is journaled by a config sink on the Session's
  permission context, so a mode set any other way is journaled too.
- `command(.{ .set_route = route })` (issue #16, #445) moves the Session
  onto a route the Host's provider control plane bound. `Route.binding` is
  what the Session sends with (`AgentSession.Route`: provider kind, OpenAI
  protocol, auth scheme, dialect, credential, model, base URL); the rest
  says who the route is (`provider_id`, `channel_id`, `protocol`,
  `offer_id`, `credential_ref`, `scope`). `AgentSession.setRoute` swaps
  them together while idle, so no request goes out on a mix of the two
  routes, and keeps the conversation and the reasoning effort; an effort
  the new provider cannot take is `error.AgentEffortUnsupportedProvider`,
  never dropped. An accepted route is journaled as `config_changed`
  `{"model":...}` (the route's model) and then `{"route":{...}}`, as the
  CLI does, before its `command_result`; the credential is in neither. A
  refused route (an invalid model or credential, a busy or poisoned
  Session) changes nothing and journals no `config_changed`. Later
  `set_model` names resolve for the new provider kind, and a teammate the
  Session spawns afterwards runs on its route (`TeammateSpawn.lead_route`,
  which `InheritLead` applies).
- Every kernel event, host event (`user_message`, `run_done`,
  `command_result`, `message_rejected`, `session_poisoned`, `run_resumed`)
  and UI request lands in the Session's `journal` as a wire line;
  CoreEvents carry `run_id` and the submission's `trace_id`. `respond(id, json)` answers a UI request, and
  may name who answered (`"by"`); anything but an open request is
  `error.NoSuchRequest`, a second answer to one that has not yet applied its
  first is `error.AlreadyAnswered`, and neither changes anything (see UI
  requests below).
- `declareCapabilities(allocator, frame)` installs the client's capability
  frame ([WIRE_PROTOCOL.md](WIRE_PROTOCOL.md#2-capability-exchange)) and
  returns, and journals, its `capabilities_accepted` line; a refused frame
  is a `wire.DeclareError` and changes nothing. A UI request the declaration
  leaves out is journaled as `ui_request_unavailable` and answered
  `unavailable` without waiting.
- `interrupt` aborts the Run (or the one being admitted) and answers a
  pending UI request as cancelled; a suspended Run's request is cancelled
  too, and the Run resumes only to record that. A Session the kernel poisoned reports
  `session_poisoned`, drops its queue and refuses further work; close and
  reopen it.
- `close` stops the driver, closes the journal (waking readers), waits only
  for an in-flight `interrupt` to leave the kernel and destroys the Session,
  so the id can be opened again as soon as it returns. It never waits for
  references: a holder keeps a closed `HostedSession` readable (journal,
  `snapshot`) until its own `release`, which frees it last.
- A team lead (`SessionConfig.team` with `.role = .lead`, once its team
  exists) is fed its inbox: while its queue is empty the driver reads it at
  most every `session_host.lead_inbox_poll_ms` (500 ms) with
  `swarm_tools.pollLeadInbox`, and a member's reply becomes the lead's next
  Run, queued behind any work already there and journaled like a submission
  without a `trace_id`. The bundled daemon does the same for its `App` lead.
- A Session that selected the cron tools (`CronCreate`, `CronDelete`,
  `CronList`; admitted only with `RuntimeConfig.enable_cron`) has its
  scheduled prompts fired by its driver, as the CLI fires them once it is
  back at the prompt: while its queue is empty and it has cron jobs, the
  driver calls `AgentSession.takeDueCronPrompts` at most every
  `session_host.cron_poll_ms` (1000 ms), and each prompt due becomes a Run
  typed `source = session_host.cron_source` (`session_host`) and
  `kind = session_host.cron_kind` (`cron_fired`), in the order the jobs were
  created. The Run's user message is the prompt byte for byte; the typing
  reaches the provider only through a submission template. A job never fires
  during a Run or ahead of queued work, and its jobs close with the Session
  (they are not persisted, as in the CLI).
- A Host sees and stops a Session's cron jobs without a Run (#493).
  `snapshot().cron_jobs` lists them oldest first, each a
  `session_host.CronJob`: `id` (a `CronJobId`, the 12 hex digits
  `CronCreate` gave the model), `next_fire_unix` (unix seconds) and
  `schedule`, `.once` or `.recurring` with its cron expression; the prompt
  stays with the model. The list is as of the last time the Session was
  between Runs: a job a Run creates or deletes shows from its `run_done` on,
  and a one-shot job is gone once it fired. `command(.{ .cancel_cron_job =
  id })` removes one job and `command(.cancel_all_cron_jobs)` all of them, in
  queue order like any command; neither job fires again, and a prompt
  already fired and queued still runs. Each is answered by `command_result`
  (`cancel_cron_job`, `cancel_all_cron_jobs`), by which time `snapshot()`
  shows the change; an id the Session does not have is `ok: false`,
  `error_name: "CronJobNotFound"`. `CronJobId.parse(text)` takes a Host's
  text and refuses anything but 12 lowercase hex digits
  (`error.InvalidCronJobId`).
- Fired prompts count against `max_queued` (#493): the driver takes only
  as many due prompts as the queue has room for, oldest job first, and a
  job left out stays due, untouched, and fires once the queue has room. So
  `queued` never passes `max_queued` and no prompt is lost; a recurring job
  is rescheduled, and a one-shot job removed, only when its prompt is
  taken. `AgentSession.takeDueCronPrompts(allocator, limit)` takes that
  limit; `cronJobs`, `cancelCronJob` and `cancelAllCronJobs` are the idle-only
  reads and changes the SessionHost makes. A team lead's inbox is read only
  while the queue has room.
- A Session whose `SessionConfig.run_control` asks for it opens, for every
  Run, the per-Run control the bundled daemon opens
  (`project_rule_activation.RunControl`, #445). It needs a durable
  `run_journal`: anything but the default on an ephemeral Session is refused
  by `open` (`error.RunControlRequiresRunJournal`). With
  `project_rules = .enforced`, an active bundle in
  `<dirname(run journal root)>/project-rules` for the workspace root is
  re-attested before the provider request and decides each tool call through
  the project kernel: a call it blocks reaches the model as a
  `project_rule_blocked` tool error. A missing or invalid kernel
  configuration, a bundle that fails attestation, or a Bash job of the
  Session still running or a team it leads (`ProjectRulesRequireDetachedWorkersIdle`)
  fails the Run before any provider request: `run_done` names the error and
  the Run is closed in the journal. Unlike other failed Runs, such a refusal
  does not poison the Session. The submission's text stays out of the
  Conversation and the Session is idle again. A refused resumption of a
  suspended Run (`ui_request_wait = .suspend`) keeps the suspension: after
  `ui_request_closed` and `run_resumed`, `run_done` names the error, the
  request's `ui_request` line is journaled again under the same id, the
  Session is `suspended` with that `pending_request_id`, and the request is
  recorded open, so the answer the refused Run took is dropped and a later
  `respond` (also after a restart) resumes the turn. A journal that cannot
  open still poisons. After a Run the bundle is re-attested and the Run's
  operational observation is published beside the journal.
  `abandoned_run = .record_abandoned` closes a Run whose process died as
  abandoned and runs the next one. The default,
  `fail_closed`, keeps the Session closed (`UnfinishedRun`).
- With `Options.teammates` (a `TeammateFactory`), the SessionHost also
  fulfils the lead's `SpawnTeammate` requests. After each Run the lead's
  driver takes the pending requests
  oldest first, calls `configure(ctx, arena, spawn)` for the member's
  `SessionConfig` (provider, workspace, tools and permissions are the
  Host's; `spawn` names the lead, team, member, prompt, `agent_type` and
  `effort`), opens it on the same SessionHost as a member of the lead's team
  under the lead's session id and a fresh lease, and submits the prompt as
  its first Run. The factory returns `team = null` (the SessionHost owns the
  identity; anything else is refused). `spawn` also carries the lead's
  current `lead_model`, `lead_permission_mode` and `lead_reasoning_effort`.
  A refused or failed spawn becomes the lead's next Run, so its model learns
  of it: `<teammate-status from="<name>" state="failed">teammate was not
  started: <error></teammate-status>`, journaled as a typed `user_message`
  (`source` `session_host`, `kind` `teammate_spawn_failed`;
  `session_host.spawn_failure_source`/`spawn_failure_kind`). When the name
  was already open and its member refused the prompt, the text says
  `teammate did not take the prompt: <error>` instead. A failure while
  fulfilling such a report Run's own spawns is only logged, so a model that
  keeps asking for a name that cannot start gets one report, not a Run per
  retry (under the `App` the failure is a tool result, bounded by the turn
  limit). A name the lead
  already opened, still open, takes the prompt as its next Run; one whose
  member the Host closed is opened again under a fresh lease, after its old
  roster entry is dropped. Closing the lead closes the members it opened.
  Without a factory the requests stay pending for the Host to fulfil itself
  (open a `.role = .member` Session).
- `session_host.InheritLead{ .base = config }.factory()` is the factory that
  configures each member like its lead, as the bundled daemon's `App`
  teammates are: `base` (the configuration the Host opens its leads with;
  borrowed, outlives the SessionHost) with the lead's current model and
  permission mode, and the spawn's `effort` or else the lead's reasoning
  effort. `InheritLead.derive(base, spawn)` is the same mapping as a pure
  function. `agent_type` is not interpreted. Its factory declares
  `TeammatePermissions.lead`, below.
- `TeammateFactory.permissions` (`TeammatePermissions`, default `.own`) says
  whose permission state a member decides its tool calls with. `.own`: what
  `configure` returned, fixed when the member opened. `.lead`: its lead's
  imported rules, additional directories and Session memory, read at each
  tool call (`AgentSession.inheritPermissions`), as the bundled daemon's
  in-process teammates borrow their lead's permission context: a rule the
  lead gains through `update_permission_rules` or an "allow always"/"deny"
  answer, and a directory it gains through `set_additional_directories`,
  decide the member's next tool call, also inside a Run already going. Both
  Sessions remember answers in the lead's memory. The member's own
  `update_permission_rules` and `set_additional_directories` are refused
  (`command_result{ok:false, error_name:"PermissionsInherited"}`); its
  permission mode, tools, workspace root and the sandbox its shell runs in
  stay what `configure` returned. Locking: each member decision holds the
  lead's `lent_permissions` lock for the whole decision (never across a
  prompt); the lead replaces its rules or directories under that lock and
  frees the old ones after it. The lead's AgentSession outlives its
  members': the lead closes them before destroying its own, and its
  `destroy` waits for any member still being destroyed (permission/lent.zig).

Options: `max_queued`, `max_turns`, `teammates`, `transcripts`,
`ui_request_timeout_ms`, `ui_request_expiry`, `ui_request_wait`,
`idempotency_retention_ms`, `idempotency_max_keys`, `models`.
Authentication, tenancy and the transport stay with the Host.
To stream a Session's journal over SSE, parse the client's position with
`event_journal.Cursor.fromLastEventId` / `fromSince`, start from
`EventJournal.planResume(cursor)` (send `resync` when it reports a restart),
and label lines with `EventJournal.eventId`.

UI requests on a long-lived Session (#446; the wire side is
[WIRE_PROTOCOL.md §1.5](WIRE_PROTOCOL.md#15-ui-requests-approvers-expiry-suspended-runs)):

- **Approver.** An answer may carry `"by":"<approver>"`, 1 to 256 bytes; the
  request's `ui_request_closed` records it. `respond` refuses any other `by`
  with `error.InvalidApprover` and leaves the request open. `by` is
  self-reported, not authenticated: a Host that needs a verified approver
  sets it from its own authentication (or records the verified identity
  apart), never from the client's answer body.
- **Expiry.** `ui_request_timeout_ms` (null: no limit) and
  `ui_request_expiry`: `.cancel` (default, as before) closes the request
  `cancelled` and the Run goes on without the answer; `.interrupt` does
  that and stops the Run; `.re_announce` journals the same `ui_request` line
  again every period until someone answers. Under `.cancel` and
  `.interrupt` alike, an expired permission prompt is denied and the model
  reads that nobody answered in time, and an expired question or custom UI
  fails with `InputAborted`
  ([WIRE_PROTOCOL.md §1.4](WIRE_PROTOCOL.md#14-requests-nobody-answered)).
  `.re_announce` needs a period: with a zero `ui_request_timeout_ms`, `open`
  is `error.InvalidUiRequestTimeout`.
- **Waiting work.** A Session runs one thing at a time: a submission or
  command queued while a request is open waits behind it, never refused for
  it. `snapshot()` says why in `queue_waiting` (`.none`, `.run`,
  `.ui_request` with `pending_request_id`). A Host that wants the work to run
  at once opens another Session.
- **Suspend mode.** `ui_request_wait = .suspend` (default `.block`; needs
  `transcripts`, else `open` is `error.SuspendRequiresTranscripts`): a
  question or custom UI request ends its Run `suspended` (`Phase.suspended`)
  instead of holding the driver. The Session's directory keeps it
  (`ui_requests.json`, written whole and fsynced, with a result for every
  other call of the suspended turn; the kernel's `suspend.json` is not
  used); `close` leaves it
  there; `open(.resume)` under the id, after a restart too, announces it
  again under the same id; `respond` then resumes the Run once through
  `AdmittedRun.resumeWithResults`, journaled as `ui_request_closed` and
  `run_resumed`. Exactly once, with the transcript as the witness: the
  settlement is recorded before it enters the conversation and dropped once
  the resumed Run's transcript holds the call's result; a crash in between
  applies it on the next open, and an open that finds the result already
  there only drops the record. A call of the suspended turn that the kernel
  did not run (it denied or deferred it) is answered on resume with a result
  saying it did not run. Nothing else runs while a Run is suspended: queued work
  waits, and a team lead does not read its inbox, so a teammate's reply
  waits there, unread, and becomes the lead's next Run after the resumed Run
  and the queue. The resumed Run keeps the suspended Run's `trace_id`, turn
  limit and `stream_retry_budget`. A question's answers reach the model as
  AskUserQuestion's result; a custom UI's `result` is the tool's result as
  is (the kernel's suspension convention); a cancelled or expired request is
  the call failing with `InputAborted`. Request ids are kept too, so none is
  reused across restarts. Each open request has its own id, and `respond`
  gives an answer only to the request it names: a permission request that
  blocks beside a suspended question is answered under its own id
  (`pending_request_id` shows it while it blocks). A `ui_requests.json` this
  version cannot read (corrupt, or written by a later version; a field it
  does not know is ignored) is left as it is and never written over:
  requests then block as under `.block`, under ids past the file's
  `next_id` and past the clock in milliseconds. A Run submitted under an
  idempotency key keeps the key spent while it is suspended, however long
  the request waits; once the resumed Run ends, the key's
  `idempotency_retention_ms` counts from the Run's start as before, so a
  Host whose requests may wait long sets the retention above the longest
  wait plus its redelivery window. One crash window is left: a crash after
  the suspended turn reaches the transcript and before `ui_requests.json`
  records its request loses the request; the next Run finds the call without
  a result and closes it as any unanswered call is closed (message_repair),
  so the conversation stays valid but the question is not asked again. A
  fresh `open` under the id drops a suspended Run with the conversation it
  belonged to. **A permission request is never
  suspended:** the kernel's permission gate reads a `pending` answer as no
  answer and denies the tool unasked, so under `.suspend` a permission
  request blocks as under `.block` (the Session reports `.running` with the
  request pending) and is cancelled by `close`. Making permission requests
  survive a restart needs the kernel to suspend at its permission gate and
  run the approved call on resume; that is follow-up work.

Static trusted plugins can contribute typed tools, streaming tools, services,
advisory policies, and deterministic provider dialects. Process plugins can only
contribute isolated tools through the versioned wire protocol. Neither receives a
mutable AgentLoop, permission, formal, or TinyKG handle.

See [LIB_API.md](LIB_API.md) for the dependency/build wiring and
`example/main.zig` for a complete consumer fixture.

## AgentCore binary embedding

The source-free bundle is one coordinate root: `sdk/metask/agentcore.h`
(C11/C++17), the `sdk/zig` and `sdk/rust` bindings, one target-specific static
library, the manifest-pinned ripgrep runtime asset, and a manifest whose file
allow-list and SHA-256 values are mandatory. Consumers call only
`metask_agentcore_get_api(METASK_AGENTCORE_ABI_V1)` and must validate ABI revision 28,
the exact 80-byte root, all seven mandatory typed tables, reserved zeros, function
slots, and the schema-1 bundle manifest. The ABI is experimental, with no
compatibility shim between revisions: pin a bundle, not only a semantic version.
What the seven tables cover, provider protocol selection, the `on_event`
observation stream and its visible-output tags, input submitted to an active
Run (`session->submit_input`, the `input_adopted` event and the `RunResultV1`
input counts), automatic compaction inside a Run (the model window, a
provider's context-window refusal and checkpoint capacity each compact the
Conversation at a safe boundary and the same Run continues; the summary
request is budgeted and the replacement commits only if the checkpoint fits —
the `auto_compact` event and its `cause`), the structured reason a Run stopped
with `STOP_API_ERROR` (the `model_error` event), each request's own re-issue
after a stream that broke off without an answer and before any tool call
started (#461), and the Host-granted stream retry budget beyond it
(`RunOptionsV1.stream_retry_budget`: a Run re-issues such a request further
times, after output and a started tool call too); for every re-issue of an
attempt that showed output the Host takes back what it showed through the
`discarded` segment, `thinking_discarded` and `retry_notice`, which precedes a
short cancellable backoff, the in-place credential update (`session->update_credential`),
edit-and-rerun (`session_control->rewind_to_user_message` and its three refusal statuses), the Session goal (the `goal` table, goal-continuation Runs, the
`goal_updated` event), the host-scheduled team (`enable_teams`, the `team`
config, and the `team` table's `describe` and `poll`), the Workspace Skill
catalog and its source priorities (`SkillSourceV1.priority` and the query's
`default_user_source_priority` / `default_workspace_source_priority`, which
pick one winner among same-scope sources defining one Skill name), process plugins, Host streaming tools, journal profiles,
and the Completion boundary are specified once in
[AGENTCORE_BINARY_ABI.md](AGENTCORE_BINARY_ABI.md) and not repeated here.

## Tool result contract

All tool origins converge on the same typed result:

```zig
const ToolResultBody = union(enum) {
    @"inline": InlineResult,
    artifact: ArtifactReceipt,
    structured_error: StructuredToolError,
};
```

Unknown or large producers should begin a kernel-owned capture before byte zero.
The capture computes SHA-256, bounded previews, quotas, and CAS publication while
streaming. Conversation receives deterministic inline bytes or an artifact
envelope; `ReadArtifact` restores bounded slices. UI and post-tool observation can
consume the original result without changing model-visible projection.

Results above `per_result_bytes` are sealed during execution and published at the
batch commit boundary. The sealed receipt renders a byte-identical artifact envelope;
publication failure uses `retainInlineAfterFailedPublish`, falling back to inline bytes
when allowed or a bounded `ArtifactPublishFailed` tool error otherwise. Other producers
that still publish during execution are tracked in #65.

Text returned by a tool is UTF-8 encoded at the text boundary and every bounded
text page ends on a code-point boundary. Raw process or document bytes remain
artifacts (or explicit base64 envelopes) and are never written as JSON text.
`TaskOutput` keeps source byte cursors: `output_next_offset` is the cursor for
the next request, `output_size_bytes` is the current source size, and the legacy
`output_total_bytes` field has the cursor value for compatibility. A cursor is
not a JSON or base64 length.

## Prompt-cache contract

For equivalent effective configuration, one provider request must be a byte prefix
of the next request until deliberate compaction. These are never model-visible:

- plugin generation/id/path and activation bookkeeping;
- operation journals, telemetry, TinyKG receipts, timestamps, and random ids;
- staging paths for artifacts or external binaries.

A real tool schema, system instruction, dialect output, conversation append, or
compaction may change the cache key. Tests compare serialized provider requests,
not internal object identity.

Selecting, staging, or explicitly overriding a TinyKG executable does not change
provider-visible bytes. TinyKG receipts and bundle identities remain execution
metadata; only governed memory content deliberately appended at a checkpoint can
change the subsequent request.

An AgentSession prompt profile is frozen into the Session: the same profile
renders the same system prompt on every Run, and replacing it while idle is one
deliberate cache boundary, announced by the next Run's `prompt_manifest`.
Volatile Host facts (the date, page state) belong in per-Run context blocks,
which join the conversation as user-role content after the existing history, so
they extend the cached prefix instead of moving the system prompt. The date is
supplied by default (issue #276): AgentCore leads each Run's context with a
`currentDate` block in the process's time zone, or in a UTC offset the Host
gives per Run (`RunOptionsV1.time_context_code` / `utc_offset_minutes`); a Host
`currentDate` block replaces it, and `TIME_CONTEXT_OFF` drops it. An explicit
Skill invocation Run (`RUN_INPUT_SKILL`) takes context blocks and the date
like any other Run (#534): they lead its invocation record, ahead of the Skill
body. The CLI's
user-context message always states the session's start date and zone, and the
first Run on a later local date gets one "the date has changed" notice in that
turn (`agent_loop.Options.time_announcer`). Source-level Hosts build the same
text with `core.time_context` (`systemZone`, `Zone.fromHostOffset`, `today`).

A Session goal (issue #277) is one objective with an optional token budget.
`core.goal` owns its rules: the transition table (`State.apply`, `update`), and
the `Meter` the agent loop charges per provider response (non-cached input plus
output, automatic compaction included) for every Run that began on an active
goal, however the Run ends. A budget used up mid-Run makes the goal
`budget_limited` and asks the model, once, at the next turn boundary to wrap
up; the Run is not cut off. `AgentSession` owns a goal (`setGoal`,
`updateGoal`, `clearGoal`, `currentGoal`), charges it on every Run, and emits
`CoreEvent.goal_updated`; AgentCore exposes it as the `goal` table and the
`RUN_INPUT_GOAL_CONTINUATION` input kind. A host-scheduled team (issue #277)
is the same core `swarm` seam: with `RuntimeConfigV1.enable_teams` the lead and
member Sessions carry a `SessionHostConfigV1.team`, delegation records a spawn
request the Host fulfils, and the `team` table's `describe` and `poll` read the
roster and take a teammate's reply.

## Errors and ownership

Public boundaries use tagged states or explicit error sets. Callback buffers are
borrowed only for the documented call duration. Returned buffers always have a
documented paired release API: AgentCore-owned byte buffers are released with
`api->buffer_release`, while callback-owned buffers are released by the host's
registered release function. Hosts must not retain sink pointers, call mutating
session APIs reentrantly, or destroy a runtime with active sessions. The normative
ownership rules live beside each public header/type and its consumer fixture.
