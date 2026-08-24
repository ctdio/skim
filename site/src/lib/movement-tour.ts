// The movement tour beside "Move through it" on the landing page.
//
// One source of truth for two consumers that cannot share a scope:
// `MovementTerminal.astro` renders `kb`, `label`, and `note` as a key legend at
// build time, and its client script hands the same objects to the tour driver
// in `demo-autoplay.ts` as chapters. A key that is pressed is therefore always
// the key the row beside it names.
//
// Every chapter here is a *move*. Nothing in this tour changes the diff, the
// layout, or the file on disk — the point it makes is that getting to a line in
// skim costs one keystroke, so a chapter that did anything else would dilute it.
//
// `]c [c` is a move like the rest, but it needs comments to move between, so
// `TOUR_COMMENTS` goes on the diff before the tour starts. That is setup, not a
// chapter: the tour itself still only moves.

import { typed } from './demo-autoplay';
import type { Chapter } from './demo-autoplay';

export type Move = Chapter & {
  /** The keys, as the legend prints them. */
  kb: string;
  /** One line on what the keys are for. */
  note: string;
};

/** One comment to put on the diff, in the shape `add_comment` takes. */
export type TourComment = {
  file: string;
  line: number;
  line_type: 'new' | 'old';
  text: string;
};

export const MOVES: Move[] = [
  {
    label: 'Line by line',
    kb: 'j k',
    note: 'The motions are the vim ones, so nothing here has to be learned twice.',
    keys: ['j', 'j', 'j', 320, 'j', 'j', 'j', 420, 'k', 'k'],
    hold: 1400,
  },
  {
    label: 'Change to change',
    kb: ']h [h',
    note: 'Jump hunk to hunk and skip the context nobody is reviewing.',
    keys: [']', 'h', 1200, ']', 'h', 1200, ']', 'h'],
    hold: 1600,
  },
  {
    label: 'Comment to comment',
    kb: ']c [c',
    note: 'Walk the comments on the review, wherever in the diff they landed.',
    keys: [300, ']', 'c', 1300, ']', 'c', 1300, '[', 'c'],
    hold: 1600,
  },
  {
    label: 'Any file by name',
    kb: 'Ctrl-p',
    note: 'Fuzzy-find a file, or walk them in order with h and l. Three of these eight match "loading".',
    keys: [300, 'Ctrl-p', 700, ...typed('loading'), 700, 'Enter'],
    hold: 2200,
  },
  {
    label: 'Anywhere it says',
    kb: '/ n',
    note: 'Smart-case search across every file, and n walks the matches.',
    keys: ['/', 250, ...typed('stream'), 420, 'Enter', 900, 'n', 900, 'n'],
    // Escape alone leaves the match count in the status bar. Opening search
    // again does clear it: `App.startSearch` resets the state before it reads.
    exit: ['/', 'Escape'],
    hold: 1800,
  },
];

/**
 * The comments the `]c [c` chapter walks, in the order the diff holds them.
 *
 * Three files apart, so the jump is worth watching: one in `src/app.zig`, one
 * in the new loader, one in the new loading screen. The lines are lines
 * `demo.diff` really has — skim rejects a comment on a line the diff does not
 * carry, so a wrong number here fails the mount rather than passing quietly.
 */
export const TOUR_COMMENTS: TourComment[] = [
  {
    file: 'src/app.zig',
    line: 1362,
    line_type: 'new',
    text: 'This runs every frame. Is the idle path really free?',
  },
  {
    file: 'src/git/diff_loader.zig',
    line: 93,
    line_type: 'new',
    text: 'Does feed keep the tail when a file splits across two reads?',
  },
  {
    file: 'src/rendering/loading.zig',
    line: 10,
    line_type: 'new',
    text: 'No App state here, so snapshot it.',
  },
];
