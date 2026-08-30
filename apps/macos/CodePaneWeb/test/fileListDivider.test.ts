import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  attachFileListDivider,
  clampFileListWidth,
  DEFAULT_FILE_LIST_WIDTH,
  loadStoredFileListWidth,
  storeFileListWidth,
} from "../src/app/fileListDivider";

describe("clampFileListWidth", () => {
  it("raises a width below the minimum up to the minimum", () => {
    expect(clampFileListWidth(50, 1000)).toBe(160);
  });

  it("lowers a width above 50% of the pane down to that fraction", () => {
    expect(clampFileListWidth(900, 1000)).toBe(500);
  });

  it("leaves a width within range unchanged", () => {
    expect(clampFileListWidth(300, 1000)).toBe(300);
  });

  it("never drops the max below the minimum, even on a very narrow pane", () => {
    // 50% of a 100px pane is 50px, below the 160px floor — the floor wins.
    expect(clampFileListWidth(500, 100)).toBe(160);
  });
});

describe("loadStoredFileListWidth / storeFileListWidth", () => {
  beforeEach(() => {
    window.localStorage.clear();
  });

  it("round-trips a stored width", () => {
    storeFileListWidth(280);
    expect(loadStoredFileListWidth()).toBe(280);
  });

  it("returns undefined when nothing is stored", () => {
    expect(loadStoredFileListWidth()).toBeUndefined();
  });

  it("returns undefined for a non-numeric or non-positive stored value", () => {
    window.localStorage.setItem("spaces.codePane.fileListWidth", "not-a-number");
    expect(loadStoredFileListWidth()).toBeUndefined();

    window.localStorage.setItem("spaces.codePane.fileListWidth", "-5");
    expect(loadStoredFileListWidth()).toBeUndefined();
  });

  it("swallows a localStorage read failure and returns undefined", () => {
    const spy = vi.spyOn(window.localStorage.__proto__, "getItem").mockImplementation(() => {
      throw new Error("blocked");
    });
    expect(loadStoredFileListWidth()).toBeUndefined();
    spy.mockRestore();
  });

  it("swallows a localStorage write failure without throwing", () => {
    const spy = vi.spyOn(window.localStorage.__proto__, "setItem").mockImplementation(() => {
      throw new Error("quota exceeded");
    });
    expect(() => storeFileListWidth(300)).not.toThrow();
    spy.mockRestore();
  });
});

// jsdom has no ResizeObserver; attachFileListDivider constructs one unconditionally to re-clamp on
// pane resize. This fake records instances so tests can fire resize callbacks by hand (unlike the
// real API, it does not fire an initial callback on observe — attach doesn't rely on one: it
// applies the restored width directly before observing).
class FakeResizeObserver {
  static instances: FakeResizeObserver[] = [];
  target: Element | undefined;

  constructor(private readonly callback: ResizeObserverCallback) {
    FakeResizeObserver.instances.push(this);
  }

  observe(el: Element): void {
    this.target = el;
  }

  unobserve(): void {}
  disconnect(): void {}

  fire(width: number): void {
    this.callback([{ contentRect: { width } } as ResizeObserverEntry], this as unknown as ResizeObserver);
  }
}

describe("attachFileListDivider", () => {
  // jsdom implements neither pointer-capture method; the module calls them unconditionally on drag
  // start/end, so a no-op stub is required for these tests to run at all.
  beforeEach(() => {
    window.localStorage.clear();
    Element.prototype.setPointerCapture = vi.fn();
    Element.prototype.releasePointerCapture = vi.fn();
    FakeResizeObserver.instances.length = 0;
    vi.stubGlobal("ResizeObserver", FakeResizeObserver);
  });

  // jsdom has no PointerEvent constructor, so a plain MouseEvent stands in — `pointerId` is assigned
  // afterward as an own property, since it isn't part of MouseEventInit.
  function makePointerEvent(type: string, init: { pointerId: number; clientX: number }): PointerEvent {
    const event = new MouseEvent(type, { clientX: init.clientX, bubbles: true }) as PointerEvent;
    Object.defineProperty(event, "pointerId", { value: init.pointerId });
    return event;
  }

  function setup(paneWidth: number): {
    divider: HTMLElement;
    fileList: HTMLElement;
    pane: HTMLElement;
    observer: FakeResizeObserver;
  } {
    const pane = document.createElement("div");
    const fileList = document.createElement("div");
    const divider = document.createElement("div");
    pane.appendChild(fileList);
    pane.appendChild(divider);
    document.body.appendChild(pane);
    vi.spyOn(pane, "getBoundingClientRect").mockReturnValue({ width: paneWidth } as DOMRect);
    attachFileListDivider(divider, fileList, pane);
    const observer = FakeResizeObserver.instances.at(-1);
    if (observer === undefined) throw new Error("attachFileListDivider did not observe the pane");
    return { divider, fileList, pane, observer };
  }

  it("applies the default width on attach when nothing is stored", () => {
    const { fileList } = setup(1000);
    expect(fileList.style.width).toBe(`${DEFAULT_FILE_LIST_WIDTH}px`);
  });

  it("applies a previously stored width on attach", () => {
    storeFileListWidth(320);
    const { fileList } = setup(1000);
    expect(fileList.style.width).toBe("320px");
  });

  it("observes the pane for resize", () => {
    const { pane, observer } = setup(1000);
    expect(observer.target).toBe(pane);
  });

  it("clamps an oversized restored width when the pane reports its size", () => {
    storeFileListWidth(600);
    const { fileList, observer } = setup(1000);

    observer.fire(500); // 50% of 500 = 250 < 600, so the restored width must clamp down
    expect(fileList.style.width).toBe("250px");
  });

  it("restores the chosen width when the pane widens again, instead of ratcheting down", () => {
    storeFileListWidth(400);
    const { fileList, observer } = setup(1000);

    observer.fire(500); // clamps the applied width to 250
    observer.fire(1000); // wide enough for the chosen 400 again
    expect(fileList.style.width).toBe("400px");
  });

  it("ignores a zero-width pane resize (pane not laid out)", () => {
    storeFileListWidth(400);
    const { fileList, observer } = setup(1000);

    observer.fire(0);
    expect(fileList.style.width).toBe("400px");
  });

  it("does not overwrite a dragged width with the stale pre-drag choice on a later resize", () => {
    const { divider, fileList, observer } = setup(1000);

    divider.dispatchEvent(makePointerEvent("pointerdown", { pointerId: 1, clientX: 200 }));
    divider.dispatchEvent(makePointerEvent("pointermove", { pointerId: 1, clientX: 300 }));
    divider.dispatchEvent(makePointerEvent("pointerup", { pointerId: 1, clientX: 300 }));

    observer.fire(1000);
    expect(fileList.style.width).toBe(`${DEFAULT_FILE_LIST_WIDTH + 100}px`);
  });

  it("resizes the file list as the pointer moves during a drag", () => {
    const { divider, fileList } = setup(1000);

    divider.dispatchEvent(makePointerEvent("pointerdown", { pointerId: 1, clientX: 200 }));
    divider.dispatchEvent(makePointerEvent("pointermove", { pointerId: 1, clientX: 250 }));

    expect(fileList.style.width).toBe(`${DEFAULT_FILE_LIST_WIDTH + 50}px`);
  });

  it("ignores pointermove events from a different pointer than the one that started the drag", () => {
    const { divider, fileList } = setup(1000);

    divider.dispatchEvent(makePointerEvent("pointerdown", { pointerId: 1, clientX: 200 }));
    divider.dispatchEvent(makePointerEvent("pointermove", { pointerId: 2, clientX: 400 }));

    expect(fileList.style.width).toBe(`${DEFAULT_FILE_LIST_WIDTH}px`);
  });

  it("clamps the resized width against the pane's current width", () => {
    const { divider, fileList } = setup(300); // 50% of 300 = 150, below the 160px floor, so the floor wins

    divider.dispatchEvent(makePointerEvent("pointerdown", { pointerId: 1, clientX: 200 }));
    divider.dispatchEvent(makePointerEvent("pointermove", { pointerId: 1, clientX: 205 }));

    expect(fileList.style.width).toBe("160px");
  });

  it("persists the final width to storage on pointer-up", () => {
    const { divider, fileList } = setup(1000);

    divider.dispatchEvent(makePointerEvent("pointerdown", { pointerId: 1, clientX: 200 }));
    divider.dispatchEvent(makePointerEvent("pointermove", { pointerId: 1, clientX: 260 }));
    divider.dispatchEvent(makePointerEvent("pointerup", { pointerId: 1, clientX: 260 }));

    expect(loadStoredFileListWidth()).toBe(parseFloat(fileList.style.width));
  });

  it("adds an 'active' class while dragging and removes it on pointer-up", () => {
    const { divider } = setup(1000);

    divider.dispatchEvent(makePointerEvent("pointerdown", { pointerId: 1, clientX: 200 }));
    expect(divider.classList.contains("active")).toBe(true);

    divider.dispatchEvent(makePointerEvent("pointerup", { pointerId: 1, clientX: 200 }));
    expect(divider.classList.contains("active")).toBe(false);
  });

  it("exposes the divider as a focusable vertical separator whose value tracks the applied width", () => {
    storeFileListWidth(320);
    const { divider, observer } = setup(1000);

    expect(divider.getAttribute("role")).toBe("separator");
    expect(divider.getAttribute("aria-orientation")).toBe("vertical");
    expect(divider.getAttribute("aria-label")).toBe("Resize file list");
    expect(divider.getAttribute("aria-valuemin")).toBe("160");
    expect(divider.tabIndex).toBe(0);
    expect(divider.getAttribute("aria-valuenow")).toBe("320");

    observer.fire(500); // clamps the applied width to 250 — the reported value must follow
    expect(divider.getAttribute("aria-valuenow")).toBe("250");
    // The max must be published too (role=separator otherwise implies 100) and track the pane.
    expect(divider.getAttribute("aria-valuemax")).toBe("250");
    observer.fire(1000);
    expect(divider.getAttribute("aria-valuemax")).toBe("500");
  });

  it("resizes with arrow keys, persisting each step", () => {
    const { divider, fileList } = setup(1000);

    divider.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", cancelable: true }));
    expect(fileList.style.width).toBe(`${DEFAULT_FILE_LIST_WIDTH + 16}px`);
    expect(loadStoredFileListWidth()).toBe(DEFAULT_FILE_LIST_WIDTH + 16);

    divider.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", cancelable: true }));
    expect(fileList.style.width).toBe(`${DEFAULT_FILE_LIST_WIDTH}px`);
    expect(loadStoredFileListWidth()).toBe(DEFAULT_FILE_LIST_WIDTH);
  });

  it("clamps keyboard resizing at the minimum width", () => {
    storeFileListWidth(170);
    const { divider, fileList } = setup(1000);

    divider.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", cancelable: true }));
    expect(fileList.style.width).toBe("160px"); // 170 - 16 clamps to the 160px floor

    divider.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", cancelable: true }));
    expect(fileList.style.width).toBe("160px");
  });

  it("keeps a keyboard step's desired width un-capped by a clamped pane instead of ratcheting the stored choice down", () => {
    storeFileListWidth(400);
    const { divider, fileList, observer } = setup(500); // 50% of 500 = 250, so the 400 choice is clamped

    observer.fire(500);
    expect(fileList.style.width).toBe("250px");

    divider.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", cancelable: true }));
    // The keypress anchors on the visible 250px and asks for 266; the paint stays pane-capped at
    // 250, but the persisted choice is 266 — never the cap itself.
    expect(fileList.style.width).toBe("250px");
    expect(loadStoredFileListWidth()).toBe(266);

    observer.fire(1000);
    expect(fileList.style.width).toBe("266px");
  });

  it("persists a rightward drag's requested width on a clamped pane, not the cap it painted at", () => {
    storeFileListWidth(400);
    const { divider, fileList, observer } = setup(500);
    observer.fire(500); // applied clamps to 250

    divider.dispatchEvent(makePointerEvent("pointerdown", { pointerId: 1, clientX: 200 }));
    divider.dispatchEvent(makePointerEvent("pointermove", { pointerId: 1, clientX: 300 }));
    divider.dispatchEvent(makePointerEvent("pointerup", { pointerId: 1, clientX: 300 }));

    expect(fileList.style.width).toBe("250px"); // still pane-capped
    expect(loadStoredFileListWidth()).toBe(350); // 250 anchor + 100 requested

    observer.fire(1000);
    expect(fileList.style.width).toBe("350px");
  });

  it("leaves the stored choice untouched when a drag never moves horizontally", () => {
    storeFileListWidth(400);
    const { divider, observer } = setup(500);
    observer.fire(500);

    divider.dispatchEvent(makePointerEvent("pointerdown", { pointerId: 1, clientX: 200 }));
    divider.dispatchEvent(makePointerEvent("pointermove", { pointerId: 1, clientX: 200 }));
    divider.dispatchEvent(makePointerEvent("pointerup", { pointerId: 1, clientX: 200 }));

    expect(loadStoredFileListWidth()).toBe(400);
  });

  it("ignores non-arrow keys on the divider", () => {
    const { divider, fileList } = setup(1000);

    divider.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", cancelable: true }));
    expect(fileList.style.width).toBe(`${DEFAULT_FILE_LIST_WIDTH}px`);
    expect(loadStoredFileListWidth()).toBeUndefined();
  });

  it("ends the drag on pointercancel just like pointerup", () => {
    const { divider, fileList } = setup(1000);

    divider.dispatchEvent(makePointerEvent("pointerdown", { pointerId: 1, clientX: 200 }));
    divider.dispatchEvent(makePointerEvent("pointercancel", { pointerId: 1, clientX: 200 }));
    divider.dispatchEvent(makePointerEvent("pointermove", { pointerId: 1, clientX: 500 }));

    // The drag ended at pointercancel, so this later pointermove (same pointerId) must be a no-op.
    expect(fileList.style.width).toBe(`${DEFAULT_FILE_LIST_WIDTH}px`);
  });
});
