//! Session discovery for ACP agents
//!
//! This module provides file-based session discovery for Claude Code and Codex.
//! It reads session history from each agent's storage location and provides
//! a unified interface for listing and loading sessions.
//!
//! ## Supported Agents
//! - **Claude Code**: `~/.claude/history.jsonl` + `~/.claude/projects/`
//! - **Codex**: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
//!
//! ## Usage
//! ```zig
//! const sessions = @import("acp/sessions.zig");
//!
//! // List sessions for current project
//! const list = try sessions.listSessions(allocator, .claude_code, cwd, 20);
//! defer sessions.freeSessions(allocator, list);
//!
//! for (list) |session| {
//!     var buf: [32]u8 = undefined;
//!     const time_str = session.formatRelativeTime(&buf);
//!     std.debug.print("{s}: {s}\n", .{ time_str, session.display });
//! }
//! ```

// Re-export types
pub const types = @import("sessions/types.zig");
pub const SessionInfo = types.SessionInfo;
pub const AgentType = types.AgentType;
pub const SessionDiscoveryError = types.SessionDiscoveryError;

// Re-export discovery functions
pub const discovery = @import("sessions/discovery.zig");
pub const listSessions = discovery.listSessions;
pub const listAllSessions = discovery.listAllSessions;
pub const freeSessions = discovery.freeSessions;
pub const DEFAULT_LIMIT = discovery.DEFAULT_LIMIT;

// Re-export adapters for direct access if needed
pub const claude_adapter = @import("sessions/claude_adapter.zig");
pub const codex_adapter = @import("sessions/codex_adapter.zig");

// Re-export history parser for session resume fallback
pub const history_parser = @import("sessions/history_parser.zig");
pub const HistoryMessage = history_parser.HistoryMessage;
pub const parseClaudeSession = history_parser.parseClaudeSession;
pub const parseCodexSession = history_parser.parseCodexSession;
pub const freeMessages = history_parser.freeMessages;

// =============================================================================
// Tests
// =============================================================================

test {
    // Run all sub-module tests
    _ = types;
    _ = discovery;
    _ = claude_adapter;
    _ = codex_adapter;
    _ = history_parser;
}
