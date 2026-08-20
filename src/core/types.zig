const std = @import("std");
const cache_mod = @import("cache");

pub const Mode = enum { hitl, no_hitl };
pub const LlmBackend = enum { mock, openai, local };

pub const Status = enum { pending, ok, rejected, failed };

pub const Step = struct {
    id: usize,
    name: []const u8,
    status: Status,
    notes: []const u8,
};

pub const Ctx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    mode: Mode,
    backend: LlmBackend,
    llm_key: ?[]const u8,
    llm_base: []const u8,
    workdir: []const u8,
    tokens: usize,
    max_tokens: ?usize,
    max_steps: ?usize = null,
    cache: ?*cache_mod.Cache,
    eval_error: ?[]const u8,
    /// Optional caller-supplied expected stdout (trimmed) for behavioral
    /// verification. Borrowed: must outlive the run. When set, the evaluator
    /// rejects a clean run whose output doesn't match, feeding the mismatch
    /// back through the self-correction loop.
    expected: ?[]const u8,
    /// Optional injected LLM completion backend. When set, transport.complete
    /// dispatches here instead of the built-in mock/http — used by tests to
    /// script backend behavior (e.g. fail-then-succeed) without network.
    llm_fn: ?LlmFn,
    /// Optional path to a persisted knowledge base. When set, the engine
    /// records a per-run lesson here and the orchestrator prepends prior
    /// lessons to its decomposition prompt. Null (and a no-op) by default.
    kb_path: ?[]const u8 = null,
    /// Optional recorded-LLM-response file for offline playback. When set and
    /// the backend is `.openai`/`.local`, transport.complete serves recorded
    /// responses in order instead of calling the network — so the real backend
    /// path is exercisable without an API key (CI, tests). Null by default.
    replay_path: ?[]const u8 = null,
    /// Position into the replay file (next entry to serve). Offline-only state.
    replay_idx: usize = 0,
    /// Optional path to write recorded LLM responses. When set, each real
    /// (non-seam, non-replay) completion is captured into `recorded` and flushed
    /// to this file at the end of engine.run, producing a `--replay`-compatible
    /// transcript (entries delimited by a line that is exactly `---`). Null by
    /// default.
    record_path: ?[]const u8 = null,
    /// Optional cap on how many prior lessons `injectPrompt` prepends to the
    /// decomposition prompt. Bounds KB growth: without it the full ledger is
    /// loaded into every run, so a long-lived engine's prompts bloat
    /// unbounded. Null (no cap) by default — matches historical behavior and
    /// keeps opt-in tests/existing pipelines unchanged.
    kb_max_lines: ?usize = null,
    /// Captured responses for the current run, flushed to `record_path` on exit.
    recorded: std.ArrayList([]const u8),
    failures: usize,
    critic_rejections: usize,
    mock_fallbacks: usize,
    retries: usize,
    deploys: usize,
    /// Set when the orchestrator aborts a run because the decomposed plan
    /// exceeded `--max-steps`. Distinct from `critic_rejections`: the plan was
    /// too large to safely build autonomously, not malformed. Surfaced as its
    /// own health-verdict clause so a deliberate fail-closed safety cap is not
    /// misread as a generic unhealthy cycle.
    max_steps_exceeded: usize = 0,
    /// Set when the build aborts because the accumulated token spend crossed
    /// `--max-tokens`. Distinct from a generic failed build (which leaves this
    /// at 0); surfaced as its own health-verdict clause.
    token_budgets_exceeded: usize = 0,
    network_retries: usize,
    events: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, mode: Mode, backend: LlmBackend, key: ?[]const u8, base: []const u8, workdir: []const u8) !Ctx {
        return .{
            .allocator = allocator,
            .io = io,
            .environ = environ,
            .mode = mode,
            .backend = backend,
            .llm_key = key,
            .llm_base = base,
            .workdir = workdir,
            .tokens = 0,
            .max_tokens = null,
            .cache = null,
            .eval_error = null,
            .failures = 0,
            .critic_rejections = 0,
            .mock_fallbacks = 0,
            .retries = 0,
            .deploys = 0,
            .max_steps_exceeded = 0,
            .token_budgets_exceeded = 0,
            .network_retries = 0,
            .expected = null,
            .llm_fn = null,
            .recorded = try std.ArrayList([]const u8).initCapacity(allocator, 0),
            .events = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    pub fn record(self: *Ctx, msg: []const u8) void {
        const owned = self.allocator.dupe(u8, msg) catch return;
        self.events.append(self.allocator, owned) catch {};
    }
    pub fn setEvalError(self: *Ctx, msg: []const u8) void {
        if (self.eval_error) |old| self.allocator.free(old);
        self.eval_error = self.allocator.dupe(u8, msg) catch null;
    }
    pub fn clearEvalError(self: *Ctx) void {
        if (self.eval_error) |old| self.allocator.free(old);
        self.eval_error = null;
    }

    pub fn log(self: *Ctx, comptime fmt: []const u8, args: anytype) void {
        logLine(self.io, fmt, args);
    }
};

/// Injectable LLM completion backend signature. Matches transport.complete's
/// call shape so a test (or future real backend) can replace the built-in
/// mock/http dispatch via Ctx.llm_fn.
pub const LlmFn = *const fn (std.mem.Allocator, std.Io, *Ctx, []const u8, []const u8) anyerror![]u8;

pub fn logLine(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.writeAll("\n") catch {};
    w.flush() catch {};
}
