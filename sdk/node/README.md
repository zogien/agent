# AgentCore for Node.js and Electron

Install `@zogien/agent-sdk` with npm. Its optional platform dependency supplies
the Node-API 8 addon, AgentCore shared library and ripgrep for Windows, macOS
and GNU/Linux on x64 and ARM64. The host needs Node 18 or later or a compatible
Electron main process.

```js
const { Runtime } = require('@zogien/agent-sdk');

async function summarize(model) {
  const runtime = new Runtime({ tools: ['Read', 'Glob', 'Grep'] });
  try {
    const session = runtime.session(model, { provider: 'anthropic', workspace: '.' });
    return await session.run('Summarize the repository in three lines.');
  } finally {
    runtime.close();
  }
}
```

A Run that stops on the model resolves normally with `stopReason === 'api_error'`,
and `result.modelError` says why: `category`, `code` and `type` (the provider's,
verbatim), `message` (safe to display), `http_status`, `request_id`, `retry`
(`'retryable'`, `'not_retryable'` or `'unknown'`), `retry_after_ms` and
`attempts`. It is `null` on any other stop. The SDK attaches no meaning to
`code`; whether it means "add funds" is yours to decide.

The API key comes from `apiKey`, else the provider's usual variable
(`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`), else
`METACODES_API_KEY`. `baseUrl` is the full endpoint; empty means the
provider's official one.

Preview features default to disabled. `new Runtime({ preview: true })`
opts in and includes the `ExecuteCode` JavaScript orchestration tool; Session
tool selection and ordinary permission checks still apply. Selecting
`ExecuteCode` with preview disabled is rejected. This requires AgentCore ABI revision 29.

## Session configuration and input

Pass a section edit list as `promptProfile` when creating a Session. Each edit
names an `id` and an `op`. Use `add` for a new `host:<name>` section with
`text` and a signed `order`, `replace` for a built-in section's text, or
`remove` for a removable section. Set `interpolate: true` to expand
`{{model}}`, `{{workspace_root}}` and `{{platform}}`. A profile admits 64
sections, 64 KiB of UTF-8 text per section and 256 KiB of text in total.

```js
session.setPromptProfile([{ op: 'replace', id: 'metacodes:identity', text: 'You are a shopkeeper.' }]);
session.updatePermissionRules({ allow: ['Read'], ask: ['Write'], deny: ['Bash'] });
await session.run([
  { type: 'text', text: 'Describe this image.' },
  { type: 'image', mediaType: 'image/png', data: pngBytes.toString('base64') },
]);
```

Both setters require an idle Session. The next Run uses the new profile and
rules. A checkpoint preserves the profile. Pass `null` to `setPromptProfile`
to restore the kernel prompt. Each rules update replaces all three lists.
`run` and `stream` accept 1–64 ordered parts. Image data uses standard base64
with a limit of 5,000,000 encoded bytes per image.

Creation and restore both accept these host options.

- `modelCapabilities` takes entries such as `{ model: 'vision-model', imageInput: true }`.
  Set `imageInput: false` to reject image input for that model.
- `runJournalMode` defaults to `'ephemeral'`. Choose `'durable_workspace'` to write
  the Session's run journal below `workspaceHome`.
- `durableBudget` takes a complete byte budget. Supply `hardBytes`, `softBytes`,
  `inputCapBytes`, `providerRequestCapBytes`, `providerResultCapBytes`,
  `toolResultCapBytes`, `mcpResultCapBytes`, `auditReserveBytes` and
  `terminalReserveBytes` as unsigned bigints or safe integers. Omit the
  profile to use AgentCore defaults.

`await session.compact()` summarizes eligible history on a separate thread.
The result contains `outcome` (`compacted`, `no_change`, `degraded` or `aborted`),
`beforeContextTokens`, `afterContextTokens` and provider `usage`.
All token counts are bigints. Call `await session.abortCompact()` to request
cancellation and await the original compact promise for the outcome.

## Tools written in JavaScript

```js
const { Runtime, tool } = require('@zogien/agent-sdk');
const lookupOrder = tool({
  name: 'lookup_order',
  description: 'Look up an order by id.',
  inputSchema: { type: 'object', properties: { id: { type: 'string' } }, required: ['id'] },
  handler: async ({ id }) => ({ id, status: 'shipped' }),   // string or anything JSON-serialisable
});
const runtime = new Runtime({ tools: ['Read'], hostTools: [lookupOrder] });
```

Handlers may be async. A thrown error or rejected promise is returned to the
model as an ordinary tool error, and the run goes on. So is a result
`JSON.stringify` cannot encode, such as a BigInt, a cycle or a function. An
`onUiRequest` answer that cannot be encoded is not answered: the run's promise
rejects with that error.

## Events and streaming

```js
const stream = session.stream('Fix the failing test');
for await (const event of stream) {
  const [[tag, payload]] = Object.entries(event);   // "text_chunk", "tool_start", "usage", ...
  if (tag === 'text_chunk') process.stdout.write(payload);
}
const result = await stream.result;
```

`session.run(prompt, { onEvent })` delivers the same events to a callback;
every event of a Run arrives before its promise settles. `result.text` is the
final answer rebuilt from the `output_segment_*` events. The event vocabulary
is listed in [doc/AGENTCORE_BINARY_ABI.md](../../doc/AGENTCORE_BINARY_ABI.md).
`session.abort()` stops the active run; `session.submit(text)` adds user input
to it. `session.updateCredential(apiKey)` replaces the provider key in place,
also during a run and from inside a tool or handler: every request sent
afterwards (the run's next turn, a retry) carries it, and a request already
sent keeps the old one. `session.rewindToUserMessage(position)` edits and
reruns: while idle it drops the user message at `position` (counted from 1 over
the whole history, as `describe().conversation.message_count` counts) and
everything after it, and the next `run()` takes its place; a refused position
throws with code `NOT_USER_MESSAGE`, `MESSAGE_POSITION_OUT_OF_RANGE` or
`MESSAGE_POSITION_COMPACTED` and changes nothing. Separate sessions run concurrently; one session runs one prompt at a
time. `session.close()` throws while a run is active, and the session stays
open; await the run, or `abort()` it, first.

A gateway stream sometimes breaks off mid-answer, and a reasoning model has
usually shown thinking by then. Every request is sent again once by itself when
its stream broke off without an answer (a stall, a dropped connection, a stream
that ended before its stop reason) and no tool call had started.
`run(prompt, { streamRetryBudget: n })` (and `stream(...)`, 0 to 8, default 0)
lets the run send a request again up to `n` more times, after a started tool
call too; a server's error is never re-sent. Before each retry of an attempt
that showed output the run tells you what to take back: the attempt's
`output_segment_end` has disposition `'discarded'` (its text is not part of
`result.text`), a `thinking_discarded` event `{ index, turn, group, bytes }`
names the thinking shown while that segment was open, and a `retry_notice`
follows before a short wait.

## Permissions

Sessions start in `permissionMode: 'default'` with the shell disabled. A tool
call that needs approval reaches `onUiRequest`, which may be async; return an
answer or `null` (no answer means the call is not allowed):

```js
const session = runtime.session('…', {
  onUiRequest: async (request) =>
    request.kind === 'permission' && request.data.tool.name === 'Write' ? request.allowOnce() : null,
  allow: ['Read'],
  deny: ['Bash(rm *)'],
});
```

## Run context, cancellation and checkpoints

`timeContext` defaults to `'system'` on both `run` and `stream`. Use
`{ timeContext: 'utc_offset', utcOffsetMinutes: 345 }` for UTC+05:45, or
`{ timeContext: 'off' }` to omit the runtime's `currentDate` block for this
Run. The offset is an integer from -840 to 840 minutes east of UTC. Only
`'utc_offset'` accepts a nonzero offset.

`run(prompt, { contextBlocks: [{ label, text }] })` and `stream` copy the blocks
when called. Each Run accepts up to 32 blocks, a 64-byte label and 64 KiB of text
per block, and 256 KiB total, measured in UTF-8.

A host tool receives `handler(args, { sessionId, runId, callId, signal })`.
Forward the signal to cancellable work. `await stream.abort()` targets that
stream's Run. `await session.abort()` targets the current Run. The returned
`status` is `cancelled` after an aborted terminal result, `already_finished`
when the Run has finished, or `failed` with a diagnostic. If a handler never
returns, cancelling releases the native waiter. Terminating a Node Worker
detaches its callbacks and lets native cleanup finish on the running thread.

Protocol 64-bit integers, including Run IDs, token counts, byte counts and
permission generations, are JavaScript `bigint`. Turn counts and tool counts
are numbers. Use a JSON replacer that converts bigints to decimal strings when
logging a complete event or session description.

```js
const { missingArtifacts } = await session.exportCheckpoint(snapshotDirectory);
const restored = await otherRuntime.restoreSession(snapshotDirectory, {
  workspace: freshWorkspace, provider: 'anthropic', apiKey,
});
const next = await restored.run('Continue');
```

Export an idle Session to a new directory with an existing parent. The v1
directory contains `manifest.json`, `checkpoint.bin` and `blobs/<sha256>.blob`.
It captures committed artifacts for this logical Session, including any retained
from earlier turns. `missingArtifacts` lists the `sha256:` artifact IDs that the
checkpoint references but the Session store no longer holds; after restore,
`ReadArtifact` reports those as not found. An export or restore holds an
operating-system lock beside its target. Another live writer is refused, and a
writer that exited without releasing it does not block a retry. Transfer the
whole directory. Restore checks file sizes and
digests, uses the supplied host options and resumes after the checkpoint's last
Run ID. Register any host tools on the receiving Runtime. The restore report
is available as `restored.restoreReport`. The checkpoint limit is 64 MiB,
with up to 128 MiB per blob and 1 GiB of blobs per Session.

The installed package locates the addon and shared library in the platform
package. Keep that package's native files unpacked when bundling an Electron
application; its library, helpers and manifest must remain accessible as files.

## Workspace skills

`resolveWorkspaceSkillCatalog` returns the descriptor for a workspace. Each
entry includes its invocation name, concrete skill ID and argument schema.
Pass the catalog and an array of granted skill IDs together to create or
restore a Session. An empty grant list denies all skills.

```js
const catalog = runtime.resolveWorkspaceSkillCatalog({ workspace });
try {
  const skill = catalog.skills.find(s => s.invocation_name === 'review');
  if (!skill) throw new Error('review skill is unavailable');
  const session = runtime.session(model, { workspace, skillCatalog: catalog, skillPolicy: [skill.skill_id] });
  const input = { skillId: skill.skill_id, catalogRevision: catalog.catalog_revision, values: ['the changes'] };
  await session.runSkill(input);
  session.bindPolicy(catalog, []);
} finally {
  runtime.releaseCatalog(catalog);
}
```

For streaming, pass `{ type: 'skill', ...input }` to `session.stream()`.
An idle Session can replace its catalog and grants together with `bindPolicy`.
After release the Session retains its binding. Use `bindPolicy(null, grants)`
to update grants against the retained catalog. Resolving a new catalog requires
granting IDs from that descriptor. To configure discovery, pass `workspaceHome`,
`workspaceEpoch`, `defaultUserSourcePriority`, `defaultWorkspaceSourcePriority`
or `additionalSources` entries with `{ scope, root, sourceInstanceId, priority }`.

## Goals

```js
session.setGoal('Review the importer changes', 10000n);
await session.continueGoal();
console.log(session.getGoal().tokens_used);
session.updateGoal({ tokenBudget: 20000n, action: 'pause' });
```

`getGoal()` and `describe().goal` return the current goal or `null`.
Budgets, token usage and millisecond timestamps and durations are `bigint`.
A zero budget removes the cap. An update can replace the objective, change the
budget and apply one action (`pause`, `activate`, `block` or `complete`)
atomically. An active goal can also be continued with
`session.stream({ type: 'goal_continuation' })`. The runtime supplies the
input, accounts for usage and preserves the goal across checkpoint restore.
Use `clearGoal()` to remove it.

## MCP servers

Configure a server with its stable 32-byte binding identity and configuration
fingerprint, each encoded as 64 hex digits. The fingerprint identifies the
endpoint and authenticated principal. Change it when either changes. Keep it
when rotating a credential for the same principal.

```js
const runtime = new Runtime({
  mcpServers: [{ namespace: 'inventory', command, args, serverBindingIdentity, configurationFingerprint }],
  mcpCatalogLimits: { maxServers: 8, maxNamespaceBytes: 24, maxIssues: 32 },
});
try {
  await runtime.refreshMcp();
  const catalog = await runtime.describeMcp();
  const tool = catalog.tools.find(entry => entry.canonical_name === 'lookup');
  if (!tool) throw new Error('lookup unavailable');
  const session = runtime.session(model, { workspace, mcpSelection: [
    { serverBindingIdentity: tool.server_binding_identity, toolName: tool.canonical_name },
  ] });
  await session.run('Look up the stock count');
  session.updateMcpSelection([]);
} finally {
  runtime.close();
}
```

`refreshMcp()` discovers the current tools and returns the catalog generation
as a `bigint`. Inspect the catalog from `describeMcp()` for server issues and negotiated
versions. `applyMcpConfiguration({ desiredRevision, servers })` reconciles a
complete replacement set. Its report includes the disposition (`applied`,
`superseded` or `rejected`), desired and active revisions, and catalog generation.
Await outstanding operations before closing the Runtime. An idle Session can
replace its selection with `updateMcpSelection`. Its description lists the
selected tools and the names sent to the model.

The stdio connector launches `command` with `args`, optional `cwd` and optional
`env`. It uses the host environment by default. To own the connection, supply
`open({ purpose, era, timeoutMs })` and choose `stdio` or `streamable_http` as
the transport. Each open returns a fresh connection with `request`, `notify`,
`requestToolStream` and `close`. Control requests return the body and, for
HTTP, the HTTP status. The tool stream yields chunks of the complete JSON-RPC
response from its first byte. Honor the per-call timeout and abort signal.
Keep HTTP protocol versions and session IDs local to each connection. A
connector can throw an error with a `code` of `timeout`, `network_error`,
`auth_error`, `server_error`, `child_exit`, `cancelled`, `indeterminate` or
`fatal`. Use `indeterminate` if a tool invocation may have reached the server.
See the [connector contract](../../doc/AGENTCORE_BINARY_ABI.md#mcp-runtime-catalog-and-session-view).

## Host-scheduled teams

Create a Runtime with `enableTeams: true`. Give the lead Session
`team: { role: 'lead' }` and select its team tools in the Session's `tools`.
After `TeamCreate` and `SpawnTeammate`, `lead.describeTeam().pending_spawns`
contains the work for the host to schedule. Open the member in the same
workspace home with `team: { role: 'member', teamName, memberName,
leadSessionId, memberLease }`. Use `lead.describe().session_id` and a fresh
24-digit lowercase hex lease. A member with `SendMessage` can reply to
`team-lead`. Both Sessions can inspect the roster with `describeTeam()`.
`lead.pollTeam()` takes unread messages as input for the next Run and returns
`null` when the inbox is empty. Member polling also returns `null`.

## Building and testing

```sh
zig build agentcore:bundle test:harness -Dtarget=aarch64-macos -Doptimize=ReleaseSafe
npm ci --prefix sdk/node --ignore-scripts
node sdk/node/scripts/build.js --bundle zig-out/agentcore/<resolved-target>
node --test sdk/node/test/metacodes.test.js
```

The build uses Zig 0.16 and the pinned Node-API headers. Set `NODE_INCLUDE_DIR`
to use an existing set of headers. Consumer tests run against a local scripted
provider. Set `METACODES_NODE_SDK_REQUIRE_LIB=1` to require the native build.
