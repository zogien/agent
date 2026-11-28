// Type declarations for the `metacodes` Node package (index.js).

export const ABI_REVISION: number;
export const BUILTIN_TOOLS: readonly string[];
export const DEFAULT_TOOLS: readonly string[];

/** One AgentCore observation event: a single key (the tag) and its payload. */
export type AgentEvent = Record<string, unknown>;

export interface ToolContext {
  sessionId: string;
  runId: bigint;
  callId: bigint;
  signal: AbortSignal;
}

export type CancelResult = { status: 'cancelled' | 'already_finished' } | { status: 'failed'; diagnostic: string };

export interface Tool<Args = Record<string, unknown>> {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  handler: (args: Args, context: ToolContext) => unknown | Promise<unknown>;
}

export function tool<Args = Record<string, unknown>>(spec: {
  name: string;
  description?: string;
  inputSchema?: Record<string, unknown>;
  handler: (args: Args, context: ToolContext) => unknown | Promise<unknown>;
}): Tool<Args>;

export class UiRequest {
  readonly kind: 'permission' | 'ask_question';
  readonly data: Record<string, any>;
  allowOnce(): object;
  allowSession(): object;
  denyOnce(): object;
  denySession(): object;
  answer(...values: string[][]): object;
}

/**
 * Why a Run stopped with `stopReason === 'api_error'`. `code` is the upstream's
 * identifier exactly as sent; the SDK attaches no meaning to it. `message` is
 * safe to display: redacted and bounded.
 */
export interface ModelError {
  run_id: bigint;
  category:
    | 'authentication' | 'permission' | 'payment_required' | 'not_found' | 'invalid_request'
    | 'context_window' | 'rate_limited' | 'overloaded' | 'server_error' | 'timeout'
    | 'connection' | 'stream_interrupted' | 'output_limit' | 'unknown';
  code: string | null;
  type: string | null;
  message: string;
  http_status: number | null;
  request_id: string | null;
  retry: 'retryable' | 'not_retryable' | 'unknown';
  retry_after_ms: bigint | null;
  attempts: number;
  truncated: boolean;
  context_window: {
    origin: 'local' | 'provider';
    estimated_input_tokens: bigint;
    blocking_limit: bigint;
    compaction: 'no_history' | 'insufficient' | 'not_evaluated';
    server_limit: { tokens: bigint; kind: 'input' | 'total' | 'unspecified' } | null;
  } | null;
}

export interface RunResult {
  runId: bigint;
  text: string;
  stopReason: string;
  turns: number;
  toolCalls: number;
  usage: {
    input_tokens: bigint;
    output_tokens: bigint;
    cache_read_input_tokens: bigint;
    cache_creation_input_tokens: bigint;
  };
  segments: { disposition: string; group: number; text: string }[];
  inputAccepted: number;
  inputAdopted: number;
  /** Set exactly when the Run stopped on the model; null otherwise. */
  modelError: ModelError | null;
}

export class AgentCoreError extends Error {
  readonly code: string;
  readonly status: number;
  readonly diagnostic: string;
}

export type PromptSection = {
  op: 'add' | 'replace' | 'remove';
  id: string;
  text?: string;
  order?: number | bigint;
  interpolate?: boolean;
};

export interface SkillInvocation {
  skillId: string;
  catalogRevision: string;
  values?: readonly string[];
}

export type RunInput = string | ({ type: 'skill' } & SkillInvocation) | { type: 'goal_continuation' } | readonly (
  | { type: 'text'; text: string }
  | { type: 'image'; mediaType: string; data: string }
)[];

export interface DurableBudget {
  hardBytes: number | bigint;
  softBytes: number | bigint;
  inputCapBytes: number | bigint;
  providerRequestCapBytes: number | bigint;
  providerResultCapBytes: number | bigint;
  toolResultCapBytes: number | bigint;
  mcpResultCapBytes: number | bigint;
  auditReserveBytes: number | bigint;
  terminalReserveBytes: number | bigint;
}

export interface CompactResult {
  outcome: 'compacted' | 'no_change' | 'degraded' | 'aborted';
  beforeContextTokens: bigint;
  afterContextTokens: bigint;
  usage: RunResult['usage'];
}

export interface SessionOptions {
  mcpSelection?: readonly McpSelector[];
  team?: TeamConfig;
  skillCatalog?: SkillCatalog;
  skillPolicy?: readonly string[];
  promptProfile?: readonly PromptSection[] | null;
  modelCapabilities?: readonly { model: string; imageInput?: boolean; maxInputTokens?: number; maxTokens?: number }[];
  durableBudget?: DurableBudget;
  runJournalMode?: 'ephemeral' | 'durable_workspace';
  provider?: 'anthropic' | 'openai' | 'gemini';
  apiKey?: string;
  /** Full endpoint; empty means the provider's official one. */
  baseUrl?: string;
  workspace?: string;
  workspaceHome?: string;
  tools?: string[];
  permissionMode?: 'default' | 'accept_edits' | 'auto' | 'dont_ask' | 'full_access';
  shell?: 'disabled' | 'sandboxed' | 'unrestricted';
  openaiProtocol?: 'chat_completions' | 'responses';
  allow?: string[];
  ask?: string[];
  deny?: string[];
  onEvent?: (event: AgentEvent) => void;
  onUiRequest?: (request: UiRequest) => object | null | undefined | Promise<object | null | undefined>;
}

export interface RunOptions {
  timeContext?: 'system' | 'utc_offset' | 'off';
  utcOffsetMinutes?: number;
  contextBlocks?: readonly { label: string; text: string }[];
  maxTurns?: number;
  /** Revision 28: re-issues after a broken-off stream, beyond each request's own one (#461), 0 to 8 (default 0). */
  streamRetryBudget?: number;
  onEvent?: (event: AgentEvent) => void;
}

export interface EventStream extends AsyncIterable<AgentEvent> {
  result: Promise<RunResult>;
  abort(): Promise<CancelResult>;
}

export interface SessionDescription extends Record<string, unknown> {
  mcp: { selection_fingerprint: string; tools: { model_name: string; namespace: string; canonical_name: string;
    server_binding_identity: string; schema_fingerprint: string; permission_binding: string; negotiated_protocol: string }[] };
  goal: Goal | null;
  session_id: string;
  model: string;
  max_input_tokens?: number;
  max_tokens?: number;
  per_result_bytes?: number;
  per_turn_bytes?: number;
  last_run_id: bigint;
  last_compact_id: bigint;
  checkpoint_generation: bigint;
  policy_generation: bigint;
  catalog_generation: bigint;
  conversation: { message_count: bigint; compact_boundary: bigint };
}

export interface CheckpointExport {
  missingArtifacts: string[];
}

export interface RestoreReport extends Record<string, unknown> {
  session_id: string;
  checkpoint_generation: bigint;
  policy_generation: bigint;
  catalog_generation: bigint;
}

export class Session {
  updateMcpSelection(selectors: readonly McpSelector[]): void;
  describeTeam(): TeamDescription | null;
  pollTeam(): string | null;
  readonly restoreReport: RestoreReport | null;
  exportCheckpoint(directory: string): Promise<CheckpointExport>;
  readonly runtime: Runtime;
  model: string;
  run(prompt: RunInput, options?: RunOptions): Promise<RunResult>;
  runSkill(input: SkillInvocation, options?: RunOptions): Promise<RunResult>;
  continueGoal(options?: RunOptions): Promise<RunResult>;
  bindPolicy(catalog: SkillCatalog | null, grantedSkillIds: readonly string[]): void;
  getGoal(): Goal | null;
  setGoal(objective: string, tokenBudget?: bigint): void;
  updateGoal(changes: { objective?: string; tokenBudget?: bigint; action?: 'pause' | 'activate' | 'complete' | 'block' }): void;
  clearGoal(): void;
  stream(prompt: RunInput, options?: Omit<RunOptions, 'onEvent'>): EventStream;
  abort(): Promise<CancelResult>;
  submit(text: string): number;
  /** Revision 25: replace the provider credential in place, also mid-Run. */
  updateCredential(apiKey: string): void;
  describe(): SessionDescription;
  setPromptProfile(profile: readonly PromptSection[] | null): void;
  updatePermissionRules(rules: Pick<SessionOptions, 'allow' | 'ask' | 'deny'>): void;
  compact(): Promise<CompactResult>;
  abortCompact(): Promise<void>;
  setModel(model: string): void;
  setPermissionMode(mode: NonNullable<SessionOptions['permissionMode']>): void;
  /** Revision 27: drop the user message at a 1-based position and everything after it. */
  rewindToUserMessage(position: bigint | number): void;
  close(): void;
}

export interface RuntimeOptions {
  enableTeams?: boolean;
  mcpServers?: readonly McpServer[];
  mcpCatalogLimits?: { maxServers: number; maxNamespaceBytes: number; maxIssues: number };
  tools?: string[];
  hostTools?: Tool<any>[];
  library?: string;
  preview?: boolean;
}

export type TeamConfig = { role: 'lead'; teamName?: string } | {
  role: 'member'; teamName: string; memberName: string; leadSessionId: string; memberLease: string;
};

export interface TeamDescription {
  name: string;
  role: 'lead' | 'member';
  members: { name: string; session_id: string; lease_id: string; status: 'active' | 'idle' }[];
  pending_spawns: { name: string; prompt: string; agent_type: string | null; effort: string | null }[];
}

export interface McpSelector {
  serverBindingIdentity: string;
  toolName: string;
}

export interface McpExchangeOptions { timeoutMs: number; signal: AbortSignal }
export interface McpConnection {
  request(frame: string, options: McpExchangeOptions):
    { httpStatus?: number; body: string | Uint8Array } | Promise<{ httpStatus?: number; body: string | Uint8Array }>;
  requestToolStream(frame: string, options: McpExchangeOptions): AsyncIterable<Uint8Array> | Promise<AsyncIterable<Uint8Array>>;
  notify(frame: string, options: McpExchangeOptions): void | Promise<void>;
  close(): void | Promise<void>;
}

export type McpServer = {
  namespace: string;
  serverBindingIdentity: string;
  configurationFingerprint: string;
  protocolLimits?: { maxFrameBytes: number; maxTools: number; maxToolNameBytes: number; maxTextBytes: number;
    maxSchemaBytes: number; maxJsonDepth: number; maxJsonNodes: number; maxCursorBytes: number; maxVersions: number };
  timeoutMs?: number;
  negotiationPolicy?: 'auto' | 'modern_only' | 'legacy_only' | 'legacy_2025_06_only';
  clientName?: string;
  clientVersion?: string;
} & ({
  transport?: 'stdio'; command: string; args?: readonly string[]; cwd?: string; env?: Record<string, string>;
} | {
  transport: 'stdio' | 'streamable_http';
  open(context: { purpose: 'probe' | 'actual'; era: '2026-07-28' | '2025-11-25' | '2025-06-18'; timeoutMs: number }):
    McpConnection | Promise<McpConnection>;
});

export interface McpCatalog {
  schema: string;
  catalog_generation: bigint;
  catalog_fingerprint: string;
  servers: { server_binding_identity: string; namespace: string; negotiated_protocol: string; server_fingerprint: string;
    cache_scope: string; fresh: boolean; ttl_remaining_ms: bigint; tool_offset: number; tool_count: number }[];
  tools: { server_binding_identity: string; canonical_name: string; schema_fingerprint: string; permission_binding: string }[];
  issues: { issue_id: string; server_binding_identity: string; tool_name: string | null; kind: string; detail: string }[];
}

export interface Goal {
  id: string;
  objective: string;
  status: 'active' | 'paused' | 'blocked' | 'complete' | 'usage_limited' | 'budget_limited';
  token_budget: bigint | null;
  tokens_used: bigint;
  time_used_ms: bigint;
  created_at_ms: bigint;
  updated_at_ms: bigint;
}

export interface SkillCatalogQuery {
  workspace?: string;
  workspaceHome?: string;
  workspaceEpoch?: string;
  defaultUserSourcePriority?: number;
  defaultWorkspaceSourcePriority?: number;
  additionalSources?: readonly { scope: 'user' | 'workspace'; root: string; sourceInstanceId: string; priority?: number }[];
}

export interface SkillCatalog {
  readonly schema: string;
  readonly catalog_scope_id: string;
  readonly catalog_revision: string;
  readonly health: 'healthy' | 'degraded';
  readonly skills: readonly {
    skill_id: string;
    skill_policy_key: string;
    invocation_name: string;
    display_name: string;
    description: string;
    content_revision: string;
    argument_schema: { schema: string; max_values: number; names: string[] };
    source: { provider_id: string; source_scope: 'user' | 'workspace'; source_instance_id: string; contribution_id: string };
  }[];
  readonly issues: readonly Record<string, unknown>[];
}

export class Runtime {
  applyMcpConfiguration(config: { desiredRevision: number | bigint; servers: readonly McpServer[] }):
    Promise<{ disposition: 'applied' | 'superseded' | 'rejected'; desiredRevision: bigint; activeRevision: bigint; catalogGeneration: bigint }>;
  refreshMcp(): Promise<bigint>;
  describeMcp(): Promise<McpCatalog>;
  constructor(options?: RuntimeOptions);
  readonly tools: string[];
  readonly hostTools: Tool<any>[];
  resolveWorkspaceSkillCatalog(query?: SkillCatalogQuery): SkillCatalog;
  releaseCatalog(catalog: SkillCatalog): void;
  session(model: string, options?: SessionOptions): Session;
  restoreSession(directory: string, options?: Omit<SessionOptions, 'promptProfile'>): Promise<Session>;
  close(): void;
}

export function candidateLibraryPaths(explicit?: string): string[];
