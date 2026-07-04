export const meta = {
  name: "decompose-app-zig",
  description:
    "Sequentially extract feature clusters out of src/app.zig into focused controller modules, verifying zig build + test + lint after each unit",
  whenToUse:
    "One-shot decomposition of the app.zig god object. Runs units strictly one-at-a-time (they all edit app.zig) with a hard green gate between each.",
  phases: [{ title: "Baseline" }, { title: "Extract" }, { title: "Review" }],
};

// Ordered most-independent -> most-entangled. Rendering is last because it is
// wired into frame allocators + profiling counters. Each unit's `seeds` are the
// obvious methods; the agent must also pull in the private helpers only those
// methods call, and the sub-state they operate on.
const UNITS = [
  {
    key: "pr",
    title: "PR review controller",
    target: "src/pr/controller.zig",
    substate:
      "state.pr : PrReviewState (already a top-level struct in app.zig)",
    seeds: [
      "startPrListLoad",
      "prFetchWorker",
      "pollPendingPrFetch",
      "loadPrsFromCache",
      "rebuildPrStacks",
      "reviewSelectedPr",
      "selectPullRequest",
      "rebuildPrFilter",
      "prMove",
      "clampPrScroll",
      "selectedPr",
      "prClearOrLeave",
      "prAppendQueryChar",
      "prBackspaceQuery",
      "openPrInBrowser",
      "prView",
      "setPrMessage",
      "openPrAuthorPicker",
      "refreshPrAuthorList",
      "applySelectedPrAuthor",
      "closePrAuthorPicker",
      "rebuildPrAuthorFilter",
      "prAuthorMove",
      "prAppendAuthorQueryChar",
      "prBackspaceAuthorQuery",
      "freePrAuthors",
      "PendingPrFetch",
    ],
  },
  {
    key: "blame",
    title: "Blame fetch/cache controller",
    target: "src/git/blame_controller.zig",
    substate:
      "blame_cache, pending_blame_* fields on App; BlameFetchContext / PendingBlameResult structs",
    seeds: [
      "requestBlameForViewport",
      "startAsyncBlameFetch",
      "blameFetchWorker",
      "pollPendingBlameResults",
      "drainPendingBlameResults",
      "getBlameForLine",
      "BlameFetchContext",
      "PendingBlameResult",
    ],
  },
  {
    key: "debug_replay",
    title: "Debug replay controller",
    target: "src/agent/debug_replay_controller.zig",
    substate: "active debug-replay state reached via getActiveAgentState",
    seeds: [
      "hasActiveDebugReplay",
      "isActiveDebugReplayPlaying",
      "toggleActiveDebugReplayPlaying",
      "restartActiveDebugReplay",
      "exitActiveDebugReplay",
      "stepActiveDebugReplay",
      "advanceDebugReplayIfDue",
      "syncActiveDebugReplayManagerStatus",
    ],
  },
  {
    key: "subagent_fetch",
    title: "Subagent modal fetch",
    target: "src/agent/subagent_fetch.zig",
    substate:
      "pending_subagent_fetch : PendingSubagentFetch; SubagentFetchContext",
    seeds: [
      "startSubagentModalFetch",
      "subagentFetchWorker",
      "pollSubagentFetch",
      "processSubagentFetchResult",
      "SubagentFetchContext",
      "PendingSubagentFetch",
    ],
  },
  {
    key: "menu_stats",
    title: "Empty-menu stats fetch",
    target: "src/menu_stats.zig",
    substate:
      "menu_stats_*, working_stats, staged_stats, main_stats, branch_stats_cache on state",
    seeds: [
      "startMenuStatsFetch",
      "menuStatsFetchWorker",
      "fetchMenuStatsSync",
    ],
  },
  {
    key: "graphite",
    title: "Graphite stack controller",
    target: "src/git/graphite_controller.zig",
    substate: "graphite_* fields on state",
    seeds: [
      "ensureGraphiteDetected",
      "startGraphiteStack",
      "refreshGraphiteStack",
      "selectGraphiteStackBranch",
      "navigateStackToParent",
      "navigateStackToChild",
    ],
  },
  {
    key: "commit_select",
    title: "Commit selection logic",
    target:
      "colocate in src/modes/commit_selection_mode.zig (or src/commit_select.zig if large)",
    substate: "commit_* fields on state",
    seeds: [
      "startCommitSelection",
      "loadMoreCommits",
      "filterCommits",
      "matchesCommitQuery",
      "selectCommitForDiff",
      "applyCommitDiff",
    ],
  },
  {
    key: "branch_select",
    title: "Branch selection logic",
    target:
      "colocate in src/modes/branch_selection_mode.zig (or src/branch_select.zig if large)",
    substate: "branch_* fields on state",
    seeds: ["startBranchSelection", "filterBranches", "matchesBranchQuery"],
  },
  {
    key: "model_select",
    title: "Model filter logic",
    target: "colocate in src/modes/model_selection_mode.zig",
    substate: "model_* fields on state",
    seeds: ["updateModelFilter", "resetModelFilter"],
  },
  {
    key: "comments",
    title: "Comment operations controller",
    target: "src/comments/controller.zig",
    substate: "state.comment_store, active_comment_input, expanded_comments",
    seeds: [
      "startCommentInput",
      "startCommentInputForVisualSelection",
      "saveCurrentComment",
      "yankCurrentCommentToClipboard",
      "yankAllCommentsToClipboard",
      "yankCommentsToAgent",
      "deleteCommentUnderCursor",
      "toggleCommentUnderCursorExpanded",
      "clearAllComments",
      "isCommentExpanded",
      "toggleCommentExpanded",
    ],
  },
  {
    key: "folds",
    title: "Fold controller",
    target: "src/folds.zig",
    substate: "state.collapsed_folds; FoldKey",
    seeds: [
      "isFileFolded",
      "isHunkFolded",
      "toggleFileFold",
      "toggleHunkFold",
      "closeFileFold",
      "closeHunkFold",
      "openFileFold",
      "openHunkFold",
      "closeAllFolds",
      "openAllFolds",
      "toggleFoldUnderCursor",
      "closeFoldUnderCursor",
      "openFoldUnderCursor",
      "closeAllFoldsAndRebuild",
      "openAllFoldsAndRebuild",
      "moveCursorToFoldHeader",
      "closeFileFoldUnderCursor",
      "openFileFoldUnderCursor",
    ],
  },
  {
    key: "hunk_view",
    title: "Hunk view-mode + viewport anchor",
    target: "src/hunk_view.zig",
    substate: "hunk_view_mode, viewport fields; ViewportAnchor",
    seeds: [
      "cycleHunkViewModePrev",
      "cycleHunkViewMode",
      "findHunkHeaderLine",
      "findCodeLine",
      "captureViewportAnchor",
      "restoreViewportFromAnchor",
      "convertHunkViewMode",
      "shouldApplyHunkFiltering",
      "ViewportAnchor",
    ],
  },
  {
    key: "mcp_handlers",
    title: "TUI-server / MCP request handlers",
    target: "src/mcp/handlers.zig",
    substate: "reads App state, returns tui_server.Response",
    seeds: [
      "startTuiServer",
      "handleTuiServerRequest",
      "writeSessionMetadata",
      "syncSessionMetadata",
      "handleGetContext",
      "handleGetDiff",
      "handleAddComment",
      "handleListComments",
      "handleDeleteComment",
      "getSessionPort",
    ],
  },
  {
    key: "agent_conn",
    title: "Agent connection coordinator",
    target: "src/acp/connect.zig",
    substate:
      "pending_connection, pending_agent_connect_idx; *ConnectContext + PendingConnection structs",
    seeds: [
      "acpConnectThreadFn",
      "startAcpSession",
      "connectToAgent",
      "connectToOpencodeAgent",
      "opcConnectThreadFn",
      "connectToCodexAgent",
      "codexConnectThreadFn",
      "buildCodexLaunchArgs",
      "isCodexCommand",
      "findArg",
      "applyCodexSessionConfig",
      "connectToSelectedAgent",
      "startQueuedAgentConnection",
      "loadConfiguredAgents",
      "stopAcpSession",
      "getAcpStatus",
      "pollAllManagers",
      "pollConnectionThread",
      "maybeAddConnectionSystemMessage",
      "getConnectingTab",
      "getConnectingAgentState",
      "pollTabManager",
      "queueSelectedAgentConnection",
      "AcpConnectContext",
      "OpencodeConnectContext",
      "CodexConnectContext",
      "PendingConnection",
    ],
  },
  {
    key: "render",
    title: "Frame render orchestration",
    target: "src/rendering/frame.zig",
    substate:
      "frame allocators + profile counters; delegates to render_unified/side_by_side",
    seeds: [
      "render",
      "renderContent",
      "getConflictMarkerStyle",
      "createHighlightedSegments",
      "findHighlightStartIndex",
      "applySearchHighlighting",
      "isMatchLine",
    ],
  },
];

const COMMIT_EACH = !!(args && args.commitEach);
const ONLY = args && Array.isArray(args.only) ? new Set(args.only) : null;
const units = ONLY ? UNITS.filter((u) => ONLY.has(u.key)) : UNITS;

const BASELINE = {
  type: "object",
  additionalProperties: false,
  required: ["buildOk", "testOk", "appLines", "failingTests", "notes"],
  properties: {
    buildOk: { type: "boolean" },
    testOk: { type: "boolean", description: "true only if zero tests fail" },
    appLines: { type: "number", description: "wc -l src/app.zig" },
    failingTests: {
      type: "array",
      items: { type: "string" },
      description:
        "Normalized names of every test failing at baseline (e.g. 'codex manager handshake', 'renderToolCall renders pending status'). This is the KNOWN-FAILING set later units are allowed to still-fail without penalty.",
    },
    notes: { type: "string" },
  },
};

const EXTRACT = {
  type: "object",
  additionalProperties: false,
  required: [
    "unit",
    "buildOk",
    "testOk",
    "lintOk",
    "blocking",
    "appLinesBefore",
    "appLinesAfter",
    "filesCreated",
    "newFailures",
    "notes",
  ],
  properties: {
    unit: { type: "string" },
    buildOk: { type: "boolean" },
    testOk: {
      type: "boolean",
      description:
        "true if NO new test failures beyond the known-failing baseline set (pre-existing env failures don't count against you)",
    },
    lintOk: { type: "boolean" },
    blocking: {
      type: "boolean",
      description: "true if left the tree non-green and could not self-heal",
    },
    appLinesBefore: { type: "number" },
    appLinesAfter: { type: "number" },
    filesCreated: { type: "array", items: { type: "string" } },
    committed: { type: "boolean" },
    newFailures: {
      type: "array",
      items: { type: "string" },
      description:
        "Tests that fail now but are NOT in the known-failing baseline set. MUST be empty for a clean unit.",
    },
    notes: { type: "string" },
  },
};

const REVIEW = {
  type: "object",
  additionalProperties: false,
  required: ["verdict", "findings"],
  properties: {
    verdict: { type: "string", enum: ["CLEAN", "ISSUES"] },
    findings: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["severity", "file", "summary"],
        properties: {
          severity: { type: "string", enum: ["blocking", "minor"] },
          file: { type: "string" },
          summary: { type: "string" },
        },
      },
    },
  },
};

function extractPrompt(unit, knownFailing) {
  const knownList = (knownFailing || []).length
    ? (knownFailing || []).map((t) => `  - ${t}`).join("\n")
    : "  (none)";
  return [
    `You are extracting ONE feature cluster out of the god object \`src/app.zig\` (${"~"}8k lines) in the Zig project "skim".`,
    ``,
    `## Unit: ${unit.key} — ${unit.title}`,
    `Target module: ${unit.target}`,
    `Sub-state it operates on: ${unit.substate}`,
    `Seed methods/structs to move (find the private helpers ONLY these call, and move those too; do NOT drag in helpers shared with other clusters — leave shared helpers on App):`,
    unit.seeds.map((s) => `  - ${s}`).join("\n"),
    ``,
    `## Hard rules`,
    `1. FIRST read AGENTS.md section "App Struct Boundaries (avoid the god object)" and /home/ctdio/.claude/CLAUDE.md code-style rules. Follow them exactly (function keyword at module level, \`err\` in catch, object param when >2 args, main exports first / helpers last, no arrow fns at module level).`,
    `2. This is a BEHAVIOR-PRESERVING move. Do NOT change logic, control flow, or output. Pure relocation + rewiring.`,
    `3. Feature logic becomes FREE FUNCTIONS in ${unit.target} that take the sub-state pointer plus only the narrow deps they need (allocator, etc.) — NOT \`*App\`, unless a function genuinely needs many cross-cutting services, in which case keep a thin forwarding method on App and move the body.`,
    `4. If the sub-state struct is defined inside app.zig, move it to the feature module (or make it \`pub\`) so the controller can name it.`,
    `5. Update EVERY call site: grep across src/ (app.zig, src/modes/, src/command_palette.zig, src/ui.zig, tests). Callers should call the controller directly where practical, matching how src/modes/pr_review_mode.zig already calls into feature logic.`,
    `6. Keep colocated tests working; move any tests that belong with the moved code.`,
    ``,
    `## Known-failing baseline (pre-existing, environmental — NOT your responsibility)`,
    `These tests already fail on this branch before any refactor (codex tests need a real codex subprocess; some grapheme/snapshot tests need vaxis unicode data not wired in the harness). They are EXPECTED to keep failing. Do not try to fix them; just don't add NEW failures:`,
    knownList,
    ``,
    `## Verify before returning (capture output to /tmp files, do not re-run blindly)`,
    `  - \`zig build 2>&1 | tee /tmp/wf-${unit.key}-build.log\`  — debug build MUST succeed (buildOk).`,
    `  - \`zig build test 2>&1 | tee /tmp/wf-${unit.key}-test.log\`  — then diff the failing-test names against the known-failing set above. testOk = the failing set is a SUBSET of the known-failing baseline (no NEW failures). Report any new ones in \`newFailures\`. If you touched rendering, snapshots must still match — do NOT blanket-update snapshots. A test that passed at baseline and now fails is a REAL regression you must fix.`,
    `  - \`./scripts/ziglint.sh <files you touched> 2>&1 | tee /tmp/wf-${unit.key}-lint.log\``,
    `Run \`zig fmt\` on files you created/edited. Self-heal up to 3 iterations if build fails, lint fails, or you introduced a new test failure.`,
    ``,
    `## If you CANNOT get build green, lint clean, and newFailures empty`,
    `Revert your uncommitted changes for this unit ONLY with \`git checkout -- <files>\` / \`git clean\` for new files you added, so the tree returns to the last green state, then return blocking:true with a precise explanation of what blocked you. Never leave the tree broken.`,
    COMMIT_EACH
      ? `## On success: commit\nRun \`git add -A && git commit -m "refactor(app): extract ${unit.key} controller out of app.zig"\`. Report committed:true.`
      : `## Do NOT commit. Leave changes staged-or-unstaged in the working tree.`,
    ``,
    `Report the structured result. appLinesBefore/After = \`wc -l src/app.zig\` before and after your work.`,
  ].join("\n");
}

// ---- run -------------------------------------------------------------------

phase("Baseline");
const base = await agent(
  "In the skim Zig repo, establish the pre-refactor baseline WITHOUT modifying anything. Run `zig build 2>&1 | tee /tmp/wf-baseline-build.log` and `zig build test 2>&1 | tee /tmp/wf-baseline-test.log`, and `wc -l src/app.zig`. Report: buildOk, testOk (true only if zero failures), appLines, and `failingTests` = the normalized name of EVERY failing test (strip the binary/module prefix, e.g. 'codex manager handshake', 'renderToolCall renders pending status', 'captureToText handles wide characters correctly'). Enumerate them all — this set defines what later units are allowed to still-fail.",
  { label: "baseline", phase: "Baseline", schema: BASELINE },
);
// Only the BUILD must be green to proceed. Test failures are tolerated as long
// as they are captured in the known-failing set (env/pre-existing); each unit is
// then gated on introducing NO NEW failures.
if (!base || !base.buildOk) {
  log(
    `Baseline build is not green (build=${base && base.buildOk}). Aborting before touching anything.`,
  );
  return { aborted: true, reason: "baseline-build-broken", base };
}
const knownFailing = base.failingTests || [];
log(
  `Baseline build green. app.zig = ${base.appLines} lines. Known-failing (tolerated): ${knownFailing.length} tests. Extracting ${units.length} units (commitEach=${COMMIT_EACH}).`,
);

phase("Extract");
const results = [];
for (const unit of units) {
  const r = await agent(extractPrompt(unit, knownFailing), {
    label: `extract:${unit.key}`,
    phase: "Extract",
    schema: EXTRACT,
  });
  results.push(r);
  if (!r) {
    log(`Unit ${unit.key}: agent returned nothing. Halting.`);
    break;
  }
  const newFails = (r.newFailures || []).length;
  if (r.blocking || !r.buildOk || !r.testOk || !r.lintOk || newFails > 0) {
    log(
      `Unit ${unit.key} did not reach green (build=${r.buildOk} test=${r.testOk} lint=${r.lintOk} blocking=${r.blocking} newFailures=${newFails}). Halting to avoid compounding errors. Notes: ${r.notes}`,
    );
    break;
  }
  log(
    `Unit ${unit.key} ✓  app.zig ${r.appLinesBefore} -> ${r.appLinesAfter} (-${r.appLinesBefore - r.appLinesAfter}); files: ${(r.filesCreated || []).join(", ")}`,
  );
}

const done = results.filter(
  (r) => r && r.buildOk && r.testOk && r.lintOk && !r.blocking,
);
const halted = done.length < units.length;

phase("Review");
const review = await agent(
  [
    "Independently review the app.zig decomposition on this branch. Run `git diff` (and `git diff --stat`) against the pre-refactor state.",
    'Check for: (1) behavior changes sneaked in during a supposedly mechanical move, (2) logic that was moved but should have stayed on App or vice-versa, (3) dead forwarders / duplicated code, (4) call sites missed, (5) violations of the AGENTS.md "App Struct Boundaries" pattern or CLAUDE.md style.',
    `Then run \`zig build test 2>&1 | tee /tmp/wf-review-test.log\`. The suite has a KNOWN-FAILING baseline set (pre-existing/environmental) that is expected to still fail — do NOT flag these as regressions: ${JSON.stringify(knownFailing)}. Only NEW failures (tests not in that set) are regressions. Report a verdict and concrete findings.`,
  ].join("\n"),
  { label: "review", phase: "Review", schema: REVIEW },
);

return {
  base,
  extracted: done.map((r) => ({
    unit: r.unit,
    saved: r.appLinesBefore - r.appLinesAfter,
    files: r.filesCreated,
  })),
  halted,
  totalLinesRemoved: done.reduce(
    (s, r) => s + (r.appLinesBefore - r.appLinesAfter),
    0,
  ),
  review,
};
