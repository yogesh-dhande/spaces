import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createContextMenu } from "../src/app/contextMenu";

const HOST_RECT = { x: 0, y: 0, width: 200, height: 100, top: 0, right: 200, bottom: 100, left: 0, toJSON: () => ({}) } as DOMRect;
const MENU_RECT = { x: 0, y: 0, width: 80, height: 40, top: 0, right: 80, bottom: 40, left: 0, toJSON: () => ({}) } as DOMRect;

describe("createContextMenu", () => {
  let host: HTMLElement;

  beforeEach(() => {
    // jsdom lays nothing out, so the clamp's two measurements are supplied here: a 200x100 host at
    // the viewport origin, and an 80x40 menu.
    vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(function (this: HTMLElement) {
      return this.classList.contains("ctx-menu") ? MENU_RECT : HOST_RECT;
    });
    host = document.createElement("div");
    document.body.appendChild(host);
  });

  afterEach(() => {
    host.remove();
    vi.restoreAllMocks();
  });

  it("renders the header and items at the pointer", () => {
    const menu = createContextMenu(host);
    const onSelect = vi.fn();

    menu.show({ x: 30, y: 20, header: "app.ts:12", items: [{ label: "Open in Editor", onSelect }] });

    const el = host.querySelector(".ctx-menu") as HTMLElement;
    expect(el.querySelector(".head")?.textContent).toBe("app.ts:12");
    expect(el.style.left).toBe("30px");
    expect(el.style.top).toBe("20px");
    expect(menu.isOpen()).toBe(true);

    (el.querySelector(".item") as HTMLButtonElement).click();

    expect(onSelect).toHaveBeenCalledTimes(1);
    expect(menu.isOpen()).toBe(false);
    expect(host.querySelector(".ctx-menu")).toBeNull();
  });

  it("clamps a menu opened near the host's edge back inside it", () => {
    const menu = createContextMenu(host);

    menu.show({ x: 190, y: 95, header: "app.ts:12", items: [{ label: "Open in Editor", onSelect: () => {} }] });

    const el = host.querySelector(".ctx-menu") as HTMLElement;
    expect(el.style.left).toBe("120px");
    expect(el.style.top).toBe("60px");
  });

  it("focuses the first item on open and returns focus where it was on close", () => {
    const previous = document.createElement("button");
    document.body.appendChild(previous);
    previous.focus();
    const menu = createContextMenu(host);

    menu.show({ x: 10, y: 10, items: [{ label: "Open in Editor", onSelect: () => {} }] });
    expect(document.activeElement).toBe(host.querySelector(".ctx-menu .item"));

    menu.hide();
    expect(document.activeElement).toBe(previous);

    previous.remove();
  });

  it("dismisses on a scroll anywhere, on window blur, and on a resize", () => {
    const menu = createContextMenu(host);
    const scroller = document.createElement("div");
    document.body.appendChild(scroller);
    const open = (): void => menu.show({ x: 10, y: 10, items: [{ label: "Open in Editor", onSelect: () => {} }] });

    open();
    scroller.dispatchEvent(new Event("scroll"));
    expect(menu.isOpen()).toBe(false);

    open();
    window.dispatchEvent(new Event("blur"));
    expect(menu.isOpen()).toBe(false);

    open();
    window.dispatchEvent(new Event("resize"));
    expect(menu.isOpen()).toBe(false);

    scroller.remove();
  });

  it("dismisses when focus moves to another surface, such as Quick Open's input, and leaves focus there", () => {
    const previous = document.createElement("button");
    document.body.appendChild(previous);
    previous.focus();
    const menu = createContextMenu(host);
    const input = document.createElement("input");
    document.body.appendChild(input);

    menu.show({ x: 10, y: 10, items: [{ label: "Open in Editor", onSelect: () => {} }] });
    expect(menu.isOpen()).toBe(true);
    input.focus();

    expect(menu.isOpen()).toBe(false);
    expect(document.activeElement).toBe(input); // not pulled back to `previous`
    input.remove();
    previous.remove();
  });

  it("moves between items with the arrow keys and activates the focused one", () => {
    const menu = createContextMenu(host);
    const first = vi.fn();
    const second = vi.fn();

    menu.show({
      x: 10,
      y: 10,
      items: [
        { label: "First", onSelect: first },
        { label: "Second", onSelect: second },
      ],
    });
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));

    expect(second).toHaveBeenCalledTimes(1);
    expect(first).not.toHaveBeenCalled();
    expect(menu.isOpen()).toBe(false);
  });
});
