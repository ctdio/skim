//! Named-module re-export root for the web (wasm) build. Rooted at `src/` so
//! `web/` files can reach `app.zig`, `git/`, `rendering/`, and `testing/` across
//! directory boundaries — a `src/web/`-rooted module cannot import those
//! directly.
//!
//! Imported *by name* ("web_core") into `web/session.zig`, mirroring the
//! `review_test_root` pattern: a named import does NOT drag the imported
//! modules' own `test {}` blocks into the web test binary, so only the web
//! files' tests run there.
//!
//! Both `zig build web` and the `web_tests` step wire this module in.

pub const App = @import("app.zig").App;
pub const parser = @import("git/parser.zig");
pub const harness = @import("testing/harness.zig");
pub const UnifiedRenderer = @import("rendering/unified.zig").UnifiedRenderer;
pub const SideBySideRenderer = @import("rendering/side_by_side.zig").SideBySideRenderer;
pub const SyntaxHighlighter = @import("highlighting/core.zig").SyntaxHighlighter;
pub const Language = @import("highlighting/core.zig").Language;
pub const StateHelpers = @import("state.zig").StateHelpers;
pub const Navigation = @import("navigation.zig").Navigation;
pub const folds = @import("folds.zig");
pub const hunk_view = @import("hunk_view.zig");
pub const Layout = @import("rendering/common.zig").Layout;
pub const UI = @import("ui.zig").UI;
pub const help = @import("help.zig");
pub const search_mode = @import("modes/search_mode.zig");
pub const visual_mode = @import("modes/visual_mode.zig");
pub const help_mode = @import("modes/help_mode.zig");
pub const command_palette_mode = @import("modes/command_palette_mode.zig");
pub const command_palette = @import("command_palette.zig");
pub const CommentController = @import("comments/controller.zig").CommentController;
pub const CommentEditor = @import("comments/editor.zig").CommentEditor;
