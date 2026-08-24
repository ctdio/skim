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

import { typed } from './demo-autoplay';
import type { Chapter } from './demo-autoplay';

export type Move = Chapter & {
  /** The keys, as the legend prints them. */
  kb: string;
  /** One line on what the keys are for. */
  note: string;
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
    label: 'File to file',
    kb: 'Ctrl-n',
    note: 'Step through the files in the diff. h and l walk them too.',
    keys: [300, 'Ctrl-n', 1100, 'Ctrl-n', 1100, 'Ctrl-n'],
    hold: 1600,
  },
  {
    label: 'Any file by name',
    kb: 'Ctrl-p',
    note: 'Fuzzy-find a file in the review. Three of these eight match "loading".',
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
