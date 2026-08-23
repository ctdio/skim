// Mounts a real, running skim into an element on the landing page.
//
// Both terminals on the page — the hero and the supporting one in "The old
// way" — call `mountLiveTerminal`. The wasm module is fetched and compiled once
// and shared: compiling is the expensive step, and one compiled module serves
// any number of instances.
//
// `web/skim.js` is the loader skim ships. It is imported as a module rather
// than fetched, so the bundler owns it and the dev server does not try to
// transform a file it served from `public/`.

import { withBase } from "./base";

export type Frame = {
  ansi: string;
  cursor: { row: number; col: number } | null;
};

export type Progress = { loaded: number; total: number | null };

/**
 * How a terminal picks its font size from the width it is given.
 *
 * `cols` is the column count to hold: a monospace cell is about 0.6em wide, so
 * a box `w` pixels across shows `w / (0.6 * size)` columns, and solving that
 * for the size keeps the same view at every width. A phone cannot have both,
 * though — holding 100 columns across 350px means a six-pixel glyph — so the
 * size stops at `min` and the terminal shows fewer columns instead. Skim reflows to
 * whatever grid it is handed, so that is the honest answer for a small screen:
 * what the real thing looks like in a narrow terminal.
 */
export type FontScale = { cols: number; min: number; max: number };

export type View = {
  render(): Frame;
  key(
    codepoint: number,
    mods?: { ctrlKey?: boolean; altKey?: boolean; shiftKey?: boolean },
  ): Frame;
  sendKey(event: KeyboardEvent): Frame | null;
  resize(cols: number, rows: number): Frame;
};

export type LiveTerminal = {
  /** The open diff. `open` replaces it, so read it at the point of use. */
  view: View;
  /** Redraw the current frame, or a frame a caller produced with `view.key`. */
  draw(frame: Frame): void;
  /**
   * Replace the open diff and draw its first frame.
   *
   * The module holds one session at a time, so this closes the one that is
   * open. It is synchronous and it parses and highlights the whole diff, so a
   * large one blocks the tab: paint whatever says so before the call. It throws
   * when skim cannot parse the text, and the module is left with no session —
   * open a diff that works before you draw again.
   */
  open(diff: string): void;
  /** Put the keyboard on the terminal. */
  focus(): void;
};

type SkimLoader = {
  loadSkimModule(params: {
    wasmUrl: string;
    onProgress?: (progress: Progress) => void;
  }): Promise<WebAssembly.Module>;
  createSkim(params: { wasmModule: WebAssembly.Module }): Promise<{
    open(params: { diff: string; cols: number; rows: number }): View;
  }>;
};

/** Width of a monospace cell, as a fraction of the font size. */
const CELL_RATIO = 0.6;

// Keys the page keeps for itself.
//
// Tab is not among them: skim binds it to the hunk view cycle, so a focused
// terminal answers it. Shift-Tab is, and it is the way a keyboard user leaves
// the terminal — without one, focus would be trapped in the frame.
//
// The Ctrl list is what a browser would rather do with the chord. Ctrl-n is
// absent because skim reads it as "next file", but note that Chrome opens a new
// window on Ctrl-n before a page ever sees the event, so the key only reaches
// skim in a browser that delivers it.
const PAGE_KEYS = new Set(["F5", "F6", "F11", "F12"]);
const PAGE_CTRL_KEYS = new Set(["w", "t", "r", "l"]);

/**
 * Load skim, open `diff`, and take over `host`.
 *
 * Nothing in the page changes until the module is in hand, so a failed load
 * leaves the loading frame in place for the caller to write an error into.
 * `reveal` runs at that point: it is where the caller unhides `host` and hides
 * the loading frame.
 */
export async function mountLiveTerminal({
  host,
  diff,
  font = { cols: 100, min: 8, max: 13 },
  onProgress,
  onInput,
  reveal,
}: {
  host: HTMLElement;
  diff: string;
  font?: FontScale;
  onProgress?: (progress: Progress) => void;
  onInput?: () => void;
  reveal?: () => void;
}): Promise<LiveTerminal> {
  const [{ Terminal }, { FitAddon }, loader] = await Promise.all([
    import("@xterm/xterm"),
    import("@xterm/addon-fit"),
    import("../../../web/skim.js") as Promise<unknown> as Promise<SkimLoader>,
  ]);

  const skim = await loader.createSkim({
    wasmModule: await skimModule(loader, onProgress),
  });

  const styles = getComputedStyle(document.documentElement);
  const term = new Terminal({
    fontFamily: styles.getPropertyValue("--sk-font-mono").trim() || "monospace",
    fontSize: font.max,
    lineHeight: 1.15,
    cursorStyle: "bar",
    cursorBlink: true,
    allowTransparency: true,
    // Fixed, not the themed `--tui-*` pair: see the token definition.
    theme: {
      background: styles.getPropertyValue("--sk-term-bg").trim() || "#16181d",
      foreground: styles.getPropertyValue("--sk-term-fg").trim() || "#d7dae0",
    },
  });
  const fit = new FitAddon();
  term.loadAddon(fit);

  reveal?.();
  term.open(host);
  // The host was hidden until `reveal`, so this is the first moment it has a
  // width to scale against.
  term.options.fontSize = fontSizeFor(host.clientWidth, font);
  fit.fit();

  let view = skim.open({ diff, cols: term.cols, rows: term.rows });
  const live: LiveTerminal = {
    // A getter, because `open` replaces the session and a caller that read the
    // field once would go on driving the diff that is no longer on screen.
    get view() {
      return view;
    },
    draw: (frame) => draw(term, frame),
    open(next) {
      view = skim.open({ diff: next, cols: term.cols, rows: term.rows });
      live.draw(view.render());
    },
    focus: () => term.focus(),
  };
  live.draw(view.render());

  term.attachCustomKeyEventHandler((event) => {
    if (event.metaKey) return false;
    if (PAGE_KEYS.has(event.key)) return false;
    if (event.key === "Tab" && event.shiftKey) return false;
    return !(event.ctrlKey && PAGE_CTRL_KEYS.has(event.key));
  });

  term.onKey(({ domEvent }) => {
    const frame = view.sendKey(domEvent);
    if (frame === null) return;
    domEvent.preventDefault();
    onInput?.();
    live.draw(frame);
  });

  // The frame changes size with the viewport. Rescale the glyph, then redraw at
  // the new grid. A phone that turns landscape crosses most of the scale.
  let pending = 0;
  new ResizeObserver(() => {
    window.clearTimeout(pending);
    pending = window.setTimeout(() => {
      const size = fontSizeFor(host.clientWidth, font);
      if (term.options.fontSize !== size) term.options.fontSize = size;
      fit.fit();
      live.draw(view.resize(term.cols, term.rows));
    }, 120);
  }).observe(host);

  return live;
}

/**
 * Whether this visitor gets a live terminal at all.
 *
 * Everyone does, except a visitor who asked for less data. The terminal is the
 * only thing in the frame — there is no mockup behind it any more — so gating
 * on pointer or viewport would leave a phone looking at an empty box.
 */
export function wantsLiveTerminal(): boolean {
  const connection = (navigator as { connection?: { saveData?: boolean } })
    .connection;
  return connection?.saveData !== true;
}

/**
 * The font size that shows `font.cols` columns across `width` pixels, held
 * inside the legible range. Rounded to a half pixel, which keeps the resize
 * handler from setting a new size on every pixel of a drag.
 */
function fontSizeFor(width: number, font: FontScale): number {
  const fits = width / (font.cols * CELL_RATIO);
  return Math.round(Math.min(font.max, Math.max(font.min, fits)) * 2) / 2;
}

// One download, one compile, however many terminals. The second caller joins
// the first one's promise, so it reports no progress of its own — it is already
// most of the way through someone else's.
let compiled: Promise<WebAssembly.Module> | null = null;

function skimModule(
  loader: SkimLoader,
  onProgress?: (progress: Progress) => void,
): Promise<WebAssembly.Module> {
  compiled ??= loader.loadSkimModule({
    wasmUrl: withBase("/demo/skim.wasm.gz"),
    onProgress,
  });
  return compiled;
}

/**
 * Repaint in place: home the cursor, erase each row as it is written, then
 * erase whatever the previous frame left below. A full clear would flicker.
 */
function draw(term: { write(data: string): void }, frame: Frame): void {
  const rows = frame.ansi.split("\n");
  let out =
    "\x1b[?25l\x1b[H" + rows.join("\x1b[0m\x1b[K\r\n") + "\x1b[0m\x1b[K\x1b[J";
  if (frame.cursor) {
    out += `\x1b[${frame.cursor.row + 1};${frame.cursor.col + 1}H\x1b[?25h`;
  }
  term.write(out);
}
