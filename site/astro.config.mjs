// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// Skim marketing + docs site.
//
// Deployed to GitHub Pages on the owner's repo (ctdio.github.io/skim), so the
// site is served under the `/skim/` base path. `site` + `base` below make
// Astro/Starlight emit correct absolute URLs, canonical links, and sitemap
// entries; internal links authored through Astro helpers (or Starlight's own
// navigation) inherit the base automatically. The custom landing page uses the
// `withBase()` helper in `src/lib/base.ts` for its hand-authored links so no
// asset or route hardcodes a leading `/`.
export default defineConfig({
  site: 'https://ctdio.github.io',
  base: '/skim',
  trailingSlash: 'ignore',
  integrations: [
    starlight({
      title: 'Skim',
      description:
        'A keyboard-driven TUI for code reviews, built in Zig. Vim-style navigation, sub-10ms startup, 60 FPS scrolling.',
      tagline: 'A keyboard-driven TUI for code reviews, built in Zig.',
      logo: {
        src: './src/assets/skim-mark.svg',
        alt: 'Skim',
        replacesTitle: false,
      },
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/ctdio/skim',
        },
      ],
      editLink: {
        baseUrl: 'https://github.com/ctdio/skim/edit/main/site/',
      },
      customCss: ['./src/styles/theme.css'],
      // The landing page is a custom full-width Astro page at `src/pages/index.astro`.
      // All Starlight docs live under the `docs/` content subtree so they serve
      // beneath `/docs/…` while `/` stays the marketing page.
      sidebar: [
        {
          label: 'Getting Started',
          items: [
            { label: 'Overview', slug: 'docs/getting-started/overview' },
            { label: 'Prerequisites', slug: 'docs/getting-started/prerequisites' },
            { label: 'Build from Source', slug: 'docs/getting-started/build-from-source' },
            { label: 'Your First Review', slug: 'docs/getting-started/first-review' },
          ],
        },
        {
          label: 'Guides',
          items: [
            { label: 'Navigating Diffs', slug: 'docs/guides/navigating-diffs' },
            { label: 'View Modes', slug: 'docs/guides/view-modes' },
            { label: 'Search & Find', slug: 'docs/guides/search-and-find' },
            { label: 'Visual Selection', slug: 'docs/guides/visual-selection' },
            { label: 'Comments & Export', slug: 'docs/guides/comments-and-export' },
            { label: 'Staging from the TUI', slug: 'docs/guides/staging' },
            { label: 'Live Refresh & Blame', slug: 'docs/guides/refresh-and-blame' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'Keybindings & Commands', slug: 'docs/reference/keybindings' },
            { label: 'Command-Line Usage', slug: 'docs/reference/cli' },
          ],
        },
        {
          label: 'Integrations',
          items: [
            { label: 'Git Diff Sources', slug: 'docs/integrations/git-diff-sources' },
            { label: 'Graphite Stacks', slug: 'docs/integrations/graphite' },
            { label: 'Editor Integration', slug: 'docs/integrations/editor' },
            { label: 'AI Agent Panel', slug: 'docs/integrations/agent-panel' },
          ],
        },
      ],
    }),
  ],
});
