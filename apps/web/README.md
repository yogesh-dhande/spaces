# Spaces Web

The static marketing site and user-facing docs published at https://usespaces.dev. It also serves the Linux installer (`/install.sh`) and the Sparkle update feeds (`/releases/`).

## Stack

- Next.js App Router with static export (`output: "export"` in `next.config.ts`)
- TypeScript
- Tailwind CSS 4 through `@tailwindcss/postcss`; there is no Tailwind config file, and theme tokens live in `app/globals.css`

## Commands

Run from `apps/web`:

```bash
npm ci
npm run dev     # development server
npm run build   # static export to out/
npm run lint
```

`npm run build` runs a `prebuild` step first: it copies `scripts/spaces-install-linux.sh` to `public/install.sh` and stages both Sparkle feeds from GitHub releases into `public/releases/` (see `scripts/stage-web-releases.sh`). The step needs network access and an authenticated `gh`.

`npm run dev` uses Turbopack and `npm run build` uses webpack, and both write `.next/`. After a build, delete `.next/` before starting the dev server, or it can serve stale CSS. To check the production output, serve `out/` with any static server.

## Where content lives

- Homepage: `app/page.tsx`, with shared copy such as the FAQ in `app/content.tsx`
- Docs pages: `app/docs/<topic>/page.tsx`; the docs index is `app/docs/page.tsx`
- Docs navigation and summaries: `app/docs/content.ts`
- Shared components: `app/components/` (site-wide) and `app/docs/components/` (docs)
- Colors and fonts: `app/globals.css`. Use its tokens rather than hard-coded values.

## Rules

- The site stays fully static: no server routes and no runtime data fetching. Use a client component only where a page needs interaction, such as a copy button.
- Copy is user-facing: describe what people can do, not how Spaces is built.

Deploys and previews run from GitHub Actions; see "Website" and "Website Deploy" in [`docs/dev.md`](../../docs/dev.md).
