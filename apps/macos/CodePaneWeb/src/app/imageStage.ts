/**
 * The Editor's image/SVG stage. Reachable for the six raster image extensions `previewMode.ts`
 * recognizes and for `.svg` (see `previewKind`), which is why this renders a data URL rather than a
 * path: the SVG preview builds a `data:image/svg+xml;charset=utf-8,...` URL from the live source buffer and
 * hands it to the same stage a raster image uses, instead of injecting the SVG markup inline. An
 * `<img>` decodes SVG as a static image: it never runs the document's script or fetches its
 * subresources, where inline SVG markup would execute as live content in the page's own DOM.
 */

export interface ImagePixelSize {
  width: number;
  height: number;
}

/** Renders `dataURL` on the stage in `host`, fit inside it without upscaling past its natural size.
 *  `onLoaded` reports the decoded pixel size once the browser has it, for the open-file bar. */
export function renderImageStage(host: HTMLElement, dataURL: string, onLoaded: (size: ImagePixelSize) => void): void {
  host.textContent = "";

  const stage = document.createElement("div");
  stage.className = "image-stage";

  const img = document.createElement("img");
  img.className = "image-stage-picture";
  img.alt = "";

  img.addEventListener("load", () => {
    onLoaded({ width: img.naturalWidth, height: img.naturalHeight });
  });

  img.addEventListener("error", () => {
    stage.textContent = "";
    const message = document.createElement("div");
    message.className = "image-stage-error";
    message.textContent = "This image could not be displayed.";
    stage.appendChild(message);
  });

  stage.appendChild(img);
  host.appendChild(stage);
  // Set last: the element is already in the document by the time decoding starts, so a
  // synchronous `load`/`error` dispatch (as jsdom and some real loads produce) still finds its
  // listeners attached.
  img.src = dataURL;
}
