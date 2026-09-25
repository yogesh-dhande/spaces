import { describe, expect, it } from "vitest";
import {
  defaultPreviewMode,
  imageMediaType,
  jsonTreeDocument,
  modeShowsPreview,
  modeShowsSource,
  parseStrictJSON,
  previewKind,
  previewModeSegments,
  resolvePreviewMode,
} from "../src/app/previewMode";

function labels(kind: Parameters<typeof previewModeSegments>[0], treeAvailable = true): Array<[string, boolean]> {
  return previewModeSegments(kind, { treeAvailable }).map((segment) => [segment.label, segment.enabled]);
}

describe("previewKind", () => {
  it("classifies each previewable family by extension, case-insensitively", () => {
    expect(previewKind("docs/spec.md")).toBe("markdown");
    expect(previewKind("README.markdown")).toBe("markdown");
    expect(previewKind("package.json")).toBe("json");
    expect(previewKind("tsconfig.jsonc")).toBe("json");
    expect(previewKind("events.jsonl")).toBe("json");
    expect(previewKind("art/logo.SVG")).toBe("svg");
    expect(previewKind("data/rows.csv")).toBe("table");
    expect(previewKind("data/rows.tsv")).toBe("table");
    for (const path of ["a.png", "a.JPG", "a.jpeg", "a.gif", "a.webp", "a.bmp"]) {
      expect(previewKind(path)).toBe("image");
    }
  });

  it("leaves everything else a plain source file, including images the stage does not show", () => {
    expect(previewKind("src/app/root.ts")).toBe("text");
    expect(previewKind("Makefile")).toBe("text");
    expect(previewKind(".gitignore")).toBe("text");
    expect(previewKind("scan.tiff")).toBe("text");
    expect(previewKind("paper.pdf")).toBe("text");
  });
});

describe("imageMediaType", () => {
  it("names the media type each stage image is served as", () => {
    expect(imageMediaType("a.png")).toBe("image/png");
    expect(imageMediaType("a.jpg")).toBe("image/jpeg");
    expect(imageMediaType("a.JPEG")).toBe("image/jpeg");
    expect(imageMediaType("a.gif")).toBe("image/gif");
    expect(imageMediaType("a.webp")).toBe("image/webp");
    expect(imageMediaType("a.bmp")).toBe("image/bmp");
  });

  it("names nothing for a file the stage does not show", () => {
    expect(imageMediaType("a.svg")).toBeUndefined();
    expect(imageMediaType("a.ts")).toBeUndefined();
  });
});

describe("previewModeSegments", () => {
  it("offers each kind its own labels, in display order", () => {
    expect(labels("markdown")).toEqual([
      ["Split", true],
      ["Source", true],
      ["Preview", true],
    ]);
    expect(labels("json")).toEqual([
      ["Tree", true],
      ["Text", true],
    ]);
    expect(labels("svg")).toEqual([
      ["Preview", true],
      ["Source", true],
    ]);
    expect(labels("table")).toEqual([
      ["Table", true],
      ["Text", true],
    ]);
  });

  it("shows the JSON tree segment disabled rather than hidden when the file does not parse", () => {
    expect(labels("json", false)).toEqual([
      ["Tree", false],
      ["Text", true],
    ]);
  });

  it("offers no control at all for an image or a plain source file", () => {
    expect(labels("image")).toEqual([]);
    expect(labels("text")).toEqual([]);
  });
});

describe("defaultPreviewMode", () => {
  it("opens every kind on its rendered view", () => {
    expect(defaultPreviewMode("markdown", { treeAvailable: true })).toBe("split");
    expect(defaultPreviewMode("json", { treeAvailable: true })).toBe("tree");
    expect(defaultPreviewMode("svg", { treeAvailable: true })).toBe("preview");
    expect(defaultPreviewMode("table", { treeAvailable: true })).toBe("table");
  });

  it("opens JSON as text when its tree is unavailable", () => {
    expect(defaultPreviewMode("json", { treeAvailable: false })).toBe("text");
  });

  it("has no mode for a kind with no control", () => {
    expect(defaultPreviewMode("image", { treeAvailable: false })).toBeUndefined();
    expect(defaultPreviewMode("text", { treeAvailable: false })).toBeUndefined();
  });
});

describe("jsonTreeDocument", () => {
  it("returns the parsed document for a strict-JSON .json file", () => {
    expect(jsonTreeDocument("config/settings.json", '{"a": 1}')).toEqual({
      value: { kind: "object", entries: [{ key: "a", value: { kind: "number", lexeme: "1" } }], count: 1 },
    });
    expect(jsonTreeDocument("config/settings.json", "null")).toEqual({ value: { kind: "null" } });
    expect(jsonTreeDocument("config/settings.json", "[1, 2, 3]")).toBeDefined();
  });

  it("refuses a .json file that does not parse", () => {
    expect(jsonTreeDocument("config/settings.json", '{"a": 1,}')).toBeUndefined();
    expect(jsonTreeDocument("config/settings.json", "")).toBeUndefined();
    expect(jsonTreeDocument("config/settings.json", "{")).toBeUndefined();
    expect(jsonTreeDocument("config/settings.json", "{} {}")).toBeUndefined();
  });

  it("accepts numbers no JavaScript double can hold, keeping their source text", () => {
    const content = '{"big": 9007199254740993, "exact": 1.00}';
    const document = jsonTreeDocument("config/settings.json", content);

    expect(document).toEqual({
      value: {
        kind: "object",
        entries: [
          { key: "big", value: { kind: "number", lexeme: "9007199254740993" } },
          { key: "exact", value: { kind: "number", lexeme: "1.00" } },
        ],
        count: 2,
      },
    });
    expect(parseStrictJSON(content)).toEqual(document);
  });

  it("offers a tree for a .json file whose duplicate keys strict JSON.parse also accepts", () => {
    expect(jsonTreeDocument("config/settings.json", '{"a": 1, "a": 2}')).toEqual({
      value: { kind: "object", entries: [{ key: "a", value: { kind: "number", lexeme: "2" } }], count: 1 },
    });
  });

  it("refuses JSONC and JSONL by extension, even when the content happens to parse", () => {
    expect(jsonTreeDocument("tsconfig.jsonc", '{"a": 1}')).toBeUndefined();
    expect(jsonTreeDocument("events.jsonl", '{"a": 1}')).toBeUndefined();
  });

  it("refuses a .json file nested deeper than the parser's MAX_NESTING_DEPTH, the same as a file that does not parse", () => {
    const deeplyNested = "[".repeat(20_000) + "1" + "]".repeat(20_000);

    expect(parseStrictJSON(deeplyNested)).toBeUndefined();
    expect(jsonTreeDocument("config/settings.json", deeplyNested)).toBeUndefined();
  });
});

describe("resolvePreviewMode", () => {
  it("honors a mode the pane remembers for the file", () => {
    expect(resolvePreviewMode("markdown", "preview", { treeAvailable: false })).toBe("preview");
    expect(resolvePreviewMode("table", "text", { treeAvailable: false })).toBe("text");
  });

  it("falls to the default when the remembered mode is not a segment of this file's control", () => {
    expect(resolvePreviewMode("markdown", "tree", { treeAvailable: true })).toBe("split");
  });

  it("leaves the JSON tree when an edit makes the file stop parsing", () => {
    expect(resolvePreviewMode("json", "tree", { treeAvailable: true })).toBe("tree");
    expect(resolvePreviewMode("json", "tree", { treeAvailable: false })).toBe("text");
  });

  it("returns the default when the pane remembers nothing", () => {
    expect(resolvePreviewMode("svg", undefined, { treeAvailable: false })).toBe("preview");
    expect(resolvePreviewMode("text", undefined, { treeAvailable: false })).toBeUndefined();
  });
});

describe("modeShowsSource / modeShowsPreview", () => {
  it("shows both halves in Markdown's Split and one half in its other modes", () => {
    expect([modeShowsSource("markdown", "split"), modeShowsPreview("markdown", "split")]).toEqual([true, true]);
    expect([modeShowsSource("markdown", "source"), modeShowsPreview("markdown", "source")]).toEqual([true, false]);
    expect([modeShowsSource("markdown", "preview"), modeShowsPreview("markdown", "preview")]).toEqual([false, true]);
  });

  it("shows the source for every text mode and the rendered surface for every rendered mode", () => {
    expect([modeShowsSource("json", "text"), modeShowsPreview("json", "text")]).toEqual([true, false]);
    expect([modeShowsSource("json", "tree"), modeShowsPreview("json", "tree")]).toEqual([false, true]);
    expect([modeShowsSource("table", "table"), modeShowsPreview("table", "table")]).toEqual([false, true]);
    expect([modeShowsSource("svg", "preview"), modeShowsPreview("svg", "preview")]).toEqual([false, true]);
  });

  it("shows a plain file as source only and an image as its stage only", () => {
    expect([modeShowsSource("text", undefined), modeShowsPreview("text", undefined)]).toEqual([true, false]);
    expect([modeShowsSource("image", undefined), modeShowsPreview("image", undefined)]).toEqual([false, true]);
  });
});
