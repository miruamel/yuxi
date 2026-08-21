const std = @import("std");
const types = @import("types");
const replay = @import("replay");
const http = @import("http");

/// Single LLM entry point. Dispatches on Ctx.backend.
pub fn complete(allocator: std.mem.Allocator, io: std.Io, ctx: *types.Ctx, system: []const u8, user: []const u8) ![]u8 {

    // Injected backend seam: when set, fully replace the built-in dispatch
    // (used by tests to script backend behavior without network/curl).
    if (ctx.llm_fn) |f| {
        ctx.tokens += user.len / 4 + system.len / 8 + 16;
        return f(allocator, io, ctx, system, user);
    }
    // Offline replay: serve recorded responses for the network backends so the
    // real .openai/.local path is exercisable without an API key (CI, tests).
    if (ctx.replay_path) |rp| {
        if (ctx.backend == .openai or ctx.backend == .local) {
            // Offline replay serves recorded responses so the real network
            // backend path runs without an API key (CI, tests). If the run
            // needs more LLM calls than the transcript recorded (a retried
            // attempt, a regenerated step, a longer plan), running past the
            // last entry used to hard-fail the whole offline run. Instead we
            // degrade to the deterministic mock for the remaining calls — the
            // same resilience philosophy as the circuit breaker — while still
            // logging the gap so a genuinely misconfigured (empty) replay is
            // visible. A fully empty transcript still serves nothing and the
            // mock then drives the run, which is the intended offline fallback.
            if (replay.replayComplete(allocator, ctx, rp)) |out| {
                return out;
            } else |err| switch (err) {
                error.ReplayExhausted => {
                    ctx.mock_fallbacks += 1;
                    ctx.log("[transport] replay exhausted; falling back to mock for remaining calls", .{});
                    return mockComplete(allocator, system, user);
                },
                else => return err,
            }
        }
    }
    if (ctx.cache) |c| {
        if (c.get(allocator, @tagName(ctx.backend), system, user) catch null) |hit| {
            return hit;
        }
    }
    ctx.tokens += user.len / 4 + system.len / 8 + 16;
    const resp = switch (ctx.backend) {
        .mock => try mockComplete(allocator, system, user),
        .openai, .local => try http.complete(allocator, io, ctx, system, user),
    };
    if (ctx.cache) |c| {
        c.put(allocator, @tagName(ctx.backend), system, user, resp) catch {};
    }
    // Offline record mode (--record): capture every real (non-seam, non-replay)
    // completion into Ctx.recorded so engine.run can flush it as a
    // --replay-compatible transcript (delimited by `---` lines). Seam/replay/
    // cache-hit paths return above without reaching here, matching the
    // "real completion" contract.
    if (ctx.record_path) |_| {
        const dup = allocator.dupe(u8, resp) catch null;
        if (dup) |d| ctx.recorded.append(allocator, d) catch {};
    }
    return resp;
}

fn mockComplete(allocator: std.mem.Allocator, system: []const u8, user: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, system, "decomposer") != null) {
        return allocator.dupe(u8,
            \\STEP: design the function signature
            \\STEP: implement the body
            \\STEP: add a unit test
        );
    }
    if (std.mem.indexOf(u8, system, "code generator") != null) {
        // The builder passes "Implement step N: <name>", so name the function
        // uniquely per step; the engine composes all steps into one binary.
        // The mock orchestrator emits a fixed 3-step plan whose final step is
        // "add a unit test"; only that step emits output, mirroring how a real
        // decomposition's run/verify step is the sole printer. This keeps the
        // composed binary's stdout single-line so `--expect` verification
        // matches deterministically instead of triplicating the line.
        var n: usize = 0;
        var emit = true;
        if (std.mem.indexOf(u8, user, "Implement step ")) |p| {
            const rest = user[p + "Implement step ".len ..];
            if (std.mem.indexOfScalar(u8, rest, ':')) |c| {
                n = std.fmt.parseUnsigned(usize, rest[0..c], 10) catch 0;
                const name = std.mem.trim(u8, rest[c + 1 ..], " ");
                emit = std.mem.indexOf(u8, name, "test") != null;
            }
        }
        if (emit) {
            return std.fmt.allocPrint(allocator,
                \\pub fn step{d}() void {{
                \\    const a: i32 = 2;
                \\    const b: i32 = 3;
                \\    const sum = a + b;
                \\    std.debug.print("step result: 2+3={{d}}\n", .{{sum}});
                \\}}
            , .{n});
        }
        return std.fmt.allocPrint(allocator,
            \\pub fn step{d}() void {{
            \\    const a: i32 = 2;
            \\    const b: i32 = 3;
            \\    _ = a + b;
            \\}}
        , .{n});
    }
    if (std.mem.indexOf(u8, system, "critic") != null) {
        return allocator.dupe(u8, "APPROVE");
    }
    return allocator.dupe(u8, user);
}
