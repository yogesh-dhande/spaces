import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { formatCSSVariablePrefix } from "@pierre/diffs";
import { createCssVariablesTheme } from "shiki";
import { describe, expect, it } from "vitest";

// Regression test for the bug fixed alongside this file: `theme/index.ts` registered a Shiki
// CSS-variables theme, but `styles/tokens.css` defined its colors under a `--shiki-*` prefix
// instead of the `--diffs-*` prefix `@pierre/diffs` actually hardcodes (see
// `formatCSSVariablePrefix` in `@pierre/diffs/dist/utils/formatCSSVariablePrefix.js`), so every
// rendered token's inline `color: var(--diffs-token-keyword)` resolved to nothing and diffs
// rendered flat/monochrome. This builds the theme exactly as `preloadCodePaneHighlighter` does
// and asserts tokens.css defines every variable name the theme actually emits, so a future prefix
// or naming drift between the two files fails a test instead of shipping invisible again.
//
// Read via Node's `node:fs`/`node:url`, not a Vite `?raw` import: this repo's vitest.config.ts
// sets `test.css: false`, which stubs out CSS module imports (including `?raw`/`?inline`
// variants) to an empty string — and the global `URL` in this file's jsdom test environment
// resolves a relative `new URL(path, import.meta.url)` against jsdom's own document location
// rather than the real module URL, so the path is built with `node:path` instead.
const TOKENS_CSS_PATH = resolve(dirname(fileURLToPath(import.meta.url)), "../src/styles/tokens.css");

/** Collects every `--diffs-*` variable name referenced from the theme's editor foreground/
 *  background and per-token foreground settings — the only parts of the theme @pierre/diffs
 *  actually applies as inline `color` styles when highlighting diff/editor content. This
 *  deliberately excludes the theme's `terminal.ansi*` color slots: `createCssVariablesTheme`
 *  always emits those regardless of caller options, but @pierre/diffs never renders ANSI-colored
 *  terminal output in this pane, so tokens.css intentionally does not define them. */
function collectRenderedThemeVariables(): Set<string> {
  const theme = createCssVariablesTheme({
    name: "spaces",
    variablePrefix: formatCSSVariablePrefix("global"),
    variableDefaults: {},
    fontStyle: false,
  });

  const varNames = new Set<string>();
  const extract = (value: string | undefined): void => {
    const match = value?.match(/^var\((--[a-z0-9-]+)\)$/);
    if (match) varNames.add(match[1]!);
  };

  extract(theme.colors?.["editor.foreground"]);
  extract(theme.colors?.["editor.background"]);
  for (const tokenColor of theme.tokenColors ?? []) {
    extract(tokenColor.settings?.foreground);
  }
  return varNames;
}

/** Plain-text scan for `--diffs-...:` custom property declarations. */
function collectDeclaredCssVariables(): Set<string> {
  const css = readFileSync(TOKENS_CSS_PATH, "utf8");
  const declared = new Set<string>();
  for (const match of css.matchAll(/(--diffs-[a-z0-9-]+)\s*:/g)) {
    declared.add(match[1]!);
  }
  return declared;
}

describe("tokens.css defines every --diffs-* variable @pierre/diffs' Shiki theme reads", () => {
  it("declares a value for each rendered theme variable", () => {
    const referenced = collectRenderedThemeVariables();
    const declared = collectDeclaredCssVariables();

    // Sanity check on the extraction itself: if this ever drops to 0, the regexes above stopped
    // matching shiki's actual output shape and the assertion below would pass vacuously.
    expect(referenced.size).toBeGreaterThan(0);

    const missing = [...referenced].filter((name) => !declared.has(name));
    expect(missing).toEqual([]);
  });
});
