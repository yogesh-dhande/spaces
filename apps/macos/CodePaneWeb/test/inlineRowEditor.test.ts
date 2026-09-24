import { describe, expect, it, vi } from "vitest";
import { beginInlineRowEdit } from "../src/app/inlineRowEditor";

function makeRow(initialText = "original.ts"): HTMLElement {
  const row = document.createElement("div");
  row.className = "row";
  row.style.setProperty("--depth", "2");
  const fn = document.createElement("span");
  fn.className = "fn";
  fn.textContent = initialText;
  row.appendChild(fn);
  return row;
}

function fieldOf(row: HTMLElement): HTMLInputElement {
  return row.querySelector("input.inline-name") as HTMLInputElement;
}

describe("inlineRowEditor: beginInlineRowEdit", () => {
  it("mounts a focused, fully-selected input in place of the row's existing content", () => {
    const row = makeRow();
    document.body.appendChild(row); // jsdom only reports document.activeElement for an attached node

    beginInlineRowEdit({ row, initialValue: "original.ts", placeholder: "Name", commit: vi.fn(), onClose: vi.fn() });

    expect(row.querySelector(".fn")).toBeNull();
    const field = fieldOf(row);
    expect(field.value).toBe("original.ts");
    expect(field.placeholder).toBe("Name");
    expect(document.activeElement).toBe(field);
    row.remove();
  });

  // The field hands its value over exactly as typed, whitespace and all: only the caller knows
  // whether a name with leading or trailing spaces is a change, a no-op, or worth refusing.
  it("Enter commits the value verbatim and closes once the commit resolves", async () => {
    const row = makeRow();
    const commit = vi.fn().mockResolvedValue(undefined);
    const onClose = vi.fn();
    beginInlineRowEdit({ row, initialValue: "", placeholder: "New file", commit, onClose });

    fieldOf(row).value = "  renamed.ts  ";
    fieldOf(row).dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    expect(commit).toHaveBeenCalledWith("  renamed.ts  ");
    await vi.waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
    expect(row.querySelector("input.inline-name")).toBeNull();
    expect(row.querySelector(".fn")?.textContent).toBe("original.ts"); // original content restored
  });

  it("Escape closes without calling commit and restores the row's original content", () => {
    const row = makeRow();
    const commit = vi.fn();
    const onClose = vi.fn();
    beginInlineRowEdit({ row, initialValue: "original.ts", placeholder: "Name", commit, onClose });

    fieldOf(row).dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));

    expect(commit).not.toHaveBeenCalled();
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(row.querySelector(".fn")?.textContent).toBe("original.ts");
  });

  it("blur closes without calling commit", () => {
    const row = makeRow();
    document.body.appendChild(row); // blur only fires with real focus/DOM attachment in jsdom
    const commit = vi.fn();
    const onClose = vi.fn();
    beginInlineRowEdit({ row, initialValue: "original.ts", placeholder: "Name", commit, onClose });

    fieldOf(row).blur();

    expect(commit).not.toHaveBeenCalled();
    expect(onClose).toHaveBeenCalledTimes(1);
    row.remove();
  });

  it("disables the field while a commit is in flight, so a second Enter does not fire a second call", async () => {
    const row = makeRow();
    let resolveCommit!: () => void;
    const commit = vi.fn(() => new Promise<void>((resolve) => (resolveCommit = resolve)));
    beginInlineRowEdit({ row, initialValue: "x", placeholder: "Name", commit, onClose: vi.fn() });

    const field = fieldOf(row);
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    expect(field.disabled).toBe(true);
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    expect(commit).toHaveBeenCalledTimes(1);

    resolveCommit();
    await vi.waitFor(() => expect(field.isConnected).toBe(false));
  });

  it("a rejected commit re-enables the field, keeps the typed value, and renders the message as .inline-error right after the row", async () => {
    const row = makeRow();
    document.body.appendChild(row);
    const commit = vi.fn().mockRejectedValue(new Error("'renamed.ts' already exists."));
    const onClose = vi.fn();
    beginInlineRowEdit({ row, initialValue: "", placeholder: "New file", commit, onClose });

    const field = fieldOf(row);
    field.value = "renamed.ts";
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    await vi.waitFor(() => expect(field.disabled).toBe(false));
    expect(onClose).not.toHaveBeenCalled(); // stays open
    expect(field.value).toBe("renamed.ts"); // value preserved
    const error = row.nextElementSibling as HTMLElement;
    expect(error.className).toBe("inline-error");
    expect(error.textContent).toBe("'renamed.ts' already exists.");
    expect(error.style.getPropertyValue("--depth")).toBe("2"); // copied from the row it follows
    row.remove();
  });

  it("a second commit attempt clears the previous error before retrying", async () => {
    const row = makeRow();
    document.body.appendChild(row);
    const commit = vi.fn().mockRejectedValueOnce(new Error("first failure")).mockResolvedValueOnce(undefined);
    beginInlineRowEdit({ row, initialValue: "", placeholder: "New file", commit, onClose: vi.fn() });

    const field = fieldOf(row);
    field.value = "a.ts";
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    await vi.waitFor(() => expect(row.nextElementSibling?.className).toBe("inline-error"));

    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    // The stale error is gone as soon as the retry starts, not just once it resolves.
    expect(row.nextElementSibling?.className).not.toBe("inline-error");
  });

  // The row this field takes over keeps its own click/keydown/contextmenu listeners; an event that
  // bubbled out of the field would drive the row behind it (see filesTreeMenu.test.ts for the
  // tree-level consequences). The field is what contains them.
  it("stops every pointer and key event it receives from reaching the row it took over", () => {
    const row = makeRow();
    document.body.appendChild(row);
    const seenByRow: string[] = [];
    for (const type of ["keydown", "keyup", "mousedown", "click", "dblclick", "contextmenu"]) {
      row.addEventListener(type, (event) => seenByRow.push(event.type));
    }
    beginInlineRowEdit({ row, initialValue: "x", placeholder: "Name", commit: vi.fn(), onClose: vi.fn() });

    const field = fieldOf(row);
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "a", bubbles: true, cancelable: true }));
    field.dispatchEvent(new KeyboardEvent("keyup", { key: "a", bubbles: true, cancelable: true }));
    for (const type of ["mousedown", "click", "dblclick", "contextmenu"]) {
      field.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true }));
    }

    expect(seenByRow).toEqual([]);
    row.remove();
  });

  it("runs onClose exactly once even when a stray event reaches the field after it already closed", async () => {
    const row = makeRow();
    document.body.appendChild(row);
    const commit = vi.fn().mockResolvedValue(undefined);
    const onClose = vi.fn();
    beginInlineRowEdit({ row, initialValue: "x", placeholder: "Name", commit, onClose });

    const field = fieldOf(row);
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    await vi.waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));

    // The field is detached from the row now, but its own listeners are still attached to it; a
    // stray Escape reaching it must not re-run onClose a second time.
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
    expect(onClose).toHaveBeenCalledTimes(1);
    row.remove();
  });
});
