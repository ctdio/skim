//! CLI subcommands for skim.
//!
//! These commands communicate with running TUI instances via TCP.

pub const sessions = @import("sessions.zig");
pub const context = @import("context.zig");
pub const comment = @import("comment.zig");
pub const client = @import("client.zig");
