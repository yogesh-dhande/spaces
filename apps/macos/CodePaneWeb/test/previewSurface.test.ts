import { describe, expect, it, vi } from "vitest";
import { jsonTreeDocument } from "../src/app/previewMode";
import { MAX_PREVIEW_SVG_CHARS, PreviewSurface, PreviewSurfaceCallbacks } from "../src/app/previewSurface";

function makeCallbacks(overrides: Partial<PreviewSurfaceCallbacks> = {}): PreviewSurfaceCallbacks {
  return {
    loadImage: vi.fn().mockResolvedValue("data:image/png;base64,AAA"),
    onOpenPath: vi.fn(),
    onImageSize: vi.fn(),
    onPreviewScrolled: vi.fn(),
    ...overrides,
  };
}

const MARKDOWN = "![shot](./img/shot.png)";

describe("PreviewSurface: document switching", () => {
  it("re-reads a Markdown document's images when another document was shown in between", async () => {
    const loadImage = vi.fn().mockResolvedValue("data:image/png;base64,AAA");
    const surface = new PreviewSurface(makeCallbacks({ loadImage }));

    surface.renderText("docs/a.md", "markdown", "preview", MARKDOWN, undefined);
    await vi.waitFor(() => expect(loadImage).toHaveBeenCalledTimes(1));

    // The Markdown preview is kept alive across this, only detached from the surface.
    surface.renderText("docs/b.json", "json", "tree", '{"a":1}', jsonTreeDocument("docs/b.json", '{"a":1}'));

    surface.renderText("docs/a.md", "markdown", "preview", MARKDOWN, undefined);
    await vi.waitFor(() => expect(loadImage).toHaveBeenCalledTimes(2));
    expect(loadImage).toHaveBeenLastCalledWith("docs/img/shot.png");
  });

  it("does the same when the document in between is an image, which has no text buffer of its own", async () => {
    const loadImage = vi.fn().mockResolvedValue("data:image/png;base64,AAA");
    const surface = new PreviewSurface(makeCallbacks({ loadImage }));

    surface.renderText("docs/a.md", "markdown", "preview", MARKDOWN, undefined);
    await vi.waitFor(() => expect(loadImage).toHaveBeenCalledTimes(1));

    surface.renderImage("docs/diagram.png", "data:image/png;base64,BBB");

    surface.renderText("docs/a.md", "markdown", "preview", MARKDOWN, undefined);
    await vi.waitFor(() => expect(loadImage).toHaveBeenCalledTimes(2));
  });

  it("keeps a document's loaded images across an edit of that same document", async () => {
    const loadImage = vi.fn().mockResolvedValue("data:image/png;base64,AAA");
    const surface = new PreviewSurface(makeCallbacks({ loadImage }));

    surface.renderText("docs/a.md", "markdown", "preview", MARKDOWN, undefined);
    await vi.waitFor(() => expect(loadImage).toHaveBeenCalledTimes(1));

    surface.renderText("docs/a.md", "markdown", "preview", `${MARKDOWN}\n\nand a typed line.`, undefined);
    await Promise.resolve();

    expect(loadImage).toHaveBeenCalledTimes(1);
    expect(surface.element.querySelector("img")?.getAttribute("src")).toBe("data:image/png;base64,AAA");
  });

  it("keeps them across hiding the preview half, which is what a mode switch to Source does", async () => {
    const loadImage = vi.fn().mockResolvedValue("data:image/png;base64,AAA");
    const surface = new PreviewSurface(makeCallbacks({ loadImage }));

    surface.renderText("docs/a.md", "markdown", "preview", MARKDOWN, undefined);
    await vi.waitFor(() => expect(loadImage).toHaveBeenCalledTimes(1));

    surface.renderText("docs/a.md", "markdown", "source", MARKDOWN, undefined);
    surface.renderText("docs/a.md", "markdown", "preview", MARKDOWN, undefined);
    await Promise.resolve();

    expect(loadImage).toHaveBeenCalledTimes(1);
  });
});

describe("PreviewSurface: SVG size bound", () => {
  const SMALL_SVG = "<svg></svg>";
  // Padded past MAX_PREVIEW_SVG_CHARS with a comment, which is valid SVG/XML and costs nothing to
  // render (the bound check runs on the raw source, before any markup is parsed).
  const OVER_BOUND_SVG = `<svg><!--${"a".repeat(MAX_PREVIEW_SVG_CHARS)}--></svg>`;

  it("renders an SVG under the bound as a data URL image", () => {
    const surface = new PreviewSurface(makeCallbacks());

    surface.renderText("docs/a.svg", "svg", "preview", SMALL_SVG, undefined);

    const img = surface.element.querySelector("img");
    expect(img?.getAttribute("src")).toMatch(/^data:image\/svg\+xml/);
  });

  it("renders a muted note and no image for an SVG over the bound", () => {
    const surface = new PreviewSurface(makeCallbacks());

    surface.renderText("docs/a.svg", "svg", "preview", OVER_BOUND_SVG, undefined);

    expect(surface.element.querySelector("img")).toBeNull();
    expect(surface.element.textContent).toContain(
      "SVG over 1,000,000 characters is not previewed. Source holds the file.",
    );
  });

  it("applies the bound on every render, so an edit that grows the source past it takes the image down", () => {
    const surface = new PreviewSurface(makeCallbacks());

    surface.renderText("docs/a.svg", "svg", "preview", SMALL_SVG, undefined);
    expect(surface.element.querySelector("img")).not.toBeNull();

    surface.renderText("docs/a.svg", "svg", "preview", OVER_BOUND_SVG, undefined);
    expect(surface.element.querySelector("img")).toBeNull();

    surface.renderText("docs/a.svg", "svg", "preview", SMALL_SVG, undefined);
    expect(surface.element.querySelector("img")).not.toBeNull();
  });
});

describe("PreviewSurface: disposal", () => {
  it("stops the Markdown preview's queued image reads", async () => {
    const pending: Array<(value: string | undefined) => void> = [];
    const loadImage = vi.fn(() => new Promise<string | undefined>((resolve) => pending.push(resolve)));
    const surface = new PreviewSurface(makeCallbacks({ loadImage }));
    const source = Array.from({ length: 6 }, (_, index) => `![shot ${index}](./img/shot-${index}.png)`).join("\n\n");

    surface.renderText("docs/a.md", "markdown", "preview", source, undefined);
    expect(loadImage).toHaveBeenCalledTimes(4); // four in flight, two queued behind them

    surface.dispose();
    while (pending.length > 0) {
      pending.shift()!("data:image/png;base64,AAA");
      await Promise.resolve();
    }

    expect(loadImage).toHaveBeenCalledTimes(4);
  });
});
