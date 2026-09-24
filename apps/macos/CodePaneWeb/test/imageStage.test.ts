import { describe, expect, it, vi } from "vitest";
import { renderImageStage } from "../src/app/imageStage";

describe("renderImageStage", () => {
  it("builds the stage with an <img> and reports the decoded natural size on load", () => {
    const host = document.createElement("div");
    const onLoaded = vi.fn();

    renderImageStage(host, "data:image/png;base64,AAAA", onLoaded);

    const stage = host.querySelector(".image-stage")!;
    const img = stage.querySelector<HTMLImageElement>("img.image-stage-picture")!;
    expect(img).not.toBeNull();
    expect(img.alt).toBe("");
    expect(img.src).toContain("data:image/png;base64,AAAA");

    Object.defineProperty(img, "naturalWidth", { value: 640, configurable: true });
    Object.defineProperty(img, "naturalHeight", { value: 480, configurable: true });
    img.dispatchEvent(new Event("load"));

    expect(onLoaded).toHaveBeenCalledTimes(1);
    expect(onLoaded).toHaveBeenCalledWith({ width: 640, height: 480 });
  });

  it("shows a muted failure message and reports nothing on a decode error", () => {
    const host = document.createElement("div");
    const onLoaded = vi.fn();

    renderImageStage(host, "data:image/png;base64,not-really-an-image", onLoaded);
    const img = host.querySelector("img.image-stage-picture")!;
    img.dispatchEvent(new Event("error"));

    expect(onLoaded).not.toHaveBeenCalled();
    expect(host.querySelector("img")).toBeNull();
    expect(host.querySelector(".image-stage-error")!.textContent).toBe("This image could not be displayed.");
  });

  it("replaces the host's previous content on re-render", () => {
    const host = document.createElement("div");
    renderImageStage(host, "data:image/png;base64,AAAA", vi.fn());
    renderImageStage(host, "data:image/png;base64,BBBB", vi.fn());

    expect(host.querySelectorAll(".image-stage")).toHaveLength(1);
  });
});
