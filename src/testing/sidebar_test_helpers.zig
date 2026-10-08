//! Tests for the PR sidebar and its flip wiring: controller logic on in-memory
//! snapshots, and sidebar snapshots. Reaches production code through the
//! `pr_sidebar_test_root` named module (see `src/pr_sidebar_test_root.zig`), so
//! only this file's `test {}` blocks run in the `sidebar_tests` binary. The
//! sidebar tests need no DB: every fixture is a `types.RecordList` built the
//! way `store.listOpen` hands one over. The flip tests use a temp-file DB.

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
    url: []const u8 = "",
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
const stacked31_all_expanded_rows = 33;
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

test "applySnapshot: stacks start expanded by default" {
    const specs = stacked31Specs();
    var sb = SidebarState{};
    defer controller.deinitState(&sb, testing.allocator);
    try controller.applySnapshot(&sb, testing.allocator, .{
        .records = try records(testing.allocator, &specs),
        .viewer_login = viewer,
        .viewer_teams = "",
        .sync = recent_sync,
    });

    try testing.expectEqual(@as(usize, stacked31_all_expanded_rows), sb.rows.items.len);
    try expectRowNumbers(&sb, 1, &.{ 814, 813, 812 });
}

test "expand: l on a collapsed header expands the stack and keeps the cursor on the header" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);

    try controller.expand(&sb, testing.allocator);

    try testing.expectEqual(@as(usize, stacked31_expanded_rows), sb.rows.items.len);
    try testing.expectEqual(@as(usize, 0), sb.cursor);
    try testing.expect(sb.cursor_on_header);
}

test "expand: leaves an already expanded stack expanded" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.toggleExpand(&sb, testing.allocator);

    try controller.expand(&sb, testing.allocator);
    try testing.expectEqual(@as(usize, stacked31_expanded_rows), sb.rows.items.len);
}

test "expand: on a standalone row is a no-op" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    controller.move(&sb, 2);

    try controller.expand(&sb, testing.allocator);

    try testing.expectEqual(@as(usize, stacked31_rows), sb.rows.items.len);
    try testing.expectEqual(@as(?u32, first_standalone), sb.selected_number);
}

test "toggleCollapseAll: expands every stack, discarding per-stack folds" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.toggleExpand(&sb, testing.allocator);

    try controller.toggleCollapseAll(&sb, testing.allocator);

    try testing.expect(!sb.collapse_stacks);
    try testing.expectEqual(@as(usize, stacked31_all_expanded_rows), sb.rows.items.len);
}

test "toggleCollapseAll: collapsing from a member puts the cursor on its header" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.toggleCollapseAll(&sb, testing.allocator);
    controller.move(&sb, 2);
    try testing.expectEqual(@as(?u32, 813), sb.selected_number);

    try controller.toggleCollapseAll(&sb, testing.allocator);

    try testing.expect(sb.collapse_stacks);
    try testing.expectEqual(@as(usize, stacked31_rows), sb.rows.items.len);
    try testing.expectEqual(@as(usize, 0), sb.cursor);
    try testing.expect(sb.cursor_on_header);
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

test "cyclePreset: walks the configured presets in config order first" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);
    try testing.expectEqual(@as(?usize, 0), sb.active_preset);

    try controller.cyclePreset(&sb, testing.allocator);

    try testing.expectEqual(@as(?usize, 1), sb.active_preset);
    try testing.expectEqualStrings("author:@me", sb.queryText());
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

test "setPresets: no configured presets → built-in \"All open\" (empty query) via effectivePresets()" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);

    try controller.setPresets(&sb, testing.allocator, &config.PrFilters{});

    try testing.expectEqual(@as(usize, 1), sb.presets.len);
    try testing.expectEqualStrings("All open", sb.presets[0].name);
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
// Filter menu
// =============================================================================

test "menu toggles: each toggle's text parses to the term its checkbox looks for" {
    for (controller.menu_toggles) |toggle| {
        var query = switch (try root.filter_query.parse(testing.allocator, toggle.text)) {
            .ok => |query| query,
            .err => return error.TestUnexpectedResult,
        };
        defer query.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), query.terms.len);
        try testing.expect(root.filter_query.hasTerm(query, toggle.term));
    }
}

test "menu presets: configured presets first, then the built-ins whose query is not configured" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);

    try expectMenuPresetNames(&sb, &.{ "ready", "mine", "All open", "Needs my review", "Changed since seen" });
}

test "menu presets: with nothing configured the built-in All open heads the list once" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &config.PrFilters{});

    try expectMenuPresetNames(&sb, &.{ "All open", "Ready for review", "Needs my review", "Mine", "Changed since seen" });
}

test "menu items: presets, then the toggles, then Custom query and Clear filter" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);

    const count = controller.menuItemCount(&sb);
    try testing.expectEqual(@as(usize, 5 + controller.menu_toggles.len + 2), count);
    try testing.expectEqual(controller.MenuItem{ .preset = 4 }, controller.menuItemAt(&sb, 4));
    try testing.expectEqual(controller.MenuItem{ .toggle = 0 }, controller.menuItemAt(&sb, 5));
    try testing.expectEqual(controller.MenuItem.custom, controller.menuItemAt(&sb, count - 2));
    try testing.expectEqual(controller.MenuItem.clear, controller.menuItemAt(&sb, count - 1));
}

test "openMenu: the cursor starts on the active preset" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);
    try controller.cyclePreset(&sb, testing.allocator);

    controller.openMenu(&sb);

    try testing.expectEqual(controller.MenuItem{ .preset = 1 }, menuCursorItem(&sb));
}

test "openMenu: a query equal to a built-in preset puts the cursor on that preset" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);
    _ = try controller.applyQuery(&sb, testing.allocator, "is:changed");

    controller.openMenu(&sb);

    try testing.expectEqualStrings("Changed since seen", controller.menuPreset(&sb, menuCursorItem(&sb).preset).name);
}

test "openMenu: a custom query that matches no preset puts the cursor on the first item" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);
    _ = try controller.applyQuery(&sb, testing.allocator, "label:x");

    controller.openMenu(&sb);

    try testing.expectEqual(@as(usize, 0), sb.menu.?.cursor);
}

test "menuKey: up and down move the cursor and clamp at both ends" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);
    controller.openMenu(&sb);

    _ = try controller.menuKey(&sb, testing.allocator, .up);
    try testing.expectEqual(@as(usize, 0), sb.menu.?.cursor);
    for (0..100) |_| _ = try controller.menuKey(&sb, testing.allocator, .down);
    try testing.expectEqual(controller.menuItemCount(&sb) - 1, sb.menu.?.cursor);
    _ = try controller.menuKey(&sb, testing.allocator, .up);
    try testing.expectEqual(controller.menuItemCount(&sb) - 2, sb.menu.?.cursor);
}

test "menuKey: activating a toggle adds its term, keeps the menu open and filters the list" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);
    controller.openMenu(&sb);
    moveMenuTo(&sb, .{ .toggle = toggleIndex("Authored by me") });

    try testing.expectEqual(controller.MenuOutcome.query_changed, try controller.menuKey(&sb, testing.allocator, .activate));

    try testing.expectEqualStrings("-is:draft author:@me", sb.queryText());
    try testing.expect(sb.menu != null);
    try testing.expect(controller.toggleChecked(&sb, toggleIndex("Authored by me")));
    try testing.expectEqual(@as(usize, 1), sb.rows.items.len);
    try testing.expectEqual(@as(u32, 749), rowNumber(&sb, 0));
    try testing.expectEqual(@as(?usize, null), sb.active_preset);
}

test "menuKey: activating a checked toggle removes only its term" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    _ = try controller.applyQuery(&sb, testing.allocator, "author:bob -is:draft label:x");
    controller.openMenu(&sb);
    moveMenuTo(&sb, .{ .toggle = toggleIndex("Hide drafts") });
    try testing.expect(controller.toggleChecked(&sb, toggleIndex("Hide drafts")));

    _ = try controller.menuKey(&sb, testing.allocator, .activate);

    try testing.expectEqualStrings("author:bob label:x", sb.queryText());
    try testing.expect(!controller.toggleChecked(&sb, toggleIndex("Hide drafts")));
}

test "menuKey: toggling back to a preset's query re-selects that preset" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);
    controller.openMenu(&sb);
    moveMenuTo(&sb, .{ .toggle = toggleIndex("CI not failing") });

    _ = try controller.menuKey(&sb, testing.allocator, .activate);
    try testing.expectEqual(@as(?usize, null), sb.active_preset);
    _ = try controller.menuKey(&sb, testing.allocator, .activate);

    try testing.expectEqualStrings("-is:draft", sb.queryText());
    try testing.expectEqual(@as(?usize, 0), sb.active_preset);
}

test "menuKey: activating a preset applies it and closes the menu" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);
    controller.openMenu(&sb);
    moveMenuTo(&sb, .{ .preset = 1 });

    try testing.expectEqual(controller.MenuOutcome.query_changed, try controller.menuKey(&sb, testing.allocator, .activate));

    try testing.expect(sb.menu == null);
    try testing.expectEqualStrings("author:@me", sb.queryText());
    try testing.expectEqual(@as(?usize, 1), sb.active_preset);
}

test "menuKey: activating a built-in preset applies its query and the header names it" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);
    controller.openMenu(&sb);
    moveMenuTo(&sb, .{ .preset = 4 });

    _ = try controller.menuKey(&sb, testing.allocator, .activate);

    try testing.expectEqualStrings("is:changed", sb.queryText());
    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();
    try testing.expectEqualStrings("Changed since seen", controller.view(&sb, viewParams(frame.allocator())).header.label);
}

test "menuKey: Custom query closes the menu and opens the prompt pre-filled with the query" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    _ = try controller.applyQuery(&sb, testing.allocator, "author:bob");
    controller.openMenu(&sb);
    moveMenuTo(&sb, .custom);

    try testing.expectEqual(controller.MenuOutcome.none, try controller.menuKey(&sb, testing.allocator, .activate));

    try testing.expect(sb.menu == null);
    try testing.expectEqualStrings("author:bob", sb.prompt.?.text());
}

test "menuKey: the custom key opens the prompt from any item" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    controller.openMenu(&sb);

    _ = try controller.menuKey(&sb, testing.allocator, .custom);

    try testing.expect(sb.menu == null);
    try testing.expect(sb.prompt != null);
}

test "menuKey: Clear filter empties the query, shows every PR and closes the menu" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    _ = try controller.applyQuery(&sb, testing.allocator, "author:bob");
    controller.openMenu(&sb);
    moveMenuTo(&sb, .clear);

    try testing.expectEqual(controller.MenuOutcome.query_changed, try controller.menuKey(&sb, testing.allocator, .activate));

    try testing.expect(sb.menu == null);
    try testing.expectEqualStrings("", sb.queryText());
    try testing.expectEqual(@as(usize, stacked31_rows), sb.rows.items.len);
}

test "menuKey: close leaves the query alone" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    _ = try controller.applyQuery(&sb, testing.allocator, "author:bob");
    controller.openMenu(&sb);

    try testing.expectEqual(controller.MenuOutcome.none, try controller.menuKey(&sb, testing.allocator, .close));

    try testing.expect(sb.menu == null);
    try testing.expectEqualStrings("author:bob", sb.queryText());
}

test "menuKey: a toggle that would overflow the query cap is refused" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    const long_query = "x" ** (root.sidebar_state.query_cap - 4);
    _ = try controller.applyQuery(&sb, testing.allocator, long_query);
    controller.openMenu(&sb);
    moveMenuTo(&sb, .{ .toggle = toggleIndex("Hide drafts") });

    try testing.expectEqual(controller.MenuOutcome.too_long, try controller.menuKey(&sb, testing.allocator, .activate));

    try testing.expectEqualStrings(long_query, sb.queryText());
    try testing.expect(sb.menu != null);
}

test "menuKey: a toggle over a stored query cut mid-term at the cap is refused, not applied" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    // 250 + 13 bytes: kept as its first 256, which ends inside the quotes.
    _ = try controller.applyQuery(&sb, testing.allocator, "x" ** 250 ++ " \"abcdefghij\"");
    const kept = try testing.allocator.dupe(u8, sb.queryText());
    defer testing.allocator.free(kept);
    controller.openMenu(&sb);
    moveMenuTo(&sb, .{ .toggle = toggleIndex("Hide drafts") });

    try testing.expectEqual(controller.MenuOutcome.too_long, try controller.menuKey(&sb, testing.allocator, .activate));

    try testing.expectEqualStrings(kept, sb.queryText());
    try testing.expect(sb.parse_error == null);
}

test "menuKey: a preset whose query does not parse closes the menu and shows the parse error" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &config.PrFilters{ .presets = &.{
        .{ .name = "ok", .query = "author:bob" },
        .{ .name = "broken", .query = "revew:requested" },
    } });
    controller.openMenu(&sb);
    moveMenuTo(&sb, .{ .preset = 1 });

    try testing.expectEqual(controller.MenuOutcome.none, try controller.menuKey(&sb, testing.allocator, .activate));

    try testing.expect(sb.menu == null);
    try testing.expect(sb.parse_error != null);
    try testing.expectEqualStrings("author:bob", sb.queryText());
}

test "menu: a re-applied snapshot (sync reload) keeps the menu open on the same item" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);
    controller.openMenu(&sb);
    moveMenuTo(&sb, .{ .toggle = 1 });

    const specs = stacked31Specs();
    try reapply(&sb, &specs);

    try testing.expectEqual(controller.MenuItem{ .toggle = 1 }, menuCursorItem(&sb));
}

test "menuKey: with the menu closed every key is a no-op" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);

    try testing.expectEqual(controller.MenuOutcome.none, try controller.menuKey(&sb, testing.allocator, .activate));
    try testing.expect(sb.menu == null);
    try testing.expect(sb.prompt == null);
}

test "menu cursor: a shorter preset list after setPresets clamps the cursor onto the last item" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &config.PrFilters{ .presets = &.{
        .{ .name = "a", .query = "label:a" },
        .{ .name = "b", .query = "label:b" },
        .{ .name = "c", .query = "label:c" },
    } });
    controller.openMenu(&sb);
    moveMenuTo(&sb, .clear);
    try controller.setPresets(&sb, testing.allocator, &two_presets);

    try testing.expectEqual(controller.MenuItem.clear, menuCursorItem(&sb));
}

test "view: menu checkboxes are derived from the parsed query" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    _ = try controller.applyQuery(&sb, testing.allocator, "author:@me -ci:failure");
    controller.openMenu(&sb);
    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();

    const menu = controller.view(&sb, viewParams(frame.allocator())).menu.?;

    // Hide drafts, Review requested, Authored by me, CI not failing, Changed since seen.
    try testing.expectEqualSlices(bool, &.{ false, false, true, true, false }, &toggleStates(menu));
    try testing.expectEqualStrings("author:@me -ci:failure", menu.query);
}

test "view: the menu counts the matching PRs and stacks" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    _ = try controller.applyQuery(&sb, testing.allocator, "stack:any");
    controller.openMenu(&sb);
    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();

    const menu = controller.view(&sb, viewParams(frame.allocator())).menu.?;

    try testing.expectEqual(@as(usize, 5), menu.visible);
    try testing.expectEqual(@as(usize, 31), menu.total);
    try testing.expectEqual(@as(usize, 2), menu.stacks);
}

test "view: no menu while it is closed" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();

    try testing.expect(controller.view(&sb, viewParams(frame.allocator())).menu == null);
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
    try root.surface_controller.enterReviewDiff(app.surfaceCtx(), .{ .head_ref = "HEAD", .base_ref = "" });
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

test "snapshot: diff_header_changed_since_seen" {
    try expectAppSnapshot(.{ .name = "diff_header_changed_since_seen", .cols = 120, .rows = 24, .file_count = 3, .changed_files = &.{ false, true, false } });
}

test "snapshot: since_seen_indicator" {
    try expectAppSnapshot(.{ .name = "since_seen_indicator", .cols = 120, .rows = 24, .previewed = 813, .previewed_view = .since_seen });
}

test "snapshot: whole_stack_indicator" {
    try expectAppSnapshot(.{ .name = "whole_stack_indicator", .cols = 120, .rows = 24, .previewed = 813, .previewed_view = .whole_stack });
}

test "help: with the sidebar open, page up lists the keys that still reach it" {
    var app = try diffFocusedApp();
    defer app.deinit();

    const top = try helpText(&app, 0);
    defer testing.allocator.free(top);
    const bottom = try helpText(&app, 20);
    defer testing.allocator.free(bottom);

    try testing.expect(std.mem.indexOf(u8, top, "b / PageUp") != null);
    try testing.expect(std.mem.indexOf(u8, top, "Ctrl-b") == null);
    try testing.expect(std.mem.indexOf(u8, bottom, "Tab            │ Cycle hunk filter") != null);
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

test "help: G scrolls to the last row with the PR sections listed" {
    var app = try diffFocusedApp();
    defer app.deinit();
    app.state.review.active = true;
    try app.handleKey(.{ .codepoint = '?' });
    try app.handleKey(.{ .codepoint = 'G' });

    const text = try helpText(&app, app.state.help_scroll_offset);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "Agent help (detailed)") != null);
}

test "help: j past the bottom does not bank rows k must scroll back through" {
    var app = try diffFocusedApp();
    defer app.deinit();
    app.state.review.active = true;
    try app.handleKey(.{ .codepoint = '?' });
    try app.handleKey(.{ .codepoint = 'G' });
    testing.allocator.free(try helpText(&app, app.state.help_scroll_offset));
    try app.handleKey(.{ .codepoint = 'j' });
    testing.allocator.free(try helpText(&app, app.state.help_scroll_offset));
    try app.handleKey(.{ .codepoint = 'k' });

    const text = try helpText(&app, app.state.help_scroll_offset);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "Agent help (detailed)") == null);
}

test "help: ? with the sidebar focused opens the overlay" {
    var app = try sidebarApp();
    defer app.deinit();

    try app.handleKey(.{ .codepoint = '?' });

    try testing.expectEqual(root.App.Mode.help, app.mode);
}

test "help: closing the overlay opened from the sidebar refocuses the sidebar" {
    var app = try sidebarApp();
    defer app.deinit();
    try app.handleKey(.{ .codepoint = '?' });

    try app.handleKey(.{ .codepoint = Key.escape });

    try testing.expectEqual(root.App.Mode.pr_review, app.mode);
}

test "help: closing the overlay opened from the diff refocuses the diff" {
    var app = try sidebarApp();
    defer app.deinit();
    try app.handleKey(.{ .codepoint = '?' });
    try app.handleKey(.{ .codepoint = Key.escape });
    app.mode = .normal;
    try app.handleKey(.{ .codepoint = '?' });

    try app.handleKey(.{ .codepoint = 'q' });

    try testing.expectEqual(root.App.Mode.normal, app.mode);
}

test "help: the PR sections list the menu, prompt, conversation, info and submit keys" {
    var app = try diffFocusedApp();
    defer app.deinit();
    app.state.review.active = true;

    const text = try helpAllText(&app);
    defer testing.allocator.free(text);

    const expected = [_][]const u8{
        "Filter menu: move / apply",
        "Filter prompt: clear / delete word",
        "Conversation: next / prev",
        "Conversation: top / bottom",
        "Conversation: jump to thread",
        "Info panel: refetch",
        "Submit: cycle verdict",
        "Submit: discard (press twice)",
    };
    for (expected) |row| {
        try testing.expect(std.mem.indexOf(u8, text, row) != null);
    }
}

test "help: the diff lists blame, stack navigation and find repeat" {
    var app = try diffFocusedApp();
    defer app.deinit();
    app.state.sidebar.open = false;

    const text = try helpAllText(&app);
    defer testing.allocator.free(text);

    const expected = [_][]const u8{ "Toggle git blame", "Graphite stack picker", "Parent / child branch in stack", "Repeat last find", "Stage file / all files" };
    for (expected) |row| {
        try testing.expect(std.mem.indexOf(u8, text, row) != null);
    }
}

test "help: staging is left out while a PR diff is open" {
    var app = try diffFocusedApp();
    defer app.deinit();

    const text = try helpAllText(&app);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "Stage file / all files") == null);
}

test "filter menu: Ctrl-n and Ctrl-p move the cursor down and up" {
    var app = try sidebarApp();
    defer app.deinit();
    try app.handleKey(.{ .codepoint = 'f' });
    const start = app.state.sidebar.menu.?.cursor;

    try app.handleKey(.{ .codepoint = 'n', .mods = .{ .ctrl = true } });
    try testing.expectEqual(start + 1, app.state.sidebar.menu.?.cursor);
    try app.handleKey(.{ .codepoint = 'p', .mods = .{ .ctrl = true } });
    try testing.expectEqual(start, app.state.sidebar.menu.?.cursor);
}

test "Esc in the sidebar: an open filter prompt is cancelled before anything else" {
    var app = try sidebarApp();
    defer app.deinit();
    try app.handleKey(.{ .codepoint = '/' });
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

test "sidebar keys: Tab and Ctrl-b keep the sidebar when no diff is loaded" {
    var app = try sidebarApp();
    defer app.deinit();

    try app.handleKey(.{ .codepoint = Key.tab });
    try app.handleKey(.{ .codepoint = 'b', .mods = .{ .ctrl = true } });

    try testing.expectEqual(root.App.Mode.pr_review, app.mode);
    try testing.expect(app.state.sidebar.visible);
}

test "sidebar keys: S collapses every stack, then l expands the one under the cursor" {
    var app = try sidebarApp();
    defer app.deinit();
    const sb = &app.state.sidebar;

    try app.handleKey(.{ .codepoint = 'S' });
    try testing.expectEqual(@as(usize, stacked31_rows), sb.rows.items.len);

    try app.handleKey(.{ .codepoint = 'l' });

    try testing.expectEqual(@as(usize, stacked31_expanded_rows), sb.rows.items.len);
    try testing.expectEqual(root.App.Mode.pr_review, app.mode);
}

test "diff keys: Tab cycles the hunk view and keeps the diff focused" {
    var app = try diffFocusedApp();
    defer app.deinit();
    const hunk_mode = app.state.hunk_view_mode;

    try app.handleKey(.{ .codepoint = Key.tab });

    try testing.expect(app.state.hunk_view_mode != hunk_mode);
    try testing.expectEqual(root.App.Mode.normal, app.mode);
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

test "diff keys: A does not stage the working tree or close the PR view" {
    var app = try diffFocusedApp();
    defer app.deinit();
    app.state.pager_mode = false;

    try app.handleKey(.{ .codepoint = 'A' });

    try testing.expect(app.state.sidebar.open);
    try testing.expect(app.state.diff_source == .stdin);
    try testing.expectEqualStrings("staging is not available on a PR diff", app.state.status_message.?);
}

test "diff keys: a does not stage the current file or close the PR view" {
    var app = try diffFocusedApp();
    defer app.deinit();
    app.state.pager_mode = false;

    try app.handleKey(.{ .codepoint = 'a' });

    try testing.expect(app.state.sidebar.open);
    try testing.expect(app.state.diff_source == .stdin);
    try testing.expectEqualStrings("staging is not available on a PR diff", app.state.status_message.?);
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
    try app.handleKey(.{ .codepoint = '/' });
    const before = app.state.sidebar.prompt.?.len;

    try app.handleKey(.{ .codepoint = Key.up });
    try app.handleKey(.{ .codepoint = Key.left });

    try testing.expectEqual(before, app.state.sidebar.prompt.?.len);
}

test "filter prompt: non-ASCII text is typed through" {
    var app = try sidebarApp();
    defer app.deinit();
    try app.handleKey(.{ .codepoint = '/' });
    try app.handleKey(.{ .codepoint = Key.end });
    const before = app.state.sidebar.prompt.?.len;

    try app.handleKey(.{ .codepoint = 0xE9, .text = "\u{e9}" });

    try testing.expectEqual(before + 2, app.state.sidebar.prompt.?.len);
}

test "filter menu keys: f, j to a toggle and Space filter the list live behind the open menu" {
    var app = try sidebarApp();
    defer app.deinit();
    const sb = &app.state.sidebar;
    try testing.expectEqual(@as(usize, stacked31_all_expanded_rows), sb.rows.items.len);

    try app.handleKey(.{ .codepoint = 'f' });
    try testing.expect(sb.menu != null);
    for (0..menuPresetCount(sb) + toggleIndex("Authored by me")) |_| try app.handleKey(.{ .codepoint = 'j' });
    try app.handleKey(.{ .codepoint = ' ', .text = " " });

    try testing.expect(sb.menu != null);
    try testing.expectEqualStrings("-is:draft author:@me", sb.queryText());
    const visible = try controller.visibleNumbers(sb, testing.allocator);
    defer testing.allocator.free(visible);
    try testing.expectEqualSlices(u32, &.{749}, visible);
}

test "filter menu keys: Esc closes the menu and keeps the surface and the filter" {
    var app = try sidebarApp();
    defer app.deinit();
    try app.handleKey(.{ .codepoint = 'f' });

    try app.handleKey(.{ .codepoint = Key.escape });

    try testing.expect(app.state.sidebar.menu == null);
    try testing.expect(app.state.sidebar.open);
    try testing.expectEqual(root.App.Mode.pr_review, app.mode);
    try testing.expectEqualStrings("-is:draft", app.state.sidebar.queryText());
}

test "filter menu keys: f again closes the menu" {
    var app = try sidebarApp();
    defer app.deinit();
    try app.handleKey(.{ .codepoint = 'f' });

    try app.handleKey(.{ .codepoint = 'f' });

    try testing.expect(app.state.sidebar.menu == null);
}

test "filter menu keys: Ctrl-c closes the menu before peeling the preset or the surface" {
    var app = try sidebarApp();
    defer app.deinit();
    _ = try controller.applyQuery(&app.state.sidebar, testing.allocator, "label:x");
    try app.handleKey(.{ .codepoint = 'f' });

    try app.handleKey(.{ .codepoint = 'c', .mods = .{ .ctrl = true } });

    try testing.expect(app.state.sidebar.menu == null);
    try testing.expectEqualStrings("label:x", app.state.sidebar.queryText());
    try testing.expect(app.state.sidebar.open);
}

test "filter menu keys: Down to a preset and Enter applies it and closes the menu" {
    var app = try sidebarApp();
    defer app.deinit();
    try app.handleKey(.{ .codepoint = 'f' });

    try app.handleKey(.{ .codepoint = Key.down });
    try app.handleKey(.{ .codepoint = Key.enter });

    try testing.expect(app.state.sidebar.menu == null);
    try testing.expectEqualStrings("author:@me", app.state.sidebar.queryText());
    try testing.expectEqual(@as(usize, 1), app.state.sidebar.rows.items.len);
}

test "filter menu keys: G then Enter on Clear filter shows every PR" {
    var app = try sidebarApp();
    defer app.deinit();
    _ = try controller.applyQuery(&app.state.sidebar, testing.allocator, "author:bob");
    try app.handleKey(.{ .codepoint = 'f' });

    try app.handleKey(.{ .codepoint = 'G' });
    try app.handleKey(.{ .codepoint = Key.enter });

    try testing.expectEqualStrings("", app.state.sidebar.queryText());
    try testing.expectEqual(@as(usize, stacked31_all_expanded_rows), app.state.sidebar.rows.items.len);
}

test "filter menu keys: / in the menu opens the prompt with the query, and typing filters on Enter" {
    var app = try sidebarApp();
    defer app.deinit();
    try app.handleKey(.{ .codepoint = 'f' });

    try app.handleKey(.{ .codepoint = '/' });
    try testing.expect(app.state.sidebar.menu == null);
    try testing.expectEqualStrings("-is:draft", app.state.sidebar.prompt.?.text());
    try app.handleKey(.{ .codepoint = Key.end });
    for (" author:bob") |c| try app.handleKey(.{ .codepoint = c, .text = &.{c} });
    try app.handleKey(.{ .codepoint = Key.enter });

    try testing.expectEqualStrings("-is:draft author:bob", app.state.sidebar.queryText());
    try testing.expectEqual(@as(usize, standalone_count / 2), app.state.sidebar.rows.items.len);
}

test "filter menu keys: F still cycles presets without opening the menu" {
    var app = try sidebarApp();
    defer app.deinit();

    try app.handleKey(.{ .codepoint = 'F' });

    try testing.expect(app.state.sidebar.menu == null);
    try testing.expectEqual(@as(?usize, 1), app.state.sidebar.active_preset);
}

test "snapshot: sidebar_filter_menu" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &config.PrFilters{});
    controller.openMenu(&sb);

    try expectSidebarSnapshot(.{ .state = &sb, .name = "sidebar_filter_menu", .cols = 44, .rows = 30 });
}

test "snapshot: sidebar_filter_menu_preset_toggles" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &config.PrFilters{ .presets = &.{
        .{ .name = "triage", .query = "-is:draft review:requested" },
        .{ .name = "all", .query = "" },
    } });
    controller.openMenu(&sb);

    try expectSidebarSnapshot(.{ .state = &sb, .name = "sidebar_filter_menu_preset_toggles", .cols = 44, .rows = 30 });
}

test "snapshot: sidebar_filter_menu_short scrolls the items to keep the cursor visible" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);
    controller.openMenu(&sb);
    moveMenuTo(&sb, .clear);

    try expectSidebarSnapshot(.{ .state = &sb, .name = "sidebar_filter_menu_short", .cols = 32, .rows = 16 });
}

test "draw: a filter menu in a sidebar too short for it draws no box and does not crash" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    controller.openMenu(&sb);
    var ctx = try harness.createTestContext(testing.allocator, 30, 6);
    defer ctx.deinit();

    sidebar_render.draw(ctx.window(), controller.view(&sb, .{
        .focused = true,
        .now_secs = now,
        .frame_allocator = ctx.frameAllocator(),
        .visible_rows = sidebar_render.listRows(6, false),
    }));

    const text = try ctx.captureToText();
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "╭") == null);
}

// =============================================================================
// Flip wiring
// =============================================================================

test "comments store: every mutating method bumps revision" {
    var store = root.comments.CommentStore.init(testing.allocator);
    defer store.deinit();
    var last = store.revision;

    _ = try store.add(.{ .file_path = "a.txt", .hunk_idx = 0, .line_idx = 0, .text = "t", .line_type = .add, .line_content = "x" });
    try expectBumped(&last, store.revision);
    try store.updateComment(0, "t2");
    try expectBumped(&last, store.revision);
    _ = try store.addReply(0, "you", "r");
    try expectBumped(&last, store.revision);
    try store.updateReply(0, 0, "r2");
    try expectBumped(&last, store.revision);
    try store.deleteReply(0, 0);
    try expectBumped(&last, store.revision);
    try store.deleteComment(0);
    try expectBumped(&last, store.revision);
    store.clearAll();
    try expectBumped(&last, store.revision);

    // A rejected mutation changes nothing, so it does not count.
    try testing.expectError(error.InvalidCommentIndex, store.updateComment(5, "x"));
    try testing.expectEqual(last, store.revision);
}

test "recordByNumber: finds a PR hidden by the filter; unknown number is null" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    _ = try controller.applyQuery(&sb, testing.allocator, "is:draft");

    try testing.expectEqual(@as(u32, 812), controller.recordByNumber(&sb, 812).?.number);
    try testing.expect(controller.recordByNumber(&sb, 1) == null);
}

test "stackPlace: a middle member has its parent, the stack's bottom and tip" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    const items = sb.records.?.items;

    const place = controller.stackPlace(&sb, controller.recordIndex(&sb, 813).?);

    try testing.expectEqual(@as(u32, 812), items[place.parent.?].number);
    try testing.expectEqual(@as(u32, 812), items[place.bottom.?].number);
    try testing.expectEqual(@as(u32, 814), items[place.tip.?].number);
}

test "stackPlace: a standalone PR has no parent, bottom or tip" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);

    const place = controller.stackPlace(&sb, controller.recordIndex(&sb, first_standalone).?);

    try testing.expect(place.parent == null and place.bottom == null and place.tip == null);
}

test "view: rows of PRs in sidebar.cached show the cache glyph" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try sb.cached.put(testing.allocator, first_standalone, {});
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const v = controller.view(&sb, viewParams(arena.allocator()));

    try testing.expectEqual(first_standalone, v.rows[2].number);
    try testing.expectEqual(sidebar_render.CacheState.cached, v.rows[2].cache);
    try testing.expectEqual(sidebar_render.CacheState.unknown, v.rows[3].cache);
}

// -----------------------------------------------------------------------------
// Notes on a temp-file DB (pr_surface.saveNotes / restoreNotes)
// -----------------------------------------------------------------------------

test "saveNotes: inserts new comments with linenos and line content; note_ids filled" {
    var nx = try NotesFixture.init();
    defer nx.deinit();
    _ = try nx.comments.add(noteOnAddedA("first"));

    try nx.save(101);

    var rows = try nx.listNotes(101);
    defer rows.deinit();
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("a.txt", rows.items[0].file_path);
    try testing.expectEqualStrings("add", rows.items[0].line_type);
    try testing.expectEqual(@as(?u32, 2), rows.items[0].new_lineno);
    try testing.expectEqualStrings("added-a", rows.items[0].line_content);
    try testing.expectEqualStrings("first", rows.items[0].text);
    try testing.expectEqual(rows.items[0].id, nx.note_ids.get(nx.comments.comments.items[0].id).?);
}

test "saveNotes: edited text and a new reply update the row in place" {
    var nx = try NotesFixture.init();
    defer nx.deinit();
    _ = try nx.comments.add(noteOnAddedA("first"));
    try nx.save(101);

    try nx.comments.updateComment(0, "edited");
    _ = try nx.comments.addReply(0, "you", "agreed");
    try nx.save(101);

    var rows = try nx.listNotes(101);
    defer rows.deinit();
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("edited", rows.items[0].text);
    try testing.expect(std.mem.indexOf(u8, rows.items[0].replies, "agreed") != null);
}

test "saveNotes: a deleted comment deletes its row" {
    var nx = try NotesFixture.init();
    defer nx.deinit();
    _ = try nx.comments.add(noteOnAddedA("first"));
    try nx.save(101);

    try nx.comments.deleteComment(0);
    try nx.save(101);

    var rows = try nx.listNotes(101);
    defer rows.deinit();
    try testing.expectEqual(@as(usize, 0), rows.items.len);
}

test "saveNotes: a row not in note_ids (an orphan) survives a save" {
    var nx = try NotesFixture.init();
    defer nx.deinit();
    _ = try nx.store().insertNote(nx.fx.surface.repo_id, orphanRow(101));

    try nx.save(101);

    var rows = try nx.listNotes(101);
    defer rows.deinit();
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("lost note", rows.items[0].text);
}

test "restoreNotes: PR A's notes land in the store; PR B's do not" {
    var nx = try NotesFixture.init();
    defer nx.deinit();
    _ = try nx.comments.add(noteOnAddedA("for-101"));
    try nx.save(101);
    nx.comments.clearAll();
    _ = try nx.comments.add(noteOnAddedA("for-102"));
    try nx.save(102);
    nx.comments.clearAll();

    try nx.restore(101);

    try testing.expectEqual(@as(usize, 1), nx.comments.comments.items.len);
    try testing.expectEqualStrings("for-101", nx.comments.comments.items[0].text);
    try testing.expectEqual(@as(u32, 1), nx.note_ids.count());
}

test "restoreNotes: an unanchorable note becomes an orphan and stays in the DB" {
    var nx = try NotesFixture.init();
    defer nx.deinit();
    _ = try nx.store().insertNote(nx.fx.surface.repo_id, orphanRow(101));

    try nx.restore(101);

    try testing.expectEqual(@as(usize, 0), nx.comments.comments.items.len);
    try testing.expectEqual(@as(usize, 1), nx.orphans.items.len);
    try testing.expectEqualStrings("lost note", nx.orphans.items[0].text);
    var rows = try nx.listNotes(101);
    defer rows.deinit();
    try testing.expectEqual(@as(usize, 1), rows.items.len);
}

// -----------------------------------------------------------------------------
// App-level flip wiring (temp DB, no worker, no subprocess)
// -----------------------------------------------------------------------------

test "installParsedFiles: a set with a displayed_key is parked in the LRU, and take returns the same pointer" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try app.installParsedFiles(try root.parser.parse(testing.allocator, flip_diff_a));
    const parked = app.state.files.ptr;
    app.state.flip.displayed_key = key_a;

    try app.installParsedFiles(try root.parser.parse(testing.allocator, flip_diff_b));

    try testing.expect(app.state.flip.displayed_key == null);
    const lru = &app.state.flip.lru.?;
    const taken = lru.take(key_a).?;
    try testing.expectEqual(parked, taken.ptr);
    lru.put(key_a, taken);
}

test "installParsedFiles: a set without a displayed_key is freed, not parked" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try app.installParsedFiles(try root.parser.parse(testing.allocator, flip_diff_a));

    try app.installParsedFiles(try root.parser.parse(testing.allocator, flip_diff_b));

    try testing.expect(!app.state.flip.lru.?.contains(key_a));
    try testing.expectEqualStrings("b.txt", app.state.files[0].new_path);
}

test "installPrDiff: keeps the sidebar focused" {
    var fx = try FlipApp.init();
    defer fx.deinit();

    try fx.install(.{ .number = 101 });

    try testing.expectEqual(root.App.Mode.pr_review, fx.app.mode);
    try testing.expectEqual(@as(?u32, 101), fx.app.state.flip.previewed);
    try testing.expectEqual(@as(u32, 101), fx.app.state.review.number);
}

test "installPrDiff: diff_source is origin/<base>...<cached head oid> with the merge base" {
    var fx = try FlipApp.init();
    defer fx.deinit();

    try fx.install(.{ .number = 101 });

    const refs = fx.app.state.diff_source.two_refs;
    try testing.expectEqualStrings("origin/main", refs.ref1);
    try testing.expectEqualStrings(oid_a, refs.ref2);
    try testing.expect(refs.use_merge_base);
}

test "installPrDiff: after A then B the comment store holds only B's notes, and A's are saved" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 101 });
    _ = try app.state.comment_store.add(noteOnAddedA("note-a"));

    try fx.install(.{ .number = 102 });

    try testing.expectEqual(@as(usize, 0), app.state.comment_store.comments.items.len);
    _ = try app.state.comment_store.add(noteOnAddedB("note-b"));
    try fx.install(.{ .number = 101 });
    try testing.expectEqual(@as(usize, 1), app.state.comment_store.comments.items.len);
    try testing.expectEqualStrings("note-a", app.state.comment_store.comments.items[0].text);
}

test "installPrDiff: a failed install leaves the outgoing PR's saved notes untouched" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 101 });
    _ = try app.state.comment_store.add(noteOnAddedA("note-a"));
    _ = try fx.store().insertNote(fx.repoId(), orphanRow(102));
    try fx.store().db.exec("UPDATE local_note SET new_lineno = -1 WHERE number = 102");

    try testing.expectError(error.SqliteError, fx.install(.{ .number = 102 }));
    root.surface_controller.tick(app.surfaceCtx(), 0);

    var rows = try fx.store().listNotes(testing.allocator, .{ .repo_id = fx.repoId(), .number = 101 });
    defer rows.deinit();
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("note-a", rows.items[0].text);
}

test "previewMiss cancels a streaming load of the outgoing PR" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 101 });
    app.state.review.gh_bin = flip_missing_bin;
    app.state.review.git_bin = flip_missing_bin;
    try app.refresh();
    try testing.expect(app.state.diff_load.isLoading());

    app.previewPr(102);

    try testing.expect(!app.state.diff_load.isLoading());
    try testing.expectEqual(@as(?u32, 102), app.state.flip.loading_number);
}

test "a failed PR→PR miss keeps the displayed PR previewed with its notes, and writes persist to it" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 101 });
    _ = try app.state.comment_store.add(noteOnAddedA("note-a"));
    app.state.review.gh_bin = flip_missing_bin;
    app.state.review.git_bin = flip_missing_bin;

    app.previewPr(102);
    try fx.awaitEntryOutcome();

    try testing.expectEqual(@as(?u32, null), app.state.flip.loading_number);
    try testing.expectEqual(@as(?u32, 101), app.state.flip.previewed);
    try testing.expect(app.localWritesBlocked() == null);
    try testing.expectEqual(@as(usize, 1), app.state.comment_store.comments.items.len);
    _ = try app.state.comment_store.add(noteOnAddedA("note-a2"));
    root.surface_controller.tick(app.surfaceCtx(), 0);
    var rows = try fx.store().listNotes(testing.allocator, .{ .repo_id = fx.repoId(), .number = 101 });
    defer rows.deinit();
    try testing.expectEqual(@as(usize, 2), rows.items.len);
}

test "an explicit open that installs from the cache marks the PR seen" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    fx.app.state.flip.focus_diff = true;

    try fx.install(.{ .number = 102 });

    try testing.expectEqual(root.App.Mode.normal, fx.app.mode);
    const row = (try fx.store().getSeen(fx.repoId(), 102)).?;
    try testing.expectEqualStrings(oid_b, &row.head_oid);
    try testing.expect(fx.app.state.flip.dwell_done);
}

test "the dwell's markSeen clears the previewed PR's changed-since-seen marks" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 101 });
    root.flip.clearDiffState(&app.state.flip, testing.allocator, &app.state.collapsed_folds);
    app.state.flip.changed_files = try testing.allocator.dupe(bool, &.{true});

    root.surface_controller.tick(app.surfaceCtx(), app.state.flip.preview_started_ms + root.flip.dwell_ms);

    try testing.expect(app.state.flip.dwell_done);
    try testing.expectEqual(@as(usize, 0), app.state.flip.changed_files.len);
}

test "installPrDiff: the whole-stack view hides review threads" {
    var fx = try FlipApp.init();
    defer fx.deinit();

    try fx.install(.{ .number = 202, .view = .whole_stack });

    try testing.expect(fx.app.reviewAnchored() == null);
    try testing.expect(!fx.app.state.review.active);
    try testing.expectEqual(root.flip.DiffView.whole_stack, fx.app.state.flip.previewed_view);
    const refs = fx.app.state.diff_source.two_refs;
    try testing.expectEqualStrings("origin/main", refs.ref1);
    try testing.expectEqualStrings(oid_s2, refs.ref2);
}

test "the whole-stack view refuses a local note, which only a PR's own diff saves" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 202, .view = .whole_stack });
    app.mode = .normal;
    app.state.global_cursor_line = firstCodeRow(&app.state.line_map);

    try root.comment_controller.CommentController.startCommentInput(app);

    try testing.expect(app.state.active_comment_input == null);
    try testing.expectEqualStrings("notes are only saved on a PR's own diff", app.state.status_message.?);
}

test "the since-seen view refuses local writes" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    surface.markSeen(&app.state.pr_surface, .{ .allocator = testing.allocator, .number = 101, .sidebar = &app.state.sidebar, .now = now });

    try fx.install(.{ .number = 101, .view = .since_seen });

    try testing.expectEqual(root.surface_controller.LocalWriteBlock.unsaved_view, app.localWritesBlocked().?);
}

test "the PR's own view accepts local writes" {
    var fx = try FlipApp.init();
    defer fx.deinit();

    try fx.install(.{ .number = 101 });

    try testing.expectEqual(@as(?root.surface_controller.LocalWriteBlock, null), fx.app.localWritesBlocked());
}

test "installPrDiff: an open comment editor keeps the diff on screen and frees the incoming files" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 101 });
    app.mode = .normal;
    app.state.global_cursor_line = firstCodeRow(&app.state.line_map);
    try root.comment_controller.CommentController.startCommentInput(app);
    try testing.expect(app.state.active_comment_input != null);

    try testing.expectError(error.CommentEditorOpen, fx.install(.{ .number = 102 }));

    try testing.expectEqual(@as(?u32, 101), app.state.flip.previewed);
    try testing.expect(app.state.active_comment_input != null);
    try testing.expectEqualStrings("finish or cancel the open comment first", app.state.sidebar.messageText());
}

test "installPrDiff refuses while a comment editor is open, keeping the shown PR" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 101 });
    app.mode = .normal;
    app.state.global_cursor_line = firstCodeRow(&app.state.line_map);
    try root.comment_controller.CommentController.startCommentInput(app);
    try testing.expect(app.state.active_comment_input != null);

    try testing.expectError(error.CommentEditorOpen, fx.install(.{ .number = 102 }));

    try testing.expectEqual(@as(?u32, 101), app.state.flip.previewed);
    try testing.expectEqualStrings("finish or cancel the open comment first", app.state.sidebar.messageText());
}

test "previewPr while a comment editor is open defers the flip until it closes" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 101 });
    app.mode = .normal;
    app.state.global_cursor_line = firstCodeRow(&app.state.line_map);
    try root.comment_controller.CommentController.startCommentInput(app);

    app.previewPr(102);

    try testing.expectEqual(@as(u32, 102), app.state.flip.pending.?.number);
    try testing.expectEqual(@as(?u32, 101), app.state.flip.previewed);
    try testing.expectEqualStrings("finish or cancel the open comment first", app.state.sidebar.messageText());
}

test "installPrDiff: with fresh cached threads the session shows them without a refetch" {
    var fx = try FlipApp.init();
    defer fx.deinit();

    try fx.install(.{ .number = 101 });

    try testing.expect(!fx.app.state.review.entry_in_flight);
    try testing.expect(!fx.app.state.review.data_unavailable);
    try testing.expectEqualStrings("Flip 101", fx.app.state.review.title);
}

test "refresh after a hit clears displayed_key, so the refreshed set is not parked" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 101 });
    try testing.expect(app.state.flip.displayed_key != null);

    try app.applyRefreshedFiles(try root.parser.parse(testing.allocator, flip_diff_a));

    try testing.expect(app.state.flip.displayed_key == null);
}

test "changed-only toggle collapses exactly the unchanged files and restores them" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 101, .diff = flip_diff_two_files });
    root.flip.clearDiffState(&app.state.flip, testing.allocator, &app.state.collapsed_folds);
    app.state.flip.changed_files = try testing.allocator.dupe(bool, &.{ false, true });

    try root.pr_review_mode.toggleChangedOnly(app);

    try testing.expectEqual(@as(u32, 1), app.state.collapsed_folds.count());
    try testing.expect(app.state.collapsed_folds.contains(root.line_map.LineMap.FoldKey.fileKey(0)));
    try root.pr_review_mode.toggleChangedOnly(app);
    try testing.expectEqual(@as(u32, 0), app.state.collapsed_folds.count());
}

test "a refresh drops the changed-only folds, so the next toggle folds again" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 101, .diff = flip_diff_two_files });
    root.flip.clearDiffState(&app.state.flip, testing.allocator, &app.state.collapsed_folds);
    app.state.flip.changed_files = try testing.allocator.dupe(bool, &.{ false, true });
    try root.pr_review_mode.toggleChangedOnly(app);

    try app.applyRefreshedFiles(try root.parser.parse(testing.allocator, flip_diff_two_files));

    try testing.expectEqual(@as(u32, 0), app.state.collapsed_folds.count());
}

test "flip_controller.toggleChangedOnly folds the unchanged files, then unfolds exactly those" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 101, .diff = flip_diff_two_files });
    root.flip.clearDiffState(&app.state.flip, testing.allocator, &app.state.collapsed_folds);
    app.state.flip.changed_files = try testing.allocator.dupe(bool, &.{ false, true });

    try testing.expectEqual(root.flip_controller.ChangedOnly.folded, try root.flip_controller.toggleChangedOnly(app.flipCtx()));
    try testing.expectEqual(@as(u32, 1), app.state.collapsed_folds.count());
    try testing.expect(app.state.collapsed_folds.contains(root.line_map.LineMap.FoldKey.fileKey(0)));

    try testing.expectEqual(root.flip_controller.ChangedOnly.unfolded, try root.flip_controller.toggleChangedOnly(app.flipCtx()));
    try testing.expectEqual(@as(u32, 0), app.state.collapsed_folds.count());
}

test "flip_controller.toggleChangedOnly with no seen diff folds nothing" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 101, .diff = flip_diff_two_files });
    root.flip.clearDiffState(&app.state.flip, testing.allocator, &app.state.collapsed_folds);

    try testing.expectEqual(root.flip_controller.ChangedOnly.no_seen_diff, try root.flip_controller.toggleChangedOnly(app.flipCtx()));
    try testing.expectEqual(@as(u32, 0), app.state.collapsed_folds.count());
}

test "the dwell's markSeen requests a render, so the changed marks clear without a keypress" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 101 });
    app.needs_render = false;

    root.surface_controller.tick(app.surfaceCtx(), app.state.flip.preview_started_ms + root.flip.dwell_ms);

    try testing.expect(app.state.flip.dwell_done);
    try testing.expect(app.needs_render);
}

test "a superseded miss entry dropped after a cache hit requests a render" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 101 });
    app.state.review.gh_bin = flip_missing_bin;
    app.state.review.git_bin = flip_missing_bin;
    app.previewPr(102);
    try testing.expect(app.state.review.entry_in_flight);

    try fx.install(.{ .number = 101 });

    try fx.awaitEntrySettled();
    try testing.expect(app.needs_render);
    try testing.expectEqual(@as(?u32, 101), app.state.flip.previewed);
}

test "a superseded miss entry still in flight is not shown as refreshing the displayed PR" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 101 });
    app.state.review.gh_bin = flip_missing_bin;
    app.state.review.git_bin = flip_missing_bin;
    app.previewPr(102);

    try fx.install(.{ .number = 101 });

    try testing.expect(app.state.review.entry_in_flight);
    try testing.expect(!root.review_controller.refreshInFlight(&app.state.review));
    const text = try statusText(app);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "refreshing") == null);
    try fx.awaitEntrySettled();
}

test "snapshot: status_line_pr_hit" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    try fx.install(.{ .number = 101 });

    const text = try statusText(&fx.app);
    defer testing.allocator.free(text);
    try snapshot.expectSnapshot(testing.allocator, "status_line_pr_hit", text);
}

test "status line in the since-seen view names the PR and shows both oids short" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    surface.markSeen(&app.state.pr_surface, .{ .allocator = testing.allocator, .number = 101, .sidebar = &app.state.sidebar, .now = now });

    try fx.install(.{ .number = 101, .view = .since_seen });

    const text = try statusText(app);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "[ddddddd..ddddddd]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "PR #101") != null);
}

test "status line in the whole-stack view names the PR and shows the tip short" {
    var fx = try FlipApp.init();
    defer fx.deinit();

    try fx.install(.{ .number = 202, .view = .whole_stack });

    const text = try statusText(&fx.app);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "[origin/main...2222222]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "PR #202") != null);
}

test "status line keeps a ref that is not a 40-hex oid whole" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try root.surface_controller.enterReviewDiff(app.surfaceCtx(), .{ .head_ref = "refs/skim/pr-101", .base_ref = "main" });

    const text = try statusText(app);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "[origin/main...refs/skim/pr-101]") != null);
}

test "a miss that fails after a whole-stack load started restores the shown PR: notes back, writes allowed, its own diff source" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 202 });
    _ = try app.state.comment_store.add(noteOnAddedB("note-202"));
    app.state.review.gh_bin = flip_missing_bin;
    app.state.review.git_bin = flip_missing_bin;
    loadWholeStack(app, 202);
    try testing.expect(app.state.diff_load.isLoading());
    try testing.expectEqual(@as(?u32, 202), app.state.flip.loading_number);

    app.state.flip.view = .pr;
    app.previewPr(101);
    try fx.awaitEntryOutcome();

    try testing.expectEqual(@as(?u32, null), app.state.flip.loading_number);
    try testing.expectEqual(@as(?u32, 202), app.state.flip.previewed);
    try testing.expect(app.localWritesBlocked() == null);
    try testing.expectEqual(@as(usize, 1), app.state.comment_store.comments.items.len);
    try testing.expectEqualStrings("note-202", app.state.comment_store.comments.items[0].text);
    const refs = app.state.diff_source.two_refs;
    try testing.expectEqualStrings("origin/s-1", refs.ref1);
    try testing.expectEqualStrings(oid_s2, refs.ref2);
    try testing.expect(refs.use_merge_base);
    _ = try app.state.comment_store.add(noteOnAddedB("note-202b"));
    root.surface_controller.tick(app.surfaceCtx(), 0);
    var rows = try fx.store().listNotes(testing.allocator, .{ .repo_id = fx.repoId(), .number = 202 });
    defer rows.deinit();
    try testing.expectEqual(@as(usize, 2), rows.items.len);
}

test "a miss that fails while the previous entry's diff loads refuses writes until a cached PR is previewed" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 101 });
    app.state.review.gh_bin = flip_missing_bin;
    app.state.review.git_bin = flip_missing_bin;
    app.previewPr(102);
    // An earlier entry landed: its diff is loading when this miss fails.
    try root.surface_controller.enterReviewDiff(app.surfaceCtx(), .{ .head_ref = "HEAD", .base_ref = "" });

    try fx.awaitEntryOutcome();

    try testing.expectEqual(@as(?u32, null), app.state.flip.previewed);
    try testing.expect(app.localWritesBlocked() != null);
    try fx.awaitDiffLoad();
    try testing.expect(app.localWritesBlocked().? == .pr_loading);

    try fx.store().putMergeBase(fx.repoId(), .{ .base_tip_oid = other_oid, .head_oid = oid_a, .merge_base_oid = flip_merge_base });
    try fx.store().putDiff(.{ .repo_id = fx.repoId(), .key = key_a, .bytes = flip_diff_a, .now = now });
    app.previewPr(101);

    try testing.expectEqual(@as(?u32, 101), app.state.flip.previewed);
    try testing.expect(app.localWritesBlocked() == null);
    _ = try app.state.comment_store.add(noteOnAddedA("note-after"));
    root.surface_controller.tick(app.surfaceCtx(), 0);
    var rows = try fx.store().listNotes(testing.allocator, .{ .repo_id = fx.repoId(), .number = 101 });
    defer rows.deinit();
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("note-after", rows.items[0].text);
    try fx.awaitEntrySettled();
}

test "openPrSurface with a comment editor open leaves no boot PR loading" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 101 });
    app.mode = .normal;
    app.state.global_cursor_line = firstCodeRow(&app.state.line_map);
    try root.comment_controller.CommentController.startCommentInput(app);
    try testing.expect(app.state.active_comment_input != null);
    app.state.sidebar.boot_number = 102;

    app.openPrSurface(.{});

    try testing.expectEqual(@as(?u32, null), app.state.flip.loading_number);
    try testing.expectEqual(@as(?u32, 101), app.state.flip.previewed);
    try testing.expect(!app.state.review.entry_in_flight);
}

test "markSeen before the merge base is known writes the 40-zero sentinel, which getSeen reads back" {
    var fx = try FlipApp.init();
    defer fx.deinit();

    surface.markSeen(&fx.app.state.pr_surface, .{ .allocator = testing.allocator, .number = 102, .sidebar = &fx.app.state.sidebar, .now = now });

    const row = (try fx.store().getSeen(fx.repoId(), 102)).?;
    try testing.expectEqualStrings(&surface.unknown_merge_base, &row.merge_base_oid);
    try testing.expectEqualStrings(oid_b, &row.head_oid);
}

test "prefetch-generation poll backfills the sentinel once the merge base resolves" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    surface.markSeen(&fx.app.state.pr_surface, .{ .allocator = testing.allocator, .number = 102, .sidebar = &fx.app.state.sidebar, .now = now });
    try fx.store().putMergeBase(fx.repoId(), .{ .base_tip_oid = other_oid, .head_oid = oid_b, .merge_base_oid = flip_merge_base });

    try surface.backfillSeen(&fx.app.state.pr_surface, .{ .allocator = testing.allocator, .sidebar = &fx.app.state.sidebar });

    const row = (try fx.store().getSeen(fx.repoId(), 102)).?;
    try testing.expectEqualStrings(flip_merge_base, &row.merge_base_oid);
}

test "markSeen reloads the sidebar: the record's seen head equals its head" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const sb = &fx.app.state.sidebar;

    surface.markSeen(&fx.app.state.pr_surface, .{ .allocator = testing.allocator, .number = 101, .sidebar = sb, .now = now });

    const record = controller.recordByNumber(sb, 101).?;
    try testing.expectEqualStrings(record.head_oid, record.seen_head_oid.?);
}

test "planFlip: no merge base → miss; merge base without a diff row → miss; both → hit with parsed files" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const sb = &fx.app.state.sidebar;
    const s = &fx.app.state.pr_surface;
    const lru = &fx.app.state.flip.lru.?;
    const plan_params: surface.PlanParams = .{ .allocator = testing.allocator, .sidebar = sb, .record = controller.recordByNumber(sb, 101).?, .view = .pr, .lru = lru, .now = now };

    try testing.expect(try surface.planFlip(s, plan_params) == .miss);
    try fx.store().putMergeBase(fx.repoId(), .{ .base_tip_oid = other_oid, .head_oid = oid_a, .merge_base_oid = flip_merge_base });
    try testing.expect(try surface.planFlip(s, plan_params) == .miss);
    try fx.store().putDiff(.{ .repo_id = fx.repoId(), .key = key_a, .bytes = flip_diff_a, .now = now });

    var plan = try surface.planFlip(s, plan_params);
    defer plan.deinit(testing.allocator);
    try testing.expectEqualStrings("a.txt", plan.hit.files[0].new_path);
    try testing.expectEqualSlices(u8, &key_a.head_oid, &plan.hit.key.head_oid);
}

test "closePrSurface saves the PR's notes before leavePrSurface restores the working-tree comments" {
    const allocator = testing.allocator;
    var fx = try FlipApp.initWithFiles(try root.parser.parse(allocator, esc_close_diff));
    defer fx.deinit();
    const app = &fx.app;
    _ = try app.state.comment_store.add(.{ .file_path = "src/x.zig", .hunk_idx = 0, .line_idx = 2, .text = "WT-NOTE", .line_type = .add, .line_content = "line10", .new_lineno = 10 });
    try fx.install(.{ .number = 101 });
    _ = try app.state.comment_store.add(noteOnAddedA("pr-note"));
    const repo_id = fx.repoId();

    try app.switchDiffMode(.working);
    try app.applyRefreshedFiles(try root.parser.parse(allocator, esc_close_diff));

    var db = try root.store.Store.open(allocator, fx.path);
    defer db.close();
    var rows = try db.listNotes(allocator, .{ .repo_id = repo_id, .number = 101 });
    defer rows.deinit();
    try testing.expectEqual(@as(usize, 1), rows.items.len);
    try testing.expectEqualStrings("pr-note", rows.items[0].text);
    try testing.expectEqual(@as(usize, 1), app.state.comment_store.comments.items.len);
    try testing.expectEqualStrings("WT-NOTE", app.state.comment_store.comments.items[0].text);
}

test "closing the PR surface during a whole-stack load drops the saved source, so a later cancel cannot restore it" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 202 });
    app.state.review.gh_bin = flip_missing_bin;
    app.state.review.git_bin = flip_missing_bin;
    loadWholeStack(app, 202);
    try testing.expect(app.state.pr_surface_parking.local_load != null);

    try app.switchDiffMode(.working);

    try testing.expect(app.state.pr_surface_parking.local_load == null);
    try testing.expectEqual(.leave_pr, app.state.pr_surface_parking.change);
    try testing.expect(app.state.diff_source == .working_dir);
}

test "applyQuery + pushVisible rebuilds the prefetch targets to the visible numbers in row order" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const sb = &fx.app.state.sidebar;
    _ = try controller.applyQuery(sb, testing.allocator, "101");

    surface.pushVisible(&fx.app.state.pr_surface, .{ .allocator = testing.allocator, .sidebar = sb });

    const visible = try controller.visibleNumbers(sb, testing.allocator);
    defer testing.allocator.free(visible);
    const targets = fx.app.state.pr_surface.targets.items;
    try testing.expectEqual(visible.len, targets.len);
    for (visible, targets) |number, target| try testing.expectEqual(number, target.number);
    try testing.expect(targets.len < 4);
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
            .url = try a.dupe(u8, spec.url),
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

/// Starts with stacks collapsed so row indices stay short; the default
/// (expanded) has its own test.
fn stateFrom(specs: []const RecSpec, sync: SyncSnapshot) !SidebarState {
    var sb = SidebarState{ .collapse_stacks = true };
    errdefer controller.deinitState(&sb, testing.allocator);
    try controller.applySnapshot(&sb, testing.allocator, .{
        .records = try records(testing.allocator, specs),
        .viewer_login = viewer,
        .viewer_teams = "",
        .sync = sync,
    });
    return sb;
}

/// Start loading `number`'s whole-stack diff with the diff focused.
fn loadWholeStack(app: *root.App, number: u32) void {
    app.state.flip.view = .whole_stack;
    app.state.flip.focus_diff = true;
    app.previewPr(number);
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

fn expectMenuPresetNames(sb: *const SidebarState, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, menuPresetCount(sb));
    for (expected, 0..) |name, index| try testing.expectEqualStrings(name, controller.menuPreset(sb, index).name);
}

fn menuPresetCount(sb: *const SidebarState) usize {
    var count: usize = 0;
    for (0..controller.menuItemCount(sb)) |index| {
        if (controller.menuItemAt(sb, index) == .preset) count += 1;
    }
    return count;
}

fn menuCursorItem(sb: *const SidebarState) controller.MenuItem {
    return controller.menuItemAt(sb, sb.menu.?.cursor);
}

/// Put the open menu's cursor on `item` the way the keys do: from the top, down.
fn moveMenuTo(sb: *SidebarState, item: controller.MenuItem) void {
    sb.menu.?.cursor = 0;
    while (!std.meta.eql(menuCursorItem(sb), item) and sb.menu.?.cursor + 1 < controller.menuItemCount(sb)) {
        _ = controller.menuKey(sb, testing.allocator, .down) catch unreachable;
    }
}

fn toggleIndex(label: []const u8) usize {
    for (controller.menu_toggles, 0..) |toggle, index| {
        if (std.mem.eql(u8, toggle.label, label)) return index;
    }
    @panic("no such toggle");
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
    file_count: usize = 2,
    changed_files: []const bool = &.{},
    previewed: ?u32 = null,
    previewed_view: root.flip.DiffView = .pr,
}) !void {
    const allocator = testing.allocator;
    const diff = try root.bench_support.buildDiffText(allocator, .{ .file_count = params.file_count, .hunks_per_file = 1, .lines_per_hunk = 6 });
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
    app.state.flip.changed_files = try allocator.dupe(bool, params.changed_files);
    app.state.flip.previewed = params.previewed;
    app.state.flip.previewed_view = params.previewed_view;

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

/// Every help popup row: the popup's pages, scrolled through and concatenated.
fn helpAllText(app: *root.App) ![]const u8 {
    var all: std.ArrayList(u8) = .empty;
    errdefer all.deinit(testing.allocator);
    var scroll: usize = 0;
    while (scroll < 300) : (scroll += 20) {
        const page = try helpText(app, scroll);
        defer testing.allocator.free(page);
        try all.appendSlice(testing.allocator, page);
    }
    return all.toOwnedSlice(testing.allocator);
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

fn expectBumped(last: *u64, revision: u64) !void {
    try testing.expect(revision > last.*);
    last.* = revision;
}

// --- Flip fixtures -------------------------------------------------------------

const flip_merge_base = "c" ** 40;
const oid_a = "d" ** 40;
const oid_b = "e" ** 40;
const oid_s1 = "1" ** 40;
const oid_s2 = "2" ** 40;
const key_a: types.DiffKey = .{ .merge_base_oid = flip_merge_base.*, .head_oid = oid_a.* };
const flip_updated_at = "2026-01-01T00:00:00Z";

const flip_diff_a =
    \\diff --git a/a.txt b/a.txt
    \\index 1111111..2222222 100644
    \\--- a/a.txt
    \\+++ b/a.txt
    \\@@ -1,2 +1,3 @@
    \\ one
    \\+added-a
    \\ two
    \\
;

const flip_diff_b =
    \\diff --git a/b.txt b/b.txt
    \\index 1111111..2222222 100644
    \\--- a/b.txt
    \\+++ b/b.txt
    \\@@ -1,2 +1,3 @@
    \\ one
    \\+added-b
    \\ two
    \\
;

const flip_diff_two_files = flip_diff_a ++ flip_diff_b;

/// A CommentStore, its note_ids/orphans and a SurfaceFixture store, over
/// `flip_diff_a`.
const NotesFixture = struct {
    fx: SurfaceFixture,
    files: []root.parser.FileDiff,
    comments: root.comments.CommentStore,
    note_ids: std.AutoHashMapUnmanaged(u64, i64) = .{},
    orphans: std.ArrayList(root.notes.OrphanNote) = .empty,

    fn init() !NotesFixture {
        var fx = try SurfaceFixture.init();
        errdefer fx.deinit();
        return .{
            .fx = fx,
            .files = try root.parser.parse(testing.allocator, flip_diff_a),
            .comments = root.comments.CommentStore.init(testing.allocator),
        };
    }

    fn deinit(self: *NotesFixture) void {
        root.notes.clearOrphans(testing.allocator, &self.orphans);
        self.orphans.deinit(testing.allocator);
        self.note_ids.deinit(testing.allocator);
        self.comments.deinit();
        for (self.files) |*file| file.deinit(testing.allocator);
        testing.allocator.free(self.files);
        self.fx.deinit();
    }

    fn store(self: *NotesFixture) *root.store.Store {
        return &self.fx.surface.store.?;
    }

    fn save(self: *NotesFixture, number: u32) !void {
        try surface.saveNotes(&self.fx.surface, .{
            .allocator = testing.allocator,
            .number = number,
            .comments = &self.comments,
            .files = self.files,
            .note_ids = &self.note_ids,
            .now = now,
        });
    }

    fn restore(self: *NotesFixture, number: u32) !void {
        try surface.restoreNotes(&self.fx.surface, .{
            .allocator = testing.allocator,
            .number = number,
            .files = self.files,
            .comments = &self.comments,
            .orphans = &self.orphans,
            .note_ids = &self.note_ids,
        });
    }

    fn listNotes(self: *NotesFixture, number: u32) !types.NoteList {
        return self.store().listNotes(testing.allocator, .{ .repo_id = self.fx.surface.repo_id, .number = number });
    }
};

fn noteOnAddedA(text: []const u8) root.comments.AddParams {
    return .{ .file_path = "a.txt", .hunk_idx = 0, .line_idx = 1, .text = text, .line_type = .add, .line_content = "added-a", .new_lineno = 2 };
}

fn noteOnAddedB(text: []const u8) root.comments.AddParams {
    return .{ .file_path = "b.txt", .hunk_idx = 0, .line_idx = 1, .text = text, .line_type = .add, .line_content = "added-b", .new_lineno = 2 };
}

fn orphanRow(number: u32) types.NoteRow {
    return .{
        .id = 0,
        .number = number,
        .file_path = "gone.txt",
        .line_type = "add",
        .old_lineno = null,
        .new_lineno = 7,
        .end_old_lineno = null,
        .end_new_lineno = null,
        .line_content = "vanished line",
        .author = "you",
        .text = "lost note",
        .replies = "[]",
        .created_at = now,
    };
}

/// A gh/git that cannot run: a miss entry spawns it and fails harmlessly.
const flip_missing_bin = "/nonexistent/skim-test-bin";

/// An App (no tty) with the PR surface open on a temp-file store holding
/// #101, #102 (trunk PRs) and the stack #201 ← #202, a ParsedLru, and no
/// worker: nothing it does spawns.
const FlipApp = struct {
    tmp: testing.TmpDir,
    path: [:0]u8,
    app: root.App,

    const InstallParams = struct {
        number: u32,
        view: root.flip.DiffView = .pr,
        diff: []const u8 = "",
    };

    fn init() !FlipApp {
        return initWithFiles(try testing.allocator.alloc(root.parser.FileDiff, 0));
    }

    fn initWithFiles(files: []root.parser.FileDiff) !FlipApp {
        const allocator = testing.allocator;
        var app = try root.App.initForRenderBench(allocator, files);
        errdefer app.deinit();
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try tmpDbPath(&tmp);
        errdefer allocator.free(path);
        {
            var db = try root.store.Store.open(allocator, path);
            defer db.close();
            const repo_id = try db.ensureRepo(.{ .key = "k", .owner = "o", .name = "r" });
            try db.upsertIndex(repo_id, &.{
                flipRow(.{ .number = 101, .head = "feat-a", .head_oid = oid_a }),
                flipRow(.{ .number = 102, .head = "feat-b", .head_oid = oid_b }),
                flipRow(.{ .number = 201, .head = "s-1", .head_oid = oid_s1 }),
                flipRow(.{ .number = 202, .head = "s-2", .base = "s-1", .head_oid = oid_s2, .base_oid = oid_s1 }),
            });
        }
        surface.openAt(&app.state.pr_surface, .{ .allocator = allocator, .sidebar = &app.state.sidebar, .db_path = path, .repo_key = "k", .owner = "o", .name = "r", .filters = &no_config_filters });
        app.state.flip.lru = root.ParsedLru.init(allocator);
        app.state.sidebar.open = true;
        app.state.sidebar.visible = true;
        app.mode = .pr_review;
        return .{ .tmp = tmp, .path = path, .app = app };
    }

    fn deinit(self: *FlipApp) void {
        self.app.deinit();
        testing.allocator.free(self.path);
        self.tmp.cleanup();
    }

    fn store(self: *FlipApp) *root.store.Store {
        return &self.app.state.pr_surface.store.?;
    }

    fn repoId(self: *FlipApp) i64 {
        return self.app.state.pr_surface.repo_id;
    }

    /// Drive the review worker until its entry lands (`pollReviewEntry`).
    fn awaitEntryOutcome(self: *FlipApp) !void {
        var waited_ms: usize = 0;
        while (self.app.state.review.entry_in_flight) : (waited_ms += 1) {
            if (waited_ms >= 5000) return error.Timeout;
            skim_io.sleep(std.time.ns_per_ms);
            self.app.pollReviewEntry();
        }
    }

    /// Drive the review worker until nothing is in flight, clearing
    /// `needs_render` before every poll: afterwards it says whether the poll
    /// that consumed the last result asked for a frame.
    fn awaitEntrySettled(self: *FlipApp) !void {
        var waited_ms: usize = 0;
        while (self.app.state.review.entry_in_flight) : (waited_ms += 1) {
            if (waited_ms >= 5000) return error.Timeout;
            skim_io.sleep(std.time.ns_per_ms);
            self.app.needs_render = false;
            self.app.pollReviewEntry();
        }
    }

    /// Drive background work until the streaming diff load has landed.
    fn awaitDiffLoad(self: *FlipApp) !void {
        var waited_ms: usize = 0;
        while (self.app.state.diff_load.isLoading()) : (waited_ms += 1) {
            if (waited_ms >= 5000) return error.Timeout;
            skim_io.sleep(std.time.ns_per_ms);
            self.app.pollBackgroundWork();
        }
    }

    /// `installPrDiff` with the PR's own diff (a.txt for #101, b.txt
    /// otherwise, or `params.diff`) and fresh cached threads in the .pr view.
    fn install(self: *FlipApp, params: InstallParams) !void {
        const allocator = testing.allocator;
        const sb = &self.app.state.sidebar;
        const record = controller.recordByNumber(sb, params.number).?;
        const diff = if (params.diff.len > 0) params.diff else if (params.number == 101) flip_diff_a else flip_diff_b;
        const payload = try threadsPayload(allocator, params.number);
        defer allocator.free(payload);
        const place = controller.stackPlace(sb, controller.recordIndex(sb, params.number).?);
        const whole_stack = params.view == .whole_stack;
        try root.surface_controller.installPrDiff(self.app.surfaceCtx(), .{
            .record = record,
            .files = try root.parser.parse(allocator, diff),
            .key = .{ .merge_base_oid = flip_merge_base.*, .head_oid = record.head_oid[0..40].* },
            .view = params.view,
            .threads_json = if (params.view == .pr) payload else null,
            .threads_fresh = true,
            .stack_base_ref = if (whole_stack) sb.records.?.items[place.bottom.?].base_ref else record.base_ref,
        });
    }
};

fn flipRow(params: struct { number: u32, head: []const u8, base: []const u8 = "main", head_oid: []const u8, base_oid: []const u8 = other_oid }) types.IndexRow {
    return .{
        .number = params.number,
        .node_id = "node",
        .title = "title",
        .author = "alice",
        .url = "https://github.com/o/r/pull/1",
        .is_draft = false,
        .head_ref = params.head,
        .base_ref = params.base,
        .head_oid = params.head_oid,
        .base_oid = params.base_oid,
        .updated_at = flip_updated_at,
        .labels = "",
    };
}

/// A review payload for PR `number` with no threads, titled "Flip <number>".
fn threadsPayload(allocator: Allocator, number: u32) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"data":{{"viewer":{{"login":"me"}},"repository":{{"pullRequest":{{
        \\"id":"PR_{d}","number":{d},"title":"Flip {d}","body":"","author":{{"login":"alice"}},
        \\"isDraft":false,"baseRefName":"main","headRefName":"feat","headRefOid":"abc","reviewDecision":"",
        \\"statusCheckRollup":null,"commits":{{"nodes":[]}},
        \\"reviews":{{"pageInfo":{{"hasNextPage":false}},"nodes":[]}},
        \\"reviewThreads":{{"totalCount":0,"pageInfo":{{"hasNextPage":false}},"nodes":[]}}
        \\}}}}}}}}
    , .{ number, number, number });
}

/// The status bar `app` renders, as text.
fn statusText(app: *root.App) ![]const u8 {
    var ctx = try harness.createTestContext(testing.allocator, 160, 1);
    defer ctx.deinit();
    try root.ui.UI.renderStatus(app, ctx.window());
    return ctx.captureToText();
}

/// Index of the first code line in `map`.
fn firstCodeRow(map: *const root.line_map.LineMap) usize {
    for (map.records, 0..) |record, idx| {
        if (record.line_type == .code_line) return idx;
    }
    unreachable;
}

// =============================================================================
// Final-review UX fixes: presets, prompt editing, seen state, forked stacks
// =============================================================================

test "restorePreset: a built-in menu preset is not a custom query, so Esc does not reapply a configured one" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);
    _ = try controller.applyQuery(&sb, testing.allocator, "review:requested");

    try testing.expect(!try controller.restorePreset(&sb, testing.allocator));
    try testing.expectEqualStrings("review:requested", sb.queryText());
}

test "Esc after picking a built-in preset keeps its query, then peels to exit" {
    var app = try sidebarApp();
    defer app.deinit();
    const sb = &app.state.sidebar;
    sb.pr_only = true;
    try app.handleKey(.{ .codepoint = 'f' });
    moveMenuTo(sb, .{ .preset = menuPresetIndex(sb, "Needs my review") });
    try app.handleKey(.{ .codepoint = Key.enter });
    try testing.expectEqualStrings("review:requested", sb.queryText());

    try app.handleKey(.{ .codepoint = Key.escape });

    try testing.expectEqualStrings("review:requested", sb.queryText());
    try testing.expect(app.should_quit);
}

test "empty states: no match under a built-in preset names the preset" {
    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();
    var sb = try stateFrom(&.{.{ .number = 1, .head = "a" }}, recent_sync);
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);
    _ = try controller.applyQuery(&sb, testing.allocator, "is:changed");

    try testing.expectEqualStrings("Changed since seen", controller.view(&sb, viewParams(frame.allocator())).empty.?.no_match);
}

test "cyclePreset: with no config F walks the built-in presets the menu shows, and wraps" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &config.PrFilters{});
    const expected = [_][]const u8{ "-is:draft", "review:requested", "author:@me", "is:changed", "" };

    for (expected) |query| {
        try controller.cyclePreset(&sb, testing.allocator);
        try testing.expectEqualStrings(query, sb.queryText());
    }
}

test "cyclePreset: after the configured presets F continues into the built-ins they do not cover" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);
    const expected = [_][]const u8{ "author:@me", "", "review:requested", "is:changed", "-is:draft" };

    for (expected) |query| {
        try controller.cyclePreset(&sb, testing.allocator);
        try testing.expectEqualStrings(query, sb.queryText());
    }
}

test "F with no config cycles presets from the sidebar" {
    var app = try sidebarApp();
    defer app.deinit();
    try controller.setPresets(&app.state.sidebar, testing.allocator, &config.PrFilters{});

    try app.handleKey(.{ .codepoint = 'F' });

    try testing.expectEqualStrings("-is:draft", app.state.sidebar.queryText());
}

test "prompt: the first printable key replaces the pre-filled query" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    _ = try controller.applyQuery(&sb, testing.allocator, "author:bob");
    controller.openPrompt(&sb);

    try typeText(&sb, "ci");

    try testing.expectEqualStrings("ci", sb.prompt.?.text());
}

test "prompt: backspace on the pre-filled query edits its end instead of replacing it" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    _ = try controller.applyQuery(&sb, testing.allocator, "author:bob");
    controller.openPrompt(&sb);

    _ = try controller.promptKey(&sb, testing.allocator, .backspace);
    try typeText(&sb, "x");

    try testing.expectEqualStrings("author:box", sb.prompt.?.text());
}

test "prompt: keep leaves the pre-filled query in place so typing appends" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    _ = try controller.applyQuery(&sb, testing.allocator, "author:bob");
    controller.openPrompt(&sb);

    _ = try controller.promptKey(&sb, testing.allocator, .keep);
    try typeText(&sb, " ci:success");

    try testing.expectEqualStrings("author:bob ci:success", sb.prompt.?.text());
}

test "prompt: clear empties the text, pre-filled or typed" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    _ = try controller.applyQuery(&sb, testing.allocator, "author:bob");
    controller.openPrompt(&sb);

    _ = try controller.promptKey(&sb, testing.allocator, .clear);
    try testing.expectEqualStrings("", sb.prompt.?.text());
    try typeText(&sb, "ci");
    _ = try controller.promptKey(&sb, testing.allocator, .clear);
    try testing.expectEqualStrings("", sb.prompt.?.text());
}

test "prompt: delete_word removes the last term and the spaces after it" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    _ = try controller.applyQuery(&sb, testing.allocator, "author:bob label:x  ");
    controller.openPrompt(&sb);

    _ = try controller.promptKey(&sb, testing.allocator, .delete_word);
    try testing.expectEqualStrings("author:bob ", sb.prompt.?.text());
    _ = try controller.promptKey(&sb, testing.allocator, .delete_word);
    try testing.expectEqualStrings("", sb.prompt.?.text());
    _ = try controller.promptKey(&sb, testing.allocator, .delete_word);
    try testing.expectEqualStrings("", sb.prompt.?.text());
}

test "prompt: the view marks pre-filled text as selected until it is edited" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();
    _ = try controller.applyQuery(&sb, testing.allocator, "author:bob");
    controller.openPrompt(&sb);
    try testing.expect(controller.view(&sb, viewParams(frame.allocator())).prompt_selected);

    _ = try controller.promptKey(&sb, testing.allocator, .backspace);

    try testing.expect(!controller.view(&sb, viewParams(frame.allocator())).prompt_selected);
}

test "filter prompt keys: Ctrl-U clears and Ctrl-W deletes a word" {
    var app = try sidebarApp();
    defer app.deinit();
    const sb = &app.state.sidebar;
    try app.handleKey(.{ .codepoint = '/' });
    try app.handleKey(.{ .codepoint = Key.end });
    for (" author:bob") |c| try app.handleKey(.{ .codepoint = c, .text = &.{c} });

    try app.handleKey(.{ .codepoint = 'w', .mods = .{ .ctrl = true } });
    try testing.expectEqualStrings("-is:draft ", sb.prompt.?.text());
    try app.handleKey(.{ .codepoint = 'u', .mods = .{ .ctrl = true } });
    try testing.expectEqualStrings("", sb.prompt.?.text());
}

test "snapshot: sidebar_filter_prompt_prefilled" {
    var sb = try stacked31State();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &two_presets);
    controller.openPrompt(&sb);

    try expectSidebarSnapshot(.{ .state = &sb, .name = "sidebar_filter_prompt_prefilled", .cols = 44, .rows = 12 });
}

test "view: a never-seen PR is unseen; seen at any head is not" {
    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();
    var sb = try stateFrom(&.{
        .{ .number = 1, .head = "a", .seen_head_oid = other_oid },
        .{ .number = 2, .head = "b", .seen_head_oid = head_oid },
        .{ .number = 3, .head = "c" },
    }, recent_sync);
    defer controller.deinitState(&sb, testing.allocator);

    const rows = controller.view(&sb, viewParams(frame.allocator())).rows;

    try testing.expect(!rows[0].unseen);
    try testing.expect(!rows[1].unseen);
    try testing.expect(rows[2].unseen);
}

test "snapshot: sidebar_seen_markers" {
    var sb = try stateFrom(&.{
        .{ .number = 3, .title = "Never opened", .head = "a" },
        .{ .number = 2, .title = "Pushed since seen", .head = "b", .seen_head_oid = other_oid },
        .{ .number = 1, .title = "Seen at its head", .head = "c", .seen_head_oid = head_oid },
    }, recent_sync);
    defer controller.deinitState(&sb, testing.allocator);
    try controller.setPresets(&sb, testing.allocator, &config.PrFilters{});

    try expectSidebarSnapshot(.{ .state = &sb, .name = "sidebar_seen_markers", .cols = 44, .rows = 8 });
}

test "m in the sidebar says whether it marked or cleared the PR's seen state" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try testing.expect(try controller.selectNumber(&app.state.sidebar, testing.allocator, 101));

    try app.handleKey(.{ .codepoint = 'm' });
    try testing.expectEqualStrings("marked #101 seen", app.state.status_message.?);
    try app.handleKey(.{ .codepoint = 'm' });
    try testing.expectEqualStrings("cleared seen for #101", app.state.status_message.?);
}

test "m on the diff says it marked the shown PR seen" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 102 });
    app.mode = .normal;

    try app.handleKey(.{ .codepoint = 'm' });

    try testing.expectEqualStrings("marked #102 seen", app.state.status_message.?);
}

test "the dwell leaves a PR seen at an older head alone, so its Δ survives" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try seeAtOlderHead(&fx, 101);
    try fx.install(.{ .number = 101 });

    root.surface_controller.tick(app.surfaceCtx(), app.state.flip.preview_started_ms + 2 * root.flip.dwell_ms);

    try testing.expectEqual(@as(?u32, 101), app.state.flip.previewed);
    try testing.expect(!app.state.flip.dwell_done);
    try testing.expectEqualStrings(oid_b, &(try fx.store().getSeen(fx.repoId(), 101)).?.head_oid);
}

test "Tab on a PR seen at an older head marks it seen at its head" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try seeAtOlderHead(&fx, 101);
    try testing.expect(try controller.selectNumber(&app.state.sidebar, testing.allocator, 101));
    try fx.install(.{ .number = 101 });

    try app.handleKey(.{ .codepoint = Key.tab });

    try testing.expectEqual(root.App.Mode.normal, app.mode);
    try testing.expectEqualStrings(oid_a, &(try fx.store().getSeen(fx.repoId(), 101)).?.head_oid);
}

test "Ctrl-w l focuses the diff and marks the shown PR seen, like Tab" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try testing.expect(try controller.selectNumber(&app.state.sidebar, testing.allocator, 102));
    try fx.install(.{ .number = 102 });

    try app.handleKey(.{ .codepoint = 'w', .mods = .{ .ctrl = true } });
    try app.handleKey(.{ .codepoint = 'l' });

    try testing.expectEqual(root.App.Mode.normal, app.mode);
    try testing.expectEqualStrings(oid_b, &(try fx.store().getSeen(fx.repoId(), 102)).?.head_oid);
}

test "a filter that hides every PR replaces the previewed PR's diff with the placeholder" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 101 });
    _ = try controller.applyQuery(&app.state.sidebar, testing.allocator, "label:nope");

    const text = try frameText(app, .{ .cols = 100, .rows = 16 });
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "No pull request selected") != null);
    try testing.expect(std.mem.indexOf(u8, text, "a.txt") == null);
}

test "with the diff focused a filtered-out preview stays on screen" {
    var fx = try FlipApp.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.install(.{ .number = 101 });
    _ = try controller.applyQuery(&app.state.sidebar, testing.allocator, "label:nope");
    app.mode = .normal;

    const text = try frameText(app, .{ .cols = 100, .rows = 16 });
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "a.txt") != null);
}

test "stackPlace: on a forked stack each leaf is its own tip and a fork point reaches its deepest leaf" {
    var sb = try forkedState();
    defer controller.deinitState(&sb, testing.allocator);

    try expectTip(&sb, .{ .number = 902, .tip = 902 });
    try expectTip(&sb, .{ .number = 904, .tip = 904 });
    try expectTip(&sb, .{ .number = 903, .tip = 904 });
    try expectTip(&sb, .{ .number = 901, .tip = 904 });
    try testing.expectEqual(@as(u32, 901), sb.records.?.items[controller.stackPlace(&sb, controller.recordIndex(&sb, 902).?).bottom.?].number);
}

test "view: an expanded forked stack draws the top connector on its first row" {
    var sb = try forkedState();
    defer controller.deinitState(&sb, testing.allocator);
    try controller.toggleExpand(&sb, testing.allocator);
    var frame = std.heap.ArenaAllocator.init(testing.allocator);
    defer frame.deinit();

    const rows = controller.view(&sb, viewParams(frame.allocator())).rows;

    try testing.expectEqual(@as(usize, 5), rows.len);
    try testing.expectEqual(root.stack.Mark.top, rows[1].connector);
    try testing.expectEqual(root.stack.Mark.middle, rows[2].connector);
    try testing.expectEqual(root.stack.Mark.middle, rows[3].connector);
    try testing.expectEqual(root.stack.Mark.bottom, rows[4].connector);
}

test "yankText: branch is the selected PR's head ref" {
    var sb = try yankState();
    defer controller.deinitState(&sb, testing.allocator);

    try testing.expectEqualStrings("feat/x", controller.yankText(&sb, .branch).?);
}

test "yankText: url is the selected PR's URL" {
    var sb = try yankState();
    defer controller.deinitState(&sb, testing.allocator);

    try testing.expectEqualStrings("https://github.com/o/r/pull/12", controller.yankText(&sb, .url).?);
}

test "yankText: follows the cursor to the next PR" {
    var sb = try yankState();
    defer controller.deinitState(&sb, testing.allocator);

    controller.move(&sb, 1);

    try testing.expectEqualStrings("fix/y", controller.yankText(&sb, .branch).?);
    try testing.expectEqualStrings("https://github.com/o/r/pull/13", controller.yankText(&sb, .url).?);
}

test "yankText: nothing to yank when the filter hides every PR" {
    var sb = try yankState();
    defer controller.deinitState(&sb, testing.allocator);
    _ = try controller.applyQuery(&sb, testing.allocator, "author:nobody");

    try testing.expectEqual(@as(?[]const u8, null), controller.yankText(&sb, .branch));
    try testing.expectEqual(@as(?[]const u8, null), controller.yankText(&sb, .url));
}

test "yankText: nothing to yank before the first load" {
    const sb = SidebarState{};

    try testing.expectEqual(@as(?[]const u8, null), controller.yankText(&sb, .branch));
}

test "yankText: no URL to yank for a PR synced without one" {
    var sb = try stateFrom(&.{.{ .number = 12, .head = "feat/x" }}, recent_sync);
    defer controller.deinitState(&sb, testing.allocator);

    try testing.expectEqual(@as(?[]const u8, null), controller.yankText(&sb, .url));
    try testing.expectEqualStrings("feat/x", controller.yankText(&sb, .branch).?);
}

fn menuPresetIndex(sb: *const SidebarState, name: []const u8) usize {
    for (0..menuPresetCount(sb)) |index| {
        if (std.mem.eql(u8, controller.menuPreset(sb, index).name, name)) return index;
    }
    @panic("no such menu preset");
}

/// Seen row for `number` at `oid_b`, an older head than #101's `oid_a`, and
/// the sidebar reloaded so its record shows Δ.
fn seeAtOlderHead(fx: *FlipApp, number: u32) !void {
    try fx.store().setSeen(.{ .repo_id = fx.repoId(), .number = number, .head_oid = oid_b, .merge_base_oid = flip_merge_base, .now = now });
    try surface.reload(&fx.app.state.pr_surface, .{ .allocator = testing.allocator, .sidebar = &fx.app.state.sidebar });
}

/// A whole App frame as text.
fn frameText(app: *root.App, size: struct { cols: u16, rows: u16 }) ![]const u8 {
    var ctx = try harness.createTestContext(testing.allocator, size.cols, size.rows);
    defer ctx.deinit();
    try root.frame.render(app, ctx.window());
    return ctx.captureToText();
}

/// #901 ← #902 and #901 ← #903 ← #904: a stack that forks at #901.
fn forkedState() !SidebarState {
    return stateFrom(&.{
        .{ .number = 901, .head = "f-base" },
        .{ .number = 902, .head = "f-left", .base = "f-base" },
        .{ .number = 903, .head = "f-right", .base = "f-base" },
        .{ .number = 904, .head = "f-right2", .base = "f-right" },
    }, recent_sync);
}

/// #12 (feat/x) above #13 (fix/y), both with URLs.
fn yankState() !SidebarState {
    const sb = try stateFrom(&.{
        .{ .number = 12, .head = "feat/x", .url = "https://github.com/o/r/pull/12" },
        .{ .number = 13, .head = "fix/y", .url = "https://github.com/o/r/pull/13" },
    }, recent_sync);
    try testing.expectEqual(@as(u32, 12), rowNumber(&sb, 0));
    return sb;
}

fn expectTip(sb: *const SidebarState, params: struct { number: u32, tip: u32 }) !void {
    const place = controller.stackPlace(sb, controller.recordIndex(sb, params.number).?);
    try testing.expectEqual(params.tip, sb.records.?.items[place.tip.?].number);
}

/// The menu's toggle checkboxes in `menu_toggles` order.
fn toggleStates(menu: root.sidebar_render.MenuView) [controller.menu_toggles.len]bool {
    var states: [controller.menu_toggles.len]bool = undefined;
    var index: usize = 0;
    for (menu.lines) |line| {
        if (line.kind != .toggle) continue;
        states[index] = line.on;
        index += 1;
    }
    return states;
}
