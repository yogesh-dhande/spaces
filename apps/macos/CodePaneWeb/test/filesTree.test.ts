import { beforeEach, describe, expect, it, vi } from "vitest";
import { FilesTreeCallbacks, renderFilesTree } from "../src/app/filesTree";

function makeCallbacks(): FilesTreeCallbacks {
  return { onSelect: vi.fn() };
}

// jsdom has no scrollIntoView implementation; setSelected calls it on the newly-highlighted row.
beforeEach(() => {
  Element.prototype.scrollIntoView = vi.fn();
});

describe("filesTree — renderFilesTree", () => {
  it("renders an empty-state row when there are no paths", () => {
    const container = document.createElement("div");

    renderFilesTree(container, [], undefined, makeCallbacks());

    expect(container.querySelector(".empty")?.textContent).toBe("No files");
  });

  it("marks the selected root-level row via the on class, and no other row", () => {
    const container = document.createElement("div");
    const callbacks = makeCallbacks();

    renderFilesTree(container, ["a.ts", "b.ts"], "b.ts", callbacks);

    const rows = [...container.querySelectorAll(".row")];
    expect(rows[0]!.className).not.toContain(" on");
    expect(rows[1]!.className).toContain(" on");
  });

  it("clicking a file row invokes onSelect with the file's full path, not just its basename", () => {
    const container = document.createElement("div");
    const callbacks = makeCallbacks();

    renderFilesTree(container, ["apps/macos/Foo.swift"], undefined, callbacks);

    // The one directory on the path is an ancestor of no selectedPath here, so it starts collapsed;
    // expand it first to reach the file row.
    (container.querySelector(".dirrow") as HTMLElement).click();
    (container.querySelector(".row") as HTMLElement).click();

    expect(callbacks.onSelect).toHaveBeenCalledWith("apps/macos/Foo.swift");
  });

  it("renders no .status or .st columns (unlike the Changes list)", () => {
    const container = document.createElement("div");

    renderFilesTree(container, ["a.ts"], undefined, makeCallbacks());

    const row = container.querySelector(".row")!;
    expect(row.querySelector(".status")).toBeNull();
    expect(row.querySelector(".st")).toBeNull();
  });

  it("renders a compacted directory chain as one dirrow", () => {
    const container = document.createElement("div");
    const paths = ["apps/ios/Sources/ViewerResync.swift", "apps/ios/Sources/MobileRootView.swift"];

    renderFilesTree(container, paths, undefined, makeCallbacks());

    const dirrows = [...container.querySelectorAll(".dirrow")];
    expect(dirrows).toHaveLength(1);
    expect(dirrows[0]!.querySelector(".dirlabel")?.textContent).toBe("apps/ios/Sources");
  });

  it("expanding a compacted directory chain materializes its files by basename only", () => {
    const container = document.createElement("div");
    const paths = ["apps/ios/Sources/ViewerResync.swift", "apps/ios/Sources/MobileRootView.swift"];

    renderFilesTree(container, paths, undefined, makeCallbacks());
    (container.querySelector(".dirrow") as HTMLElement).click();

    const fnTexts = [...container.querySelectorAll(".row .fn")].map((el) => el.textContent);
    expect(fnTexts).toEqual(["ViewerResync.swift", "MobileRootView.swift"]);
  });

  it("sets data-path and a title tooltip to the full path on a nested file row", () => {
    const container = document.createElement("div");

    renderFilesTree(container, ["apps/macos/Foo.swift"], undefined, makeCallbacks());
    (container.querySelector(".dirrow") as HTMLElement).click();

    const row = container.querySelector(".row")!;
    expect(row.getAttribute("data-path")).toBe("apps/macos/Foo.swift");
    expect(row.querySelector(".fn")?.getAttribute("title")).toBe("apps/macos/Foo.swift");
  });

  it("row keydown Enter and Space both invoke onSelect, matching fileList.ts's row keydown handling", () => {
    const container = document.createElement("div");
    const callbacks = makeCallbacks();
    renderFilesTree(container, ["apps/macos/Foo.swift", "apps/macos/Bar.swift"], undefined, callbacks);
    (container.querySelector(".dirrow") as HTMLElement).click();

    const rows = [...container.querySelectorAll(".row")] as HTMLElement[];
    expect(rows[0]!.getAttribute("role")).toBe("button");
    expect(rows[0]!.tabIndex).toBe(0);

    rows[0]!.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    expect(callbacks.onSelect).toHaveBeenCalledWith("apps/macos/Foo.swift");

    rows[1]!.dispatchEvent(new KeyboardEvent("keydown", { key: " ", bubbles: true, cancelable: true }));
    expect(callbacks.onSelect).toHaveBeenCalledWith("apps/macos/Bar.swift");

    // A non-activation key must not select.
    callbacks.onSelect = vi.fn();
    rows[0]!.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true }));
    expect(callbacks.onSelect).not.toHaveBeenCalled();
  });

  it("renders root-level files directly with no wrapping directory row, alongside a nested directory's dirrow", () => {
    const container = document.createElement("div");
    const paths = ["README.md", "apps/macos/Foo.swift"];

    renderFilesTree(container, paths, undefined, makeCallbacks());

    expect(container.querySelectorAll(".dirrow")).toHaveLength(1);
    // The root-level file renders even though the nested directory is collapsed.
    const fnTexts = [...container.querySelectorAll(".row .fn")].map((el) => el.textContent);
    expect(fnTexts).toEqual(["README.md"]);
  });

  it("re-rendering into the same container replaces prior content instead of appending", () => {
    const container = document.createElement("div");

    renderFilesTree(container, ["a.ts"], undefined, makeCallbacks());
    renderFilesTree(container, ["b.ts", "c.ts"], undefined, makeCallbacks());

    const fnTexts = [...container.querySelectorAll(".row .fn")].map((el) => el.textContent);
    expect(fnTexts).toEqual(["b.ts", "c.ts"]);
  });

  describe("collapsed-by-default and lazy materialization", () => {
    it("starts every directory collapsed, with its triangle, aria-expanded, and display reflecting that", () => {
      const container = document.createElement("div");
      renderFilesTree(container, ["apps/macos/Foo.swift"], undefined, makeCallbacks());

      const dirrow = container.querySelector(".dirrow") as HTMLElement;
      const dirChildren = container.querySelector(".dir-children") as HTMLElement;
      expect(dirrow.querySelector(".tri")?.textContent).toBe("▸");
      expect(dirrow.getAttribute("aria-expanded")).toBe("false");
      expect(dirChildren.style.display).toBe("none");
    });

    it("installs no descendant row or listener DOM before a directory's first expand", () => {
      const container = document.createElement("div");
      const callbacks = makeCallbacks();
      renderFilesTree(container, ["apps/macos/Foo.swift", "apps/macos/Bar.swift"], undefined, callbacks);

      const dirChildren = container.querySelector(".dir-children") as HTMLElement;
      expect(dirChildren.children).toHaveLength(0);
      expect(container.querySelectorAll(".row")).toHaveLength(0);

      // Clicking anywhere inside the still-empty children container can't reach a row handler either.
      dirChildren.click();
      expect(callbacks.onSelect).not.toHaveBeenCalled();
    });

    it("materializes a directory's rows on first expand, flipping the triangle, aria-expanded, and display", () => {
      const container = document.createElement("div");
      renderFilesTree(container, ["apps/macos/Foo.swift"], undefined, makeCallbacks());

      const dirrow = container.querySelector(".dirrow") as HTMLElement;
      const dirChildren = container.querySelector(".dir-children") as HTMLElement;

      dirrow.click();
      expect(dirrow.querySelector(".tri")?.textContent).toBe("▾");
      expect(dirrow.getAttribute("aria-expanded")).toBe("true");
      expect(dirChildren.style.display).not.toBe("none");
      expect(container.querySelectorAll(".row")).toHaveLength(1);

      dirrow.click();
      expect(dirrow.querySelector(".tri")?.textContent).toBe("▸");
      expect(dirrow.getAttribute("aria-expanded")).toBe("false");
      expect(dirChildren.style.display).toBe("none");
    });

    it("preserves row element identity across collapse/re-expand — no rebuild on subsequent toggles", () => {
      const container = document.createElement("div");
      renderFilesTree(container, ["apps/macos/Foo.swift"], undefined, makeCallbacks());

      const dirrow = container.querySelector(".dirrow") as HTMLElement;
      dirrow.click(); // first expand: materializes
      const rowAfterFirstExpand = container.querySelector(".row");

      dirrow.click(); // collapse
      dirrow.click(); // re-expand

      expect(container.querySelector(".row")).toBe(rowAfterFirstExpand);
    });

    it("exposes the dirrow as a focusable button and toggles/materializes it from the keyboard", () => {
      const container = document.createElement("div");
      renderFilesTree(container, ["apps/macos/Foo.swift"], undefined, makeCallbacks());

      const dirrow = container.querySelector(".dirrow") as HTMLElement;
      expect(dirrow.getAttribute("role")).toBe("button");
      expect(dirrow.tabIndex).toBe(0);

      dirrow.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
      expect(dirrow.getAttribute("aria-expanded")).toBe("true");
      expect(container.querySelectorAll(".row")).toHaveLength(1);

      dirrow.dispatchEvent(new KeyboardEvent("keydown", { key: " ", bubbles: true, cancelable: true }));
      expect(dirrow.getAttribute("aria-expanded")).toBe("false");

      // A non-activation key must not toggle.
      dirrow.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true }));
      expect(dirrow.getAttribute("aria-expanded")).toBe("false");

      // A held key's auto-repeated keydowns must not oscillate the disclosure.
      dirrow.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
      expect(dirrow.getAttribute("aria-expanded")).toBe("true");
      dirrow.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", repeat: true, bubbles: true, cancelable: true }));
      expect(dirrow.getAttribute("aria-expanded")).toBe("true");
    });
  });

  describe("selectedPath pre-expansion on initial paint", () => {
    it("expands and materializes every ancestor of selectedPath, and highlights its row", () => {
      const container = document.createElement("div");

      renderFilesTree(container, ["apps/macos/Foo.swift", "apps/macos/Bar.swift"], "apps/macos/Foo.swift", makeCallbacks());

      const dirrow = container.querySelector(".dirrow") as HTMLElement;
      expect(dirrow.getAttribute("aria-expanded")).toBe("true");
      expect(dirrow.querySelector(".tri")?.textContent).toBe("▾");

      const rows = [...container.querySelectorAll(".row")];
      expect(rows).toHaveLength(2); // both siblings materialized — expand happens per directory, not per file
      const selected = container.querySelector('.row[data-path="apps/macos/Foo.swift"]')!;
      expect(selected.className).toContain(" on");
    });

    it("leaves a directory unrelated to selectedPath collapsed and unmaterialized", () => {
      const container = document.createElement("div");
      // Two top-level directories, each a single-file leaf, so they render as separate uncompacted
      // dirrows ("macos", "ios") rather than compacting into one shared "apps/..." chain.
      const paths = ["macos/Foo.swift", "ios/Bar.swift"];

      renderFilesTree(container, paths, "macos/Foo.swift", makeCallbacks());

      const dirrows = [...container.querySelectorAll(".dirrow")] as HTMLElement[];
      const macosRow = dirrows.find((d) => d.querySelector(".dirlabel")?.textContent === "macos")!;
      const iosRow = dirrows.find((d) => d.querySelector(".dirlabel")?.textContent === "ios")!;
      expect(macosRow.getAttribute("aria-expanded")).toBe("true");
      expect(iosRow.getAttribute("aria-expanded")).toBe("false");
      expect(container.querySelector('.row[data-path="ios/Bar.swift"]')).toBeNull();
    });
  });

  describe("FilesTreeHandle.setSelected", () => {
    it("moves the highlight from the old row to the new one without touching other materialized rows' identity", () => {
      const container = document.createElement("div");
      const handle = renderFilesTree(container, ["a.ts", "b.ts", "c.ts"], "a.ts", makeCallbacks());
      const unrelatedRow = container.querySelector('.row[data-path="c.ts"]');

      handle.setSelected("b.ts");

      expect(container.querySelector('.row[data-path="a.ts"]')!.className).not.toContain(" on");
      expect(container.querySelector('.row[data-path="b.ts"]')!.className).toContain(" on");
      expect(container.querySelector('.row[data-path="c.ts"]')).toBe(unrelatedRow); // untouched, same element
    });

    it("expands and materializes the new path's ancestor chain, without rebuilding an already-materialized sibling", () => {
      const container = document.createElement("div");
      const paths = ["macos/Foo.swift", "ios/Bar.swift"];
      const handle = renderFilesTree(container, paths, "macos/Foo.swift", makeCallbacks());
      const macosRowBefore = container.querySelector('.row[data-path="macos/Foo.swift"]');

      handle.setSelected("ios/Bar.swift");

      const dirrows = [...container.querySelectorAll(".dirrow")] as HTMLElement[];
      const iosRow = dirrows.find((d) => d.querySelector(".dirlabel")?.textContent === "ios")!;
      expect(iosRow.getAttribute("aria-expanded")).toBe("true");
      const selected = container.querySelector('.row[data-path="ios/Bar.swift"]')!;
      expect(selected.className).toContain(" on");
      // The previously-selected file's directory stays expanded and its row keeps its identity —
      // setSelected only ever expands, it never collapses an unrelated directory.
      expect(container.querySelector('.row[data-path="macos/Foo.swift"]')).toBe(macosRowBefore);
    });

    it("scrolls the newly-selected row into view", () => {
      const container = document.createElement("div");
      const handle = renderFilesTree(container, ["a.ts", "b.ts"], "a.ts", makeCallbacks());

      handle.setSelected("b.ts");

      const row = container.querySelector('.row[data-path="b.ts"]') as HTMLElement;
      expect(row.scrollIntoView).toHaveBeenCalledWith({ block: "nearest" });
    });

    it("clears the previous highlight and does nothing else for a path not present in the tree", () => {
      const container = document.createElement("div");
      const handle = renderFilesTree(container, ["a.ts", "b.ts"], "a.ts", makeCallbacks());

      handle.setSelected("missing.ts");

      expect(container.querySelector(".row.on")).toBeNull();
    });

    it("clears the previous highlight for undefined and does not throw", () => {
      const container = document.createElement("div");
      const handle = renderFilesTree(container, ["a.ts", "b.ts"], "a.ts", makeCallbacks());

      expect(() => handle.setSelected(undefined)).not.toThrow();
      expect(container.querySelector(".row.on")).toBeNull();
    });

    it("is a safe no-op on the empty-state handle", () => {
      const container = document.createElement("div");
      const handle = renderFilesTree(container, [], undefined, makeCallbacks());

      expect(() => handle.setSelected("a.ts")).not.toThrow();
    });
  });
});
