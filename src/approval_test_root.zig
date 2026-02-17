pub const render = @import("agent/render.zig");
pub const codex_manager = @import("codex/manager.zig");
pub const codex_protocol = @import("codex/protocol.zig");

pub const CodexManager = codex_manager.CodexManager;
pub const UserInputOption = codex_protocol.UserInputOption;
pub const UserInputQuestion = CodexManager.UserInputQuestion;
pub const CommandDecision = CodexManager.CommandDecision;
pub const FileChangeDecision = CodexManager.FileChangeDecision;

pub const renderCommandApproval = render.renderCommandApproval;
pub const renderFileChangeApproval = render.renderFileChangeApproval;
pub const renderUserInputApproval = render.renderUserInputApproval;
