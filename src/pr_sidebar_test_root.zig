//! Named-module re-export root for the PR sidebar tests (Phase 6a). Rooted at
//! `src/` so the helpers in `testing/sidebar_test_helpers.zig` can reach
//! `pr/`, `rendering/` and `app.zig` across directory boundaries. Imported by
//! name ("pr_sidebar_test_root"), so the re-exported files' own `test {}`
//! blocks stay out of the `sidebar_tests` binary (see review_test_root.zig).

pub const sidebar_state = @import("pr/sidebar/state.zig");
pub const sidebar_controller = @import("pr/sidebar/controller.zig");
pub const sidebar_render = @import("pr/sidebar/render.zig");
pub const sidebar_layout = @import("pr/sidebar/layout.zig");
pub const types = @import("pr/db/types.zig");
pub const config = @import("config.zig");
pub const filter_query = @import("pr/filter_query.zig");
pub const stack = @import("pr/stack.zig");
pub const surface = @import("pr/surface.zig");
pub const store = @import("pr/db/store.zig");
pub const github = @import("pr/github.zig");
pub const harness = @import("testing/harness.zig");
pub const snapshot = @import("testing/snapshot.zig");

pub const App = @import("app.zig").App;
pub const frame = @import("rendering/frame.zig");
pub const help = @import("help.zig");
pub const parser = @import("git/parser.zig");
pub const bench_support = @import("testing/bench_support.zig");
pub const TabManager = @import("agent/tab_manager.zig").TabManager;
