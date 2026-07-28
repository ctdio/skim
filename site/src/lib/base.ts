// Base-path-aware URL helper for the hand-authored landing page.
//
// The site is served under `/skim/` on GitHub Pages (see `base` in
// astro.config.mjs). Starlight's own navigation and Astro's content links
// already respect the base, but the landing page authors its own `<a href>`s
// and asset paths — those must be run through `withBase()` so they resolve to
// `/skim/...` in production and `/` locally without hardcoding either.
//
// `import.meta.env.BASE_URL` is Astro's canonical base string (always has a
// trailing slash, e.g. `/skim/`).
export function withBase(path = ''): string {
  const base = import.meta.env.BASE_URL.replace(/\/$/, '');
  if (!path) return base || '/';
  const clean = path.startsWith('/') ? path : `/${path}`;
  return `${base}${clean}`;
}
