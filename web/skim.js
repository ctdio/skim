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
// `wasmUrl` may point at a gzipped module. The loader unpacks it when the host
// sent it verbatim, so a host that does not compress `application/wasm` itself
// still sends the small file.
//
// `render`, `key`, `sendKey`, and `resize` all return a frame:
//
//   { ansi: string, cursor: { row, col } | null }
//
// Write `ansi` to a terminal emulator such as xterm.js. `cursor` is set while
// the comment editor is open; put the terminal cursor there and show it.

const STATUS = {
  0: "ok",
  "-1": "no session",
  "-2": "failed to parse the diff",
  "-3": "failed to render",
  "-4": "failed to handle the key",
  "-5": "failed to resize",
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
  const imports = { wasi_snapshot_preview1: wasiStubs() };
  const compiled =
    wasmModule ?? (await loadSkimModule({ wasmUrl, wasmBytes, onProgress }));
  const instance = await WebAssembly.instantiate(compiled, imports);

  instance.exports._start();
  const wasm = instance.exports;

  return {
    open({ diff, cols = 100, rows = 32 }) {
      const bytes = new TextEncoder().encode(diff);
      const ptr = wasm.skimAlloc(bytes.length);
      if (ptr === 0) throw new Error("skim: out of memory");

      new Uint8Array(wasm.memory.buffer, ptr, bytes.length).set(bytes);
      const status = wasm.skimLoad(ptr, bytes.length, cols, rows);
      wasm.skimFree(ptr, bytes.length);
      check(status);

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

    resize(cols, rows) {
      check(wasm.skimResize(cols, rows));
      return readFrame(wasm);
    },

    close() {
      wasm.skimUnload();
    },
  };
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

// The module never reads a file, writes a file, or reads the clock for anything
// the caller can observe. Every syscall returns success with no data, except
// `proc_exit`, which only runs if the module panics.
function wasiStubs() {
  const ok = () => 0;
  return {
    args_get: ok,
    args_sizes_get: ok,
    fd_close: ok,
    fd_fdstat_get: ok,
    fd_fdstat_set_flags: ok,
    fd_filestat_get: ok,
    fd_pread: ok,
    fd_pwrite: ok,
    fd_read: ok,
    fd_seek: ok,
    fd_write: ok,
    clock_time_get: ok,
    proc_exit: (code) => {
      throw new Error(`skim: the module exited with code ${code}`);
    },
  };
}
