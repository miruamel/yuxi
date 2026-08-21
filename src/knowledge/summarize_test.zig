const std = @import("std");
const knowledge = @import("knowledge");

test "knowledge summarize categorizes ledger lines correctly" {
    // `summarize` is the pure core of `--kb-stats`; it must bucket every line
    // shape `knowledge` writes without double-counting or dropping any.
    const content =
        \\- design a feature: deployed (steps=3 retries=0) critic_rej=0 ...
        \\- fix a bug: failed (steps=2 retries=1) critic_rej=1 ...
        \\- critic rejected: missing error handling
        \\- health: no deploy; self-correction exhausted; critic_rej=2
        \\- batch: tasks=2 deploys=2 unhealthy=0
        \\- some non-standard note line
    ;
    const s = knowledge.summarize(content);
    try std.testing.expectEqual(@as(usize, 6), s.total);
    try std.testing.expectEqual(@as(usize, 1), s.deployed);
    try std.testing.expectEqual(@as(usize, 1), s.failed);
    try std.testing.expectEqual(@as(usize, 1), s.critic);
    try std.testing.expectEqual(@as(usize, 1), s.health);
    try std.testing.expectEqual(@as(usize, 1), s.batch);
    try std.testing.expectEqual(@as(usize, 1), s.other);
    // latest borrows the final non-empty line.
    try std.testing.expectEqualStrings("- some non-standard note line", s.latest);
}

test "knowledge summarize handles empty content" {
    const s = knowledge.summarize("");
    try std.testing.expectEqual(@as(usize, 0), s.total);
    try std.testing.expectEqual(@as(usize, 0), s.deployed);
    try std.testing.expectEqual(@as(usize, 0), s.other);
    try std.testing.expectEqual(@as(usize, 0), s.latest.len);
}
