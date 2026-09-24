import { describe, expect, it, vi } from "vitest";
import { PreviewModeSegment } from "../src/app/previewMode";
import { PreviewModeControl } from "../src/app/modeControl";

const MARKDOWN_SEGMENTS: PreviewModeSegment[] = [
  { mode: "split", label: "Split", enabled: true },
  { mode: "source", label: "Source", enabled: true },
  { mode: "preview", label: "Preview", enabled: true },
];

const JSON_SEGMENTS_TREE_UNAVAILABLE: PreviewModeSegment[] = [
  { mode: "tree", label: "Tree", enabled: false },
  { mode: "text", label: "Text", enabled: true },
];

function segButtons(control: PreviewModeControl): HTMLButtonElement[] {
  return [...control.element.querySelectorAll<HTMLButtonElement>("button.seg")];
}

describe("PreviewModeControl", () => {
  it("renders one button per segment with the segment's label", () => {
    const control = new PreviewModeControl(vi.fn());
    control.render(MARKDOWN_SEGMENTS, "split");

    expect(segButtons(control).map((b) => b.textContent)).toEqual(["Split", "Source", "Preview"]);
    expect(segButtons(control).map((b) => b.dataset.mode)).toEqual(["split", "source", "preview"]);
  });

  it("marks the selected segment aria-pressed=true and the rest false", () => {
    const control = new PreviewModeControl(vi.fn());
    control.render(MARKDOWN_SEGMENTS, "preview");

    const [split, source, preview] = segButtons(control);
    expect(split!.getAttribute("aria-pressed")).toBe("false");
    expect(source!.getAttribute("aria-pressed")).toBe("false");
    expect(preview!.getAttribute("aria-pressed")).toBe("true");
  });

  it("renders a disabled segment as disabled, still visible, with its reason in the title", () => {
    const control = new PreviewModeControl(vi.fn());
    control.render(JSON_SEGMENTS_TREE_UNAVAILABLE, "text");

    const [tree, text] = segButtons(control);
    expect(tree!.disabled).toBe(true);
    expect(tree!.title).toBe("Needs strict JSON");
    expect(text!.disabled).toBe(false);
  });

  it("calls back with the clicked segment's mode when it is enabled and not already selected", () => {
    const onSelect = vi.fn();
    const control = new PreviewModeControl(onSelect);
    control.render(MARKDOWN_SEGMENTS, "split");

    segButtons(control)[1]!.click(); // "Source"

    expect(onSelect).toHaveBeenCalledTimes(1);
    expect(onSelect).toHaveBeenCalledWith("source");
  });

  it("does not call back when clicking the already-selected segment", () => {
    const onSelect = vi.fn();
    const control = new PreviewModeControl(onSelect);
    control.render(MARKDOWN_SEGMENTS, "split");

    segButtons(control)[0]!.click(); // "Split", already selected

    expect(onSelect).not.toHaveBeenCalled();
  });

  it("does not call back when clicking a disabled segment", () => {
    const onSelect = vi.fn();
    const control = new PreviewModeControl(onSelect);
    control.render(JSON_SEGMENTS_TREE_UNAVAILABLE, "text");

    segButtons(control)[0]!.click(); // "Tree", disabled

    expect(onSelect).not.toHaveBeenCalled();
  });

  it("hides the control entirely when given an empty segment list", () => {
    const control = new PreviewModeControl(vi.fn());
    control.render(MARKDOWN_SEGMENTS, "split");
    expect(control.element.style.display).not.toBe("none");

    control.render([], undefined);

    expect(control.element.style.display).toBe("none");
    expect(segButtons(control)).toHaveLength(0);
  });

  it("reuses the same button nodes across a re-render with the same segments, updating them in place", () => {
    const control = new PreviewModeControl(vi.fn());
    control.render(MARKDOWN_SEGMENTS, "split");
    const before = segButtons(control);

    control.render(MARKDOWN_SEGMENTS, "preview");
    const after = segButtons(control);

    expect(after).toEqual(before); // same nodes, not rebuilt
    expect(after.map((b) => b.getAttribute("aria-pressed"))).toEqual(["false", "false", "true"]);
  });

  it("drops a button whose mode is no longer offered and keeps the ones that remain", () => {
    const control = new PreviewModeControl(vi.fn());
    control.render(JSON_SEGMENTS_TREE_UNAVAILABLE, "text");
    const text = segButtons(control)[1]!;

    control.render(MARKDOWN_SEGMENTS, "split");

    expect(segButtons(control).map((b) => b.dataset.mode)).toEqual(["split", "source", "preview"]);
    expect(text.isConnected).toBe(false);
  });

  it("keeps focus on the activated segment's button across the re-render its own activation triggers", () => {
    // Mirrors EditorView.selectPreviewMode: activating a segment repaints this control on the same
    // tick, while the just-activated button still holds focus. jsdom only tracks
    // document.activeElement for a connected node, so the control is attached to the document here.
    const control = new PreviewModeControl((mode) => control.render(MARKDOWN_SEGMENTS, mode));
    document.body.appendChild(control.element);
    control.render(MARKDOWN_SEGMENTS, "split");

    const sourceBtn = segButtons(control)[1]!; // "Source"
    sourceBtn.focus();
    sourceBtn.click(); // stands in for both a mouse click and an Enter/Space key activation

    expect(document.activeElement).toBe(sourceBtn);
    expect(sourceBtn.getAttribute("aria-pressed")).toBe("true");

    control.element.remove();
  });
});
