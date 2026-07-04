//! Named-module re-export root for the PR review-thread tests (Phase 2). Rooted
//! at `src/` so it can reach `git/parser.zig`, `rendering/`, and `pr/` across
//! directory boundaries — a `src/testing/`-rooted test file cannot import these
//! directly. Imported *by name* ("review_test_root") into
//! `testing/review_test_helpers.zig`, which mirrors the `approval_test_root`
//! pattern: a named import does NOT drag the imported modules' own `test {}`
//! blocks into the test binary, so only the helper's tests run.

pub const thread_anchor = @import("pr/thread_anchor.zig");
pub const review_parse = @import("pr/review_parse.zig");
pub const parser = @import("git/parser.zig");
pub const line_map = @import("line_map.zig");
pub const comments = @import("comments/store.zig");
pub const thread_block = @import("rendering/thread_block.zig");
pub const harness = @import("testing/harness.zig");
pub const snapshot = @import("testing/snapshot.zig");

pub const AnchoredThread = thread_anchor.AnchoredThread;
pub const Placement = thread_anchor.Placement;
pub const BucketReason = thread_anchor.BucketReason;
pub const anchorThreads = thread_anchor.anchorThreads;
pub const countUnplaced = thread_anchor.countUnplaced;
pub const deriveGithubCoords = thread_anchor.deriveGithubCoords;
pub const GithubCoords = thread_anchor.GithubCoords;

pub const ReviewThread = review_parse.ReviewThread;
pub const ReviewComment = review_parse.ReviewComment;
pub const ReviewState = review_parse.ReviewState;
pub const Side = review_parse.Side;
pub const SubjectType = review_parse.SubjectType;

pub const FileDiff = parser.FileDiff;
pub const Hunk = parser.Hunk;
pub const HunkHeader = parser.HunkHeader;
pub const Line = parser.Line;
