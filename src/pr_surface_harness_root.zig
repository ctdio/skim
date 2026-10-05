//! Named-module re-export root for the offline PR surface harness
//! (`src/testing/pr_surface_harness.zig`, Phase 6a; 6b appends `flip`,
//! `notes`, `prefetch`, `priority`). Rooted at `src/` so the harness, which
//! lives in `src/testing/`, can reach `app.zig` and `pr/` across directory
//! boundaries. Imported by name ("pr_surface_harness_root"), mirroring
//! `review_test_root.zig`.

pub const App = @import("app.zig").App;
pub const store = @import("pr/db/store.zig");
pub const types = @import("pr/db/types.zig");
pub const sync = @import("pr/sync/sync.zig");
pub const surface = @import("pr/surface.zig");
pub const sidebar_state = @import("pr/sidebar/state.zig");
pub const sidebar_controller = @import("pr/sidebar/controller.zig");
pub const sidebar_layout = @import("pr/sidebar/layout.zig");
pub const sidebar_render = @import("pr/sidebar/render.zig");
pub const config = @import("config.zig");
pub const parser = @import("git/parser.zig");
pub const review_controller = @import("pr/review_controller.zig");
pub const comments = @import("comments/store.zig");
pub const github = @import("pr/github.zig");
