const std = @import("std");

// Test entry point for `zig build test`.
//
// Importing these modules compiles them and pulls their `test` blocks into the
// suite, so the cache, the evaluator deploy-gate, and engine composition are
// all exercised without duplicating test code in this file.
const _cache = @import("util/cache.zig");
const _evaluator = @import("evaluator/evaluator.zig");
const _engine = @import("core/engine.zig");

const _transport = @import("llm/transport.zig");
const _monitoring = @import("monitoring/monitoring_test.zig");
const _selfcorr = @import("core/selfcorr_test.zig");
