import { describe, expect, it } from "vitest";
import { MAX_CONTAINER_CHILDREN } from "../src/app/jsonDocument";
import { renderJSONTree } from "../src/app/jsonTreeView";
import { parseStrictJSON } from "../src/app/previewMode";

/** Renders the document `json` spells, through the same parse the Editor feeds the tree, so every
 *  case exercises the values the tree actually receives (numbers carrying their source lexeme). */
function render(host: HTMLElement, json: string): void {
  renderJSONTree(host, parseStrictJSON(json)!.value);
}

function rows(host: HTMLElement): HTMLElement[] {
  return [...host.querySelectorAll<HTMLElement>(".json-row")];
}

function rowText(row: HTMLElement): string {
  return row.textContent ?? "";
}

function disclosureOf(row: HTMLElement): HTMLButtonElement {
  return row.querySelector<HTMLButtonElement>(".json-disclosure")!;
}

describe("renderJSONTree", () => {
  it("shows an object root's direct members", () => {
    const host = document.createElement("div");
    render(host, '{"a": 1, "b": "two"}');

    // Root row (the object itself) plus its two members.
    expect(rows(host)).toHaveLength(3);
    expect(rowText(rows(host)[1]!)).toContain('"a"');
    expect(rowText(rows(host)[2]!)).toContain('"b"');
  });

  it("starts a nested container collapsed, showing a member-count summary", () => {
    const host = document.createElement("div");
    render(host, '{"child": {"x": 1, "y": 2, "z": 3}}');

    const childRow = rows(host)[1]!;
    expect(rowText(childRow)).toContain("3 keys");
    expect(disclosureOf(childRow).getAttribute("aria-expanded")).toBe("false");
  });

  it("uses singular wording for a container with exactly one member", () => {
    const host = document.createElement("div");
    render(host, '{"arr": [1]}');

    expect(rowText(rows(host)[1]!)).toContain("1 item");
    expect(rowText(rows(host)[1]!)).not.toContain("1 items");
  });

  it("does not build a collapsed node's children until its first expand", () => {
    const host = document.createElement("div");
    render(host, '{"child": {"x": 1, "y": 2}}');

    // The root auto-expands (it always shows its direct members), so its own children container
    // (holding the "child" row) already exists; what must NOT exist yet is "child"'s own children
    // container, since "child" itself starts collapsed.
    const childRow = rows(host)[1]!;
    expect(childRow.nextElementSibling?.className).not.toBe("json-children");
  });

  it("expands a disclosure to reveal its children, and collapses them again on a second click", () => {
    const host = document.createElement("div");
    render(host, '{"child": {"x": 1, "y": 2}}');

    const childRow = rows(host)[1]!;
    const disclosure = disclosureOf(childRow);
    disclosure.click();

    expect(disclosure.getAttribute("aria-expanded")).toBe("true");
    expect(rows(host)).toHaveLength(4); // root, child, x, y
    const childrenHost = childRow.nextElementSibling as HTMLElement;
    expect(childrenHost.className).toBe("json-children");
    expect(childrenHost.style.display).not.toBe("none");

    disclosure.click();

    expect(disclosure.getAttribute("aria-expanded")).toBe("false");
    expect(childrenHost.style.display).toBe("none");
    // The rows stay in the DOM (rebuilding would be wasted work); they are only hidden.
    expect(rows(host)).toHaveLength(4);
  });

  it("does not rebuild children on a later expand", () => {
    const host = document.createElement("div");
    render(host, '{"child": {"x": 1}}');

    const childRow = rows(host)[1]!;
    const disclosure = disclosureOf(childRow);
    disclosure.click();
    const firstChildrenHost = childRow.nextElementSibling;
    disclosure.click();
    disclosure.click();
    const secondChildrenHost = childRow.nextElementSibling;

    expect(secondChildrenHost).toBe(firstChildrenHost);
  });

  it("names a disclosure button by its key and summary, and flips the name on toggle", () => {
    const host = document.createElement("div");
    render(host, '{"user": {"a": 1, "b": 2, "c": 3, "d": 4}}');

    const disclosure = disclosureOf(rows(host)[1]!);
    expect(disclosure.getAttribute("aria-label")).toBe("Expand user: object with 4 keys");

    disclosure.click();
    expect(disclosure.getAttribute("aria-label")).toBe("Collapse user: object with 4 keys");

    disclosure.click();
    expect(disclosure.getAttribute("aria-label")).toBe("Expand user: object with 4 keys");
  });

  it("names a disclosure inside an array by the member's position, since it has no key", () => {
    const host = document.createElement("div");
    render(host, '{"items": [[1, 2, 3], {"k": 1}]}');

    const itemsDisclosure = disclosureOf(rows(host)[1]!);
    expect(itemsDisclosure.getAttribute("aria-label")).toBe("Expand items: array of 2");

    itemsDisclosure.click();
    expect(disclosureOf(rows(host)[2]!).getAttribute("aria-label")).toBe("Expand item 0: array of 3");
    expect(disclosureOf(rows(host)[3]!).getAttribute("aria-label")).toBe("Expand item 1: object with 1 key");
  });

  it("shows an empty object/array with no disclosure control", () => {
    const host = document.createElement("div");
    render(host, '{"emptyObj": {}, "emptyArr": []}');

    const objRow = rows(host)[1]!;
    const arrRow = rows(host)[2]!;
    expect(rowText(objRow)).toContain("{}");
    expect(objRow.querySelector(".json-disclosure")).toBeNull();
    expect(rowText(arrRow)).toContain("[]");
    expect(arrRow.querySelector(".json-disclosure")).toBeNull();
  });

  it("gives strings, numbers, booleans and null their own classes with JSON-quoted text", () => {
    const host = document.createElement("div");
    render(host, '{"s": "hi", "n": 42, "b": true, "nul": null}');

    const [, sRow, nRow, bRow, nulRow] = rows(host);
    expect(sRow!.querySelector(".json-string")!.textContent).toBe('"hi"');
    expect(nRow!.querySelector(".json-number")!.textContent).toBe("42");
    expect(bRow!.querySelector(".json-keyword")!.textContent).toBe("true");
    expect(nulRow!.querySelector(".json-keyword")!.textContent).toBe("null");
  });

  it("prints every number exactly as the file writes it, past what a double can hold", () => {
    const host = document.createElement("div");
    render(host, '{"big": 9007199254740993, "exact": 1.0, "huge": 1e400, "wide": 123456789012345678901234567890, "neg": -0.5}');

    expect([...host.querySelectorAll(".json-number")].map((el) => el.textContent)).toEqual([
      "9007199254740993",
      "1.0",
      "1e400",
      "123456789012345678901234567890",
      "-0.5",
    ]);
  });

  it("renders an object whose members name another parser's number box as the object it is", () => {
    const host = document.createElement("div");
    render(host, '{"boxed": {"isLosslessNumber": true, "value": "7"}}');

    const boxedRow = rows(host)[1]!;
    expect(rowText(boxedRow)).toContain("2 keys");
    disclosureOf(boxedRow).click();

    expect(rows(host).slice(2).map(rowText)).toEqual(['"isLosslessNumber":true', '"value":"7"']);
  });

  it("renders a repeated key once, holding its last value in the first occurrence's position", () => {
    const host = document.createElement("div");
    render(host, '{"a": 1, "b": 2, "a": 3}');

    expect(rows(host).slice(1).map(rowText)).toEqual(['"a":3', '"b":2']);
  });

  it("renders a __proto__ member as an ordinary member", () => {
    const host = document.createElement("div");
    render(host, '{"__proto__": 1, "after": 2}');

    expect(rows(host).slice(1).map(rowText)).toEqual(['"__proto__":1', '"after":2']);
  });

  it("renders an array root's items with no key prefix", () => {
    const host = document.createElement("div");
    render(host, "[1, 2]");

    expect(rows(host)).toHaveLength(3); // root array, item 0, item 1
    expect(rows(host)[1]!.querySelector(".json-key")).toBeNull();
  });

  it("replaces the host's previous content on re-render", () => {
    const host = document.createElement("div");
    render(host, '{"a": 1}');
    render(host, '{"b": 2}');

    expect(rows(host)).toHaveLength(2);
    expect(rowText(rows(host)[1]!)).toContain('"b"');
  });

  it("builds the children the parse retained and says how many the file holds", () => {
    const host = document.createElement("div");
    render(host, JSON.stringify(Array.from({ length: 2500 }, (_, index) => index)));

    // The expanded root, its first 2000 items, and the trailing note.
    expect(rows(host)).toHaveLength(2002);
    expect(host.querySelectorAll(".json-truncated")).toHaveLength(1);
    expect(host.querySelector(".json-truncated")!.textContent).toBe("2000 of 2500 items shown");
    expect(rowText(rows(host)[2000]!)).toBe("1999");
    expect(rowText(rows(host)[0]!)).toContain("2500 items");
  });

  it("reads the counts it reports off the model rather than what it was handed", () => {
    // What a capped parse produces: two retained items standing for a container of a thousand.
    const host = document.createElement("div");
    renderJSONTree(host, {
      kind: "array",
      items: [{ kind: "number", lexeme: "1" }, { kind: "number", lexeme: "2" }],
      count: 1000,
    });

    expect(rowText(rows(host)[0]!)).toContain("1000 items");
    expect(host.querySelector(".json-truncated")!.textContent).toBe("2 of 1000 items shown");
    expect(rows(host)).toHaveLength(4); // root, two items, the note
  });

  it("caps a nested container the same way, on its first expand", () => {
    const host = document.createElement("div");
    render(host, JSON.stringify({ items: Array.from({ length: 2500 }, (_, index) => index) }));
    expect(host.querySelector(".json-truncated")).toBeNull(); // nothing is built while it is collapsed

    disclosureOf(rows(host)[1]!).click();

    expect(host.querySelector(".json-truncated")!.textContent).toBe("2000 of 2500 items shown");
  });

  it("adds no note to a container at or below the cap", () => {
    const host = document.createElement("div");
    render(host, JSON.stringify(Array.from({ length: MAX_CONTAINER_CHILDREN }, (_, index) => index)));

    expect(rows(host)).toHaveLength(MAX_CONTAINER_CHILDREN + 1);
    expect(host.querySelector(".json-truncated")).toBeNull();
  });
});
