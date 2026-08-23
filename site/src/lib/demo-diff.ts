// The diffs the landing page opens.
//
// Both are plain `.diff` files next to this one, imported raw so they stay
// readable and need no escaping. Vite inlines them at build time.
//
// `DEMO_DIFF` is a real commit from skim's own history — the one that made
// diffs stream in file by file. Eight files and twenty hunks, so every key the
// hero advertises has somewhere to go: `l` for the next file, `]h` for the next
// change, `/` for a search that spans files.
//
// `PROBLEM_DIFF` is short on purpose. The terminal in "The old way" is half a
// column wide, and it steps through the changes with `]h` on its own until a
// visitor takes over.

import demo from './demo.diff?raw';
import problem from './problem.diff?raw';

export const DEMO_DIFF = demo;
export const PROBLEM_DIFF = problem;
