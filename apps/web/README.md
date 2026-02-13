# Spaceship Web

Static marketing and docs website for Spaceship.

## Stack
- Next.js App Router
- TypeScript
- Tailwind CSS
- Static export via `next.config.ts` (`output: "export"`)

## Local development

```bash
npm run dev
```

## Build (static prerender)

```bash
npm run build
```

Output is written to `out/` for static hosting.

## Content map
- Homepage/marketing: `app/page.tsx`
- Docs: `app/docs/page.tsx`
- Shared styling: `app/globals.css`
- Shared navigation: `app/components/site-header.tsx`

## Notes
- Keep the site fully static.
- Prefer static/server-rendered content unless dynamic behavior is explicitly required.
