import { getFiletypeFromFileName, preloadHighlighter, registerCustomCSSVariableTheme, type SupportedLanguages } from "@pierre/diffs";

/**
 * Theme name registered with `@pierre/diffs`' shared Shiki highlighter. Its
 * colors resolve through CSS custom properties (`--diffs-*`, see
 * `styles/tokens.css`) rather than a baked palette, so syntax highlighting
 * follows the app's own light/dark tokens instead of shipping a second,
 * independent color scheme. See `docs/design.md` (read by this plugin's
 * author) for the app-wide token rules this mirrors.
 */
export const CODE_PANE_THEME_NAME = "spaces";

/**
 * The language set this bundle highlights, per Phase 3's scope: the
 * languages Spaces workspaces are expected to contain, plus a plaintext
 * fallback for everything else. Each id is a Shiki bundled-language id;
 * `getFiletypeFromFileName` (used internally by @pierre/diffs) maps common
 * extensions onto these automatically, so files do not need to declare
 * `lang` explicitly.
 */
const LANGUAGES: SupportedLanguages[] = [
  "typescript",
  "javascript",
  "tsx",
  "jsx",
  "swift",
  "python",
  "go",
  "rust",
  "c",
  "cpp",
  "objective-c",
  "json",
  "yaml",
  "toml",
  "html",
  "css",
  "markdown",
  "shellscript",
  "sql",
  "text",
];

const ALLOWED_LANGUAGES = new Set<SupportedLanguages>(LANGUAGES);

/**
 * Maps a file name to a highlighter language, but only from the bundle's
 * fixed language set above; anything else resolves to `"text"`.
 *
 * This is required, not cosmetic: `@pierre/diffs`'s render pipeline calls the
 * shared highlighter's `codeToHast` with whatever `getFiletypeFromFileName`
 * infers, and the highlighter only has the languages `preloadCodePaneHighlighter`
 * loaded above attached to it. A file whose extension maps to some other
 * Shiki language (e.g. `.rb`, `.php`) would make that call throw, and by
 * default `@pierre/diffs` catches that and renders a visible error box in the
 * pane rather than falling back to plain text. Every call site that builds a
 * `FileContents`/`FileDiffMetadata` for the highlighter must set `lang`
 * explicitly to this function's result instead of leaving it to
 * auto-detection, so out-of-set files render as plain text as intended.
 */
export function resolveAllowedLanguage(fileName: string): SupportedLanguages {
  const detected = getFiletypeFromFileName(fileName);
  return ALLOWED_LANGUAGES.has(detected) ? detected : "text";
}

let preloadPromise: Promise<void> | undefined;

/**
 * Registers the CSS-variables theme and preloads the shared highlighter with
 * the fixed language set above. Idempotent and safe to call from multiple
 * entry points (main.ts, tests); the underlying highlighter load only
 * happens once per page load.
 */
export function preloadCodePaneHighlighter(): Promise<void> {
  if (!preloadPromise) {
    // No variableDefaults: this theme's colors resolve through CSS custom
    // properties prefixed `--diffs-` (the prefix is hardcoded by
    // @pierre/diffs' formatCSSVariablePrefix, not something this call can
    // change), and styles/tokens.css defines every one of them directly,
    // for both light and dark.
    registerCustomCSSVariableTheme(CODE_PANE_THEME_NAME, {}, true);
    // @pierre/diffs references Shiki's full dynamic-import grammar/theme
    // registry, so Vite's build emits every Shiki grammar and theme as its
    // own lazy chunk into the dist output (this is why the checked-in dist
    // under Resources/CodePane carries roughly 320 assets / 11 MB of Shiki
    // chunks). The call below only ever requests the LANGUAGES allowlist
    // above, so none of those extra chunks are fetched at runtime — the
    // cost this imposes is app-bundle disk size only, not memory or
    // startup time. Accepted as v1 behavior: constraining Shiki to a
    // static grammar/theme registry, or build-time filtering the emitted
    // chunks, is disproportionate complexity right now. Revisit if bundle
    // size becomes a shipping concern.
    preloadPromise = preloadHighlighter({ themes: [CODE_PANE_THEME_NAME], langs: LANGUAGES });
  }
  return preloadPromise;
}
