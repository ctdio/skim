// Browser wrapper around zig-out/web/skim.wasm.
//
// The module is a WASI command module that needs only stub syscalls, so the
// shim below is inlined and this file has no dependencies.
//
//   import { createSkim } from './skim.js';
//   const skim = await createSkim({ wasmUrl: '/skim.wasm' });
//   const view = skim.open({ diff, cols: 100, rows: 32 });
//   draw(view.render());
//   term.onKey(({ domEvent }) => draw(view.sendKey(domEvent)));
//
// `agentReplay` opens the agent panel on a recorded ACP session and `agentStep`
// plays it one entry at a time. The caller owns the pacing:
//
//   draw(view.agentReplay(transcript));
//   const frame = view.agentStep();   // null once the transcript runs out
//
// `agentRender` draws that panel into a screen of its own, for a page that puts
// it in a second terminal beside the diff.
//
// `addComment` and `listComments` serve the two MCP requests a browser can
// answer, through the same handlers skim's stdio MCP server calls.
//
// `wasmUrl` may point at a gzipped module. The loader unpacks it when the host
// sent it verbatim, so a host that does not compress `application/wasm` itself
// still sends the small file.
//
// `render`, `key`, `sendKey`, `scroll`, and `resize` all return a frame:
//
//   { ansi: string, cursor: { row, col } | null }
//
// Write `ansi` to a terminal emulator such as xterm.js. `cursor` is set while
// the comment editor is open; put the terminal cursor there and show it.

const STATUS = {
  0: "ok",
  "-1": "no session",
  "-2": "failed to load the input",
  "-3": "failed to render",
  "-4": "failed to handle the key",
  "-5": "failed to resize",
  "-6": "failed to scroll",
  "-7": "failed to serve the request",
};

// Special keys, matching vaxis src/Key.zig.
const KEYS = {
  Tab: 0x09,
  Enter: 0x0d,
  Escape: 0x1b,
  Backspace: 0x7f,
  Delete: 57349,
  ArrowLeft: 57350,
  ArrowRight: 57351,
  ArrowUp: 57352,
  ArrowDown: 57353,
  PageUp: 57354,
  PageDown: 57355,
  Home: 57356,
  End: 57357,
};

const MOD_SHIFT = 1;
const MOD_ALT = 2;
const MOD_CTRL = 4;

/// Fetch and compile the module. Pass the result to `createSkim` as
/// `wasmModule` to put more than one terminal on a page: compiling is the
/// expensive step, and one compiled module serves any number of instances.
export async function loadSkimModule({ wasmUrl, wasmBytes, onProgress } = {}) {
  const source = wasmBytes ?? (await moduleBytes(wasmUrl, onProgress));
  return WebAssembly.compile(source);
}

/// Instantiate the module. One instance holds one open diff at a time; call
/// `open` again to replace it.
export async function createSkim({
  wasmUrl,
  wasmBytes,
  wasmModule,
  onProgress,
} = {}) {
  const compiled =
    wasmModule ?? (await loadSkimModule({ wasmUrl, wasmBytes, onProgress }));
  const wasi = wasiStubs(compiled);
  const instance = await WebAssembly.instantiate(compiled, wasi.imports);
  wasi.useMemory(instance.exports.memory);

  instance.exports._start();
  const wasm = instance.exports;

  return {
    open({ diff, cols = 100, rows = 32 }) {
      check(
        withText(wasm, diff, (ptr, len) => wasm.skimLoad(ptr, len, cols, rows)),
      );
      return view(wasm);
    },
    close() {
      wasm.skimUnload();
    },
  };
}

function view(wasm) {
  return {
    render() {
      check(wasm.skimRender());
      return readFrame(wasm);
    },

    /// Send one key by codepoint. `mods` is anything with the KeyboardEvent
    /// modifier fields: `{ ctrlKey, altKey, shiftKey }`.
    key(codepoint, mods = {}) {
      check(wasm.skimKey(codepoint, packMods(mods)));
      return this.render();
    },

    /// Send a browser KeyboardEvent. Returns null for a key skim does not use,
    /// so the caller can let the browser keep its own shortcut.
    sendKey(event) {
      const codepoint = codepointFor(event);
      if (codepoint === null) return null;
      return this.key(codepoint, event);
    },

    /// Scroll the surface skim is showing by whole lines: negative up,
    /// positive down. This is what a mouse wheel maps to. The caller turns a
    /// wheel event into a line count, because only it knows how tall a cell is
    /// on screen and which unit the wheel reported.
    scroll(lines) {
      check(wasm.skimScroll(lines));
      return this.render();
    },

    resize(cols, rows) {
      check(wasm.skimResize(cols, rows));
      return readFrame(wasm);
    },

    /// Open the agent panel on a recorded ACP session, in the JSONL shape
    /// `skim debug acp` reads. The panel opens paused on entry one.
    agentReplay(session) {
      check(
        withText(wasm, session, (ptr, len) => wasm.skimAgentReplay(ptr, len)),
      );
      return this.render();
    },

    /// Put `text` in the panel's input box, as if it had been typed there.
    /// Call it with each prefix of a prompt to type one out, and with an empty
    /// string to clear the box. Read the panel back with `agentRender`.
    agentInput(text) {
      check(withText(wasm, text, (ptr, len) => wasm.skimAgentInput(ptr, len)));
    },

    /// Play the next entry of the session. Returns null once it runs out, so a
    /// caller can stop its own timer.
    agentStep() {
      if (wasm.skimAgentStep() === 0) return null;
      return this.render();
    },

    /// Draw the agent panel alone, into a screen of its own, for a page that
    /// gives it a terminal beside the diff rather than the right 30% of one
    /// frame. Skim draws the panel either way; only the box around it differs.
    ///
    /// Asking for this frame is also what tells `render` to keep the diff full
    /// width, so a caller that asks once must keep asking.
    agentRender(cols, rows) {
      check(wasm.skimAgentRender(cols, rows));
      return readAgentFrame(wasm);
    },

    /// Serve an MCP `add_comment` request against the open diff. `params` is
    /// the tool's own arguments object: `file`, `line`, `line_type`, `text`.
    /// The request goes through the handler the stdio MCP server calls, so the
    /// comment arrives the way an agent's comment arrives. Returns the new
    /// frame and skim's own answer. Throws when skim rejects it — a line that
    /// is not in the diff, for one.
    addComment(params) {
      const json = JSON.stringify(params);
      check(withText(wasm, json, (ptr, len) => wasm.skimAddComment(ptr, len)));
      const answer = readJson(wasm);
      if (answer.error) throw new Error(`skim: ${answer.error.message}`);
      return { frame: this.render(), answer };
    },

    /// Serve an MCP `list_comments` request. Returns every comment on the open
    /// diff, whoever wrote it.
    listComments() {
      check(wasm.skimListComments());
      return readJson(wasm).comments;
    },

    close() {
      wasm.skimUnload();
    },
  };
}

/// Copy `text` into the module, run `call` on it, and free it again. The module
/// owns nothing it is handed: every entry point copies what it needs.
function withText(wasm, text, call) {
  const bytes = new TextEncoder().encode(text);

  // Ask for a byte even when there is nothing to copy. A zero-length request
  // comes back as a sentinel address rather than a place in the buffer, and
  // reading the buffer there throws. The module is handed the real length, so
  // an empty text arrives empty.
  const size = Math.max(bytes.length, 1);
  const ptr = wasm.skimAlloc(size);
  if (ptr === 0) throw new Error("skim: out of memory");

  try {
    new Uint8Array(wasm.memory.buffer, ptr, bytes.length).set(bytes);
    return call(ptr, bytes.length);
  } finally {
    wasm.skimFree(ptr, size);
  }
}

function codepointFor(event) {
  if (event.key in KEYS) return KEYS[event.key];
  if ([...event.key].length !== 1) return null;
  return event.key.codePointAt(0);
}

function packMods({ ctrlKey, altKey, shiftKey }) {
  return (
    (ctrlKey ? MOD_CTRL : 0) |
    (altKey ? MOD_ALT : 0) |
    (shiftKey ? MOD_SHIFT : 0)
  );
}

function readJson(wasm) {
  const bytes = new Uint8Array(
    wasm.memory.buffer,
    wasm.skimJsonPtr(),
    wasm.skimJsonLen(),
  );
  return JSON.parse(new TextDecoder().decode(bytes));
}

function readAgentFrame(wasm) {
  const bytes = new Uint8Array(
    wasm.memory.buffer,
    wasm.skimAgentOutPtr(),
    wasm.skimAgentOutLen(),
  );
  // The panel never wants a text cursor: skim shows one for the comment
  // editor, which lives in the diff.
  return { ansi: new TextDecoder().decode(bytes), cursor: null };
}

function readFrame(wasm) {
  const bytes = new Uint8Array(
    wasm.memory.buffer,
    wasm.skimOutPtr(),
    wasm.skimOutLen(),
  );
  return {
    ansi: new TextDecoder().decode(bytes),
    cursor: wasm.skimCursorVisible()
      ? { row: wasm.skimCursorRow(), col: wasm.skimCursorCol() }
      : null,
  };
}

/**
 * Fetch the module bytes, unpacking gzip when the host did not.
 *
 * Hosts disagree about a `.gz` URL: some send it verbatim, some set
 * `Content-Encoding: gzip` and the browser unpacks it before this code sees it.
 * Neither the URL nor the header tells the two apart after the fact, so read the
 * magic number of what actually arrived.
 *
 * `onProgress({ loaded, total })` runs as the bytes arrive. `total` is null when
 * the host compresses on the fly and so sends no `Content-Length`.
 */
async function moduleBytes(url, onProgress) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`skim: ${url} returned ${response.status}`);

  const bytes = await readBody(response, onProgress);
  if (bytes[0] !== 0x1f || bytes[1] !== 0x8b) return bytes;

  const stream = new Blob([bytes])
    .stream()
    .pipeThrough(new DecompressionStream("gzip"));
  return new Response(stream).arrayBuffer();
}

async function readBody(response, onProgress) {
  if (!onProgress || !response.body) {
    return new Uint8Array(await response.arrayBuffer());
  }

  const header = response.headers.get("content-length");
  const total = header ? Number(header) : null;
  const reader = response.body.getReader();
  const chunks = [];
  let loaded = 0;

  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    loaded += value.length;
    onProgress({ loaded, total });
  }

  const bytes = new Uint8Array(loaded);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return bytes;
}

function check(status) {
  if (status !== 0)
    throw new Error(`skim: ${STATUS[status] ?? `error ${status}`}`);
}

// The module never reads a file and never writes one, so most syscalls here
// return success and write nothing. Four do not, and each one has to be what it
// is:
//
//   `fd_prestat_get` must report EBADF. Zig walks the preopened directories at
//   start-up by asking for descriptor 3, then 4, and so on until one comes back
//   bad. Answering "success" without filling the struct in leaves it reading
//   whatever was in that memory, and the walk then runs off into a trap inside
//   `_start` — before a single export is reachable.
//
//   `args_sizes_get` and `environ_sizes_get` must write their two counts. Same
//   hazard: the caller reads the counts whatever the return code says.
//
//   `clock_time_get` must return a real time. The agent panel stamps every
//   message it holds and lays the transcript out from those stamps, so a clock
//   stuck at one value collapses the panel to its first message. A diff on its
//   own never asks.
//
//   `proc_exit` throws, and only runs if the module panics.
//
// The list comes from the module itself, not from a list written here by hand.
// A change to the Zig standard library or to the code the browser build pulls
// in adds a syscall to the module, and a hand-written list then misses it. That
// is a LinkError, which stops the whole demo: `poll_oneoff` broke it this way.
const WASI_EBADF = 8;

function wasiStubs(module) {
  const stubs = {};
  // Filled in after instantiation: the stubs that write need the memory, and
  // the module does not have one until it is instantiated with these.
  let memory = null;

  // Realtime in nanoseconds for the wall clock, and the page's monotonic timer
  // for everything else. `id` 0 is realtime; 1 and up are monotonic or
  // per-process, none of which may run backwards.
  const readClock = (id, precision, outPtr) => {
    const ms = Date.now();
    new DataView(memory.buffer).setBigUint64(
      outPtr,
      BigInt(Math.round(ms * 1e6)),
      true,
    );
    return 0;
  };

  const zeroCounts = (countPtr, sizePtr) => {
    const view = new DataView(memory.buffer);
    view.setUint32(countPtr, 0, true);
    view.setUint32(sizePtr, 0, true);
    return 0;
  };

  for (const entry of WebAssembly.Module.imports(module)) {
    if (entry.module !== "wasi_snapshot_preview1") {
      throw new Error(`skim: the module needs ${entry.module}.${entry.name}`);
    }
    switch (entry.name) {
      case "proc_exit":
        stubs[entry.name] = (code) => {
          throw new Error(`skim: the module exited with code ${code}`);
        };
        break;
      case "fd_prestat_get":
        stubs[entry.name] = () => WASI_EBADF;
        break;
      case "args_sizes_get":
      case "environ_sizes_get":
        stubs[entry.name] = zeroCounts;
        break;
      case "clock_time_get":
        stubs[entry.name] = readClock;
        break;
      default:
        stubs[entry.name] = () => 0;
    }
  }

  return {
    imports: { wasi_snapshot_preview1: stubs },
    useMemory(exported) {
      memory = exported;
    },
  };
}
