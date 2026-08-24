// The recorded agent session the landing page replays.
//
// It is JSONL in the shape `skim debug acp` reads, imported raw so it stays
// readable and needs no escaping. Vite inlines it at build time.
//
// It is a recording, not a live agent: the browser has no subprocess to talk
// to. Everything the panel draws goes through `src/agent/render.zig`, the same
// path a real session takes, and `src/testing/session_replay_scenarios.zig`
// replays this file so a parser change cannot quietly break it.
//
// Two things in it are not recorded. The `get_comments` result carries the
// `{{comments}}` placeholder, which the page fills with what the running skim
// answers, and the `add_comment` call is served for real against the open diff.
// See `src/components/McpTerminals.astro`.
//
// It works the diff in `problem.diff`, and the line numbers it names are the
// real ones — open that diff beside it or the two will disagree.

import twoWay from "./agent-two-way.jsonl?raw";

/** Where the page writes the comments the running skim reports. */
export const COMMENTS_PLACEHOLDER = "{{comments}}";

/**
 * One conversation: the visitor's comment is pulled back with `get_comments`,
 * and the agent's own finding goes onto the diff with `add_comment`.
 */
export const AGENT_TWO_WAY = twoWay;
