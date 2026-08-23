// Drives a live skim terminal through a scripted tour.
//
// A chapter is a list of keys and pauses. The driver presses them one at a
// time and draws every frame, so what a visitor watches is the real Zig
// renderer answering real keys — a recording cannot drift from the product
// because there is no recording.
//
// The tour is polite. It runs only while the frame is on screen and the tab is
// in front, and it does nothing at all under `prefers-reduced-motion: reduce`.
//
// It also gets out of the way whenever the visitor touches the terminal. One
// rule covers both ways they can: focusing it and typing in it each arm a
// hand-back countdown, and the countdown is on hold for as long as they stay
// focused. So a reader who clicks in and reads keeps the terminal, and a reader
// who clicks away gets the full `HANDBACK_MS` before the tour comes back.
//
// `onStatus` reports all of this, including the seconds left, so the page can
// show what is about to happen instead of letting a still frame look broken.
//
// The tour always returns to the top of the diff in normal mode before it
// starts a chapter, so no chapter inherits the state of the last one.

import type { LiveTerminal } from "./live-terminal";

export type Step = string | number;

export type Chapter = {
  label: string;
  /** Key names and pauses in milliseconds, pressed in order. */
  keys: Step[];
  /** Keys that undo whatever the chapter changed. Pressed before the next one. */
  exit?: string[];
  /** A setting this chapter steps round a cycle. See `Cycle`. */
  cycle?: Cycle;
  /** Milliseconds to rest on the final frame. */
  hold: number;
};

/**
 * A key that steps a setting round a fixed ring: `s` over the two layouts, Tab
 * over the three hunk filters.
 *
 * A fixed `exit` cannot undo one of these, because how far round the ring the
 * setting has travelled depends on how much of the chapter actually ran. So the
 * driver counts the presses instead and, before the next chapter, presses the
 * key out the rest of the way. An interrupted chapter leaves the setting where
 * it found it, and a chapter that ran to the end costs nothing.
 */
export type Cycle = { key: string; length: number };

/**
 * Who has the terminal.
 *
 * `held` means the visitor is focused and the tour is waiting on them with no
 * deadline. `resuming` means they have stepped away and the tour comes back in
 * `seconds`.
 */
export type TourStatus =
  | { kind: "playing" }
  | { kind: "held" }
  | { kind: "resuming"; seconds: number };

export type Autoplay = {
  /** Jump to a chapter and play from there. */
  play(index: number): void;
  /** Hand the terminal to the visitor, and start the countdown to take it back. */
  yieldToVisitor(): void;
  /**
   * Report whether the visitor has the terminal focused.
   *
   * A keypress is not the only sign someone is using it. Clicking in and
   * reading is too, and a tour that keeps typing under a reader is worse than
   * one that waits.
   */
  setFocused(next: boolean): void;
};

// Named keys, matching the table `web/skim.js` maps browser events through.
// Anything else in a script is a single character and goes by codepoint, which
// is how skim reads it: `?` and `D` need no shift flag, only their codepoint.
// A `Ctrl-` prefix sends the key with the control modifier, e.g. `Ctrl-p`.
const KEYS: Record<string, number> = {
  Tab: 0x09,
  Enter: 0x0d,
  Escape: 0x1b,
  Backspace: 0x7f,
};

const CTRL = "Ctrl-";

/** Between two characters of `typed`. Fast enough to read as typing. */
const TYPE_MS = 90;

/** After the reset keys, so the jump back to the top registers as a move. */
const RESET_MS = 500;

/**
 * How long the visitor keeps the terminal after they step away from it.
 *
 * Long enough to finish reading the frame they stopped on, short enough that a
 * hero left alone goes back to demonstrating itself.
 */
const HANDBACK_MS = 15000;

/** How often the countdown is recomputed. Four times a second reads as smooth. */
const TICK_MS = 250;

/**
 * Start a tour over `terminal`, and watch `host` to know when it is on screen.
 *
 * The returned handle is what the chapter tabs and the key handler drive.
 */
export function createAutoplay({
  terminal,
  host,
  chapters,
  onChapter,
  onStatus,
}: {
  terminal: LiveTerminal;
  host: HTMLElement;
  chapters: Chapter[];
  /**
   * Called as each chapter starts, with how long it runs from that moment.
   * The page uses the duration to draw a progress bar with one CSS transition
   * rather than a second timer that could drift from this one.
   */
  onChapter?: (index: number, durationMs: number) => void;
  /**
   * Called whenever the answer to "who has the terminal" changes, and once a
   * second while a countdown runs. Scrolling the frame off screen is not a
   * status change: nobody is watching, so there is nothing to explain.
   */
  onStatus?: (status: TourStatus) => void;
}): Autoplay {
  // Every run carries a token. Anything that interrupts bumps it, and the loop
  // stops at its next check rather than fighting whatever interrupted it.
  let token = 0;
  let running = false;
  let index = 0;
  let visible = false;
  let timer = 0;
  let focused = false;
  let pendingExit: string[] = [];
  let pendingCycle: (Cycle & { pressed: number }) | null = null;

  // When the tour may take the terminal back, as a timestamp. Zero means the
  // visitor has not touched it and there is nothing to count down.
  let handBackAt = 0;
  let ticker = 0;
  let reported = "";

  const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  new IntersectionObserver(
    ([entry]) => {
      visible = entry.isIntersecting;
      if (visible) resume();
      else cancel();
    },
    { threshold: 0.2 },
  ).observe(host);

  document.addEventListener("visibilitychange", () => {
    if (document.hidden) cancel();
    else resume();
  });

  return {
    play(next: number): void {
      // A tab click asks for the tour, so the countdown is over.
      stopCountdown();
      cancel();
      report();
      void run(next);
    },
    yieldToVisitor(): void {
      cancel();
      startCountdown();
    },
    setFocused(next: boolean): void {
      if (focused === next) return;
      focused = next;
      if (next) cancel();
      // Focusing arms the countdown; the tick holds it there until they blur.
      startCountdown();
    },
  };

  function resume(): void {
    if (still || running || !visible || document.hidden) return;
    if (focused || handBackAt) return;
    void run(index);
  }

  /** Give the visitor the terminal for `HANDBACK_MS` from now. */
  function startCountdown(): void {
    if (still) return;
    handBackAt = Date.now() + HANDBACK_MS;
    ticker ||= window.setInterval(tick, TICK_MS);
    report();
  }

  function stopCountdown(): void {
    handBackAt = 0;
    window.clearInterval(ticker);
    ticker = 0;
  }

  /**
   * Advance the countdown, or hold it.
   *
   * While the visitor is focused the deadline is pushed forward every tick, so
   * the clock only starts running once they step away from the terminal.
   */
  function tick(): void {
    if (focused) {
      handBackAt = Date.now() + HANDBACK_MS;
      report();
      return;
    }
    if (Date.now() < handBackAt) {
      report();
      return;
    }
    stopCountdown();
    report();
    resume();
  }

  /** Tell the page who has the terminal, whenever the answer changes. */
  function report(): void {
    const status: TourStatus = focused
      ? { kind: "held" }
      : handBackAt
        ? {
            kind: "resuming",
            seconds: Math.max(0, Math.ceil((handBackAt - Date.now()) / 1000)),
          }
        : { kind: "playing" };

    const key = status.kind + ("seconds" in status ? status.seconds : "");
    if (key === reported) return;
    reported = key;
    onStatus?.(status);
  }

  function cancel(): void {
    token += 1;
    running = false;
    window.clearTimeout(timer);
  }

  async function run(from: number): Promise<void> {
    const mine = (token += 1);
    running = true;
    index = from;

    while (token === mine) {
      settle();
      await wait(RESET_MS);
      if (token !== mine) return;

      const chapter = chapters[index];
      pendingExit = chapter.exit ?? [];
      pendingCycle = chapter.cycle ? { ...chapter.cycle, pressed: 0 } : null;
      onChapter?.(index, durationOf(chapter));

      for (const step of chapter.keys) {
        if (typeof step === "number") {
          await wait(step);
        } else {
          press(step);
          if (pendingCycle && step === pendingCycle.key) pendingCycle.pressed += 1;
        }
        if (token !== mine) return;
      }

      await wait(chapter.hold);
      index = (index + 1) % chapters.length;

      // Under reduced motion the tour never starts itself. A tab click is the
      // one way in, so play what was asked for and stop there.
      if (still) return;
    }
  }

  /**
   * Return to the state every chapter starts from: normal mode, cursor at the
   * top of the diff. Escape first, because the last chapter — or the visitor —
   * may have left a mode open that would eat the keys after it.
   */
  function settle(): void {
    press("Escape");
    for (const key of pendingExit) press(key);
    pendingExit = [];

    if (pendingCycle) {
      const { key, length, pressed } = pendingCycle;
      pendingCycle = null;
      let left = (length - (pressed % length)) % length;
      while (left > 0) {
        press(key);
        left -= 1;
      }
    }

    press("g");
    press("g");
  }

  function press(key: string): void {
    const ctrl = key.startsWith(CTRL);
    const name = ctrl ? key.slice(CTRL.length) : key;
    terminal.draw(terminal.view.key(codepointFor(name), { ctrlKey: ctrl }));
  }

  function wait(ms: number): Promise<void> {
    return new Promise((resolve) => {
      timer = window.setTimeout(resolve, ms);
    });
  }
}

/**
 * How long a chapter takes from the moment it starts.
 *
 * Only the pauses and the closing hold cost time — a keypress is drawn in the
 * same tick it is sent.
 */
function durationOf(chapter: Chapter): number {
  const pauses = chapter.keys.reduce<number>(
    (total, step) => (typeof step === "number" ? total + step : total),
    0,
  );
  return pauses + chapter.hold;
}

/** A string as one key per character, spaced out so it reads as typing. */
export function typed(text: string, delay: number = TYPE_MS): Step[] {
  return [...text].flatMap((char) => [delay, char]);
}

function codepointFor(key: string): number {
  return KEYS[key] ?? key.codePointAt(0)!;
}
