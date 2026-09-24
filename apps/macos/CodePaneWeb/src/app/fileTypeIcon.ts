import { FILE_TYPE_ICON_SYMBOLS } from "./fileTypeIconSprite";
import { DEFAULT_FILE_TYPE_ICON, FILE_TYPE_ICON_BY_EXTENSION, FILE_TYPE_ICON_BY_NAME } from "./fileTypeIconTable";

/**
 * The file-type icon a file row carries between its disclosure slot and its name, in both the
 * Files tree (`filesTree.ts`) and the Changes list (`fileList.ts`). A directory row never takes
 * one: its chevron already says what it is.
 *
 * The art and every mapping come from the vscode-icons pack (MIT); `scripts/generate-file-type-icons.mjs`
 * resolves the pack's own manifest into the two tables and the sprite this module reads, so which
 * file gets which icon is the pack's answer rather than one written here. Icons keep the colors
 * the pack ships them in, which is what makes a row scannable by hue before its name is read.
 */
const SVG_NAMESPACE = "http://www.w3.org/2000/svg";

/**
 * The pack's icon for one file's BASENAME (never a path: a directory named `src.css` must not
 * decide the icon of a file below it). An exact-name match wins over an extension, so
 * `package.json` is the npm icon rather than the JSON one, and `.gitignore` is matched as a name
 * rather than read as an extension. Extensions are then tried longest first, so a compound
 * spelling the pack knows wins over its own tail. Matching is
 * case-insensitive, which the pack's tables are built for; a name the tables do not answer gets
 * the pack's default file icon.
 */
export function fileTypeIconID(name: string): string {
  const lower = name.toLowerCase();
  // Own-property reads: the tables are plain objects, so a file named `constructor` or `__proto__`
  // would otherwise answer with something inherited from `Object.prototype`.
  const byName = Object.hasOwn(FILE_TYPE_ICON_BY_NAME, lower) ? FILE_TYPE_ICON_BY_NAME[lower] : undefined;
  if (byName !== undefined) return byName;
  // From index 1, so a dotfile's leading dot never starts an extension: `.gitignore` that no name
  // rule answers is a name without an extension, not a `gitignore` extension.
  for (let dot = lower.indexOf(".", 1); dot !== -1; dot = lower.indexOf(".", dot + 1)) {
    const extension = lower.slice(dot + 1);
    const byExtension = Object.hasOwn(FILE_TYPE_ICON_BY_EXTENSION, extension) ? FILE_TYPE_ICON_BY_EXTENSION[extension] : undefined;
    if (byExtension !== undefined) return byExtension;
  }
  return DEFAULT_FILE_TYPE_ICON;
}

/**
 * The icon element for a file row, referencing the sprite mounted by `createFileTypeIconSprite`.
 * Purely presentational: the row's own name is what names the file's type, so the icon carries no
 * title, no tooltip and no tab stop, and is hidden from assistive technology.
 */
export function createFileTypeIcon(name: string): SVGSVGElement {
  const svg = document.createElementNS(SVG_NAMESPACE, "svg");
  svg.setAttribute("class", "ficon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(SVG_NAMESPACE, "use");
  use.setAttribute("href", `#file-type-icon-${fileTypeIconID(name)}`);
  svg.appendChild(use);
  return svg;
}

/**
 * The sprite every row's `<use>` resolves against: one `<symbol>` per shipped icon, inlined in the
 * bundle so a row costs no request and paints with the rest of the list. Mounted once per pane
 * (root.ts) rather than per list, since both lists reference the same symbols. Sized to nothing and
 * taken out of flow instead of hidden with `display: none`, so the symbols stay resolvable wherever
 * the pane puts it.
 */
export function createFileTypeIconSprite(): SVGSVGElement {
  const host = document.createElement("div");
  host.innerHTML = `<svg xmlns="${SVG_NAMESPACE}" class="ficon-sprite" width="0" height="0" aria-hidden="true">${FILE_TYPE_ICON_SYMBOLS}</svg>`;
  return host.firstElementChild as SVGSVGElement;
}
