// Fetches a diff from GitHub for the full-screen demo at `/try`.
//
// GitHub's REST API returns a unified diff for a pull request, a commit, or a
// comparison when the request asks for the diff media type, and it sends
// permissive CORS headers, so the page can read it directly. No token is sent:
// anonymous callers get public repositories and 60 requests an hour per address.
//
// The `.diff` URLs on github.com itself are not usable here — they redirect to
// a host that sends no CORS headers — so every form below is rewritten to the
// API path that serves the same change.

/** One diff, ready to open, and what to call it on screen. */
export type GitHubDiff = {
  /** Short human label, e.g. `ctdio/skim#42`. */
  label: string;
  /** The github.com page the diff came from, for the address bar. */
  url: string;
  diff: string;
};

type Target = { path: string; label: string; url: string };

const API = "https://api.github.com";
const DIFF_MEDIA_TYPE = "application/vnd.github.diff";

// The browser build parses and highlights the whole diff in one synchronous
// call, and nothing paints while it runs: a 57-file, 430 KB comparison blocks
// for about 170ms. This cap keeps that under about a second. Most pull requests
// are far below it, and one that is not is better reviewed in a clone.
const MAX_BYTES = 2_000_000;

const FORMS: {
  pattern: RegExp;
  path: (m: RegExpMatchArray) => string;
  label: (m: RegExpMatchArray) => string;
  url: (m: RegExpMatchArray) => string;
}[] = [
  {
    // github.com/owner/repo/pull/123, with or without a trailing /files.
    pattern:
      /^(?:https?:\/\/)?(?:www\.)?github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)/i,
    path: (m) => `/repos/${m[1]}/${m[2]}/pulls/${m[3]}`,
    label: (m) => `${m[1]}/${m[2]}#${m[3]}`,
    url: (m) => `https://github.com/${m[1]}/${m[2]}/pull/${m[3]}`,
  },
  {
    // github.com/owner/repo/commit/<sha>
    pattern:
      /^(?:https?:\/\/)?(?:www\.)?github\.com\/([^/]+)\/([^/]+)\/commit\/([0-9a-f]{7,40})/i,
    path: (m) => `/repos/${m[1]}/${m[2]}/commits/${m[3]}`,
    label: (m) => `${m[1]}/${m[2]}@${m[3].slice(0, 7)}`,
    url: (m) => `https://github.com/${m[1]}/${m[2]}/commit/${m[3]}`,
  },
  {
    // github.com/owner/repo/compare/base...head — the range may hold slashes,
    // because a branch name may.
    pattern:
      /^(?:https?:\/\/)?(?:www\.)?github\.com\/([^/]+)\/([^/]+)\/compare\/(.+)$/i,
    path: (m) => `/repos/${m[1]}/${m[2]}/compare/${m[3]}`,
    label: (m) => `${m[1]}/${m[2]} ${m[3]}`,
    url: (m) => `https://github.com/${m[1]}/${m[2]}/compare/${m[3]}`,
  },
  {
    // owner/repo#123, the way a pull request is written in prose.
    pattern: /^([\w.-]+)\/([\w.-]+)#(\d+)$/,
    path: (m) => `/repos/${m[1]}/${m[2]}/pulls/${m[3]}`,
    label: (m) => `${m[1]}/${m[2]}#${m[3]}`,
    url: (m) => `https://github.com/${m[1]}/${m[2]}/pull/${m[3]}`,
  },
  {
    // owner/repo@<sha>
    pattern: /^([\w.-]+)\/([\w.-]+)@([0-9a-f]{7,40})$/i,
    path: (m) => `/repos/${m[1]}/${m[2]}/commits/${m[3]}`,
    label: (m) => `${m[1]}/${m[2]}@${m[3].slice(0, 7)}`,
    url: (m) => `https://github.com/${m[1]}/${m[2]}/commit/${m[3]}`,
  },
];

/**
 * Read `input` as a pull request, a commit, or a comparison, and fetch its diff.
 *
 * Every failure throws an `Error` whose message is written for a visitor to
 * read, because that is where it ends up.
 */
export async function fetchGitHubDiff(input: string): Promise<GitHubDiff> {
  const target = targetFor(input);
  if (target === null) {
    throw new Error(
      "That is not a GitHub pull request, commit, or comparison URL.",
    );
  }

  let response: Response;
  try {
    response = await fetch(`${API}${target.path}`, {
      headers: { Accept: DIFF_MEDIA_TYPE },
    });
  } catch {
    throw new Error("Could not reach GitHub.");
  }
  if (!response.ok) throw new Error(await failureFor(response));

  const declared = Number(response.headers.get("content-length") ?? 0);
  if (declared > MAX_BYTES) throw new Error(tooLarge(declared));

  const diff = await response.text();
  if (diff.length > MAX_BYTES) throw new Error(tooLarge(diff.length));
  if (diff.trim().length === 0) throw new Error("That change has no diff.");

  return { label: target.label, url: target.url, diff };
}

/** The first form that matches, or null. */
function targetFor(input: string): Target | null {
  const raw = input.trim();
  if (raw.length === 0) return null;

  // A pasted URL may carry a `.diff` or `.patch` suffix, a query, or a fragment
  // such as the file anchor GitHub adds. None of them change which diff is
  // meant. The stripped form is tried first, because a `.diff` suffix would
  // otherwise land inside a comparison range. The raw form is tried after it,
  // because `owner/repo#123` writes a pull request number where a URL writes a
  // fragment, and stripping takes it away.
  const clean = raw
    .replace(/[?#].*$/, "")
    .replace(/\.(diff|patch)$/i, "")
    .replace(/\/+$/, "");

  return matchForm(clean) ?? matchForm(raw);
}

function matchForm(value: string): Target | null {
  for (const form of FORMS) {
    const match = value.match(form.pattern);
    if (match) {
      return {
        path: form.path(match),
        label: form.label(match),
        url: form.url(match),
      };
    }
  }
  return null;
}

/** What went wrong, in the words a visitor needs. */
async function failureFor(response: Response): Promise<string> {
  if (response.status === 404) {
    return "GitHub has no such change. A private repository looks the same from here.";
  }
  if (response.status === 403 || response.status === 429) {
    const left = response.headers.get("x-ratelimit-remaining");
    if (left === "0") {
      return "GitHub's hourly limit for anonymous requests is used up. Try again later.";
    }
    return "GitHub refused the request.";
  }
  if (response.status === 451) return "GitHub has blocked that repository.";

  // GitHub explains a refusal in the body, and it names the limit it hit — a
  // file count, a line count — which is more exact than a guess made here. It
  // answers 406 for a diff over one of those limits.
  const reason = await githubMessage(response);
  if (response.status === 406) {
    return (
      reason ??
      "GitHub will not send a diff this large. Clone the repository and run skim there."
    );
  }
  return reason ?? `GitHub answered ${response.status}.`;
}

/** The `message` GitHub puts in a failed response, if it sent one. */
async function githubMessage(response: Response): Promise<string | null> {
  try {
    const body: unknown = await response.json();
    const message = (body as { message?: unknown }).message;
    return typeof message === "string" && message.length > 0 ? message : null;
  } catch {
    return null;
  }
}

function tooLarge(bytes: number): string {
  const mb = (bytes / 1_000_000).toFixed(1);
  return `That diff is ${mb} MB. The browser build holds the whole diff in memory, so it stops at ${MAX_BYTES / 1_000_000} MB. Clone the repository and run skim there.`;
}
