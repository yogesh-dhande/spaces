import { describe, expect, it, vi } from "vitest";
import { MarkdownPreview, MarkdownPreviewCallbacks, MAX_DOCUMENT_IMAGE_BYTES, MAX_PREVIEW_SOURCE_CHARS } from "../src/app/markdownPreview";

function makeCallbacks(overrides: Partial<MarkdownPreviewCallbacks> = {}): MarkdownPreviewCallbacks {
  return {
    loadImage: vi.fn().mockResolvedValue(undefined),
    onOpenPath: vi.fn(),
    ...overrides,
  };
}

/** Stamps a fixed `getBoundingClientRect()` result onto `el`, the way this file's scroll-sync
 *  tests give jsdom (which reports 0 for every real layout value) a rect to read. */
function stubRect(el: Element, rect: Partial<DOMRect>): void {
  Object.defineProperty(el, "getBoundingClientRect", { value: () => rect, configurable: true });
}

describe("MarkdownPreview: rendering", () => {
  it("renders headings, paragraphs, and lists as their corresponding elements", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    preview.render("docs/notes.md", "# Title\n\nSome text.\n\n- one\n- two\n");

    const body = preview.element.querySelector(".markdown-body")!;
    expect(body.querySelector("h1")?.textContent).toBe("Title");
    expect(body.querySelector("p")?.textContent).toBe("Some text.");
    expect(Array.from(body.querySelectorAll("li")).map((li) => li.textContent)).toEqual(["one", "two"]);
  });

  it("renders raw HTML in the source as text, not as markup (the html: false guarantee)", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    preview.render("docs/notes.md", "<strong>hi</strong>\n\n<script>window.x = 1</script>\n");

    const body = preview.element.querySelector(".markdown-body")!;
    expect(body.querySelector("strong")).toBeNull();
    expect(body.querySelector("script")).toBeNull();
    expect(body.textContent).toContain("<strong>hi</strong>");
    expect(body.textContent).toContain("<script>window.x = 1</script>");
  });
});

describe("MarkdownPreview: images", () => {
  it("resolves a relative image src against its file, loads it once, and applies the data URL", async () => {
    const loadImage = vi.fn().mockResolvedValue("data:image/png;base64,AAA");
    const preview = new MarkdownPreview(makeCallbacks({ loadImage }));

    preview.render("docs/notes.md", "![shot](./img/shot.png)");

    expect(loadImage).toHaveBeenCalledTimes(1);
    expect(loadImage).toHaveBeenCalledWith("docs/img/shot.png");
    await vi.waitFor(() => {
      expect(preview.element.querySelector("img")?.getAttribute("src")).toBe("data:image/png;base64,AAA");
    });
  });

  it("does not re-request an already-loaded image on a re-render, and applies its cached data URL immediately", async () => {
    const loadImage = vi.fn().mockResolvedValue("data:image/png;base64,AAA");
    const preview = new MarkdownPreview(makeCallbacks({ loadImage }));
    const source = "![shot](./img/shot.png)";

    preview.render("docs/notes.md", source);
    await vi.waitFor(() => expect(preview.element.querySelector("img")?.getAttribute("src")).toBe("data:image/png;base64,AAA"));

    preview.render("docs/notes.md", source + "\n"); // same file, buffer changed by a keystroke
    // Set inline while building the HTML this time, not via the async callback, so it's already
    // present with no waitFor needed.
    expect(preview.element.querySelector("img")?.getAttribute("src")).toBe("data:image/png;base64,AAA");
    expect(loadImage).toHaveBeenCalledTimes(1);
  });

  it("does not re-request an image whose load failed on a later render", async () => {
    const loadImage = vi.fn().mockResolvedValue(undefined);
    const preview = new MarkdownPreview(makeCallbacks({ loadImage }));
    const source = "![shot](./img/shot.png)";

    preview.render("docs/notes.md", source);
    await vi.waitFor(() => expect(loadImage).toHaveBeenCalledTimes(1));

    preview.render("docs/notes.md", source + "\n");
    expect(loadImage).toHaveBeenCalledTimes(1);
    expect(preview.element.querySelector("img")?.hasAttribute("src")).toBe(false);
  });

  it("shows a remote image's alt text instead of the image, leaving nothing the web view could fetch", () => {
    const loadImage = vi.fn().mockResolvedValue(undefined);
    const preview = new MarkdownPreview(makeCallbacks({ loadImage }));

    preview.render("docs/notes.md", "![Build status](https://example.com/badge.svg)");

    const body = preview.element.querySelector(".markdown-body")!;
    expect(body.querySelector("img")).toBeNull();
    expect(body.querySelector("[src]")).toBeNull();
    expect(body.querySelector(".markdown-image-alt")?.textContent).toBe("Build status");
    expect(loadImage).not.toHaveBeenCalled();
  });

  it("does the same for every other source that names nothing in the workspace", () => {
    const loadImage = vi.fn().mockResolvedValue(undefined);
    const preview = new MarkdownPreview(makeCallbacks({ loadImage }));

    preview.render(
      "docs/notes.md",
      ["![data url](data:image/png;base64,AAA)", "![protocol relative](//cdn.example.com/shot.png)", "![above root](../../secrets.png)"].join(
        "\n\n",
      ),
    );

    const body = preview.element.querySelector(".markdown-body")!;
    expect(body.querySelector("[src]")).toBeNull();
    expect([...body.querySelectorAll(".markdown-image-alt")].map((el) => el.textContent)).toEqual([
      "data url",
      "protocol relative",
      "above root",
    ]);
    expect(loadImage).not.toHaveBeenCalled();
  });

  it("escapes the alt text it renders rather than treating it as markup", () => {
    const preview = new MarkdownPreview(makeCallbacks());

    preview.render("docs/notes.md", "![<img src=x onerror=boom>](https://example.com/shot.png)");

    const body = preview.element.querySelector(".markdown-body")!;
    expect(body.querySelector("[src]")).toBeNull();
    expect(body.querySelector(".markdown-image-alt")?.textContent).toBe("<img src=x onerror=boom>");
  });
});

describe("MarkdownPreview: image load bounds", () => {
  /** A `loadImage` stub whose calls are resolved by hand, so a test can hold reads open and count
   *  how many the preview has outstanding at once. */
  function deferredLoader(): { loadImage: MarkdownPreviewCallbacks["loadImage"]; paths: string[]; resolveAll: () => Promise<void> } {
    const paths: string[] = [];
    const pending: Array<(value: string | undefined) => void> = [];
    const loadImage = vi.fn((path: string) => {
      paths.push(path);
      return new Promise<string | undefined>((resolve) => pending.push(resolve));
    });
    return {
      loadImage,
      paths,
      resolveAll: async () => {
        // One at a time, yielding between: a settled read only starts the next queued one once its
        // own `then` has run, which appends that next read's resolver here.
        while (pending.length > 0) {
          pending.shift()!("data:image/png;base64,AAA");
          await Promise.resolve();
        }
      },
    };
  }

  function documentCiting(count: number): string {
    return Array.from({ length: count }, (_, index) => `![shot ${index}](./img/shot-${index}.png)`).join("\n\n");
  }

  it("keeps at most four reads in flight, starting the rest in document order as they settle", async () => {
    const { loadImage, paths, resolveAll } = deferredLoader();
    const preview = new MarkdownPreview(makeCallbacks({ loadImage }));

    preview.render("docs/notes.md", documentCiting(10));

    expect(loadImage).toHaveBeenCalledTimes(4);
    expect(paths).toEqual(["docs/img/shot-0.png", "docs/img/shot-1.png", "docs/img/shot-2.png", "docs/img/shot-3.png"]);

    await resolveAll();
    await vi.waitFor(() => expect(loadImage).toHaveBeenCalledTimes(10));
    expect(paths).toEqual(Array.from({ length: 10 }, (_, index) => `docs/img/shot-${index}.png`));
    await vi.waitFor(() => {
      const images = [...preview.element.querySelectorAll("img")];
      expect(images).toHaveLength(10);
      expect(images.every((img) => img.getAttribute("src") === "data:image/png;base64,AAA")).toBe(true);
    });
  });

  it("resolves the first 200 distinct images in a document and shows the rest as alt text", async () => {
    const loadImage = vi.fn().mockResolvedValue("data:image/png;base64,AAA");
    const preview = new MarkdownPreview(makeCallbacks({ loadImage }));

    preview.render("docs/notes.md", documentCiting(250));

    await vi.waitFor(() => expect(loadImage).toHaveBeenCalledTimes(200));
    const body = preview.element.querySelector(".markdown-body")!;
    expect(body.querySelectorAll("img")).toHaveLength(200);
    const alts = [...body.querySelectorAll(".markdown-image-alt")];
    expect(alts).toHaveLength(50);
    expect(alts[0]?.textContent).toBe("shot 200");
    expect(loadImage).not.toHaveBeenCalledWith("docs/img/shot-200.png");
  });

  /**
   * A `data:` URL whose `.length` reports `byteLength` (which is what the byte budget adds up)
   * while its real character content stays a tiny, valid data URL: `toString`/`valueOf` (what the
   * `src` assignment and markdown-it's own `escapeHtml` coerce through) and `replace` (what
   * `escapeHtml` calls directly) all delegate to that short real string. This exercises the budget
   * arithmetic at realistic (megabyte) sizes without actually allocating and re-embedding tens of
   * megabytes of text across renders, which is expensive enough in jsdom to exhaust the test
   * worker's heap.
   */
  function fakeDataUrl(byteLength: number): string {
    const real = "data:image/png;base64,AAA";
    return {
      length: byteLength,
      toString: () => real,
      valueOf: () => real,
      replace: (...args: Parameters<typeof real.replace>) => real.replace(...args),
    } as unknown as string;
  }

  it("discards a read that settles over the byte budget, renders its alt text, and drops the rest of the document's queued images unfetched", async () => {
    // Manual settlement, one image at a time, so the test controls exactly which read crosses the
    // budget and can inspect queue state around it (deferredLoader's resolveAll always uses the
    // same tiny fixed size and settles everything, which can't exercise either).
    const paths: string[] = [];
    const pending: Array<(value: string | undefined) => void> = [];
    const loadImage = vi.fn((path: string) => {
      paths.push(path);
      return new Promise<string | undefined>((resolve) => pending.push(resolve));
    });
    const preview = new MarkdownPreview(makeCallbacks({ loadImage }));

    // Four images dispatch immediately (the concurrency cap). Re-rendering with three more added
    // queues them behind the four already in flight, none of which has settled yet.
    preview.render("docs/notes.md", documentCiting(4));
    expect(loadImage).toHaveBeenCalledTimes(4);
    preview.render("docs/notes.md", documentCiting(7));
    expect(loadImage).toHaveBeenCalledTimes(4); // shot-4/5/6 are queued, not yet fetched

    const small = Math.ceil(MAX_DOCUMENT_IMAGE_BYTES * 0.3);
    const over = Math.ceil(MAX_DOCUMENT_IMAGE_BYTES * 0.5); // 0.3 + 0.3 + 0.5 crosses the budget

    pending[0]!(fakeDataUrl(small)); // shot-0 settles under budget
    await Promise.resolve();
    expect(loadImage).toHaveBeenCalledTimes(5); // the freed slot pulled shot-4 off the queue

    pending[1]!(fakeDataUrl(small)); // shot-1 settles under budget
    await Promise.resolve();
    expect(loadImage).toHaveBeenCalledTimes(6); // the freed slot pulled shot-5 off the queue

    pending[2]!(fakeDataUrl(over)); // shot-2 settles over budget
    await Promise.resolve();

    const body = preview.element.querySelector(".markdown-body")!;
    const alts = () => [...body.querySelectorAll(".markdown-image-alt")].map((el) => el.textContent);
    // shot-0 and shot-1 rendered as images; shot-3/4/5 are still in flight (an <img> with no src
    // yet), so this checks only the ones that already resolved with a src.
    expect([...body.querySelectorAll("img[src]")].map((img) => img.getAttribute("src"))).toEqual([
      "data:image/png;base64,AAA",
      "data:image/png;base64,AAA",
    ]);
    // shot-2 crossed the budget; shot-6 was still queued when it closed and is dropped unfetched.
    expect(alts()).toEqual(["shot 2", "shot 6"]);
    expect(loadImage).toHaveBeenCalledTimes(6);
    expect(paths).not.toContain("docs/img/shot-6.png");

    // shot-3, shot-4, and shot-5 were already dispatched (in flight) when the budget closed. They
    // are refused too once they settle, regardless of their own tiny size, since the document's
    // budget is closed rather than re-opened by a read that happens to fit.
    pending[3]!(fakeDataUrl(1));
    pending[4]!(fakeDataUrl(1));
    pending[5]!(fakeDataUrl(1));
    await Promise.resolve();
    expect(alts()).toEqual(["shot 2", "shot 3", "shot 4", "shot 5", "shot 6"]);
    expect(body.querySelectorAll("img")).toHaveLength(2); // already-rendered images are never evicted
    expect(loadImage).toHaveBeenCalledTimes(6); // no read past the queue-drop is ever fetched
  });

  it("refuses admission once a settled read has already exhausted the byte budget", async () => {
    const overBudget = fakeDataUrl(MAX_DOCUMENT_IMAGE_BYTES + 1);
    const loadImage = vi.fn().mockResolvedValueOnce(overBudget);
    const preview = new MarkdownPreview(makeCallbacks({ loadImage }));

    preview.render("docs/notes.md", "![one](./img/one.png)");
    await vi.waitFor(() => expect(preview.element.querySelector(".markdown-image-alt")?.textContent).toBe("one"));

    // "one" alone already crossed the budget and closed it; "two" must render as alt text
    // immediately and never be fetched, exactly like an image past the 200-count cap.
    preview.render("docs/notes.md", "![one](./img/one.png)\n\n![two](./img/two.png)");

    const body = preview.element.querySelector(".markdown-body")!;
    expect(body.querySelectorAll("img")).toHaveLength(0);
    expect([...body.querySelectorAll(".markdown-image-alt")].map((el) => el.textContent)).toEqual(["one", "two"]);
    expect(loadImage).toHaveBeenCalledTimes(1);
    expect(loadImage).not.toHaveBeenCalledWith("docs/img/two.png");
  });

  it("resets the byte budget and the exhausted flag on beginDocument, the same as the count cap", async () => {
    const overBudget = fakeDataUrl(MAX_DOCUMENT_IMAGE_BYTES + 1);
    const small = "data:image/png;base64,AAA";
    const loadImage = vi.fn().mockResolvedValueOnce(overBudget).mockResolvedValueOnce(small);
    const preview = new MarkdownPreview(makeCallbacks({ loadImage }));

    preview.render("docs/notes.md", "![one](./img/one.png)");
    await vi.waitFor(() => expect(loadImage).toHaveBeenCalledTimes(1));
    await vi.waitFor(() => expect(preview.element.querySelector(".markdown-image-alt")?.textContent).toBe("one"));

    preview.render("docs/notes.md", "![one](./img/one.png)\n\n![two](./img/two.png)");
    await Promise.resolve();
    // "one" alone already exhausted the budget, so "two" is refused at admission and never fetched.
    expect(loadImage).toHaveBeenCalledTimes(1);

    preview.beginDocument("docs/other.md");
    preview.render("docs/other.md", "![three](./img/three.png)");

    // A fresh document's budget is open again: "three" is fetched and, being far under the cap on
    // its own, renders as an image rather than being refused by a flag left over from "one".
    await vi.waitFor(() => expect(loadImage).toHaveBeenCalledTimes(2));
    expect(loadImage).toHaveBeenLastCalledWith("docs/img/three.png");
    await vi.waitFor(() => expect(preview.element.querySelector("img")?.getAttribute("src")).toBe(small));
  });

  it("discards the cache when a different file is opened, so reopening the first one reads again", async () => {
    const loadImage = vi.fn().mockResolvedValue("data:image/png;base64,AAA");
    const preview = new MarkdownPreview(makeCallbacks({ loadImage }));
    const source = "![shot](./img/shot.png)";

    preview.render("docs/notes.md", source);
    await vi.waitFor(() => expect(loadImage).toHaveBeenCalledTimes(1));

    preview.render("docs/other.md", source);
    await vi.waitFor(() => expect(loadImage).toHaveBeenCalledTimes(2));
    expect(loadImage).toHaveBeenLastCalledWith("docs/img/shot.png");

    preview.render("docs/notes.md", source);
    await vi.waitFor(() => expect(loadImage).toHaveBeenCalledTimes(3));
  });

  it("drops the rendered images when another document takes the surface without ever calling render for it", async () => {
    // PreviewSurface.noteDocument calls beginDocument() directly for a document of another kind
    // (JSON, a table, an SVG, an image): it never calls render() for that document, since a
    // different renderer owns its surface. Without beginDocument also clearing the rendered body,
    // the previous document's <img src="data:..."> nodes, and the bytes they hold, would stay
    // reachable through this instance for as long as it stays open.
    const loadImage = vi.fn().mockResolvedValue("data:image/png;base64,AAA");
    const preview = new MarkdownPreview(makeCallbacks({ loadImage }));

    preview.render("docs/notes.md", "![shot](./img/shot.png)");
    await vi.waitFor(() => expect(preview.element.querySelector("img")).not.toBeNull());

    preview.beginDocument("docs/data.json");

    expect(preview.element.querySelectorAll("img")).toHaveLength(0);
  });

  it("stops reading queued images once the preview is disposed", async () => {
    const { loadImage, resolveAll } = deferredLoader();
    const preview = new MarkdownPreview(makeCallbacks({ loadImage }));

    preview.render("docs/notes.md", documentCiting(6));
    expect(loadImage).toHaveBeenCalledTimes(4); // four in flight, two queued behind them

    preview.dispose();
    await resolveAll();
    await Promise.resolve();

    expect(loadImage).toHaveBeenCalledTimes(4);
  });

  it("keeps the cache across a clear, which is how the Editor hides the preview half", async () => {
    const loadImage = vi.fn().mockResolvedValue("data:image/png;base64,AAA");
    const preview = new MarkdownPreview(makeCallbacks({ loadImage }));
    const source = "![shot](./img/shot.png)";

    preview.render("docs/notes.md", source);
    await vi.waitFor(() => expect(preview.element.querySelector("img")?.getAttribute("src")).toBe("data:image/png;base64,AAA"));

    preview.clear();
    preview.render("docs/notes.md", source);

    expect(loadImage).toHaveBeenCalledTimes(1);
    expect(preview.element.querySelector("img")?.getAttribute("src")).toBe("data:image/png;base64,AAA");
  });
});

describe("MarkdownPreview: image pixel bounds", () => {
  /** Stamps a fake decoded natural size onto `img` and fires its `load` event, the way
   *  `renderImageStage`'s own tests fake a decode result: jsdom never actually decodes a `data:`
   *  URL, so `naturalWidth`/`naturalHeight` stay 0, and no `load` event fires on its own, unless a
   *  test drives both by hand. */
  function settleWithNaturalSize(img: HTMLImageElement, width: number, height: number): void {
    Object.defineProperty(img, "naturalWidth", { value: width, configurable: true });
    Object.defineProperty(img, "naturalHeight", { value: height, configurable: true });
    img.dispatchEvent(new Event("load"));
  }

  it("demotes an image whose decoded size alone exceeds the pixel budget, even though its data URL is tiny", async () => {
    const loadImage = vi.fn().mockResolvedValue("data:image/png;base64,AAA");
    const preview = new MarkdownPreview(makeCallbacks({ loadImage }));

    preview.render("docs/notes.md", "![huge](./img/huge.png)");
    await vi.waitFor(() => expect(preview.element.querySelector("img")).not.toBeNull());

    const img = preview.element.querySelector<HTMLImageElement>("img")!;
    settleWithNaturalSize(img, 9000, 9000); // 81 megapixels, over MAX_DOCUMENT_IMAGE_PIXELS alone

    const body = preview.element.querySelector(".markdown-body")!;
    expect(body.querySelector("img")).toBeNull();
    expect(body.querySelector(".markdown-image-alt")?.textContent).toBe("huge");
  });

  it("keeps the first of two images whose combined decoded size crosses the pixel budget and demotes the second", async () => {
    const loadImage = vi.fn().mockResolvedValue("data:image/png;base64,AAA");
    const preview = new MarkdownPreview(makeCallbacks({ loadImage }));

    preview.render("docs/notes.md", "![one](./img/one.png)\n\n![two](./img/two.png)");
    await vi.waitFor(() => expect(preview.element.querySelectorAll("img")).toHaveLength(2));

    const [imgOne, imgTwo] = [...preview.element.querySelectorAll<HTMLImageElement>("img")];
    settleWithNaturalSize(imgOne!, 6000, 6000); // 36 megapixels, under the budget on its own
    settleWithNaturalSize(imgTwo!, 6000, 6000); // another 36 MP, 72 MP total, over the 64 MP budget

    const body = preview.element.querySelector(".markdown-body")!;
    expect([...body.querySelectorAll("img")].map((el) => el.getAttribute("alt"))).toEqual(["one"]);
    expect(body.querySelector(".markdown-image-alt")?.textContent).toBe("two");
  });

  it("resets the pixel budget and the exhausted flag on beginDocument, the same as the byte budget", async () => {
    const loadImage = vi.fn().mockResolvedValue("data:image/png;base64,AAA");
    const preview = new MarkdownPreview(makeCallbacks({ loadImage }));

    preview.render("docs/notes.md", "![huge](./img/huge.png)");
    await vi.waitFor(() => expect(preview.element.querySelector("img")).not.toBeNull());
    settleWithNaturalSize(preview.element.querySelector<HTMLImageElement>("img")!, 9000, 9000);
    expect(preview.element.querySelector(".markdown-image-alt")?.textContent).toBe("huge");

    preview.beginDocument("docs/other.md");
    preview.render("docs/other.md", "![small](./img/small.png)");

    // A fresh document's pixel budget is open again: "small" is fetched and, being far under the
    // cap on its own, renders as an image rather than being refused by a flag left over from "huge".
    await vi.waitFor(() => expect(preview.element.querySelector("img")).not.toBeNull());
    const secondImg = preview.element.querySelector<HTMLImageElement>("img")!;
    settleWithNaturalSize(secondImg, 100, 100);
    expect(preview.element.querySelector(".markdown-image-alt")).toBeNull();
    expect(secondImg.getAttribute("src")).toBe("data:image/png;base64,AAA");
  });

  it("charges the pixel budget for a read that settles while the preview is hidden, once it is shown again", async () => {
    let resolveLoad!: (value: string | undefined) => void;
    const loadImage = vi.fn(() => new Promise<string | undefined>((resolve) => (resolveLoad = resolve)));
    const preview = new MarkdownPreview(makeCallbacks({ loadImage }));

    preview.render("docs/notes.md", "![huge](./img/huge.png)");
    await vi.waitFor(() => expect(loadImage).toHaveBeenCalledTimes(1));

    // The user switches to Source before the read settles: the preview's DOM is cleared, so
    // `settleImageLoad` finds no <img> to attach its pixel-settling listener to.
    preview.clear();
    resolveLoad("data:image/png;base64,AAA");
    await Promise.resolve(); // flushes settleImageLoad's `.then`, run with the preview still hidden

    // Back to Preview: the cached data URL renders immediately, with no second read.
    preview.render("docs/notes.md", "![huge](./img/huge.png)");
    expect(loadImage).toHaveBeenCalledTimes(1);
    const img = preview.element.querySelector<HTMLImageElement>("img")!;
    expect(img.getAttribute("src")).toBe("data:image/png;base64,AAA");

    // The pixel budget is still charged on this first real render: a 9000x9000 decode is demoted
    // exactly as it would be had the read settled with the preview showing all along.
    settleWithNaturalSize(img, 9000, 9000); // 81 megapixels, over MAX_DOCUMENT_IMAGE_PIXELS alone

    const body = preview.element.querySelector(".markdown-body")!;
    expect(body.querySelector("img")).toBeNull();
    expect(body.querySelector(".markdown-image-alt")?.textContent).toBe("huge");
  });

  it("charges a hidden-settled entry's pixels exactly once across renders, proven by a later image's admit decision", async () => {
    let resolveOne!: (value: string | undefined) => void;
    const loadImage = vi.fn((path: string) =>
      path === "docs/img/one.png"
        ? new Promise<string | undefined>((resolve) => (resolveOne = resolve))
        : Promise.resolve("data:image/png;base64,BBB"),
    );
    const preview = new MarkdownPreview(makeCallbacks({ loadImage }));

    preview.render("docs/notes.md", "![one](./img/one.png)");
    await vi.waitFor(() => expect(loadImage).toHaveBeenCalledTimes(1));

    // Settles hidden, exactly as the previous test: cached, but not yet charged.
    preview.clear();
    resolveOne("data:image/png;base64,AAA");
    await Promise.resolve();

    // Shown again: this render's <img> is charged for the first time.
    preview.render("docs/notes.md", "![one](./img/one.png)");
    settleWithNaturalSize(preview.element.querySelector<HTMLImageElement>("img")!, 6000, 6000); // 36 MP
    expect(preview.element.querySelector(".markdown-image-alt")).toBeNull(); // 36 MP alone is under budget

    // A further re-render finds the entry already charged, so it attaches no second listener; firing
    // `load` again on the fresh element that render builds is therefore a no-op either way.
    preview.render("docs/notes.md", "![one](./img/one.png)");
    settleWithNaturalSize(preview.element.querySelector<HTMLImageElement>("img")!, 6000, 6000);
    expect(preview.element.querySelector(".markdown-image-alt")).toBeNull();

    // The decisive proof: were "one" charged twice (72 MP, over the 64 MP budget), that second charge
    // would have closed the document's pixel budget right there, and a distinct second 6000x6000
    // image would be refused at admission, rendering straight to alt text with no read ever
    // dispatched. Charged once (36 MP), the budget is still open, so "two" is admitted: it renders as
    // an <img> and its read is requested, even though its own eventual settle (72 MP total) will
    // demote it in turn.
    preview.render("docs/notes.md", "![one](./img/one.png)\n\n![two](./img/two.png)");
    expect(preview.element.querySelector<HTMLImageElement>('img[alt="two"]')).not.toBeNull();
    expect(loadImage).toHaveBeenCalledWith("docs/img/two.png");
  });

  it("charges a path cited three times in one document once, not once per copy, so a later image is still admitted", async () => {
    const loadImage = vi.fn((path: string) =>
      Promise.resolve(path === "docs/img/one.png" ? "data:image/png;base64,AAA" : "data:image/png;base64,BBB"),
    );
    const preview = new MarkdownPreview(makeCallbacks({ loadImage }));

    preview.render("docs/notes.md", "![one](./img/one.png)\n\n![one](./img/one.png)\n\n![one](./img/one.png)");
    await vi.waitFor(() => expect(preview.element.querySelectorAll("img")).toHaveLength(3));
    expect(loadImage).toHaveBeenCalledTimes(1); // one distinct path, one read, however many times it's cited

    // Each citation is its own <img> element sharing the one cached data URL, and each decodes (and
    // fires its own `load`) independently.
    const copies = [...preview.element.querySelectorAll<HTMLImageElement>("img")];
    for (const copy of copies) settleWithNaturalSize(copy, 5000, 5000); // 25 megapixels each

    // All three copies stayed images: charged once (25 MP), nowhere near the 64 MP budget. Charged
    // once per copy (75 MP between them) would have demoted the path on the third settle instead.
    const body = preview.element.querySelector(".markdown-body")!;
    expect(body.querySelectorAll("img")).toHaveLength(3);
    expect(body.querySelector(".markdown-image-alt")).toBeNull();

    // Decisive proof it was one charge: a distinct 30 MP image brings the document to 55 MP (25 + 30),
    // under budget, so it is admitted and its own read is requested. Had the repeats charged 75 MP
    // between them, the budget would already be exhausted and this image would render straight to alt
    // text with no read dispatched at all.
    preview.render(
      "docs/notes.md",
      "![one](./img/one.png)\n\n![one](./img/one.png)\n\n![one](./img/one.png)\n\n![two](./img/two.png)",
    );
    await vi.waitFor(() => expect(loadImage).toHaveBeenCalledWith("docs/img/two.png"));
    expect(preview.element.querySelector<HTMLImageElement>('img[alt="two"]')).not.toBeNull();
  });

  it("charges once when a rerender leaves an earlier, still-decoding copy's listener alongside a new one", async () => {
    const loadImage = vi.fn().mockResolvedValue("data:image/png;base64,AAA");
    const preview = new MarkdownPreview(makeCallbacks({ loadImage }));

    preview.render("docs/notes.md", "![one](./img/one.png)");
    await vi.waitFor(() => expect(preview.element.querySelector("img")).not.toBeNull());
    const firstImg = preview.element.querySelector<HTMLImageElement>("img")!;
    expect(firstImg.getAttribute("src")).toBe("data:image/png;base64,AAA"); // the read has already settled

    // A keystroke rerenders the document before `firstImg` fires its own `load` (its decode is still
    // in flight): a fresh <img> for the same, already-cached path takes its place in the DOM, and
    // `attachPendingImages` gives that new element its own pixel-settling listener, since the cache
    // entry isn't charged yet.
    preview.render("docs/notes.md", "![one](./img/one.png)");
    const secondImg = preview.element.querySelector<HTMLImageElement>("img")!;
    expect(secondImg).not.toBe(firstImg);

    // Both elements' decodes finish: the orphaned first element fires its `load` late, then the
    // element actually on screen does too.
    settleWithNaturalSize(firstImg, 6000, 6000); // 36 megapixels
    settleWithNaturalSize(secondImg, 6000, 6000);

    // Charged twice (72 MP) would already exceed the 64 MP budget and demote "one" on the spot; charged
    // once (36 MP), it is still an image.
    expect(preview.element.querySelector("img")).not.toBeNull();
    expect(preview.element.querySelector(".markdown-image-alt")).toBeNull();

    // Decisive proof, the same shape as the repeated-path test above: a further image is still
    // admitted, which a second 36 MP charge (72 MP total, over budget) would have refused outright.
    preview.render("docs/notes.md", "![one](./img/one.png)\n\n![two](./img/two.png)");
    await vi.waitFor(() => expect(loadImage).toHaveBeenCalledWith("docs/img/two.png"));
    expect(preview.element.querySelector<HTMLImageElement>('img[alt="two"]')).not.toBeNull();
  });
});

describe("MarkdownPreview: links", () => {
  it("renders every link without an href, so nothing the web view follows on its own is left behind", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    preview.render("docs/notes.md", "[sibling](./other.md) [site](https://example.com) [top](#intro) <https://auto.example.com>");

    const anchors = [...preview.element.querySelectorAll("a")];
    expect(anchors).toHaveLength(4);
    expect(anchors.every((anchor) => !anchor.hasAttribute("href"))).toBe(true);
    expect(preview.element.querySelector("[href]")).toBeNull();
  });

  it("resolves a relative link, prevents default, and calls onOpenPath with the resolved path", () => {
    const onOpenPath = vi.fn();
    const preview = new MarkdownPreview(makeCallbacks({ onOpenPath }));
    preview.render("docs/notes.md", "[sibling](./other.md)");

    const anchor = preview.element.querySelector("a")!;
    expect(anchor.dataset.link).toBe("docs/other.md");
    const event = new MouseEvent("click", { bubbles: true, cancelable: true });
    anchor.dispatchEvent(event);

    expect(onOpenPath).toHaveBeenCalledWith("docs/other.md");
    expect(event.defaultPrevented).toBe(true);
  });

  it("opens a workspace link from the keyboard, since it is a tab stop with a link role", () => {
    const onOpenPath = vi.fn();
    const preview = new MarkdownPreview(makeCallbacks({ onOpenPath }));
    preview.render("docs/notes.md", "[sibling](./other.md)");

    const anchor = preview.element.querySelector("a")!;
    expect(anchor.getAttribute("role")).toBe("link");
    expect(anchor.getAttribute("tabindex")).toBe("0");
    const event = new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true });
    anchor.dispatchEvent(event);

    expect(onOpenPath).toHaveBeenCalledWith("docs/other.md");
    expect(event.defaultPrevented).toBe(true);
  });

  it("does nothing at all for a link pointing outside the workspace", () => {
    const onOpenPath = vi.fn();
    const preview = new MarkdownPreview(makeCallbacks({ onOpenPath }));
    preview.render("docs/notes.md", "[site](https://example.com)");

    const anchor = preview.element.querySelector("a")!;
    expect(anchor.hasAttribute("href")).toBe(false);
    // Nothing to act on, so it is not a tab stop either.
    expect(anchor.hasAttribute("data-link")).toBe(false);
    expect(anchor.hasAttribute("tabindex")).toBe(false);
    anchor.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    anchor.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    expect(onOpenPath).not.toHaveBeenCalled();
  });

  it("leaves a middle click on a workspace link with nothing to navigate", () => {
    const onOpenPath = vi.fn();
    const preview = new MarkdownPreview(makeCallbacks({ onOpenPath }));
    preview.render("docs/notes.md", "[sibling](./other.md)");

    const anchor = preview.element.querySelector("a")!;
    anchor.dispatchEvent(new MouseEvent("auxclick", { button: 1, bubbles: true, cancelable: true }));

    // No href for the web view to open in its own way, and an auxiliary click is not the preview's
    // own activation either, so the pane stays exactly where it is.
    expect(anchor.hasAttribute("href")).toBe(false);
    expect(onOpenPath).not.toHaveBeenCalled();
  });

  it("scrolls a table-of-contents link to the heading it names", () => {
    const onOpenPath = vi.fn();
    const preview = new MarkdownPreview(makeCallbacks({ onOpenPath }));
    // The link is written before the heading it names, which is where a table of contents sits.
    preview.render("docs/notes.md", "[Getting started](#getting-started)\n\n## Getting started!\n\nBody.\n");

    const heading = preview.element.querySelector("h2")!;
    expect(heading.id).toBe("getting-started");
    heading.scrollIntoView = vi.fn();

    const anchor = preview.element.querySelector("a")!;
    expect(anchor.dataset.link).toBe("#getting-started");
    expect(anchor.getAttribute("role")).toBe("link");
    anchor.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));

    expect(heading.scrollIntoView).toHaveBeenCalled();
    expect(onOpenPath).not.toHaveBeenCalled();
  });

  it("matches a percent-encoded fragment against the heading it names", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    preview.render("docs/notes.md", "[Café](#café)\n\n# Café\n");

    const heading = preview.element.querySelector("h1")!;
    expect(heading.id).toBe("café");
    heading.scrollIntoView = vi.fn();

    // markdown-it percent-encodes what it writes into an href, so the fragment reaching the link
    // rule is `#caf%C3%A9`; it still has to resolve to the heading a reader wrote it for.
    const anchor = preview.element.querySelector("a")!;
    anchor.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));

    expect(heading.scrollIntoView).toHaveBeenCalled();
  });

  it("gives two headings of the same text distinct ids, and links resolve to each", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    preview.render("docs/notes.md", "[first](#notes) [second](#notes-1)\n\n## Notes\n\ntext\n\n## Notes\n\nmore\n");

    const headings = [...preview.element.querySelectorAll("h2")];
    expect(headings.map((heading) => heading.id)).toEqual(["notes", "notes-1"]);

    const anchors = [...preview.element.querySelectorAll("a")];
    expect(anchors.map((anchor) => anchor.dataset.link)).toEqual(["#notes", "#notes-1"]);
    headings[1]!.scrollIntoView = vi.fn();
    anchors[1]!.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));

    expect(headings[1]!.scrollIntoView).toHaveBeenCalled();
  });

  it("leaves a fragment naming no heading inert, so it is neither actionable nor focusable", () => {
    const onOpenPath = vi.fn();
    const preview = new MarkdownPreview(makeCallbacks({ onOpenPath }));
    preview.render("docs/notes.md", "[missing](#nowhere) [bare](#)\n\n# Intro\n");

    const anchors = [...preview.element.querySelectorAll("a")];
    expect(anchors.map((anchor) => anchor.textContent)).toEqual(["missing", "bare"]);
    for (const anchor of anchors) {
      expect(anchor.hasAttribute("data-link")).toBe(false);
      expect(anchor.hasAttribute("href")).toBe(false);
      expect(anchor.hasAttribute("tabindex")).toBe(false);
      anchor.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
      anchor.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    }

    expect(onOpenPath).not.toHaveBeenCalled();
  });

  it("drops a heading id that no longer exists once the document is retyped without it", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    preview.render("docs/notes.md", "[top](#intro)\n\n# Intro\n");
    expect(preview.element.querySelector("a")!.dataset.link).toBe("#intro");

    preview.render("docs/notes.md", "[top](#intro)\n\n# Summary\n");

    expect(preview.element.querySelector("a")!.hasAttribute("data-link")).toBe(false);
  });
});

describe("MarkdownPreview: source-line attribution", () => {
  it("stamps data-source-line on top-level blocks, matching their source line", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    preview.render("docs/notes.md", "Intro paragraph.\n\n# Heading\n\nMore text.\n");

    const blocks = Array.from(preview.element.querySelectorAll<HTMLElement>("[data-source-line]"));
    expect(blocks.map((el) => el.tagName.toLowerCase())).toEqual(["p", "h1", "p"]);
    expect(blocks.map((el) => el.dataset.sourceLine)).toEqual(["1", "3", "5"]);
  });

  it("does not attribute nested content, only top-level blocks", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    preview.render("docs/notes.md", "> quoted line\n> second line\n\nAfter.\n");

    const blocks = Array.from(preview.element.querySelectorAll<HTMLElement>("[data-source-line]"));
    // One anchor for the whole blockquote, not one for the paragraph nested inside it.
    expect(blocks.map((el) => el.tagName.toLowerCase())).toEqual(["blockquote", "p"]);
    expect(blocks.map((el) => el.dataset.sourceLine)).toEqual(["1", "4"]);
  });

  it("stamps data-source-line on a fenced code block and an indented code block, not just paragraphs", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    // fence and code_block render through their own renderer rules, bypassing the shared
    // renderToken override the other block kinds go through.
    preview.render("docs/notes.md", ["Intro.", "", "```js", "const a = 1;", "```", "", "    indented code", "", "After."].join("\n"));

    const blocks = Array.from(preview.element.querySelectorAll<HTMLElement>("[data-source-line]"));
    expect(blocks.map((el) => el.tagName.toLowerCase())).toEqual(["p", "pre", "pre", "p"]);
    expect(blocks.map((el) => el.dataset.sourceLine)).toEqual(["1", "3", "7", "9"]);
  });
});

describe("MarkdownPreview: scroll sync", () => {
  it("scrollToSourceLine scrolls to the block with the greatest attributed line at or below the requested line", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    preview.render("docs/notes.md", "one\n\ntwo\n\nthree\n");
    const blocks = Array.from(preview.element.querySelectorAll<HTMLElement>("[data-source-line]"));
    expect(blocks.map((el) => el.dataset.sourceLine)).toEqual(["1", "3", "5"]);

    stubRect(preview.element, { top: 20 });
    stubRect(blocks[0]!, { top: 20 });
    stubRect(blocks[1]!, { top: 120 });
    stubRect(blocks[2]!, { top: 220 });
    preview.element.scrollTop = 50;

    // Line 4 falls between the block starting at line 3 and the block starting at line 5, so the
    // line-3 block (blocks[1]) is the target.
    preview.scrollToSourceLine(4);

    expect(preview.element.scrollTop).toBe(50 + (120 - 20));
  });

  it("scrollToSourceLine scrolls to the top when the requested line is before the first block", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    preview.render("docs/notes.md", "one\n\ntwo\n");
    const blocks = Array.from(preview.element.querySelectorAll<HTMLElement>("[data-source-line]"));
    stubRect(preview.element, { top: 0 });
    stubRect(blocks[0]!, { top: 0 });
    stubRect(blocks[1]!, { top: 50 });
    preview.element.scrollTop = 7;

    preview.scrollToSourceLine(0); // before the first block's line (1)

    expect(preview.element.scrollTop).toBe(0);
  });

  it("scrollToSourceLine follows the source to the top of a document that opens with blank lines", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    preview.render("docs/notes.md", "\n\none\n\ntwo\n");
    const blocks = Array.from(preview.element.querySelectorAll<HTMLElement>("[data-source-line]"));
    // The leading blank lines render nothing, so the first block is attributed to source line 3 and
    // line 1 falls before every block the preview holds.
    expect(blocks.map((el) => el.dataset.sourceLine)).toEqual(["3", "5"]);
    stubRect(preview.element, { top: 0 });
    stubRect(blocks[0]!, { top: 0 });
    stubRect(blocks[1]!, { top: 50 });
    preview.element.scrollTop = 120;
    expect(preview.element.scrollTop).toBe(120);

    preview.scrollToSourceLine(1);

    expect(preview.element.scrollTop).toBe(0);
  });

  it("scrollToSourceLine leaves an empty preview alone", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    preview.element.scrollTop = 7;

    preview.scrollToSourceLine(1);

    expect(preview.element.scrollTop).toBe(7);
  });

  it("visibleSourceLine returns the line of the block whose band covers the container's top edge", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    preview.render("docs/notes.md", "one\n\ntwo\n\nthree\n");
    const blocks = Array.from(preview.element.querySelectorAll<HTMLElement>("[data-source-line]"));
    expect(blocks.map((el) => el.dataset.sourceLine)).toEqual(["1", "3", "5"]);

    stubRect(preview.element, { top: 0 });
    stubRect(blocks[0]!, { bottom: -50 }); // fully scrolled past
    stubRect(blocks[1]!, { bottom: 100 }); // straddles the top edge
    stubRect(blocks[2]!, { bottom: 250 });

    expect(preview.visibleSourceLine()).toBe(3);
  });

  it("visibleSourceLine returns null when nothing is rendered", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    expect(preview.visibleSourceLine()).toBeNull();
  });

  it("scrollToSourceLine resolves a line inside a long fence to the fence's own block, not a neighbour", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    const fenceLines = Array.from({ length: 20 }, (_, index) => `line ${index}`);
    preview.render("docs/notes.md", ["Intro.", "", "```text", ...fenceLines, "```", "", "After."].join("\n"));

    const blocks = Array.from(preview.element.querySelectorAll<HTMLElement>("[data-source-line]"));
    expect(blocks.map((el) => el.tagName.toLowerCase())).toEqual(["p", "pre", "p"]);
    expect(blocks.map((el) => el.dataset.sourceLine)).toEqual(["1", "3", "26"]);

    stubRect(preview.element, { top: 0 });
    stubRect(blocks[0]!, { top: 0 });
    stubRect(blocks[1]!, { top: 20 });
    stubRect(blocks[2]!, { top: 500 });
    preview.element.scrollTop = 0;

    // Line 15 sits inside the fence's content (source lines 4-23), which carries no stamp of its
    // own; it must resolve to the fence block's line (3), the nearest one at or before it, not to
    // "After." (26) or fall through to nothing.
    preview.scrollToSourceLine(15);

    expect(preview.element.scrollTop).toBe(20);
  });

  it("visibleSourceLine attributes a long fence's straddling band to the fence, not a neighbour", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    const fenceLines = Array.from({ length: 20 }, (_, index) => `line ${index}`);
    preview.render("docs/notes.md", ["Intro.", "", "```text", ...fenceLines, "```", "", "After."].join("\n"));

    const blocks = Array.from(preview.element.querySelectorAll<HTMLElement>("[data-source-line]"));
    expect(blocks.map((el) => el.dataset.sourceLine)).toEqual(["1", "3", "26"]);

    stubRect(preview.element, { top: 0 });
    stubRect(blocks[0]!, { bottom: -50 }); // "Intro." fully scrolled past
    stubRect(blocks[1]!, { bottom: 400 }); // the fence's own rendered band straddles the top edge
    stubRect(blocks[2]!, { bottom: 500 });

    expect(preview.visibleSourceLine()).toBe(3);
  });
});

describe("MarkdownPreview: source-line cap", () => {
  it("renders the first 5000 lines of a longer file and says how long the file is", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    // Consecutive ATX headings are one block per line, so a block's stamped source line is its
    // own line number and the last stamped line is exactly what was rendered.
    preview.render("docs/notes.md", Array.from({ length: 6000 }, (_, index) => `# H${index + 1}`).join("\n"));

    const blocks = Array.from(preview.element.querySelectorAll<HTMLElement>("[data-source-line]"));
    expect(blocks).toHaveLength(5000);
    expect(Math.max(...blocks.map((el) => Number(el.dataset.sourceLine)))).toBe(5000);
    expect(preview.element.querySelector(".markdown-preview-note")!.textContent).toBe("Showing first 5000 of 6000 lines");
  });

  it("renders a file at the cap whole, with no note", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    preview.render("docs/notes.md", Array.from({ length: 5000 }, (_, index) => `# H${index + 1}`).join("\n"));

    expect(preview.element.querySelectorAll("[data-source-line]")).toHaveLength(5000);
    expect(preview.element.querySelector(".markdown-preview-note")).toBeNull();
  });

  it("counts a lone-CR document's lines the same as a \\n one, so the cap and note apply identically", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    // markdown-it treats a lone `\r` as a line break exactly like `\n` (both normalize to the same
    // token map), so 6000 CR-joined headings must be capped, and counted, the same way 6000
    // \n-joined ones are above: a scan that only recognized `\n` would read the whole document as
    // one line and render every heading with no note.
    preview.render("docs/notes.md", Array.from({ length: 6000 }, (_, index) => `# H${index + 1}`).join("\r"));

    const blocks = Array.from(preview.element.querySelectorAll<HTMLElement>("[data-source-line]"));
    expect(blocks).toHaveLength(5000);
    expect(Math.max(...blocks.map((el) => Number(el.dataset.sourceLine)))).toBe(5000);
    expect(preview.element.querySelector(".markdown-preview-note")!.textContent).toBe("Showing first 5000 of 6000 lines");
  });

  it("counts a CRLF document's lines the same as a \\n one, so the cap and note apply identically", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    preview.render("docs/notes.md", Array.from({ length: 6000 }, (_, index) => `# H${index + 1}`).join("\r\n"));

    const blocks = Array.from(preview.element.querySelectorAll<HTMLElement>("[data-source-line]"));
    expect(blocks).toHaveLength(5000);
    expect(Math.max(...blocks.map((el) => Number(el.dataset.sourceLine)))).toBe(5000);
    expect(preview.element.querySelector(".markdown-preview-note")!.textContent).toBe("Showing first 5000 of 6000 lines");
  });

  it("renders every heading with no note for a document under both caps that mixes line endings", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    const endings = ["\n", "\r\n", "\r"];
    const headings = Array.from({ length: 30 }, (_, index) => `# H${index + 1}`);
    const source = headings.reduce((acc, heading, index) => (index === 0 ? heading : `${acc}${endings[index % endings.length]}${heading}`), "");

    preview.render("docs/notes.md", source);

    const blocks = Array.from(preview.element.querySelectorAll<HTMLElement>("[data-source-line]"));
    expect(blocks).toHaveLength(30);
    expect(preview.element.querySelector(".markdown-preview-note")).toBeNull();
  });
});

describe("MarkdownPreview: source-size cap", () => {
  it("bounds a single huge line with the size note and does not crash", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    // One line, well past the character budget but nowhere near the line cap: the line cap's
    // `lines.slice(0, 5000)` would be a no-op here, so only the character budget bounds it.
    const hugeLine = "a".repeat(1_200_000);

    preview.render("docs/notes.md", hugeLine);

    const note = preview.element.querySelector(".markdown-preview-note");
    expect(note?.textContent).toBe(`Showing the first ${MAX_PREVIEW_SOURCE_CHARS.toLocaleString("en-US")} characters of 1,200,000`);
    // The one line alone exceeds the budget, so it is cut at the budget itself rather than at a line
    // boundary (there is no earlier one), leaving exactly one bounded paragraph.
    const paragraphs = preview.element.querySelectorAll(".markdown-body > p");
    expect(paragraphs).toHaveLength(1);
    expect(paragraphs[0]!.textContent).toHaveLength(MAX_PREVIEW_SOURCE_CHARS);
  });

  it("still hits the line cap, with the line note, for a 6000-line document well under the character budget", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    preview.render("docs/notes.md", Array.from({ length: 6000 }, (_, index) => `# H${index + 1}`).join("\n"));

    expect(preview.element.querySelectorAll("[data-source-line]")).toHaveLength(5000);
    expect(preview.element.querySelector(".markdown-preview-note")?.textContent).toBe("Showing first 5000 of 6000 lines");
  });

  it("shows no note for a document under both the line and character bounds", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    preview.render("docs/notes.md", "# Title\n\nShort body.\n");

    expect(preview.element.querySelector(".markdown-preview-note")).toBeNull();
  });

  it("cuts the character cap at a line boundary when one falls inside the budget", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    // ATX headings, so each source line is its own top-level block; there are far fewer than 5000 of
    // them, so only the character budget bites, and the cut must land on a whole heading rather than
    // slicing through one.
    const body = "x".repeat(300);
    const lineOf = (index: number) => `# H${index} ${body}`;
    const lineCount = Math.ceil((MAX_PREVIEW_SOURCE_CHARS * 1.5) / (lineOf(0).length + 1));
    const lines = Array.from({ length: lineCount }, (_, index) => lineOf(index));
    const source = lines.join("\n");

    // Independently compute the expected cut: the longest prefix of whole lines fitting the budget.
    let expectedLines = 0;
    let consumed = 0;
    for (const line of lines) {
      const withSeparator = expectedLines === 0 ? line.length : consumed + 1 + line.length;
      if (withSeparator > MAX_PREVIEW_SOURCE_CHARS) break;
      expectedLines += 1;
      consumed = withSeparator;
    }
    expect(expectedLines).toBeGreaterThan(0);
    expect(expectedLines).toBeLessThan(lineCount);

    preview.render("docs/notes.md", source);

    const note = preview.element.querySelector(".markdown-preview-note");
    expect(note?.textContent).toBe(
      `Showing the first ${MAX_PREVIEW_SOURCE_CHARS.toLocaleString("en-US")} characters of ${source.length.toLocaleString("en-US")}`,
    );
    const headings = [...preview.element.querySelectorAll(".markdown-body > h1")];
    expect(headings).toHaveLength(expectedLines);
    // Every rendered heading is whole (its full body text), never a fragment of one cut mid-line.
    expect(headings.every((h, index) => h.textContent === `H${index} ${body}`)).toBe(true);
  });

  it("keeps a leading blank line when the character cap bites, so later lines' source-line attribution isn't shifted", () => {
    const preview = new MarkdownPreview(makeCallbacks());
    // A leading blank line (an empty first source line), then enough ATX headings to cross the
    // character budget on their own, the same shape as the boundary test above. A cut that treats
    // the blank line as never having been taken (the bug: tracking "first line" by `consumed === 0`,
    // which an empty line also leaves at 0) drops it and its separator, reading the second line as
    // the first and shifting every `data-source-line` after it by one.
    const body = "x".repeat(300);
    const lineOf = (index: number) => `# H${index} ${body}`;
    const lineCount = Math.ceil((MAX_PREVIEW_SOURCE_CHARS * 1.5) / (lineOf(0).length + 1));
    const headingLines = Array.from({ length: lineCount }, (_, index) => lineOf(index));
    const source = "\n" + headingLines.join("\n");
    const lines = source.split("\n");

    // Independently compute the expected cut with the fixed rule: a line is "taken" once any line,
    // even an empty one, has been.
    let expectedLines = 0;
    let consumed = 0;
    let tookAny = false;
    for (const line of lines) {
      const withSeparator = tookAny ? consumed + 1 + line.length : line.length;
      if (withSeparator > MAX_PREVIEW_SOURCE_CHARS) break;
      expectedLines += 1;
      consumed = withSeparator;
      tookAny = true;
    }
    expect(expectedLines).toBeGreaterThan(1);
    expect(expectedLines).toBeLessThan(lines.length);

    preview.render("docs/notes.md", source);

    const note = preview.element.querySelector(".markdown-preview-note");
    expect(note?.textContent).toBe(
      `Showing the first ${MAX_PREVIEW_SOURCE_CHARS.toLocaleString("en-US")} characters of ${source.length.toLocaleString("en-US")}`,
    );
    const headings = [...preview.element.querySelectorAll<HTMLElement>(".markdown-body > h1")];
    // The blank line is real source line 1 and renders no block of its own, so the heading count is
    // one less than the lines taken, and the first heading's own source line is 2, not 1.
    expect(headings).toHaveLength(expectedLines - 1);
    expect(headings[0]!.dataset.sourceLine).toBe("2");
    expect(headings.every((h, index) => h.dataset.sourceLine === String(index + 2))).toBe(true);
    expect(headings.every((h, index) => h.textContent === `H${index} ${body}`)).toBe(true);
  });
});
