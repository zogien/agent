# metacodes for Python

Embed the [metacodes](https://github.com/metask-ai/metacodes) agent runtime in a
Python program. The package calls the AgentCore C ABI through `ctypes`: no
compiler, no third-party dependencies, Python 3.9 or newer.

```python
import metacodes

with metacodes.Runtime(tools=["Read", "Glob", "Grep"]) as runtime:
    session = runtime.session(
        "claude-sonnet-4-5",          # any model your provider serves
        provider="anthropic",         # or "openai", "gemini"
        workspace=".",
    )
    result = session.run("Summarize this repository in three lines.")
    print(result.text, result.stop_reason, result.usage)
```

A Run that stops on the model returns normally with `stop_reason == "api_error"`,
and `result.model_error` says why: `category`, `code` and `type` (the provider's,
verbatim), `message` (safe to display), `http_status`, `request_id`, `retry`
(`"retryable"`, `"not_retryable"` or `"unknown"`), `retry_after_ms` and
`attempts`. It is `None` on any other stop. The SDK attaches no meaning to
`code`; whether it means "add funds" is yours to decide.

The API key comes from `api_key=`, else the provider's usual variable
(`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`), else
`METACODES_API_KEY`. `base_url=` is the full endpoint; empty means the
provider's official one. An OpenAI-compatible server is addressed with
`provider="openai"` and its full URL.

Preview features default to disabled. `metacodes.Runtime(preview=True)` opts
in and includes the `ExecuteCode` JavaScript orchestration tool; Session tool
selection and ordinary permission checks still apply. Selecting `ExecuteCode`
with preview disabled is rejected. This requires AgentCore ABI revision 29.

## Session configuration and input

```python
session.set_prompt_profile([{"op": "replace", "id": "metacodes:identity", "text": "You are a shopkeeper."}])
session.update_permission_rules(allow=["Read"], ask=["Write"], deny=["Bash"])
session.run([
    {"type": "text", "text": "Describe this image."},
    {"type": "image", "media_type": "image/png", "data": base64_png},
])
```

Pass the same edit list as `prompt_profile` when creating a Session. Use
`add` with a `host:<name>` id, text and signed `order`, `replace` with a
built-in id and text, or `remove` with a removable id. Optional
`interpolate=True` expands `{{model}}`, `{{workspace_root}}` and `{{platform}}`.
Use `set_prompt_profile(None)` to clear the edits. Each profile admits 64 edits,
64 KiB of UTF-8 text per edit and 256 KiB total. Replace the profile or all three
permission lists while idle. The next Run uses the new settings.

Both `run` and `stream` accept 1–64 ordered parts. Each image admits up to
5,000,000 bytes of standard base64 data. Declare model support with
`model_capabilities=[{"model": "vision-model", "image_input": True}]`.

Set `run_journal_mode="durable_workspace"` to record Runs under `workspace_home`.
The default is `"ephemeral"`. To supply a complete `durable_budget`, pass a dict
of integer byte counts with the keys `hard_bytes`, `soft_bytes`, `input_cap_bytes`,
`provider_request_cap_bytes`, `provider_result_cap_bytes`, `tool_result_cap_bytes`,
`mcp_result_cap_bytes`, `audit_reserve_bytes` and `terminal_reserve_bytes`.

Use `time_context="system"` (default), `"utc_offset"` or `"off"` on either
`run` or `stream`. For a fixed offset, supply `utc_offset_minutes` as an
integer from -840 to 840. The other modes require zero. Add per-Run context
with `context_blocks=[{"label": "Review", "text": "Check the new importer"}]`.

An idle Session exposes `get_goal()`, `set_goal(objective, token_budget=0)`,
`update_goal(objective=..., token_budget=..., action=...)` and `clear_goal()`.
Supply only the fields you want to update. A zero budget removes the cap.
Pass `{"type": "goal_continuation"}` to `run` or `stream` to continue an
active goal with runtime-generated input. Goal counters are Python integers.

## Tools written in Python

```python
@metacodes.tool(
    description="Look up an order by id.",
    input_schema={"type": "object", "properties": {"id": {"type": "string"}}, "required": ["id"]},
)
def lookup_order(arguments):
    return {"id": arguments["id"], "status": "shipped"}   # str or anything JSON-serialisable

runtime = metacodes.Runtime(tools=["Read"], host_tools=[lookup_order])
```

An exception inside a tool is returned to the model as an ordinary tool error;
the run goes on. Tools may be called from AgentCore worker threads, in parallel.

## Events and streaming

```python
for event in session.stream("Fix the failing test"):
    (tag, payload), = event.items()        # e.g. "text_chunk", "tool_start", "usage"
    if tag == "text_chunk":
        print(payload, end="", flush=True)
```

`session.run(prompt, on_event=callback)` delivers the same events to a
callback. `RunResult.text` is the final answer rebuilt from the
`output_segment_*` events (commentary and discarded output are excluded); the
event vocabulary is listed in
[doc/AGENTCORE_BINARY_ABI.md](../../doc/AGENTCORE_BINARY_ABI.md).
`session.abort()` stops the active run and `session.submit(text)` adds user
input to it; both may be called from another thread. Each run executes on its
own thread; Ctrl+C while `run()` waits aborts the run and waits for it to stop.
`session.update_credential(api_key)` replaces the provider key in place, while
idle or during a run, from any thread or from inside a tool or handler: every
request sent afterwards (the run's next turn, a retry) carries it, and a
request already sent keeps the old one. The provider, endpoint and model stay.

To edit an earlier message and rerun from it, call
`session.rewind_to_user_message(position)` while idle, then `run()` the edited
text. `position` counts the whole history from 1, as
`describe()["conversation"]["message_count"]` does, so a run's own message is
`message_count + 1` read just before it. The message and everything after it
are dropped; files and other effects of the dropped turns stay. A position that
is not a user message, is out of range, or lies behind the compact boundary
raises `AgentCoreError` (`NOT_USER_MESSAGE`, `MESSAGE_POSITION_OUT_OF_RANGE`,
`MESSAGE_POSITION_COMPACTED`) and changes nothing.

A gateway stream sometimes breaks off mid-answer, and a reasoning model has
usually shown thinking by then. Every request is sent again once by itself when
its stream broke off without an answer (a stall, a dropped connection, a stream
that ended before its stop reason) and no tool call had started.
`run(prompt, stream_retry_budget=n)` (and `stream(...)`, 0 to 8, default 0)
lets the run send a request again up to `n` more times, after a started tool
call too; a server's error is never re-sent. Before each retry of an attempt
that showed output the run tells you what to take back: the attempt's
`output_segment_end` has disposition `"discarded"` (its text is not part of
`RunResult.text`), a `thinking_discarded` event
`{"index", "turn", "group", "bytes"}` names the thinking shown while that
segment was open, and a `retry_notice` follows before a short wait.

`session.close()`, and leaving a `with` block, aborts a run that is still going
and waits for it first. That includes a `stream()` the loop stopped early with
`break`.

Abort is cooperative, so a tool or `on_ui_request` that blocks keeps
`close()` waiting too. An `on_ui_request` waiting for the thread that is
closing never returns. `close(timeout=seconds)` raises TimeoutError instead,
and leaves the Session open. The abort has been requested by then, so the run
still ends `aborted` once the blocking call returns.

The handle is dropped only once AgentCore has destroyed the Session. If
AgentCore refuses, `close()` raises and the Session stays usable. One of the
Session's own callbacks (its event listener, `on_ui_request`, or a tool
running in its run) cannot close it, since that run could never return:
`close()` raises RuntimeError there. The same holds for the callbacks of a
child Session's run that such a tool started. Opening and closing a different
Session from a tool is fine.

## Permissions

Sessions start in `permission_mode="default"` with the shell disabled. A tool
call that needs approval reaches `on_ui_request`; return an answer or `None`
(no answer means the call is not allowed):

```python
def approve(request):
    if request.kind == "permission" and request.data["tool"]["name"] == "Write":
        return request.allow_once()
    return None

session = runtime.session("…", on_ui_request=approve, allow=["Read"], deny=["Bash(rm *)"])
```

`permission_mode` is `default`, `accept_edits`, `auto`, `dont_ask` or
`full_access`; `shell` is `disabled`, `sandboxed` or `unrestricted`. `allow`,
`ask` and `deny` take rules in the `Tool(specifier)` syntax.

## Where the native library comes from

Platform wheels carry `libmetask_agentcore` and ripgrep inside the package.
Otherwise the package looks, in order, at `Runtime(library=...)`,
`METACODES_AGENTCORE_LIB`, `METACODES_AGENTCORE_SDK/lib`, and the SDK from an
existing upstream CLI install under `~/.local/opt/metacodes` or
`~/.local/opt/metacodes-dev`. To use a standalone SDK archive, set
`METACODES_AGENTCORE_SDK` to the extracted bundle directory.
`metacodes.candidate_library_paths()` prints the list. The
package refuses any library whose ABI revision differs from the one it was
written for (`metacodes.ABI_REVISION`).

## Building and testing

```sh
zig build agentcore:bundle -Dtarget=aarch64-macos -Doptimize=ReleaseSafe
python3 sdk/python/build_wheel.py --bundle zig-out/agentcore/<resolved target> --out dist/
METACODES_AGENTCORE_LIB=zig-out/agentcore/<resolved target>/lib/libmetask_agentcore.dylib \
  python3 -m unittest discover -s sdk/python/tests
```

The tests drive the real library against a scripted local mock provider; no
network, no API key. Without a library they skip, unless
`METACODES_PY_SDK_REQUIRE_LIB=1`.

## Status

Experimental, like the AgentCore ABI it wraps: the package pins one exact ABI
revision and follows it. Not yet published to PyPI; build the wheel as above.
Windows is not covered by CI. Manual compaction, skills, MCP, checkpoints and teams exist in
the ABI but are not wrapped yet; contributions welcome.
