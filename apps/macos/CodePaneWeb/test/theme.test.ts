import { getSharedHighlighter } from "@pierre/diffs";
import { describe, expect, it } from "vitest";
import { CODE_PANE_THEME_NAME, preloadCodePaneHighlighter } from "../src/theme";

// Regression test for the bug fixed alongside this file: Shiki's `normalizeTheme` replaces every
// non-hex theme color (every color in this all-`var(--diffs-*)` theme) with a sentinel hex like
// `#00000001` and records the reverse mapping in the resolved theme's `colorReplacements`. Shiki's
// own render paths swap sentinels back via `applyColorReplacements` before use, but @pierre/diffs'
// EDITOR tokenizer calls the shared highlighter's `setTheme(name)` directly and styles token spans
// from the raw `colorMap` it returns, with no such swap. A user editing a line in the built-in
// editor got that line's spans styled with `rgba(0,0,0,0.004)` (`#00000001`) and the text vanished.
// `preloadCodePaneHighlighter` wraps the shared highlighter's `setTheme` so its returned `colorMap`
// already has sentinels substituted back to their `var(--diffs-*)` originals, which is exactly the
// contract this test asserts on.
const SENTINEL_COLOR = /^#0{6}[0-9a-f]{2}$/i;

describe("preloadCodePaneHighlighter's setTheme wrap", () => {
  it("returns a colorMap with no Shiki sentinel colors, only the theme's real var(--diffs-*) colors", async () => {
    await preloadCodePaneHighlighter();
    const highlighter = await getSharedHighlighter({ themes: [CODE_PANE_THEME_NAME], langs: ["typescript"] });

    const { colorMap } = highlighter.setTheme(CODE_PANE_THEME_NAME);

    const sentinels = colorMap.filter((color) => SENTINEL_COLOR.test(color));
    expect(sentinels).toEqual([]);
    expect(colorMap.some((color) => color.startsWith("var(--diffs-"))).toBe(true);
  });

  it("stays sentinel-free across repeated setTheme calls", async () => {
    await preloadCodePaneHighlighter();
    const highlighter = await getSharedHighlighter({ themes: [CODE_PANE_THEME_NAME], langs: ["typescript"] });

    const first = highlighter.setTheme(CODE_PANE_THEME_NAME);
    const second = highlighter.setTheme(CODE_PANE_THEME_NAME);

    for (const { colorMap } of [first, second]) {
      expect(colorMap.filter((color) => SENTINEL_COLOR.test(color))).toEqual([]);
    }
  });
});
