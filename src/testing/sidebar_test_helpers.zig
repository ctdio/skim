//! Tests for the PR sidebar (Phase 6a): controller logic on in-memory
//! snapshots, and sidebar snapshots. Reaches production code through the
//! `pr_sidebar_test_root` named module (see `src/pr_sidebar_test_root.zig`), so
//! only this file's `test {}` blocks run in the `sidebar_tests` binary. No
//! DB: every fixture is a `types.RecordList` built the way `store.listOpen`
//! hands one over.

const std = @import("std");
const skim_io = @import("skim_io");
const vaxis = @import("vaxis");
const root = @import("pr_sidebar_test_root");

const types = root.types;
const config = root.config;
const controller = root.sidebar_controller;
const sidebar_render = root.sidebar_render;
const harness = root.harness;
const snapshot = root.snapshot;
const surface = root.surface;

const Allocator = std.mem.Allocator;
const SidebarState = root.sidebar_state.SidebarState;
const SyncSnapshot = root.sidebar_state.SyncSnapshot;
const PrRecord = types.PrRecord;
const CiStatus = @FieldType(PrRecord, "ci");

const testing = std.testing;
const Key = vaxis.Key;

const RecSpec = struct {
    number: u32,
    title: []const u8 = "t",
    author: []const u8 = "alice",
    head: []const u8,
    base: []const u8 = "main",
    head_oid: []const u8 = head_oid,
    draft: bool = false,
    ci: CiStatus = .none,
    review_decision: []const u8 = "",
    requested_users: []const u8 = "",
    labels: []const u8 = "",
    my_review_state: []const u8 = "",
    my_review_oid: []const u8 = "",
    seen_head_oid: ?[]const u8 = null,
};

const head_oid = "a" ** 40;
const other_oid = "b" ** 40;
const viewer = "me";
/// Fixed clock for view() and snapshots.
const now: i64 = 1_700_000_000;
const recent_sync = SyncSnapshot{ .last_ok_at = now - 120 };

/// Rows of `stacked31` with both stacks collapsed: 2 headers + 26 standalones.
const stacked31_rows = 28;
const stacked31_expanded_rows = 31;
const standalone_count = 26;
const first_standalone: u32 = 750;
/// One added line on `src/x.zig` for the App-backed close test.
const esc_close_diff =
    \\diff --git a/src/x.zig b/src/x.zig
    \\index 1111111..2222222 100644
    \\--- a/src/x.zig
    \\+++ b/src/x.zig
    \\@@ -8,3 +8,4 @@
    \\ line8
    \\ line9
    \\+line10
    \\ line11
    \\
;

const standalone_heads = names("feat-{d}");
const standalone_titles = names("Standalone change {d}");

// =============================================================================
// applySnapshot / row building
// =============================================================================

test "applySnapshot: stacks start collapsed — one header row per multi-PR stack, one member row per standalone" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);

    try testing.expectEqual(@as(usize, stacked31_rows), sb.rows.items.len);
    try testing.expectEqual(root.sidebar_state.RowKind.stack_header, sb.rows.items[0].kind);
    try testing.expectEqual(root.sidebar_state.RowKind.stack_header, sb.rows.items[1].kind);
    for (sb.rows.items[2..]) |row| try testing.expectEqual(root.sidebar_state.RowKind.member, row.kind);
}

test "applySnapshot: header row's record is the stack's review target" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);

    // #812 is approved by the viewer at its head, so the target is #813.
    try testing.expectEqual(@as(u32, 813), rowNumber(&sb, 0));
    try testing.expectEqual(@as(u32, 790), rowNumber(&sb, 1));
}

test "toggleExpand: expanding a header inserts members tip-first after it" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);

    try controller.toggleExpand(&sb, testing.allocator);

    try testing.expectEqual(@as(usize, stacked31_expanded_rows), sb.rows.items.len);
    try expectRowNumbers(&sb, 1, &.{ 814, 813, 812 });
    try testing.expectEqual(@as(usize, 0), sb.cursor);
}

test "toggleExpand: expanded set is keyed by tip number — survives a re-applied snapshot that reorders stacks" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.toggleExpand(&sb, testing.allocator);

    var reordered = stacked31Specs();
    std.mem.rotate(RecSpec, reordered[0..5], 3);
    try reapply(&sb, &reordered);

    try testing.expectEqual(@as(u32, 790), rowNumber(&sb, 0));
    try testing.expectEqual(@as(u32, 813), rowNumber(&sb, 1));
    try expectRowNumbers(&sb, 2, &.{ 814, 813, 812 });
    try testing.expectEqual(@as(usize, stacked31_expanded_rows), sb.rows.items.len);
}

test "toggleExpand: on a standalone row is a no-op" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    controller.move(&sb, 2);

    try controller.toggleExpand(&sb, testing.allocator);

    try testing.expectEqual(@as(usize, stacked31_rows), sb.rows.items.len);
    try testing.expectEqual(@as(?u32, first_standalone), sb.selected_number);
}

// =============================================================================
// Navigation
// =============================================================================

test "move: j over a collapsed stack moves to the next stack" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);

    controller.move(&sb, 1);

    try testing.expectEqual(@as(?u32, 790), sb.selected_number);
}

test "move: j inside an expanded stack moves member by member" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.toggleExpand(&sb, testing.allocator);

    controller.move(&sb, 1);
    try testing.expectEqual(@as(?u32, 814), sb.selected_number);
    controller.move(&sb, 1);
    try testing.expectEqual(@as(?u32, 813), sb.selected_number);
    try testing.expect(!sb.cursor_on_header);
}

test "move: clamps at top and bottom" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);

    controller.move(&sb, -1);
    try testing.expectEqual(@as(usize, 0), sb.cursor);
    controller.move(&sb, 1000);
    try testing.expectEqual(@as(usize, stacked31_rows - 1), sb.cursor);
    controller.move(&sb, 1);
    try testing.expectEqual(@as(?u32, 725), sb.selected_number);
}

test "moveStack: skips expanded members to the next header/standalone" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.toggleExpand(&sb, testing.allocator);

    controller.moveStack(&sb, 1);
    try testing.expectEqual(@as(usize, 4), sb.cursor);
    try testing.expectEqual(@as(?u32, 790), sb.selected_number);
    controller.moveStack(&sb, 1);
    try testing.expectEqual(@as(?u32, first_standalone), sb.selected_number);
    controller.moveStack(&sb, -2);
    try testing.expectEqual(@as(usize, 0), sb.cursor);
}

test "moveWithinStack: J on a collapsed stack expands it and lands on the target member" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);

    try controller.moveWithinStack(&sb, testing.allocator, 1);

    try testing.expectEqual(@as(usize, stacked31_expanded_rows), sb.rows.items.len);
    try testing.expectEqual(@as(usize, 2), sb.cursor);
    try testing.expectEqual(@as(?u32, 813), sb.selected_number);
    try testing.expect(!sb.cursor_on_header);
}

test "moveWithinStack: stops at the stack's last member (does not leave the stack)" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);

    try controller.moveWithinStack(&sb, testing.allocator, 1);
    try controller.moveWithinStack(&sb, testing.allocator, 1);
    try testing.expectEqual(@as(?u32, 812), sb.selected_number);
    try controller.moveWithinStack(&sb, testing.allocator, 1);
    try testing.expectEqual(@as(?u32, 812), sb.selected_number);
    try controller.moveWithinStack(&sb, testing.allocator, -5);
    try testing.expectEqual(@as(?u32, 814), sb.selected_number);
    try testing.expectEqual(@as(usize, 1), sb.cursor);
}

test "moveWithinStack: no-op on a standalone" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    controller.move(&sb, 2);

    try controller.moveWithinStack(&sb, testing.allocator, 1);

    try testing.expectEqual(@as(?u32, first_standalone), sb.selected_number);
    try testing.expectEqual(@as(usize, stacked31_rows), sb.rows.items.len);
}

test "moveToEdge: gg/G land on first/last row" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);

    controller.moveToEdge(&sb, .bottom);
    try testing.expectEqual(@as(?u32, 725), sb.selected_number);
    controller.moveToEdge(&sb, .top);
    try testing.expectEqual(@as(?u32, 813), sb.selected_number);
    try testing.expect(sb.cursor_on_header);
}

test "collapse: h on a member collapses its stack and puts the cursor on the header" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.toggleExpand(&sb, testing.allocator);
    controller.move(&sb, 3);
    try testing.expectEqual(@as(?u32, 812), sb.selected_number);

    try controller.collapse(&sb, testing.allocator);

    try testing.expectEqual(@as(usize, stacked31_rows), sb.rows.items.len);
    try testing.expectEqual(@as(usize, 0), sb.cursor);
    try testing.expectEqual(@as(?u32, 813), sb.selected_number);
    try testing.expect(sb.cursor_on_header);
}

test "toggleExpand: collapsing from a member puts the cursor on the header" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.toggleExpand(&sb, testing.allocator);
    controller.move(&sb, 1);

    try controller.toggleExpand(&sb, testing.allocator);

    try testing.expectEqual(@as(usize, stacked31_rows), sb.rows.items.len);
    try testing.expectEqual(@as(usize, 0), sb.cursor);
}

test "selectedPr: header row returns the review target; member row returns the member" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);

    try testing.expectEqual(@as(u32, 813), controller.selectedPr(&sb).?.number);
    try controller.toggleExpand(&sb, testing.allocator);
    controller.move(&sb, 3);
    try testing.expectEqual(@as(u32, 812), controller.selectedPr(&sb).?.number);
}

test "selectedPr: null with no rows" {
    var sb = SidebarState{};
    defer controller.deinitState(&sb, testing.allocator);

    try testing.expectEqual(@as(?*const PrRecord, null), controller.selectedPr(&sb));
}

// =============================================================================
// Reload (re-applied snapshot) and cursor identity
// =============================================================================

test "applySnapshot (re-applied, as on reload) keeps the cursor on the same PR number when rows shift above it" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    controller.move(&sb, 7);
    try testing.expectEqual(@as(?u32, 745), sb.selected_number);

    const base = stacked31Specs();
    var grown: [32]RecSpec = undefined;
    grown[0] = .{ .number = 900, .head = "new-pr" };
    @memcpy(grown[1..], &base);
    try reapply(&sb, &grown);

    try testing.expectEqual(@as(?u32, 745), sb.selected_number);
    try testing.expectEqual(@as(usize, 8), sb.cursor);
}

test "applySnapshot (re-applied) clamps the cursor when the selected PR disappeared" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    controller.moveToEdge(&sb, .bottom);

    const base = stacked31Specs();
    try reapply(&sb, base[0 .. base.len - 1]);

    try testing.expectEqual(@as(usize, stacked31_rows - 2), sb.cursor);
    try testing.expectEqual(@as(?u32, 726), sb.selected_number);
}

test "cursorChanged: set when the selected number changes, not on a no-op move at the edge" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try testing.expect(controller.takeCursorChanged(&sb));

    controller.move(&sb, -1);
    try testing.expect(!controller.takeCursorChanged(&sb));
    controller.move(&sb, 1);
    try testing.expect(controller.takeCursorChanged(&sb));
    try testing.expect(!controller.takeCursorChanged(&sb));
}

test "cursorChanged: not set by a re-applied snapshot that keeps the same selected number" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    controller.move(&sb, 4);
    _ = controller.takeCursorChanged(&sb);

    const specs = stacked31Specs();
    try reapply(&sb, &specs);

    try testing.expect(!controller.takeCursorChanged(&sb));
}

test "applySnapshot: re-applied with zero records empties the rows and clears the selection" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);

    try reapply(&sb, &.{});

    try testing.expectEqual(@as(usize, 0), sb.rows.items.len);
    try testing.expectEqual(@as(?u32, null), sb.selected_number);
    try testing.expectEqual(@as(?*const PrRecord, null), controller.selectedPr(&sb));
}

// =============================================================================
// Filter
// =============================================================================

test "applyQuery: valid query replaces rows and clears parse_error" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    _ = try controller.applyQuery(&sb, testing.allocator, "revew:x");

    try testing.expect(try controller.applyQuery(&sb, testing.allocator, "author:bob"));

    try testing.expectEqual(@as(usize, standalone_count / 2), sb.rows.items.len);
    try testing.expectEqual(@as(?root.sidebar_state.ParseErrorView, null), sb.parse_error);
    try testing.expectEqualStrings("author:bob", sb.queryText());
}

test "applyQuery: invalid query sets parse_error and keeps the last good rows" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    _ = try controller.applyQuery(&sb, testing.allocator, "author:bob");

    try testing.expect(!try controller.applyQuery(&sb, testing.allocator, "revew:requested"));

    try testing.expect(sb.parse_error != null);
    try testing.expectEqual(@as(usize, standalone_count / 2), sb.rows.items.len);
    try testing.expectEqualStrings("author:bob", sb.queryText());
}

test "applyQuery: parse error stores ParseErrorReason and ParseError.format text" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);

    _ = try controller.applyQuery(&sb, testing.allocator, "revew:requested");

    const parse_error = sb.parse_error.?;
    try testing.expectEqual(root.filter_query.ParseErrorReason.unknown_qualifier, parse_error.reason);
    try testing.expectEqualStrings("unknown qualifier \"revew\" in \"revew:requested\"", parse_error.message());
}

test "applyQuery: an over-long error message is truncated, not dropped" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);

    const long_key = "x" ** 200 ++ ":y";
    _ = try controller.applyQuery(&sb, testing.allocator, long_key);

    try testing.expectEqual(@as(usize, 128), sb.parse_error.?.message().len);
}

test "applyQuery: matching preset query re-selects that preset; other text → active_preset null" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);

    _ = try controller.applyQuery(&sb, testing.allocator, "author:@me");
    try testing.expectEqual(@as(?usize, 1), sb.active_preset);
    _ = try controller.applyQuery(&sb, testing.allocator, "label:x");
    try testing.expectEqual(@as(?usize, null), sb.active_preset);
}

test "cyclePreset: walks presets in config order and wraps" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);
    try testing.expectEqual(@as(?usize, 0), sb.active_preset);

    try controller.cyclePreset(&sb, testing.allocator);
    try testing.expectEqual(@as(?usize, 1), sb.active_preset);
    try testing.expectEqualStrings("author:@me", sb.queryText());
    try controller.cyclePreset(&sb, testing.allocator);
    try testing.expectEqual(@as(?usize, 0), sb.active_preset);
    try testing.expectEqualStrings("-is:draft", sb.queryText());
}

test "cyclePreset: from a custom query starts at the first preset" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);
    _ = try controller.applyQuery(&sb, testing.allocator, "label:x");

    try controller.cyclePreset(&sb, testing.allocator);

    try testing.expectEqual(@as(?usize, 0), sb.active_preset);
}

test "restorePreset: a custom query returns to the preset that was active before it" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);
    try controller.cyclePreset(&sb, testing.allocator);
    _ = try controller.applyQuery(&sb, testing.allocator, "label:x");

    try testing.expect(try controller.restorePreset(&sb, testing.allocator));

    try testing.expectEqual(@as(?usize, 1), sb.active_preset);
    try testing.expectEqualStrings("author:@me", sb.queryText());
}

test "restorePreset: already on a preset → false, nothing changes" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);

    try testing.expect(!try controller.restorePreset(&sb, testing.allocator));

    try testing.expectEqual(@as(?usize, 0), sb.active_preset);
    try testing.expectEqualStrings("-is:draft", sb.queryText());
}

test "restorePreset: no presets installed → false" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    _ = try controller.applyQuery(&sb, testing.allocator, "label:x");

    try testing.expect(!try controller.restorePreset(&sb, testing.allocator));
    try testing.expectEqualStrings("label:x", sb.queryText());
}

test "setPresets: no configured presets → built-in \"all\" (empty query) via effectivePresets()" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);

    try controller.setPresets(&sb, testing.allocator, &config.PrFilters{});

    try testing.expectEqual(@as(usize, 1), sb.presets.len);
    try testing.expectEqualStrings("all", sb.presets[0].name);
    try testing.expectEqual(@as(?usize, 0), sb.active_preset);
    try testing.expectEqual(@as(usize, stacked31_rows), sb.rows.items.len);
}

test "setPresets: default names the second preset → active_preset == defaultIndex() == 1 and its query applied" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    var filters = two_presets;
    filters.default = "mine";

    try controller.setPresets(&sb, testing.allocator, &filters);

    try testing.expectEqual(@as(?usize, filters.defaultIndex()), sb.active_preset);
    try testing.expectEqual(@as(?usize, 1), sb.active_preset);
    try testing.expectEqualStrings("author:@me", sb.queryText());
    try testing.expectEqual(@as(usize, 1), sb.rows.items.len);
}

test "setPresets: unknown default name → index 0" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    var filters = two_presets;
    filters.default = "nope";

    try controller.setPresets(&sb, testing.allocator, &filters);

    try testing.expectEqual(@as(?usize, 0), sb.active_preset);
}

test "setPresets: replacing presets frees the previous copies" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);

    try controller.setPresets(&sb, testing.allocator, &two_presets);
    try controller.setPresets(&sb, testing.allocator, &two_presets);

    try testing.expectEqual(@as(usize, 2), sb.presets.len);
}

test "promptKey: Enter with a valid changed query returns .query_changed; Esc and a parse error return .none" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);

    controller.openPrompt(&sb);
    try typeText(&sb, "author:bob");
    try testing.expectEqual(controller.PromptOutcome.query_changed, try controller.promptKey(&sb, testing.allocator, .enter));
    try testing.expectEqual(@as(?root.sidebar_state.Prompt, null), sb.prompt);

    controller.openPrompt(&sb);
    try testing.expectEqual(controller.PromptOutcome.none, try controller.promptKey(&sb, testing.allocator, .escape));

    controller.openPrompt(&sb);
    try typeText(&sb, " revew:x");
    try testing.expectEqual(controller.PromptOutcome.none, try controller.promptKey(&sb, testing.allocator, .enter));
    try testing.expect(sb.prompt != null);
    try testing.expect(sb.parse_error != null);
}

test "promptKey: Enter with the unchanged query closes the prompt without a change" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    _ = try controller.applyQuery(&sb, testing.allocator, "author:bob");

    controller.openPrompt(&sb);
    try testing.expectEqualStrings("author:bob", sb.prompt.?.text());

    try testing.expectEqual(controller.PromptOutcome.none, try controller.promptKey(&sb, testing.allocator, .enter));
    try testing.expectEqual(@as(?root.sidebar_state.Prompt, null), sb.prompt);
}

test "promptKey: backspace removes a whole multi-byte character" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    controller.openPrompt(&sb);

    _ = try controller.promptKey(&sb, testing.allocator, .{ .char = 'a' });
    _ = try controller.promptKey(&sb, testing.allocator, .{ .char = 'é' });
    try testing.expectEqualStrings("aé", sb.prompt.?.text());
    _ = try controller.promptKey(&sb, testing.allocator, .backspace);
    try testing.expectEqualStrings("a", sb.prompt.?.text());
    _ = try controller.promptKey(&sb, testing.allocator, .backspace);
    _ = try controller.promptKey(&sb, testing.allocator, .backspace);
    try testing.expectEqualStrings("", sb.prompt.?.text());
}

test "promptKey: input past the query cap is ignored" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    controller.openPrompt(&sb);

    for (0..root.sidebar_state.query_cap + 10) |_| _ = try controller.promptKey(&sb, testing.allocator, .{ .char = 'x' });

    try testing.expectEqual(@as(usize, root.sidebar_state.query_cap), sb.prompt.?.len);
}

test "visibleNumbers: display order, collapsed stack members included, filtered-out PRs excluded" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);

    const all = try controller.visibleNumbers(&sb, testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 31), all.len);
    try testing.expectEqualSlices(u32, &.{ 814, 813, 812, 791, 790, 750 }, all[0..6]);

    _ = try controller.applyQuery(&sb, testing.allocator, "author:bob");
    const bob = try controller.visibleNumbers(&sb, testing.allocator);
    defer testing.allocator.free(bob);
    try testing.expectEqual(@as(usize, standalone_count / 2), bob.len);
    try testing.expectEqual(@as(u32, 750), bob[0]);
}

test "prompt: Esc restores the query that was active before f" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    _ = try controller.applyQuery(&sb, testing.allocator, "author:bob");

    controller.openPrompt(&sb);
    try typeText(&sb, "x");
    _ = try controller.promptKey(&sb, testing.allocator, .escape);

    try testing.expectEqualStrings("author:bob", sb.queryText());
    try testing.expectEqual(@as(usize, standalone_count / 2), sb.rows.items.len);
}

test "prompt: a re-applied snapshot (sync reload) while the prompt is open leaves the prompt text untouched" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    controller.openPrompt(&sb);
    try typeText(&sb, "abc");

    const specs = stacked31Specs();
    try reapply(&sb, &specs);

    try testing.expectEqualStrings("abc", sb.prompt.?.text());
}

test "selectNumber: selects a member inside a collapsed stack by expanding it" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);

    try testing.expect(try controller.selectNumber(&sb, testing.allocator, 812));

    try testing.expectEqual(@as(usize, stacked31_expanded_rows), sb.rows.items.len);
    try testing.expectEqual(@as(?u32, 812), sb.selected_number);
    try testing.expectEqual(@as(usize, 3), sb.cursor);
}

test "selectNumber: unknown number returns false and leaves the cursor" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    controller.move(&sb, 3);

    try testing.expect(!try controller.selectNumber(&sb, testing.allocator, 9999));

    try testing.expectEqual(@as(usize, 3), sb.cursor);
}

// =============================================================================
// View
// =============================================================================

test "empty states: zero records → .no_prs; records but nothing visible → .no_match" {
    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();

    var empty = try stateFrom(&.{}, recent_sync);
    defer controller.deinitState(&empty, testing.allocator);
    try testing.expect(controller.view(&empty, viewParams(frame.allocator())).empty.? == .no_prs);

    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    _ = try controller.applyQuery(&sb, testing.allocator, "label:nope");
    try testing.expectEqualStrings("label:nope", controller.view(&sb, viewParams(frame.allocator())).empty.?.no_match);
}

test "empty states: zero records before the first sync → .syncing" {
    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();
    var sb = try stateFrom(&.{}, .{ .running = true });
    defer controller.deinitState(&sb, testing.allocator);

    try testing.expect(controller.view(&sb, viewParams(frame.allocator())).empty.? == .syncing);
}

test "empty states: no records after a failed first sync → .sync_failed with the classified message" {
    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();
    var sb = try stateFrom(&.{}, .{ .last_error = .network, .last_error_message = "network error reaching GitHub" });
    defer controller.deinitState(&sb, testing.allocator);

    try testing.expectEqualStrings("network error reaching GitHub", controller.view(&sb, viewParams(frame.allocator())).empty.?.sync_failed);
}

test "empty states: a retry running after a failed first sync → .syncing" {
    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();
    var sb = try stateFrom(&.{}, .{ .running = true, .last_error = .network, .last_error_message = "network error reaching GitHub" });
    defer controller.deinitState(&sb, testing.allocator);

    try testing.expect(controller.view(&sb, viewParams(frame.allocator())).empty.? == .syncing);
}

test "empty states: no records after an earlier good sync stays .no_prs when offline" {
    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();
    var sb = try stateFrom(&.{}, .{ .last_ok_at = now - 600, .last_error = .network, .last_error_message = "network error reaching GitHub" });
    defer controller.deinitState(&sb, testing.allocator);

    try testing.expect(controller.view(&sb, viewParams(frame.allocator())).empty.? == .no_prs);
}

test "snapshot: sidebar_offline_never_synced" {
    var sb = try stateFrom(&.{}, .{ .last_error = .network, .last_error_message = "network error reaching GitHub" });
    defer controller.deinitState(&sb, testing.allocator);
    try expectSidebarSnapshot(.{ .state = &sb, .name = "sidebar_offline_never_synced", .cols = 32, .rows = 10 });
}

test "snapshot: sidebar_unavailable_narrow" {
    var sb = SidebarState{ .unavailable = .gh_unauthenticated };
    defer controller.deinitState(&sb, testing.allocator);
    try expectSidebarSnapshot(.{ .state = &sb, .name = "sidebar_unavailable_narrow", .cols = 32, .rows = 10 });
}

test "empty states: unavailable wins and carries its message" {
    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();
    var sb = SidebarState{ .unavailable = .not_github };
    defer controller.deinitState(&sb, testing.allocator);

    const v = controller.view(&sb, viewParams(frame.allocator()));

    try testing.expectEqualStrings("Not a GitHub repository (no github.com origin)", v.empty.?.unavailable);
    try testing.expectEqualStrings("", v.sync_line);
}

test "view: review glyph — approved_by_me only when my_review_oid == head_oid" {
    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();
    var sb = try stateFrom(&.{
        .{ .number = 1, .head = "a", .my_review_state = "APPROVED", .my_review_oid = head_oid },
        .{ .number = 2, .head = "b", .my_review_state = "APPROVED", .my_review_oid = other_oid, .review_decision = "APPROVED" },
        .{ .number = 3, .head = "c", .requested_users = "Me" },
        .{ .number = 4, .head = "d", .review_decision = "CHANGES_REQUESTED" },
        .{ .number = 5, .head = "e" },
    }, recent_sync);
    defer controller.deinitState(&sb, testing.allocator);

    const rows = controller.view(&sb, viewParams(frame.allocator())).rows;

    try testing.expectEqual(sidebar_render.ReviewGlyph.approved_by_me, rows[0].review);
    try testing.expectEqual(sidebar_render.ReviewGlyph.approved, rows[1].review);
    try testing.expectEqual(sidebar_render.ReviewGlyph.requested_me, rows[2].review);
    try testing.expectEqual(sidebar_render.ReviewGlyph.changes_requested, rows[3].review);
    try testing.expectEqual(sidebar_render.ReviewGlyph.none, rows[4].review);
}

test "view: changed_since_seen when record.seen_head_oid != record.head_oid; false when seen_head_oid is null" {
    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();
    var sb = try stateFrom(&.{
        .{ .number = 1, .head = "a", .seen_head_oid = other_oid },
        .{ .number = 2, .head = "b", .seen_head_oid = head_oid },
        .{ .number = 3, .head = "c" },
    }, recent_sync);
    defer controller.deinitState(&sb, testing.allocator);

    const rows = controller.view(&sb, viewParams(frame.allocator())).rows;

    try testing.expect(rows[0].changed_since_seen);
    try testing.expect(!rows[1].changed_since_seen);
    try testing.expect(!rows[2].changed_since_seen);
}

test "view: builds only the rows on screen, starting at the scroll offset" {
    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    sb.scroll = 5;
    sb.cursor = 6;
    var params = viewParams(frame.allocator());
    params.visible_rows = 4;

    const v = controller.view(&sb, params);

    try testing.expectEqual(@as(usize, 4), v.rows.len);
    try testing.expectEqual(rowNumber(&sb, 5), v.rows[0].number);
    try testing.expectEqual(rowNumber(&sb, 8), v.rows[3].number);
    try testing.expectEqual(@as(?usize, 1), v.cursor);
    try testing.expectEqual(@as(usize, 31), v.header.visible);
}

test "view: a cursor scrolled off the built rows is not marked" {
    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    sb.scroll = 5;
    sb.cursor = 2;
    var params = viewParams(frame.allocator());
    params.visible_rows = 4;

    try testing.expectEqual(@as(?usize, null), controller.view(&sb, params).cursor);
}

test "view: the last rows are built when fewer remain than fit" {
    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    sb.scroll = sb.rows.items.len - 2;
    sb.cursor = sb.rows.items.len - 1;
    var params = viewParams(frame.allocator());
    params.visible_rows = 10;

    const v = controller.view(&sb, params);

    try testing.expectEqual(@as(usize, 2), v.rows.len);
    try testing.expectEqual(@as(?usize, 1), v.cursor);
}

test "view: header counts, label and stack rows" {
    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.toggleExpand(&sb, testing.allocator);
    _ = try controller.applyQuery(&sb, testing.allocator, "-label:nope");

    const v = controller.view(&sb, viewParams(frame.allocator()));

    try testing.expectEqualStrings("custom", v.header.label);
    try testing.expectEqual(@as(usize, 31), v.header.visible);
    try testing.expectEqual(@as(usize, 31), v.header.total);
    try testing.expectEqual(@as(u16, 3), v.rows[0].stack_size);
    try testing.expect(v.rows[0].expanded);
    try testing.expectEqual(root.stack.Mark.top, v.rows[1].connector);
    try testing.expectEqual(root.stack.Mark.bottom, v.rows[3].connector);
    try testing.expectEqual(root.stack.Mark.none, v.rows[6].connector);
}

test "view: sync line — busy / ok age / stale after 5 min / never synced shows the classified error / gh error shows last_error_message / running beats a previous error" {
    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();
    const cases = [_]struct { sync: SyncSnapshot, line: []const u8, tone: sidebar_render.SyncTone }{
        .{ .sync = .{ .running = true, .last_ok_at = now - 30 }, .line = "⟳ syncing…", .tone = .busy },
        .{ .sync = .{}, .line = "⟳ syncing…", .tone = .busy },
        .{ .sync = .{ .last_ok_at = now - 120 }, .line = "⟳ 2m ago", .tone = .ok },
        .{ .sync = .{ .last_ok_at = now - 3 * 3600 }, .line = "offline · 3h old", .tone = .stale },
        .{ .sync = .{ .last_ok_at = now - 60, .last_error = .network }, .line = "offline · 1m old", .tone = .stale },
        .{ .sync = .{ .last_error = .network, .last_error_message = "network error reaching GitHub" }, .line = "offline · network error reaching GitHub", .tone = .stale },
        .{ .sync = .{ .last_error = .other }, .line = "offline · never synced", .tone = .stale },
        .{ .sync = .{ .running = true, .last_ok_at = now - 60, .last_error = .network }, .line = "⟳ syncing…", .tone = .busy },
        .{ .sync = .{ .running = true, .last_error = .not_authenticated, .last_error_message = "gh: not authenticated — run gh auth login" }, .line = "⟳ syncing…", .tone = .busy },
        .{ .sync = .{ .last_error = .not_authenticated, .last_error_message = "gh: not authenticated — run gh auth login" }, .line = "gh: not authenticated — run gh auth login", .tone = .err },
        .{ .sync = .{ .last_error = .not_installed, .last_error_message = "gh not found — review features unavailable" }, .line = "gh: not installed", .tone = .err },
    };
    for (cases) |case| {
        const sb = SidebarState{ .sync = case.sync };
        const v = controller.view(&sb, viewParams(frame.allocator()));
        try testing.expectEqualStrings(case.line, v.sync_line);
        try testing.expectEqual(case.tone, v.sync_tone);
    }
}

test "clampScroll: keeps the cursor visible for small heights" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);

    controller.move(&sb, 20);
    controller.clampScroll(&sb, 5);
    try testing.expectEqual(@as(usize, 16), sb.scroll);
    controller.move(&sb, -18);
    controller.clampScroll(&sb, 5);
    try testing.expectEqual(@as(usize, 2), sb.scroll);
    controller.clampScroll(&sb, 100);
    try testing.expectEqual(@as(usize, 0), sb.scroll);
}

test "setMessage: truncates on a UTF-8 boundary" {
    var sb = SidebarState{};
    controller.setMessage(&sb, "é" ** 80);

    try testing.expectEqual(@as(usize, 128), sb.messageText().len);
    try testing.expect(std.unicode.utf8ValidateSlice(sb.messageText()));
}

// =============================================================================
// pr_surface against a real temp-file DB (no worker, no subprocess)
// =============================================================================

test "reload: reads open PRs and seen rows from a temp-file store" {
    var fx = try SurfaceFixture.init();
    defer fx.deinit();
    try fx.surface.store.?.upsertIndex(fx.surface.repo_id, &.{ indexRow(11, "open-pr"), indexRow(12, "closed-pr") });
    try fx.surface.store.?.markClosed(fx.surface.repo_id, &.{.{ .number = 12, .state = .closed, .updated_at = "2026-01-02T00:00:00Z" }});
    try fx.surface.store.?.setSeen(.{ .repo_id = fx.surface.repo_id, .number = 11, .head_oid = other_oid, .merge_base_oid = head_oid, .now = now });

    try surface.reload(&fx.surface, .{ .allocator = testing.allocator, .sidebar = &fx.sidebar });

    try testing.expectEqual(@as(usize, 1), fx.sidebar.rows.items.len);
    const record = controller.selectedPr(&fx.sidebar).?;
    try testing.expectEqual(@as(u32, 11), record.number);
    try testing.expectEqualStrings(other_oid, record.seen_head_oid.?);
}

test "reload: viewer login/teams come from the repo row and outlive OwnedRepo" {
    var fx = try SurfaceFixture.init();
    defer fx.deinit();
    try fx.surface.store.?.setViewer(fx.surface.repo_id, "octocat");
    try fx.surface.store.?.setViewerTeams(.{ .repo_id = fx.surface.repo_id, .teams = &.{ "org/a", "org/b" }, .now = now });

    try surface.reload(&fx.surface, .{ .allocator = testing.allocator, .sidebar = &fx.sidebar });

    try testing.expectEqualStrings("octocat", fx.sidebar.viewer_login);
    try testing.expectEqualStrings("org/a\norg/b", fx.sidebar.viewer_teams);
}

test "reload: with store == null is a no-op" {
    var s = surface.Surface{};
    var sb = SidebarState{};
    defer controller.deinitState(&sb, testing.allocator);

    try surface.reload(&s, .{ .allocator = testing.allocator, .sidebar = &sb });

    try testing.expectEqual(@as(?types.RecordList, null), sb.records);
}

test "syncSnapshot: without a worker, last_ok_at and last_error come from the repo row" {
    var fx = try SurfaceFixture.init();
    defer fx.deinit();
    try fx.surface.store.?.setSyncResult(fx.surface.repo_id, .{ .at = 123, .err_tag = "network" });

    try surface.reload(&fx.surface, .{ .allocator = testing.allocator, .sidebar = &fx.sidebar });

    try testing.expectEqual(@as(?i64, 123), fx.sidebar.sync.last_ok_at);
    try testing.expectEqual(@as(?types.SyncErrorKind, .network), fx.sidebar.sync.last_error);
    try testing.expectEqualStrings(root.github.kindMessage(.network), fx.sidebar.sync.last_error_message);
}

test "syncSnapshot: maps every SyncErrorKind tag stored by the worker and fills last_error_message from kindMessage" {
    for (std.enums.values(root.github.GhErrorKind)) |kind| {
        var fx = try SurfaceFixture.init();
        defer fx.deinit();
        try fx.surface.store.?.setSyncResult(fx.surface.repo_id, .{ .at = 50, .err_tag = @tagName(kind) });

        try surface.reload(&fx.surface, .{ .allocator = testing.allocator, .sidebar = &fx.sidebar });

        try testing.expectEqualStrings(@tagName(kind), @tagName(fx.sidebar.sync.last_error.?));
        try testing.expectEqualStrings(root.github.kindMessage(kind), fx.sidebar.sync.last_error_message);
    }
}

test "openAt: corrupt DB file → sidebar.message names the quarantined file and the sidebar is empty, not unavailable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp);
    defer testing.allocator.free(path);
    try writeGarbage(path);
    var s = surface.Surface{};
    defer surface.close(&s);
    var sb = SidebarState{};
    defer controller.deinitState(&sb, testing.allocator);

    surface.openAt(&s, .{ .allocator = testing.allocator, .sidebar = &sb, .db_path = path, .repo_key = "k", .owner = "o", .name = "r", .filters = &no_config_filters });

    try testing.expect(std.mem.indexOf(u8, sb.messageText(), "prs.db.corrupt-") != null);
    try testing.expectEqual(root.sidebar_state.Unavailable.none, sb.unavailable);
    try testing.expectEqual(@as(usize, 0), sb.rows.items.len);
    try testing.expect(s.store != null);
}

test "openAt: unopenable path → unavailable == .db_error, no crash" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // A regular file where the DB's directory should be: createDirPath fails.
    const blocker = try tmpDbPath(&tmp);
    defer testing.allocator.free(blocker);
    try writeGarbage(blocker);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/nested/prs.db", .{blocker});
    defer testing.allocator.free(path);
    var s = surface.Surface{};
    defer surface.close(&s);
    var sb = SidebarState{};
    defer controller.deinitState(&sb, testing.allocator);

    surface.openAt(&s, .{ .allocator = testing.allocator, .sidebar = &sb, .db_path = path, .repo_key = "k", .owner = "o", .name = "r", .filters = &no_config_filters });

    try testing.expectEqual(root.sidebar_state.Unavailable.db_error, sb.unavailable);
    try testing.expect(s.store == null);
    try testing.expect(sb.messageText().len > 0);
}

test "openAt: an existing DB paints its open PRs before any sync" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp);
    defer testing.allocator.free(path);
    {
        var db = try root.store.Store.open(testing.allocator, path);
        defer db.close();
        const repo_id = try db.ensureRepo(.{ .key = "k", .owner = "o", .name = "r" });
        try db.upsertIndex(repo_id, &.{ indexRow(1, "a"), indexRow(2, "b") });
    }
    var s = surface.Surface{};
    defer surface.close(&s);
    var sb = SidebarState{};
    defer controller.deinitState(&sb, testing.allocator);

    surface.openAt(&s, .{ .allocator = testing.allocator, .sidebar = &sb, .db_path = path, .repo_key = "k", .owner = "o", .name = "r", .filters = &no_config_filters });

    try testing.expectEqual(@as(usize, 2), sb.records.?.items.len);
    try testing.expectEqual(root.sidebar_state.Unavailable.none, sb.unavailable);
    try testing.expect(!surface.poll(&s, .{ .allocator = testing.allocator, .sidebar = &sb }));
}

test "openAt: installs the injected presets instead of reading the user's config" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp);
    defer testing.allocator.free(path);
    var s = surface.Surface{};
    defer surface.close(&s);
    var sb = SidebarState{};
    defer controller.deinitState(&sb, testing.allocator);
    const presets = [_]root.config.PrFilterPreset{
        .{ .name = "all", .query = "" },
        .{ .name = "drafts", .query = "is:draft" },
    };
    const filters = root.config.PrFilters{ .default = "drafts", .presets = &presets };

    surface.openAt(&s, .{ .allocator = testing.allocator, .sidebar = &sb, .db_path = path, .repo_key = "k", .owner = "o", .name = "r", .filters = &filters });

    try testing.expectEqual(@as(usize, 2), sb.presets.len);
    try testing.expectEqualStrings("drafts", sb.presets[sb.active_preset.?].name);
}

test "reload: a successful reload clears the db_error a failed initial reload left" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp);
    defer testing.allocator.free(path);
    var s = surface.Surface{};
    defer surface.close(&s);
    var sb = SidebarState{};
    defer controller.deinitState(&sb, testing.allocator);
    surface.openAt(&s, .{ .allocator = testing.allocator, .sidebar = &sb, .db_path = path, .repo_key = "k", .owner = "o", .name = "r", .filters = &no_config_filters });
    // What openAt leaves when its first reload fails on an open store.
    sb.unavailable = .db_error;

    try surface.reload(&s, .{ .allocator = testing.allocator, .sidebar = &sb });

    try testing.expectEqual(root.sidebar_state.Unavailable.none, sb.unavailable);
}

test "reload: a gh unavailability is left for poll to manage" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp);
    defer testing.allocator.free(path);
    var s = surface.Surface{};
    defer surface.close(&s);
    var sb = SidebarState{};
    defer controller.deinitState(&sb, testing.allocator);
    surface.openAt(&s, .{ .allocator = testing.allocator, .sidebar = &sb, .db_path = path, .repo_key = "k", .owner = "o", .name = "r", .filters = &no_config_filters });
    sb.unavailable = .gh_unauthenticated;

    try surface.reload(&s, .{ .allocator = testing.allocator, .sidebar = &sb });

    try testing.expectEqual(root.sidebar_state.Unavailable.gh_unauthenticated, sb.unavailable);
}

// =============================================================================
// Snapshots
// =============================================================================

test "snapshot: sidebar_collapsed_stacks" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &config.PrFilters{});

    try expectSidebarSnapshot(.{ .state = &sb, .name = "sidebar_collapsed_stacks", .cols = 44, .rows = 20 });
}

test "snapshot: sidebar_expanded_stack" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &config.PrFilters{});
    try controller.moveWithinStack(&sb, testing.allocator, 1);

    try expectSidebarSnapshot(.{ .state = &sb, .name = "sidebar_expanded_stack", .cols = 44, .rows = 20 });
}

test "snapshot: sidebar_filter_prompt" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);
    controller.openPrompt(&sb);
    for (0..sb.prompt.?.len) |_| _ = try controller.promptKey(&sb, testing.allocator, .backspace);
    try typeText(&sb, "author:@me");

    try expectSidebarSnapshot(.{ .state = &sb, .name = "sidebar_filter_prompt", .cols = 44, .rows = 12 });
}

test "snapshot: sidebar_filter_error" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);
    controller.openPrompt(&sb);
    for (0..sb.prompt.?.len) |_| _ = try controller.promptKey(&sb, testing.allocator, .backspace);
    try typeText(&sb, "revew:requested");
    _ = try controller.promptKey(&sb, testing.allocator, .enter);

    try expectSidebarSnapshot(.{ .state = &sb, .name = "sidebar_filter_error", .cols = 44, .rows = 12 });
}

test "snapshot: sidebar_empty_no_match" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    _ = try controller.applyQuery(&sb, testing.allocator, "label:nope");

    try expectSidebarSnapshot(.{ .state = &sb, .name = "sidebar_empty_no_match", .cols = 44, .rows = 10 });
}

test "snapshot: sidebar_offline_stale" {
    const specs = stacked31Specs();
    var sb = try stateFrom(&specs, .{ .last_ok_at = now - 3 * 3600, .last_error = .network });
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &config.PrFilters{});

    try expectSidebarSnapshot(.{ .state = &sb, .name = "sidebar_offline_stale", .cols = 44, .rows = 10, .focused = false });
}

test "snapshot: sidebar_narrow" {
    var sb = try stateFrom(&.{
        .{ .number = 1204, .title = "Rework the incremental highlighter to batch tree-sitter edits", .author = "averyveryverylonglogin", .head = "n1", .ci = .success },
        .{ .number = 1198, .title = "Fix scroll jitter when the agent panel resizes", .author = "bob", .head = "n2", .ci = .failure, .draft = true },
        .{ .number = 977, .title = "Docs", .author = "carol", .head = "n3", .requested_users = viewer },
    }, recent_sync);
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &config.PrFilters{});

    try expectSidebarSnapshot(.{ .state = &sb, .name = "sidebar_narrow", .cols = 32, .rows = 12 });
}

test "Esc close: switches to the working-tree diff, closes the store, and restores the parked comments once that diff installs" {
    const allocator = testing.allocator;
    var app = try root.App.initForRenderBench(allocator, try root.parser.parse(allocator, esc_close_diff));
    defer app.deinit();
    _ = try app.state.comment_store.add(.{
        .file_path = "src/x.zig",
        .hunk_idx = 0,
        .line_idx = 2,
        .text = "WT-NOTE",
        .line_type = .add,
        .line_content = "line10",
        .new_lineno = 10,
    });
    try app.enterReviewDiff(.{ .head_ref = "HEAD", .base_ref = "" });
    try app.applyRefreshedFiles(try root.parser.parse(allocator, esc_close_diff));
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp);
    defer allocator.free(path);
    surface.openAt(&app.state.pr_surface, .{ .allocator = allocator, .sidebar = &app.state.sidebar, .db_path = path, .repo_key = "k", .owner = "o", .name = "r", .filters = &no_config_filters });
    app.state.sidebar.open = true;
    app.state.sidebar.visible = true;
    app.mode = .pr_review;

    try app.prSidebarBack();

    try testing.expect(app.state.pr_surface.store == null);
    try testing.expect(app.state.pr_surface.sync == null);
    try testing.expect(!app.state.sidebar.open);
    try testing.expect(!app.state.sidebar.visible);
    try testing.expectEqual(root.App.Mode.normal, app.mode);
    try testing.expect(std.meta.activeTag(app.state.diff_source) == .working_dir);
    try testing.expect(app.state.pr_surface_parking.pending());
    try testing.expectEqual(@as(usize, 0), app.state.comment_store.comments.items.len);

    try app.applyRefreshedFiles(try root.parser.parse(allocator, esc_close_diff));

    try testing.expect(app.state.pr_surface_parking.comments == null);
    try testing.expect(!app.state.pr_surface_parking.pending());
    try testing.expectEqual(@as(usize, 1), app.state.comment_store.comments.items.len);
    try testing.expectEqualStrings("WT-NOTE", app.state.comment_store.comments.items[0].text);
}

test "snapshot: pr_surface_layout" {
    try expectAppSnapshot(.{ .name = "pr_surface_layout", .cols = 120, .rows = 30 });
}

test "snapshot: pr_surface_sidebar_hidden" {
    try expectAppSnapshot(.{ .name = "pr_surface_sidebar_hidden", .cols = 120, .rows = 30, .sidebar_visible = false });
}

test "snapshot: pr_surface_with_agent" {
    try expectAppSnapshot(.{ .name = "pr_surface_with_agent", .cols = 140, .rows = 30, .agent_panel = true });
}

test "help: with the sidebar open, the diff's hunk filter and page up list the keys that still reach them" {
    var app = try diffFocusedApp();
    defer app.deinit();

    const top = try helpText(&app, 0);
    defer testing.allocator.free(top);
    const bottom = try helpText(&app, 20);
    defer testing.allocator.free(bottom);

    try testing.expect(std.mem.indexOf(u8, top, "b / PageUp") != null);
    try testing.expect(std.mem.indexOf(u8, top, "Ctrl-b") == null);
    try testing.expect(std.mem.indexOf(u8, bottom, "Shift-Tab      │ Cycle hunk filter (backward)") != null);
    try testing.expect(std.mem.indexOf(u8, bottom, "  Tab            │") == null);
}

test "help: with the sidebar closed, Tab and Ctrl-b are listed for the diff" {
    var app = try diffFocusedApp();
    defer app.deinit();
    app.state.sidebar.open = false;

    const top = try helpText(&app, 0);
    defer testing.allocator.free(top);
    const bottom = try helpText(&app, 20);
    defer testing.allocator.free(bottom);

    try testing.expect(std.mem.indexOf(u8, top, "b / Ctrl-b") != null);
    try testing.expect(std.mem.indexOf(u8, bottom, "Tab            │ Cycle hunk filter") != null);
    try testing.expect(std.mem.indexOf(u8, bottom, "Shift-Tab") == null);
}

test "Esc in the sidebar: an open filter prompt is cancelled before anything else" {
    var app = try sidebarApp();
    defer app.deinit();
    try app.handleKey(.{ .codepoint = 'f' });
    try app.handleKey(.{ .codepoint = 'x', .text = "x" });

    try app.handleKey(.{ .codepoint = Key.escape });

    try testing.expect(app.state.sidebar.prompt == null);
    try testing.expect(app.state.sidebar.open);
    try testing.expectEqual(root.App.Mode.pr_review, app.mode);
    try testing.expectEqualStrings("-is:draft", app.state.sidebar.queryText());
}

test "Esc in the sidebar: a custom query returns to its preset and keeps the surface open" {
    var app = try sidebarApp();
    defer app.deinit();
    _ = try controller.applyQuery(&app.state.sidebar, testing.allocator, "label:x");

    try app.handleKey(.{ .codepoint = Key.escape });

    try testing.expectEqual(@as(?usize, 0), app.state.sidebar.active_preset);
    try testing.expect(app.state.sidebar.open);
    try testing.expect(!app.should_quit);
}

test "Esc in the sidebar: `skim pr` quits once nothing is left to peel" {
    var app = try sidebarApp();
    defer app.deinit();
    app.state.sidebar.pr_only = true;

    try app.handleKey(.{ .codepoint = Key.escape });

    try testing.expect(app.should_quit);
}

test "sidebar keys: l and Ctrl-b keep the sidebar when no diff is loaded" {
    var app = try sidebarApp();
    defer app.deinit();

    try app.handleKey(.{ .codepoint = 'l' });
    try app.handleKey(.{ .codepoint = 'b', .mods = .{ .ctrl = true } });

    try testing.expectEqual(root.App.Mode.pr_review, app.mode);
    try testing.expect(app.state.sidebar.visible);
}

test "diff keys: Tab with the sidebar hidden shows it and focuses it" {
    var app = try diffFocusedApp();
    defer app.deinit();
    app.state.sidebar.visible = false;

    try app.handleKey(.{ .codepoint = Key.tab });

    try testing.expect(app.state.sidebar.visible);
    try testing.expectEqual(root.App.Mode.pr_review, app.mode);
}

test "diff keys: Shift-Tab still cycles the hunk view with the sidebar hidden" {
    var app = try diffFocusedApp();
    defer app.deinit();
    app.state.sidebar.visible = false;
    const hunk_mode = app.state.hunk_view_mode;

    try app.handleKey(.{ .codepoint = Key.tab, .mods = .{ .shift = true } });

    try testing.expect(app.state.hunk_view_mode != hunk_mode);
    try testing.expect(!app.state.sidebar.visible);
    try testing.expectEqual(root.App.Mode.normal, app.mode);
}

test "diff keys: Ctrl-b beside a wide diff hides the sidebar and keeps the diff focused" {
    var app = try diffFocusedApp();
    defer app.deinit();
    var screen = try TestScreen.attach(&app, 120);
    defer screen.detach(&app);

    try app.handleKey(.{ .codepoint = 'b', .mods = .{ .ctrl = true } });

    try testing.expect(!app.state.sidebar.visible);
    try testing.expectEqual(root.App.Mode.normal, app.mode);
}

test "diff keys: Ctrl-b below 72 cols shows the sidebar full width and focuses it" {
    var app = try diffFocusedApp();
    defer app.deinit();
    var screen = try TestScreen.attach(&app, 60);
    defer screen.detach(&app);

    try app.handleKey(.{ .codepoint = 'b', .mods = .{ .ctrl = true } });

    try testing.expect(app.state.sidebar.visible);
    try testing.expectEqual(root.App.Mode.pr_review, app.mode);
    try testing.expectEqual(@as(u16, 60), root.sidebar_layout.split(.{ .width = 60, .visible = true, .sidebar_focused = true }).sidebar_cols);
}

test "diff keys: Ctrl-b below 72 cols with the sidebar hidden shows and focuses it" {
    var app = try diffFocusedApp();
    defer app.deinit();
    app.state.sidebar.visible = false;
    var screen = try TestScreen.attach(&app, 60);
    defer screen.detach(&app);

    try app.handleKey(.{ .codepoint = 'b', .mods = .{ .ctrl = true } });

    try testing.expect(app.state.sidebar.visible);
    try testing.expectEqual(root.App.Mode.pr_review, app.mode);
}

test "filter prompt: named keys without text (arrows) insert nothing" {
    var app = try sidebarApp();
    defer app.deinit();
    try app.handleKey(.{ .codepoint = 'f' });
    const before = app.state.sidebar.prompt.?.len;

    try app.handleKey(.{ .codepoint = Key.up });
    try app.handleKey(.{ .codepoint = Key.left });

    try testing.expectEqual(before, app.state.sidebar.prompt.?.len);
}

test "filter prompt: non-ASCII text is typed through" {
    var app = try sidebarApp();
    defer app.deinit();
    try app.handleKey(.{ .codepoint = 'f' });
    const before = app.state.sidebar.prompt.?.len;

    try app.handleKey(.{ .codepoint = 0xE9, .text = "\u{e9}" });

    try testing.expectEqual(before + 2, app.state.sidebar.prompt.?.len);
}

// =============================================================================
// Helpers
// =============================================================================

const two_presets = config.PrFilters{ .presets = &.{
    .{ .name = "ready", .query = "-is:draft" },
    .{ .name = "mine", .query = "author:@me" },
} };

fn names(comptime fmt: []const u8) [standalone_count][]const u8 {
    var out: [standalone_count][]const u8 = undefined;
    for (&out, 0..) |*name, i| name.* = std.fmt.comptimePrint(fmt, .{first_standalone - i});
    return out;
}

/// 3-PR stack #812 ← #813 ← #814 (tip #814; #812 approved by the viewer at
/// its head, so the review target is #813, which requests the viewer), 2-PR
/// stack #790 ← #791, then 26 standalones #750..#725 alternating bob/alice
/// (one authored by the viewer).
fn stacked31Specs() [31]RecSpec {
    var specs: [31]RecSpec = undefined;
    specs[0] = .{ .number = 814, .title = "Wire retry into cli", .head = "s3-c", .base = "s3-b", .draft = true, .ci = .pending };
    specs[1] = .{ .number = 813, .title = "Backoff helper", .head = "s3-b", .base = "s3-a", .ci = .success, .requested_users = viewer, .seen_head_oid = other_oid };
    specs[2] = .{ .number = 812, .title = "Retry fetch on 502", .head = "s3-a", .ci = .success, .my_review_state = "APPROVED", .my_review_oid = head_oid };
    specs[3] = .{ .number = 791, .title = "Parser tests", .head = "s2-b", .base = "s2-a" };
    specs[4] = .{ .number = 790, .title = "Split parser module", .head = "s2-a", .ci = .failure };
    for (specs[5..], 0..) |*spec, i| {
        spec.* = .{
            .number = first_standalone - @as(u32, @intCast(i)),
            .title = standalone_titles[i],
            .author = if (i % 2 == 0) "bob" else if (i == 1) viewer else "alice",
            .head = standalone_heads[i],
            .ci = if (i % 3 == 0) .success else .none,
            .review_decision = if (i % 4 == 1) "APPROVED" else "",
        };
    }
    return specs;
}

/// A RecordList whose strings live in its own arena, as `store.listOpen`
/// hands one over.
fn records(allocator: Allocator, specs: []const RecSpec) !types.RecordList {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const items = try a.alloc(PrRecord, specs.len);
    for (specs, items) |spec, *item| {
        item.* = .{
            .number = spec.number,
            .node_id = "",
            .state = .open,
            .title = try a.dupe(u8, spec.title),
            .author = try a.dupe(u8, spec.author),
            .url = "",
            .is_draft = spec.draft,
            .head_ref = try a.dupe(u8, spec.head),
            .base_ref = try a.dupe(u8, spec.base),
            .head_oid = try a.dupe(u8, spec.head_oid),
            .base_oid = "",
            .updated_at = "2026-01-01T00:00:00Z",
            .hydrated_at_update = "2026-01-01T00:00:00Z",
            .additions = 0,
            .deletions = 0,
            .changed_files = 0,
            .review_decision = try a.dupe(u8, spec.review_decision),
            .ci = spec.ci,
            .labels = try a.dupe(u8, spec.labels),
            .requested_users = try a.dupe(u8, spec.requested_users),
            .requested_teams = "",
            .my_review_state = try a.dupe(u8, spec.my_review_state),
            .my_review_oid = try a.dupe(u8, spec.my_review_oid),
            .seen_head_oid = if (spec.seen_head_oid) |oid| try a.dupe(u8, oid) else null,
            .seen_merge_base_oid = null,
        };
    }
    return .{ .arena = arena, .items = items };
}

fn stateFrom(specs: []const RecSpec, sync: SyncSnapshot) !SidebarState {
    var sb = SidebarState{};
    errdefer controller.deinitState(&sb, testing.allocator);
    try controller.applySnapshot(&sb, testing.allocator, .{
        .records = try records(testing.allocator, specs),
        .viewer_login = viewer,
        .viewer_teams = "",
        .sync = sync,
    });
    return sb;
}

fn stacked31State() !SidebarState {
    const specs = stacked31Specs();
    return stateFrom(&specs, recent_sync);
}

fn reapply(sb: *SidebarState, specs: []const RecSpec) !void {
    try controller.applySnapshot(sb, testing.allocator, .{
        .records = try records(testing.allocator, specs),
        .viewer_login = viewer,
        .viewer_teams = "",
        .sync = recent_sync,
    });
}

fn rowNumber(sb: *const SidebarState, index: usize) u32 {
    return sb.records.?.items[sb.rows.items[index].record].number;
}

fn expectRowNumbers(sb: *const SidebarState, start: usize, expected: []const u32) !void {
    for (expected, start..) |number, index| try testing.expectEqual(number, rowNumber(sb, index));
}

fn typeText(sb: *SidebarState, text: []const u8) !void {
    for (text) |c| _ = try controller.promptKey(sb, testing.allocator, .{ .char = c });
}

/// An App with no diff, the PR sidebar open and focused over stacked31, and
/// the two_presets presets (`ready` active). No store, no sync worker.
fn sidebarApp() !root.App {
    const allocator = testing.allocator;
    var app = try root.App.initForRenderBench(allocator, try allocator.alloc(root.parser.FileDiff, 0));
    errdefer app.deinit();
    const specs = stacked31Specs();
    try controller.applySnapshot(&app.state.sidebar, allocator, .{
        .records = try records(allocator, &specs),
        .viewer_login = viewer,
        .viewer_teams = "",
        .sync = recent_sync,
    });
    try controller.setPresets(&app.state.sidebar, allocator, &two_presets);
    app.state.sidebar.open = true;
    app.state.sidebar.visible = true;
    app.mode = .pr_review;
    return app;
}

/// `sidebarApp` with a 2-file diff loaded and the diff focused.
fn diffFocusedApp() !root.App {
    const allocator = testing.allocator;
    const diff = try root.bench_support.buildDiffText(allocator, .{ .file_count = 2, .hunks_per_file = 1, .lines_per_hunk = 6 });
    defer allocator.free(diff);
    var app = try root.App.initForRenderBench(allocator, try root.parser.parse(allocator, diff));
    errdefer app.deinit();
    const specs = stacked31Specs();
    try controller.applySnapshot(&app.state.sidebar, allocator, .{
        .records = try records(allocator, &specs),
        .viewer_login = viewer,
        .viewer_teams = "",
        .sync = recent_sync,
    });
    try controller.setPresets(&app.state.sidebar, allocator, &two_presets);
    app.state.sidebar.open = true;
    app.state.sidebar.visible = true;
    app.mode = .normal;
    return app;
}

/// A headless vaxis screen of `cols` columns installed as `app.vx`, so key
/// handlers see a terminal width. `App.deinit` leaves a tty-less vx alone;
/// `detach` frees it.
const TestScreen = struct {
    out: std.Io.Writer.Allocating,

    fn attach(app: *root.App, cols: u16) !TestScreen {
        const allocator = testing.allocator;
        var screen: TestScreen = .{ .out = .init(allocator) };
        errdefer screen.out.deinit();
        app.vx = try vaxis.init(skim_io.get(), allocator, skim_io.environMap(), .{});
        try app.vx.?.resize(allocator, &screen.out.writer, .{ .rows = 30, .cols = cols, .x_pixel = 0, .y_pixel = 0 });
        return screen;
    }

    fn detach(self: *TestScreen, app: *root.App) void {
        app.vx.?.screen.deinit(testing.allocator);
        app.vx.?.screen_last.deinit(testing.allocator);
        app.vx = null;
        self.out.deinit();
    }
};

/// Render a whole App frame (sidebar + diff + status bar) with the stacked31
/// list beside a 2-file synthetic diff, diff focused, and compare it. The sync
/// age is relative to the real clock, which `frame.render` reads.
fn expectAppSnapshot(params: struct {
    name: []const u8,
    cols: u16,
    rows: u16,
    sidebar_visible: bool = true,
    agent_panel: bool = false,
}) !void {
    const allocator = testing.allocator;
    const diff = try root.bench_support.buildDiffText(allocator, .{ .file_count = 2, .hunks_per_file = 1, .lines_per_hunk = 6 });
    defer allocator.free(diff);
    var app = try root.App.initForRenderBench(allocator, try root.parser.parse(allocator, diff));
    defer app.deinit();
    const specs = stacked31Specs();
    try controller.applySnapshot(&app.state.sidebar, allocator, .{
        .records = try records(allocator, &specs),
        .viewer_login = viewer,
        .viewer_teams = "",
        .sync = .{ .last_ok_at = skim_io.timestamp() - 120 },
    });
    try controller.setPresets(&app.state.sidebar, allocator, &config.PrFilters{});
    app.state.sidebar.open = true;
    app.state.sidebar.visible = params.sidebar_visible;
    app.mode = .normal;
    if (params.agent_panel) {
        app.tab_manager = root.TabManager.init(allocator, .right);
        app.tab_manager.?.panel_visible = true;
        app.tab_manager.?.full_screen = false;
        _ = try app.tab_manager.?.createTab("Agent Tab");
    }

    var ctx = try harness.createTestContext(allocator, params.cols, params.rows);
    defer ctx.deinit();
    try root.frame.render(&app, ctx.window());
    const text = try ctx.captureToText();
    defer allocator.free(text);
    try snapshot.expectSnapshot(allocator, params.name, text);
}

/// The help popup's text at `scroll` rows down, rendered from `app`.
fn helpText(app: *root.App, scroll: usize) ![]const u8 {
    var ctx = try harness.createTestContext(testing.allocator, 80, 40);
    defer ctx.deinit();
    app.state.help_scroll_offset = scroll;
    try root.help.renderHelpPopup(app, ctx.window());
    return ctx.captureToText();
}

fn viewParams(frame_allocator: Allocator) controller.ViewParams {
    return .{ .focused = true, .now_secs = now, .frame_allocator = frame_allocator, .visible_rows = 100 };
}

fn expectSidebarSnapshot(params: struct {
    state: *SidebarState,
    name: []const u8,
    cols: u16,
    rows: u16,
    focused: bool = true,
}) !void {
    const allocator = testing.allocator;
    var ctx = try harness.createTestContext(allocator, params.cols, params.rows);
    defer ctx.deinit();
    controller.clampScroll(params.state, sidebar_render.listRows(params.rows, params.state.parse_error != null));
    sidebar_render.draw(ctx.window(), controller.view(params.state, .{
        .focused = params.focused,
        .now_secs = now,
        .frame_allocator = ctx.frameAllocator(),
        .visible_rows = sidebar_render.listRows(params.rows, params.state.parse_error != null),
    }));

    const text = try ctx.captureToText();
    defer allocator.free(text);
    try snapshot.expectSnapshot(allocator, params.name, text);
}

/// A Surface on a temp-file store with one registered repo, no worker.
const SurfaceFixture = struct {
    tmp: testing.TmpDir,
    path: [:0]u8,
    surface: surface.Surface,
    sidebar: SidebarState = .{},

    fn init() !SurfaceFixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try tmpDbPath(&tmp);
        errdefer testing.allocator.free(path);
        var db = try root.store.Store.open(testing.allocator, path);
        errdefer db.close();
        const repo_id = try db.ensureRepo(.{ .key = "k", .owner = "o", .name = "r" });
        return .{ .tmp = tmp, .path = path, .surface = .{ .store = db, .repo_id = repo_id } };
    }

    fn deinit(self: *SurfaceFixture) void {
        controller.deinitState(&self.sidebar, testing.allocator);
        surface.close(&self.surface);
        testing.allocator.free(self.path);
        self.tmp.cleanup();
    }
};

fn indexRow(number: u32, head: []const u8) types.IndexRow {
    return .{
        .number = number,
        .node_id = "node",
        .title = "title",
        .author = "alice",
        .url = "https://github.com/o/r/pull/1",
        .is_draft = false,
        .head_ref = head,
        .base_ref = "main",
        .head_oid = head_oid,
        .base_oid = other_oid,
        .updated_at = "2026-01-01T00:00:00Z",
        .labels = "",
    };
}

/// Presets for `surface.openAt` tests, so they never read ~/.skim/config.json.
const no_config_filters = root.config.PrFilters{};

fn tmpDbPath(tmp: *testing.TmpDir) ![:0]u8 {
    const relative = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/prs.db", .{tmp.sub_path});
    defer testing.allocator.free(relative);
    const absolute = try skim_io.absolutePathAlloc(testing.allocator, relative);
    defer testing.allocator.free(absolute);
    return testing.allocator.dupeZ(u8, absolute);
}

fn writeGarbage(path: []const u8) !void {
    const file = try std.Io.Dir.createFileAbsolute(skim_io.get(), path, .{});
    defer file.close(skim_io.get());
    const garbage = [_]u8{0xAB} ** 4096;
    try file.writeStreamingAll(skim_io.get(), &garbage);
}
