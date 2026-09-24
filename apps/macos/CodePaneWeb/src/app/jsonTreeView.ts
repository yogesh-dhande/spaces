/**
 * The Editor's read-only JSON tree preview: a collapsible, lazily-expanded view of a parsed JSON
 * document. Only reachable for a `.json` file whose content is strict JSON (`jsonTreeDocument` in
 * previewMode.ts); this module trusts the caller and renders whatever `value` it is given.
 *
 * The document reaching it is `jsonDocument.ts`'s own model, where every value carries its own
 * `kind` tag and a number carries the lexeme the file wrote rather than a JavaScript `number`. The
 * tree prints that lexeme, which is what makes a value outside the safe integer range, or one
 * written `1.00`, read exactly as the file has it.
 *
 * A container arrives already bounded: the parser retains only as many members as the tree can
 * build rows for and counts the rest, so this module renders every member it is handed and reads
 * the real total off the model for its trailing note.
 */

import { JSONMember, JSONValue } from "./jsonDocument";

/**
 * An object or array node, holding just the pieces `renderJSONTree` needs to describe and expand
 * it: which shape it is, its retained members in source order, and how many members the document
 * gave it. The parser retains at most `MAX_CONTAINER_CHILDREN` of them, and only as many as the
 * document's own `MAX_DOCUMENT_NODES` budget still admits (`jsonDocument.ts`), so the two differ
 * exactly where a container ran past either bound, and the trailing note reports both.
 */
type Container =
  | { type: "object"; entries: JSONMember[]; count: number }
  | { type: "array"; items: JSONValue[]; count: number };

/**
 * How a node is identified by the container holding it: an object member by its key, an array
 * member by its index, or nothing at all for the root. Only a key renders a prefix on the row; the
 * index is carried so a disclosure button inside an array can still say which member it opens.
 */
type NodeLabel = { kind: "key"; key: string } | { kind: "index"; index: number } | undefined;

/** The container `value` is, or `undefined` for a leaf. */
function classifyContainer(value: JSONValue): Container | undefined {
  if (value.kind === "object") return { type: "object", entries: value.entries, count: value.count };
  if (value.kind === "array") return { type: "array", items: value.items, count: value.count };
  return undefined;
}

/** How many of the container's members the tree can build rows for: everything the parser kept. */
function renderedCount(container: Container): number {
  return container.type === "array" ? container.items.length : container.entries.length;
}

/** The collapsed-state summary text: `{…} 3 keys` for an object, `[…] 5 items` for an array,
 *  singular for exactly one member. Only called for a non-empty container; an empty one shows
 *  `{}`/`[]` instead (see `appendEmptyContainerRow`). */
function summaryText(container: Container, count: number): string {
  if (container.type === "array") return `[…] ${count} item${count === 1 ? "" : "s"}`;
  return `{…} ${count} key${count === 1 ? "" : "s"}`;
}

/** The same summary said in words, for the disclosure button's accessible name. The visible summary
 *  leads with `{…}`/`[…]`, which a screen reader reads as punctuation rather than as the shape it
 *  stands for; this names the shape and the same count instead. */
function spokenSummary(container: Container, count: number): string {
  if (container.type === "array") return `array of ${count}`;
  return `object with ${count} key${count === 1 ? "" : "s"}`;
}

/** What the disclosure button calls the node it opens: the object key, or an array member's
 *  position. The root belongs to no container and is named as such. */
function spokenName(label: NodeLabel): string {
  if (label === undefined) return "root";
  return label.kind === "key" ? label.key : `item ${label.index}`;
}

/** A leaf value's syntax class: JSON's own value kinds, string/number/boolean/null, map onto the
 *  three token colors the tree distinguishes (`json-string`, `json-number`, and `json-keyword` for
 *  the two that read as fixed vocabulary rather than data, booleans and null). */
function leafClass(value: JSONValue): string {
  if (value.kind === "string") return "json-string";
  if (value.kind === "number") return "json-number";
  return "json-keyword";
}

/** A leaf value's printed text. A number prints its source lexeme; a string prints its JSON form,
 *  which re-escapes exactly what the file quoted. */
function leafText(value: JSONValue): string {
  switch (value.kind) {
    case "number":
      return value.lexeme;
    case "string":
      return JSON.stringify(value.value);
    case "boolean":
      return value.value ? "true" : "false";
    default:
      return "null";
  }
}

/** Appends the row's key prefix (`"key":`) when the node is an object member. An array's items are
 *  identified by position rather than by a key, so this is a no-op for them; a leaf and a container
 *  row both call it identically. */
function appendKeyPrefix(row: HTMLElement, label: NodeLabel): void {
  if (label === undefined || label.kind !== "key") return;
  const keySpan = document.createElement("span");
  keySpan.className = "json-key";
  keySpan.textContent = JSON.stringify(label.key);
  row.appendChild(keySpan);
  const punct = document.createElement("span");
  punct.className = "json-punct";
  punct.textContent = ":";
  row.appendChild(punct);
}

function newRow(depth: number): HTMLElement {
  const row = document.createElement("div");
  row.className = "json-row";
  row.style.setProperty("--json-depth", String(depth));
  return row;
}

function appendLeafRow(parent: HTMLElement, value: JSONValue, label: NodeLabel, depth: number): void {
  const row = newRow(depth);
  appendKeyPrefix(row, label);
  const valueSpan = document.createElement("span");
  valueSpan.className = leafClass(value);
  valueSpan.textContent = leafText(value);
  row.appendChild(valueSpan);
  parent.appendChild(row);
}

/** The muted last row of a container whose members ran past one of the parser's retention budgets,
 *  naming how many of them the tree actually built and how many the file holds. */
function appendTruncationRow(parent: HTMLElement, rendered: number, count: number, depth: number): void {
  const row = newRow(depth);
  const note = document.createElement("span");
  note.className = "json-truncated";
  note.textContent = `${rendered} of ${count} items shown`;
  row.appendChild(note);
  parent.appendChild(row);
}

function appendEmptyContainerRow(parent: HTMLElement, container: Container, label: NodeLabel, depth: number): void {
  const row = newRow(depth);
  appendKeyPrefix(row, label);
  const summary = document.createElement("span");
  summary.className = "json-summary";
  summary.textContent = container.type === "array" ? "[]" : "{}";
  row.appendChild(summary);
  parent.appendChild(row);
}

/**
 * Appends one node (its row, and lazily its children) to `parent`. `expanded` controls only the
 * node's initial state; the disclosure button owns every state change after that.
 *
 * Children are built on first expand rather than up front: a large document's collapsed members
 * cost only their own row, not their entire subtree, until the user actually opens them.
 */
function appendNode(parent: HTMLElement, value: JSONValue, label: NodeLabel, depth: number, expanded: boolean): void {
  const container = classifyContainer(value);
  if (container === undefined) {
    appendLeafRow(parent, value, label, depth);
    return;
  }
  const count = container.count;
  if (count === 0) {
    appendEmptyContainerRow(parent, container, label, depth);
    return;
  }

  const row = newRow(depth);
  const disclosure = document.createElement("button");
  disclosure.type = "button";
  disclosure.className = "json-disclosure";
  row.appendChild(disclosure);
  appendKeyPrefix(row, label);
  const summary = document.createElement("span");
  summary.className = "json-summary";
  summary.textContent = summaryText(container, count);
  row.appendChild(summary);
  parent.appendChild(row);

  let childrenHost: HTMLElement | undefined;
  let isExpanded = false;

  /** Keeps the button's glyph and its announced state and name on the same truth. The glyph alone
   *  is all the button contains, so without the name a screen reader reads every disclosure in the
   *  document as the same triangle. */
  const syncDisclosure = (): void => {
    disclosure.textContent = isExpanded ? "▾" : "▸"; // ▾ / ▸
    disclosure.setAttribute("aria-expanded", isExpanded ? "true" : "false");
    const action = isExpanded ? "Collapse" : "Expand";
    disclosure.setAttribute("aria-label", `${action} ${spokenName(label)}: ${spokenSummary(container, count)}`);
  };

  const expand = (): void => {
    isExpanded = true;
    syncDisclosure();
    if (childrenHost === undefined) {
      const children = document.createElement("div");
      children.className = "json-children";
      if (container.type === "array") {
        for (const [index, item] of container.items.entries()) {
          appendNode(children, item, { kind: "index", index }, depth + 1, false);
        }
      } else {
        for (const entry of container.entries) {
          appendNode(children, entry.value, { kind: "key", key: entry.key }, depth + 1, false);
        }
      }
      const rendered = renderedCount(container);
      if (count > rendered) appendTruncationRow(children, rendered, count, depth + 1);
      row.insertAdjacentElement("afterend", children);
      childrenHost = children;
    }
    childrenHost.style.display = "";
  };

  const collapse = (): void => {
    isExpanded = false;
    syncDisclosure();
    if (childrenHost !== undefined) childrenHost.style.display = "none";
  };

  disclosure.addEventListener("click", () => (isExpanded ? collapse() : expand()));
  syncDisclosure();

  if (expanded) expand();
}

/** Renders `value` as a read-only collapsible tree into `host`, replacing whatever it held. The
 *  root node is expanded; every nested container starts collapsed. */
export function renderJSONTree(host: HTMLElement, value: JSONValue): void {
  host.textContent = "";
  appendNode(host, value, undefined, 0, true);
}
