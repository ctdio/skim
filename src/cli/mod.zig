//! CLI subcommands for skim.
//!
//! These commands communicate with running TUI instances via TCP.

pub const session = @import("session.zig");
pub const client = @import("client.zig");
pub const debug = @import("debug.zig");
pub const print = @import("print.zig");

// Legacy exports (deprecated, use `skim session` instead)
pub const sessions = @import("sessions.zig");
pub const context = @import("context.zig");
pub const comment = @import("comment.zig");
