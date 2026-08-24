//! Production-code root for the session-replay tests in
//! `src/testing/session_replay_scenarios.zig`. Rooted at `src/` so the parser
//! can reach `../agent/state.zig`.

pub const acp_session_replay = @import("acp/session_replay.zig");

pub const AgentState = @import("agent/state.zig").AgentState;
pub const AgentMessage = @import("agent/state.zig").Message;
pub const AcpManager = @import("acp/manager.zig").AcpManager;
