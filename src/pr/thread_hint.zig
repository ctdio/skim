//! Status-bar hint for the cursor's relationship to a review thread (FR-5). The
//! decision — which keys to advertise — is a pure function so it is unit- and
//! snapshot-testable without constructing an `App`. The `e:edit` / `d:delete`
//! keys are dropped when the viewer owns no comment in the thread (those actions
//! would refuse), matching the plan's `review_status_thread_hints_not_mine`.

const std = @import("std");

pub const ThreadHint = enum {
    /// Cursor is not on a thread and no delete is pending — show nothing.
    none,
    /// The two-step delete confirmation is armed.
    delete_confirm,
    /// On a thread the viewer has a comment in (reply/resolve/edit/delete/fold).
    full,
    /// On a thread the viewer does NOT own a comment in (no edit/delete keys).
    reply_only,
};

/// Pick the hint for the current cursor/session state. `delete_confirm` wins over
/// everything (a destructive action is pending); otherwise the thread hints show
/// only while the cursor sits on a thread record.
pub fn threadHint(params: struct { delete_confirm: bool, on_thread: bool, owns_comment: bool }) ThreadHint {
    if (params.delete_confirm) return .delete_confirm;
    if (!params.on_thread) return .none;
    return if (params.owns_comment) .full else .reply_only;
}

/// The status-bar text for `hint` (empty string for `.none`). `thread_resolved`
/// flips the `x` label to `unresolve`, matching what `startToggleResolve` fires
/// on an already-resolved thread (otherwise the advertised action contradicts it).
pub fn hintText(hint: ThreadHint, thread_resolved: bool) []const u8 {
    return switch (hint) {
        .none => "",
        .delete_confirm => " │ delete your comment? d again to confirm",
        .full => if (thread_resolved)
            " │ ↵reply  x:unresolve  e:edit  d:delete  o:fold"
        else
            " │ ↵reply  x:resolve  e:edit  d:delete  o:fold",
        .reply_only => if (thread_resolved)
            " │ ↵reply  x:unresolve  o:fold"
        else
            " │ ↵reply  x:resolve  o:fold",
    };
}
