//! Pure placement types for anchored GitHub review threads. Deliberately free
//! of any `git/parser.zig` dependency so modules compiled under the `src/pr/`
//! module root (e.g. `review_controller.zig` via the pr test target) can hold
//! anchored results without pulling in a cross-module-path import. The anchoring
//! *algorithm* — which does need the parsed diff — lives in `thread_anchor.zig`.

pub const BucketReason = enum { outdated, out_of_context, file_level };

pub const Placement = union(enum) {
    inline_line: struct { file_idx: usize, hunk_idx: usize, line_idx: usize },
    file_bucket: struct { file_idx: usize, reason: BucketReason },
    unplaced, // path not present in the diff at all
};

pub const AnchoredThread = struct {
    thread_idx: usize,
    placement: Placement,
};

/// Count of `.unplaced` placements (path not in the diff) — surfaced in the
/// status bar / info panel so nothing is silently dropped (AD-9 spirit).
pub fn countUnplaced(anchored: []const AnchoredThread) usize {
    var count: usize = 0;
    for (anchored) |a| {
        if (a.placement == .unplaced) count += 1;
    }
    return count;
}
