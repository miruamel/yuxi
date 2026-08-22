const std = @import("std");
const types = @import("types");

/// Commit a generated file into an isolated git repository inside `ctx.workdir`,
/// so a Yuxi run yields a self-contained, versioned artifact directory instead of
/// polluting the engine's own repository. Best-effort: if `git` is unavailable the
/// checkpoint is skipped rather than failing the pipeline.
pub fn run(ctx: *types.Ctx, path: []const u8) !bool {
    const wd = ctx.workdir;
    // Spawn git through a real-allocator Threaded io. `ctx.io` is the global
    // single-threaded Io whose allocator is `.failing` (init_single_threaded),
    // so `std.process.run` OOMs on the child argv/env arena (the same trap as
    // `evaluator.runTo`). A per-call Threaded io backed by `ctx.allocator`
    // with the real OS environ lets git spawn cleanly and report its verdict.
    // The spawn environment is the process environ, not `ctx.environ` (which
    // tests set to `.empty`), so git still resolves PATH/HOME.
    var threaded = std.Io.Threaded.init(ctx.allocator, .{ .environ = std.Io.Threaded.global_single_threaded.environ.process_environ });
    defer threaded.deinit();
    const io = threaded.io();
    // Best-effort repo init: a Yuxi run yields a self-contained, versioned
    // artifact directory. If git is unavailable the checkpoint can't exist, so
    // report `false` (no deploy) rather than pretending success — an honest
    // signal matters more than a clean exit here (§30 autonomy-health).
    const init_res = std.process.run(ctx.allocator, io, .{ .argv = &[_][]const u8{ "git", "-C", wd, "init" } }) catch |e| {
        ctx.log("[deploy] git unavailable ({s}); no checkpoint", .{@errorName(e)});
        return false;
    };
    defer ctx.allocator.free(init_res.stdout);
    defer ctx.allocator.free(init_res.stderr);
    if (!succeeded(init_res.term)) {
        const err = std.mem.trim(u8, init_res.stderr, &std.ascii.whitespace);
        ctx.log("[deploy] git init failed (term={s}): {s}; no checkpoint", .{ @tagName(init_res.term), err });
        return false;
    }

    const base = std.fs.path.basename(path);
    const add_res = std.process.run(ctx.allocator, io, .{ .argv = &[_][]const u8{ "git", "-C", wd, "add", base } }) catch |e| {
        ctx.log("[deploy] git add failed: {s}", .{@errorName(e)});
        return false;
    };
    defer ctx.allocator.free(add_res.stdout);
    defer ctx.allocator.free(add_res.stderr);
    if (!succeeded(add_res.term)) {
        const err = std.mem.trim(u8, add_res.stderr, &std.ascii.whitespace);
        ctx.log("[deploy] git add exited {s}: {s}; no checkpoint", .{ @tagName(add_res.term), err });
        return false;
    }

    const msg = try std.fmt.allocPrint(ctx.allocator, "yuxi: stable change ({s})", .{path});
    defer ctx.allocator.free(msg);
    const commit = [_][]const u8{ "git", "-C", wd, "-c", "user.name=Yuxi Engine", "-c", "user.email=yuxi@localhost", "commit", "-m", msg };
    const res = std.process.run(ctx.allocator, io, .{ .argv = &commit }) catch |e| {
        ctx.log("[deploy] commit skipped: {s}", .{@errorName(e)});
        return false;
    };
    defer ctx.allocator.free(res.stdout);
    defer ctx.allocator.free(res.stderr);
    if (!succeeded(res.term)) {
        // A non-zero commit means no checkpoint was created. An unchanged
        // artifact ("nothing to commit") is already checkpointed from a prior
        // run, so treat it as a successful (idempotent) deploy and keep
        // re-runs in the same workdir green. Any other commit error is a real
        // failure: surface the reason and report no checkpoint.
        // git prints "nothing to commit, working tree clean" to STDOUT (stderr
        // is empty) when there is nothing to stage, so scan both streams.
        // Also handles "nothing added to commit but untracked files present"
        // when fragment files exist but the main artifact is already committed.
        const out = std.mem.trim(u8, res.stdout, &std.ascii.whitespace);
        const err = std.mem.trim(u8, res.stderr, &std.ascii.whitespace);
        if (std.mem.indexOf(u8, out, "nothing to commit") != null or
            std.mem.indexOf(u8, out, "nothing added to commit") != null or
            std.mem.indexOf(u8, err, "nothing to commit") != null or
            std.mem.indexOf(u8, err, "nothing added to commit") != null)
        {
            ctx.log("[deploy] artifact unchanged; already checkpointed", .{});
            return true;
        }
        ctx.log("[deploy] commit failed (term={s}): {s}", .{ @tagName(res.term), err });
        return false;
    }
    ctx.log("[deploy] committed {s}", .{base});
    ctx.record("deploy: committed");
    return true;
}

/// True iff the spawned git command exited zero. Any other term means the
/// operation did not take effect, so the caller must not count it as done.
fn succeeded(term: std.process.Child.Term) bool {
    return term == .exited and term.exited == 0;
}
