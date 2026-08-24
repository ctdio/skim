// Mounts a real, running skim into an element on the landing page.
//
// Both terminals on the page — the hero and the movement tour under "The tour"
// — call `mountLiveTerminal`. The wasm module is fetched and compiled once
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

/** One comment on the open diff, as `list_comments` reports it. */
export type SkimComment = {
  index: number;
  file_path: string;
  hunk_idx: number;
  line_idx: number;
  text: string;
};

export type View = {
  render(): Frame;
  key(
    codepoint: number,
    mods?: { ctrlKey?: boolean; altKey?: boolean; shiftKey?: boolean },
  ): Frame;
  sendKey(event: KeyboardEvent): Frame | null;
  scroll(lines: number): Frame;
  resize(cols: number, rows: number): Frame;
  agentReplay(session: string): Frame;
  agentStep(): Frame | null;
  /**
   * Put `text` in the panel's input box, as if it had been typed there. An
   * empty string clears it. The panel frame comes from `agentRender`.
   */
  agentInput(text: string): void;
  /** Draw the agent panel alone, into a screen of its own, at this size. */
  agentRender(cols: number, rows: number): Frame;
  /**
   * Serve an MCP `add_comment` request against the open diff. This is the
   * handler skim's stdio MCP server calls, so the comment arrives the way an
   * agent's comment arrives. Returns the new frame and skim's own answer, and
   * throws when skim rejects the request.
   */
  addComment(params: {
    file: string;
    line: number;
    line_type: "new" | "old";
    text: string;
  }): { frame: Frame; answer: { success: boolean; comment_index: number } };
  /** Serve an MCP `list_comments` request. Every comment, whoever wrote it. */
  listComments(): SkimComment[];
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
  /**
   * Open the agent panel on a recorded ACP session and play it through.
   *
   * `session` is JSONL in the shape `skim debug acp` reads. The panel takes the
   * right 30% of the frame and the diff keeps the rest. The promise settles
   * when the transcript runs out. Calling it again stops the run in progress,
   * as do `open` and `stopAgentSession`.
   *
   * `pacing` is handed each raw entry after it plays and returns how long to
   * hold before the next one, so a caller can give a paragraph longer than a
   * tool call. The pacing lives here because the module cannot do it: the
   * browser build runs against WASI stubs that answer the clock with a
   * constant, so every entry would read as not yet due.
   *
   * There is no agent behind this. The transcript is the whole of it, and skim
   * renders it through the same code a live session goes through.
   */
  playAgentSession(params: {
    session: string;
    pacing?: (entry: string) => number;
    /**
     * Called with each raw entry as it plays, before the frames are drawn, so
     * a caller can serve a tool call in it for real — an `add_comment` that
     * really does put a comment on the diff.
     */
    onEntry?: (entry: string) => void;
    /**
     * Called once the panel is open and empty, before the first entry plays.
     * This is where a caller types the opening prompt out with
     * `showAgentPrompt`. The box is cleared when it returns, which is what
     * sending the prompt does — the first entry then arrives as the message.
     */
    onOpen?: () => void | Promise<void>;
  }): Promise<void>;
  /**
   * Put `text` in the panel's input box and draw it.
   *
   * Call it with each prefix of a prompt to type one out. Skim's own input box
   * holds the text, so it wraps and scrolls the way it does under a keyboard.
   */
  showAgentPrompt(text: string): void;
  /** Stop the session in flight. Leaves the frame where it stopped. */
  stopAgentSession(): void;
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
 * `reveal` runs at that point: it is where the caller unhides the hosts and
 * hides the loading frame.
 *
 * Pass `agentHost` to put skim's agent panel in a second terminal beside the
 * diff. One session drives both, so a comment an agent writes over MCP shows up
 * in the diff pane while the call it came from is still on the panel.
 */
export async function mountLiveTerminal({
  host,
  agentHost,
  diff,
  font = { cols: 100, min: 8, max: 13 },
  onProgress,
  onInput,
  reveal,
}: {
  host: HTMLElement;
  /**
   * Where to draw skim's agent panel, when the page wants it in a terminal of
   * its own beside the diff rather than the right 30% of one frame. Skim draws
   * the panel either way; only the box around it differs.
   */
  agentHost?: HTMLElement;
  diff: string;
  font?: FontScale;
  onProgress?: (progress: Progress) => void;
  onInput?: () => void;
  reveal?: () => void;
}): Promise<LiveTerminal> {
  const [{ Terminal }, { FitAddon }, { WebglAddon }, loader] =
    await Promise.all([
      import("@xterm/xterm"),
      import("@xterm/addon-fit"),
      import("@xterm/addon-webgl"),
      import("../../../web/skim.js") as Promise<unknown> as Promise<SkimLoader>,
    ]);

  const skim = await loader.createSkim({
    wasmModule: await skimModule(loader, onProgress),
  });

  const styles = getComputedStyle(document.documentElement);

  /**
   * The type size both panes draw at, for the width the diff has now.
   *
   * One size, not one per pane. The panes are two boxes of the same skim, and
   * a panel whose glyphs are half again the size of the diff's beside it does
   * not read as one program. The diff sets it because code cannot reflow: it
   * needs its columns, and the panel takes whatever columns its own width comes
   * to at that size.
   */
  function paneFontSize(): number {
    return fontSizeFor(host.clientWidth, font);
  }

  /** One xterm over one element: the terminal, its writer, and its fitter. */
  function openPane(paneHost: HTMLElement) {
    const term = new Terminal({
      fontFamily:
        styles.getPropertyValue("--sk-font-mono").trim() || "monospace",
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
    term.open(paneHost);

    // Draw on the GPU. Without this xterm builds the screen out of DOM: an
    // element for every row, and a span for every run of colour in it. A
    // syntax-highlighted diff is hundreds of runs, and the browser lays out and
    // rasterises the lot again every time a frame changes. WebGL draws the same
    // cells as textured quads and does not touch the document at all.
    //
    // The addon throws where there is no WebGL2, and loses its context when the
    // browser takes the GPU back. Either way the terminal keeps working:
    // without the addon xterm falls back to the DOM it used before.
    const webgl = new WebglAddon();
    try {
      webgl.onContextLoss(() => webgl.dispose());
      term.loadAddon(webgl);
    } catch {
      webgl.dispose();
    }

    /** Rescale the glyph to the width the diff has now, then re-grid. */
    function refit(): void {
      const size = paneFontSize();
      if (term.options.fontSize !== size) term.options.fontSize = size;
      fit.fit();
    }

    refit();
    return { host: paneHost, term, painter: createPainter(term), refit };
  }

  // The hosts are hidden until `reveal`, so this is the first moment they have
  // a width to scale against.
  reveal?.();
  const diffPane = openPane(host);
  const agentPane = agentHost ? openPane(agentHost) : null;

  let view = skim.open({
    diff,
    cols: diffPane.term.cols,
    rows: diffPane.term.rows,
  });

  // Cancels the session in flight. Each run raises it, so a second `open` or
  // `playAgentSession` stops the first rather than interleaving with it.
  let sessionRun = 0;

  /**
   * Draw the agent panel into its own pane.
   *
   * Only the replay and a resize call this. A keystroke in the diff cannot
   * change what the panel holds, so painting it per key would be a second full
   * render for nothing.
   */
  function drawAgent(repaint = false): void {
    if (!agentPane) return;
    const frame = view.agentRender(agentPane.term.cols, agentPane.term.rows);
    if (repaint) agentPane.painter.repaint(frame);
    else agentPane.painter.draw(frame);
  }

  /**
   * Open the panel on an empty session.
   *
   * A session with no panel draws nothing into the second pane, so without this
   * the pane is an empty box until the first turn arrives — and the first turn
   * can be a minute of typing away. An empty panel is skim's own: the title
   * bar, the line that says to type a prompt, and the input box. Loading a
   * transcript later replaces it.
   */
  function openEmptyPanel(): void {
    if (!agentPane) return;
    view.agentReplay("");
  }

  const live: LiveTerminal = {
    get view() {
      return view;
    },
    draw: (frame) => diffPane.painter.draw(frame),
    open(next) {
      sessionRun += 1;
      view = skim.open({
        diff: next,
        cols: diffPane.term.cols,
        rows: diffPane.term.rows,
      });
      // The panel screen first: asking for it is what keeps the diff frame at
      // full width, and a fresh session would otherwise draw one frame with
      // the panel inset.
      openEmptyPanel();
      drawAgent(true);
      diffPane.painter.repaint(view.render());
    },
    focus: () => diffPane.term.focus(),
    stopAgentSession() {
      sessionRun += 1;
    },
    showAgentPrompt(text) {
      view.agentInput(text);
      drawAgent();
    },
    async playAgentSession({ session, pacing = () => 900, onEntry, onOpen }) {
      sessionRun += 1;
      const run = sessionRun;

      // The module walks the same entries, so this split has to match the one
      // in `acp/session_replay.zig`: non-empty lines, in order.
      const entries = session.split("\n").filter((line) => line.trim() !== "");

      // Open on an empty panel and hold, so the first turn arrives rather than
      // being there from the start.
      drawAgent(true);
      diffPane.painter.repaint(view.agentReplay(session));
      drawAgent(true);
      await delay(700);
      if (run !== sessionRun) return;

      await onOpen?.();
      if (run !== sessionRun) return;
      // Whatever the hook typed goes back out of the box: the turn it wrote is
      // about to arrive as a message, and a box that still holds it would read
      // as a prompt that never sent.
      view.agentInput("");

      for (const entry of entries) {
        if (run !== sessionRun) return;
        if (view.agentStep() === null) return;

        // Before the frames, because an entry may be a tool call the caller
        // serves for real — an `add_comment` that changes the diff.
        onEntry?.(entry);
        diffPane.painter.draw(view.render());
        drawAgent();
        await delay(pacing(entry));
      }
    },
  };
  openEmptyPanel();
  drawAgent(true);
  diffPane.painter.repaint(view.render());

  diffPane.term.attachCustomKeyEventHandler((event) => {
    if (event.metaKey) return false;
    if (PAGE_KEYS.has(event.key)) return false;
    if (event.key === "Tab" && event.shiftKey) return false;
    return !(event.ctrlKey && PAGE_CTRL_KEYS.has(event.key));
  });

  diffPane.term.onKey(({ domEvent }) => {
    const frame = view.sendKey(domEvent);
    if (frame === null) return;
    domEvent.preventDefault();
    onInput?.();
    live.draw(frame);
  });

  // The wheel scrolls the diff, the way it does in a real terminal.
  //
  // It is taken only while the terminal holds the keyboard. A visitor who has
  // not clicked in is reading the page, and the page must keep its own scroll —
  // a full-height terminal that ate the wheel on the way past would trap them.
  // Clicking in is the same act that arms every other key, so the rule is one
  // rule: the terminal answers the mouse once it is yours.
  //
  // The handler returns false either way. Xterm has no scrollback to move here
  // and no process to report the wheel to, so there is nothing for it to do.
  let carried = 0;
  diffPane.term.attachCustomWheelEventHandler((event) => {
    if (!host.contains(document.activeElement)) return false;
    event.preventDefault();

    const rows = diffPane.term.rows;
    const delta = wheelLines(event, rows, host.clientHeight / rows);
    // A flick the other way starts over rather than paying off the fraction the
    // last one left behind.
    if (delta > 0 !== carried > 0) carried = 0;
    carried += delta;

    const lines = Math.trunc(carried);
    carried -= lines;
    if (lines === 0) return false;

    onInput?.();
    live.draw(view.scroll(lines));
    return false;
  });

  // The frame changes size with the viewport. Rescale the glyph, then redraw at
  // the new grid. A phone that turns landscape crosses most of the scale.
  let pending = 0;
  const observer = new ResizeObserver(() => {
    window.clearTimeout(pending);
    pending = window.setTimeout(() => {
      diffPane.refit();
      agentPane?.refit();
      drawAgent(true);
      diffPane.painter.repaint(
        view.resize(diffPane.term.cols, diffPane.term.rows),
      );
    }, 120);
  });
  observer.observe(host);
  if (agentHost) observer.observe(agentHost);

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

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

/**
 * How many lines of the diff one wheel event asks for. Positive is down.
 *
 * A wheel reports its delta in one of three units, and only the middle one is
 * already what skim counts in. A pixel delta is divided by the height of a
 * cell, which is the step a terminal scrolls by. A page delta is the screen.
 *
 * The result is fractional on purpose: a trackpad sends many small pixel
 * deltas, and the caller keeps what is left over so a slow drag still moves.
 */
function wheelLines(
  event: WheelEvent,
  rows: number,
  cellHeight: number,
): number {
  if (event.deltaMode === event.DOM_DELTA_LINE) return event.deltaY;
  if (event.deltaMode === event.DOM_DELTA_PAGE) return event.deltaY * rows;
  return event.deltaY / cellHeight;
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
 * The writer for one terminal.
 *
 * Skim hands back the whole screen every frame, but a frame rarely changes much
 * of it: `j` rewrites two rows of forty-five, and a `ctrl-d` that is already at
 * the bottom rewrites none. Writing all forty-five back marks every row dirty,
 * and xterm's renderer then rebuilds the row elements for the whole screen —
 * per keystroke, and per repeat while a key is held. So the writer keeps the
 * rows it last painted and sends only the ones that differ.
 *
 * It also paints at most once an animation frame. Key repeat delivers keys
 * faster than a screen can show them, and a write per key makes the queue grow
 * for as long as the key is down: the terminal then keeps scrolling after the
 * visitor lets go. Skim still answers every key — only the painting is dropped,
 * and only for frames that were already superseded.
 */
function createPainter(term: { write(data: string): void }): {
  draw(frame: Frame): void;
  repaint(frame: Frame): void;
} {
  let painted: string[] = [];
  let paintedCursor = "";
  let queued: Frame | null = null;
  let scheduled = 0;

  return {
    draw,
    /** Paint every row, for a frame that shares no rows with the last one. */
    repaint(frame) {
      painted = [];
      draw(frame);
    },
  };

  function draw(frame: Frame): void {
    queued = frame;
    scheduled ||= requestAnimationFrame(flush);
  }

  function flush(): void {
    scheduled = 0;
    const frame = queued;
    queued = null;
    if (frame) paint(frame);
  }

  function paint(frame: Frame): void {
    const rows = frame.ansi.split("\n");
    const cursor = frame.cursor
      ? `\x1b[${frame.cursor.row + 1};${frame.cursor.col + 1}H\x1b[?25h`
      : "";

    // A new grid shares no rows with the old one, so home the cursor, erase
    // each row as it is written, and erase whatever the last frame left below.
    // A full clear would flicker.
    let body = "";
    if (rows.length !== painted.length) {
      body = "\x1b[H" + rows.join("\x1b[0m\x1b[K\r\n") + "\x1b[0m\x1b[K\x1b[J";
    } else {
      for (let row = 0; row < rows.length; row += 1) {
        if (rows[row] === painted[row]) continue;
        body += `\x1b[${row + 1};1H` + rows[row] + "\x1b[0m\x1b[K";
      }
    }

    painted = rows;
    if (body === "" && cursor === paintedCursor) return;
    paintedCursor = cursor;
    term.write("\x1b[?25l" + body + cursor);
  }
}
