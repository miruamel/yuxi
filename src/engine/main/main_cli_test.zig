const std = @import("std");
const mainmod = @import("mainmod");
const monitoring = @import("monitoring");
const fs = @import("fs");

test "main --version prints the build stamp and exits zero" {
    // The version comes from git describe at build time; a gate or operator
    // can read `yuxi vX.Y.Z-...` from stdout. Assert the exact prefix so the
    // contract (not just a non-empty line) is locked.
    const a = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(a, .{ .environ = std.Io.Threaded.global_single_threaded.environ.process_environ });
    const bin = "zig-out/bin/yuxi";
    const ver = try std.process.run(a, threaded.io(), .{ .argv = &[_][]const u8{ bin, "--version" } });
    defer a.free(ver.stdout);
    defer a.free(ver.stderr);
    try std.testing.expect(ver.term == .exited and ver.term.exited == 0);
    // stdout has a trailing newline from logLine; trim it before matching.
    const out = std.mem.trim(u8, ver.stdout, "\r\n");
    try std.testing.expect(std.mem.startsWith(u8, out, "yuxi v"));
}

test "main --kb-stats prints a ledger summary and exits zero" {
    // Regression: the --kb-stats read-only inspector (main.zig:30-33) was
    // reachable only via manual invocation — no test covered either of its two
    // paths. The pure core (knowledge.summarize) was tested, but printStats'
    // logLine formatting and the no-ledger short-circuit were unexercised, so
    // a regression there shipped silently. Both paths are asserted here.
    const a = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(a, .{ .environ = std.Io.Threaded.global_single_threaded.environ.process_environ });
    defer threaded.deinit();
    const io = threaded.io();
    const bin = "zig-out/bin/yuxi";

    // No --kb: short-circuit, exit 0, and the summary line names the gap.
    const none = try std.process.run(a, io, .{ .argv = &[_][]const u8{ bin, "--no-hitl", "--mock", "--kb-stats" } });
    defer a.free(none.stdout);
    defer a.free(none.stderr);
    try std.testing.expect(none.term == .exited and none.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, none.stdout, "no --kb ledger configured; nothing to summarize") != null);

    // With a populated --kb ledger: exit 0 and the category counts are printed.
    const kb = "/tmp/yuxi_kb_stats_cli.md";
    const kb_content =
        \\- add a feature: deployed (steps=1 deploys=1 retries=0 critic_rej=0 mock_fb=0 budget_ex=0 max_steps_ex=0 run_time_ex=0)
        \\- fix a bug: failed (steps=2 deploys=0 retries=1 critic_rej=1 mock_fb=0 budget_ex=0 max_steps_ex=0 run_time_ex=0)
        \\- critic rejected: missing error handling
        \\- health: no deploy; self-correction exhausted; critic_rej=2
        \\- batch: tasks=2 deploys=2 unhealthy=0
        \\- some non-standard note line
    ;
    try fs.writeFileAlloc(a, kb, kb_content);
    defer _ = std.Io.Dir.deleteFile(std.Io.Dir.cwd(), io, kb) catch {};
    const got = try std.process.run(a, io, .{ .argv = &[_][]const u8{ bin, "--no-hitl", "--mock", "--kb-stats", "--kb", kb } });
    defer a.free(got.stdout);
    defer a.free(got.stderr);
    try std.testing.expect(got.term == .exited and got.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "lessons:        6") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "deployed:       1") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "failed:         1") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "critic-rejected:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "health:         1") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "batch:          1") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "other:          1") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "latest: - some non-standard note line") != null);

    // --kb-max-lines cap is echoed back by printStats so an operator can see
    // the bound the inspector applied (knowledge.zig:192). This line had no
    // test; assert it round-trips through the CLI. The bare form `--kb-max-lines`
    // defaults to 200 (same convention as --cache/--report/--record), so use
    // the `=` form to pin the value at 5 rather than asserting on the default.
    const capped = try std.process.run(a, io, .{ .argv = &[_][]const u8{ bin, "--no-hitl", "--mock", "--kb-stats", "--kb-max-lines=5", "--kb", kb } });
    defer a.free(capped.stdout);
    defer a.free(capped.stderr);
    try std.testing.expect(capped.term == .exited and capped.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, capped.stdout, "cap (--kb-max-lines): 5") != null);
}

test "main --expect gates deploy end-to-end via the CLI flag" {
    // Regression guard (§21): the --expect behavioral-verification flag must
    // work through the real CLI path (main -> config.parse -> engine.newCtx ->
    // evaluator.run), not just the evaluator unit test. The mock backend emits
    // `step result: 2+3=5`, so a matching expectation verifies successfully
    // (deploy, exit 0) while a wrong expectation fails self-correction and the
    // run exits 1 (the §30 unhealthy-verdict contract).
    const a = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(a, .{ .environ = std.Io.Threaded.global_single_threaded.environ.process_environ });
    defer threaded.deinit();
    const bin = "zig-out/bin/yuxi";
    // Isolated workdir: deploy.run `git init`-commits into it, so a pre-existing
    // `ae_out/` (left by the selfcorr engine test in this same binary, or a
    // prior CI run) would make the commit collide and the run exit non-zero. A
    // dedicated dir keeps the CLI test hermetic regardless of ordering.
    const wd = "/tmp/yuxi_expect_cli";
    const io = threaded.io();
    std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, wd) catch |e| if (e != error.FileNotFound) return e;
    // The engine writes gen_*.zig into workdir but does not create it; it must
    // pre-exist (deploy.run's ensureDir runs after the builder writes). Mirror
    // a real operator's checkout by creating it first so the run can deploy.
    try fs.ensureDir(a, wd);

    // Matching expectation -> verified deploy -> exit 0.
    const ok = try std.process.run(a, io, .{ .argv = &[_][]const u8{ bin, "--no-hitl", "--mock", "--out", wd, "--expect", "step result: 2+3=5", "add a calculator" } });
    defer a.free(ok.stdout);
    defer a.free(ok.stderr);
    try std.testing.expect(ok.term == .exited and ok.term.exited == 0);

    // Mismatching expectation -> eval error fed back, retries exhausted, no
    // deploy -> unhealthy verdict -> exit 1 (mock output is deterministic, so a
    // wrong --expect can never be satisfied).
    const bad = try std.process.run(a, io, .{ .argv = &[_][]const u8{ bin, "--no-hitl", "--mock", "--out", wd, "--expect", "nope", "add a calculator" } });
    defer a.free(bad.stdout);
    defer a.free(bad.stderr);
    try std.testing.expect(bad.term == .exited and bad.term.exited == 1);

    std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, wd) catch |e| if (e != error.FileNotFound) return e;
}
