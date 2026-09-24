import { describe, expect, it } from "vitest";
import {
  JSONDepthError,
  JSONSyntaxError,
  JSONValue,
  MAX_CONTAINER_CHILDREN,
  MAX_DOCUMENT_NODES,
  MAX_NESTING_DEPTH,
  parseJSONDocument,
} from "../src/app/jsonDocument";

/** A document nesting `depth` empty arrays inside one another, down to a single number: parses to
 *  `depth` levels of `{ kind: "array" }` wrapping `{ kind: "number", lexeme: "1" }`. */
function nestedArray(depth: number): string {
  return "[".repeat(depth) + "1" + "]".repeat(depth);
}

/** The members of an object value, as `key -> printed shape`, so a case can assert order and value
 *  together without restating the whole tagged model. */
function members(value: JSONValue): [string, JSONValue][] {
  if (value.kind !== "object") throw new Error(`expected an object, got ${value.kind}`);
  return value.entries.map((entry) => [entry.key, entry.value]);
}

/** The retained items of an array value, so a case can read what a container kept. */
function itemsOf(value: JSONValue): JSONValue[] {
  if (value.kind !== "array") throw new Error(`expected an array, got ${value.kind}`);
  return value.items;
}

/** Every member a container was given, retained or counted past a retention budget. */
function containerCount(value: JSONValue): number {
  if (value.kind !== "object" && value.kind !== "array") throw new Error(`expected a container, got ${value.kind}`);
  return value.count;
}

describe("parseJSONDocument: values", () => {
  it("tags each JSON value kind, keeping a string's decoded text", () => {
    expect(parseJSONDocument('"hi"')).toEqual({ kind: "string", value: "hi" });
    expect(parseJSONDocument("true")).toEqual({ kind: "boolean", value: true });
    expect(parseJSONDocument("false")).toEqual({ kind: "boolean", value: false });
    expect(parseJSONDocument("null")).toEqual({ kind: "null" });
    expect(parseJSONDocument("{}")).toEqual({ kind: "object", entries: [], count: 0 });
    expect(parseJSONDocument("[]")).toEqual({ kind: "array", items: [], count: 0 });
  });

  it("keeps every number as the exact text the document wrote, past what a double can hold", () => {
    const value = parseJSONDocument('[9007199254740993, 1.0, 1e400, 123456789012345678901234567890, -0.5, 1E-7]');
    expect(value).toEqual({
      kind: "array",
      items: [
        { kind: "number", lexeme: "9007199254740993" },
        { kind: "number", lexeme: "1.0" },
        { kind: "number", lexeme: "1e400" },
        { kind: "number", lexeme: "123456789012345678901234567890" },
        { kind: "number", lexeme: "-0.5" },
        { kind: "number", lexeme: "1E-7" },
      ],
      count: 6,
    });
  });

  it("decodes the escapes JSON defines, including a lone surrogate the way JSON.parse keeps it", () => {
    expect(parseJSONDocument('"a\\"b\\\\c\\/d\\be\\ff\\ng\\rh\\ti"')).toEqual({
      kind: "string",
      value: 'a"b\\c/d\be\ff\ng\rh\ti',
    });
    expect(parseJSONDocument('"\\u00e9"')).toEqual({ kind: "string", value: "é" });
    expect(parseJSONDocument('"\\ud83d\\ude00"')).toEqual({ kind: "string", value: "😀" });
    // A lone high surrogate is accepted and kept, exactly as JSON.parse accepts and keeps it.
    expect(parseJSONDocument('"\\ud800"')).toEqual({ kind: "string", value: "\ud800" });
    expect(JSON.parse('"\\ud800"')).toBe("\ud800");
  });

  it("ignores JSON's whitespace between tokens, anywhere it is allowed", () => {
    expect(parseJSONDocument(' \t\r\n{ "a" : [ 1 , 2 ] } \n')).toEqual({
      kind: "object",
      entries: [
        {
          key: "a",
          value: {
            kind: "array",
            items: [{ kind: "number", lexeme: "1" }, { kind: "number", lexeme: "2" }],
            count: 2,
          },
        },
      ],
      count: 1,
    });
  });
});

describe("parseJSONDocument: object members", () => {
  it("keeps members in source order", () => {
    expect(members(parseJSONDocument('{"b": 1, "a": 2}')).map(([key]) => key)).toEqual(["b", "a"]);
  });

  it("lets a repeated key's last value win while it keeps the first occurrence's position", () => {
    // Exactly what JSON.parse does, since an object built by assignment overwrites in place.
    const parsed = members(parseJSONDocument('{"a": 1, "b": 2, "a": 3}'));
    expect(parsed).toEqual([
      ["a", { kind: "number", lexeme: "3" }],
      ["b", { kind: "number", lexeme: "2" }],
    ]);
    expect(Object.entries(JSON.parse('{"a": 1, "b": 2, "a": 3}'))).toEqual([
      ["a", 3],
      ["b", 2],
    ]);
  });

  it("treats __proto__ as an ordinary member rather than a write through the prototype", () => {
    // Nothing here materializes a JavaScript object, so the key cannot reach a prototype setter:
    // it is an entry in a list like any other, in the position the document wrote it.
    const parsed = members(parseJSONDocument('{"__proto__": {"polluted": true}, "after": 1}'));
    expect(parsed.map(([key]) => key)).toEqual(["__proto__", "after"]);
    expect(parsed[0]![1]).toEqual({
      kind: "object",
      entries: [{ key: "polluted", value: { kind: "boolean", value: true } }],
      count: 1,
    });
    expect(Object.getPrototypeOf(parsed[0]![1])).toBe(Object.prototype);
  });

  it("keeps a member whose value looks like another parser's internal number box", () => {
    const parsed = members(parseJSONDocument('{"isLosslessNumber": true, "value": "7"}'));
    expect(parsed).toEqual([
      ["isLosslessNumber", { kind: "boolean", value: true }],
      ["value", { kind: "string", value: "7" }],
    ]);
  });
});

describe("parseJSONDocument: rejections", () => {
  /** Every case a strict `JSON.parse` refuses, refused here too and with the same verdict. */
  it.each([
    ["a trailing comma in an object", '{"a": 1,}'],
    ["a trailing comma in an array", "[1, 2,]"],
    ["a line comment", '{"a": 1} // note'],
    ["a block comment", '{/* note */ "a": 1}'],
    ["single quotes", "{'a': 1}"],
    ["an unquoted key", "{a: 1}"],
    ["a leading zero", "01"],
    ["a bare fraction", ".5"],
    ["a trailing decimal point", "1."],
    ["an exponent with no digits", "1e"],
    ["an unterminated string", '"abc'],
    ["a raw newline inside a string", '"a\nb"'],
    ["an invalid escape", '"\\x41"'],
    ["a short unicode escape", '"\\u12"'],
    ["an unterminated object", "{"],
    ["two documents", "{} {}"],
    ["nothing at all", ""],
    ["whitespace alone", "  \n "],
  ])("refuses %s", (_name, content) => {
    expect(() => parseJSONDocument(content)).toThrow(JSONSyntaxError);
    expect(() => JSON.parse(content)).toThrow(SyntaxError);
  });

  it("reports a syntax error as a SyntaxError carrying the offset it gave up at", () => {
    let thrown: unknown;
    try {
      parseJSONDocument('{"a": 1,}');
    } catch (error) {
      thrown = error;
    }

    expect(thrown).toBeInstanceOf(SyntaxError);
    const error = thrown as JSONSyntaxError;
    expect(error.offset).toBe(8); // the `}` that followed the comma
    expect(error.message).toContain("offset 8");
  });
});

describe("parseJSONDocument: container retention", () => {
  /** A document whose root array holds `length` copies of `item`. */
  function arrayOf(length: number, item: (index: number) => string): string {
    return `[${Array.from({ length }, (_unused, index) => item(index)).join(",")}]`;
  }

  /** The array value `parseJSONDocument` produced, so a case can read its retained items and count
   *  without restating the tagged model. */
  function asArray(value: JSONValue): { items: JSONValue[]; count: number } {
    if (value.kind !== "array") throw new Error(`expected an array, got ${value.kind}`);
    return value;
  }

  it("retains only the budgeted items of a long array while counting every one of them", () => {
    const parsed = asArray(parseJSONDocument(arrayOf(5000, (index) => String(index))));

    expect(parsed.items).toHaveLength(MAX_CONTAINER_CHILDREN);
    expect(parsed.count).toBe(5000);
    expect(parsed.items[0]).toEqual({ kind: "number", lexeme: "0" });
    expect(parsed.items[MAX_CONTAINER_CHILDREN - 1]).toEqual({ kind: "number", lexeme: "1999" });
  });

  it("retains only the budgeted members of a wide object while counting every key", () => {
    const content = `{${Array.from({ length: 3000 }, (_unused, index) => `"k${index}": ${index}`).join(",")}}`;
    const parsed = parseJSONDocument(content);

    expect(members(parsed)).toHaveLength(MAX_CONTAINER_CHILDREN);
    expect(containerCount(parsed)).toBe(3000);
    expect(members(parsed)[MAX_CONTAINER_CHILDREN - 1]![0]).toBe(`k${MAX_CONTAINER_CHILDREN - 1}`);
  });

  it("builds no model for a container past the cap, however large the document is", () => {
    // Every item is itself a container, so a model per item would be a model per nested object too.
    const parsed = asArray(parseJSONDocument(arrayOf(5000, (index) => `{"id": ${index}, "tags": [1, 2]}`)));

    expect(parsed.items).toHaveLength(MAX_CONTAINER_CHILDREN);
    expect(parsed.count).toBe(5000);
    expect(parsed.items.every((item) => item.kind === "object")).toBe(true);
  });

  it("still reports a syntax error that lies past the cap, at its offset", () => {
    const content = `${arrayOf(4000, (index) => String(index)).slice(0, -1)},01]`;
    let thrown: unknown;
    try {
      parseJSONDocument(content);
    } catch (error) {
      thrown = error;
    }

    expect(thrown).toBeInstanceOf(JSONSyntaxError);
    // The `1` that followed the leading zero, which JSON reads as a second token.
    expect((thrown as JSONSyntaxError).offset).toBe(content.length - 2);
    expect(() => JSON.parse(content)).toThrow(SyntaxError);
  });

  it("still reports a syntax error nested inside a value it skipped", () => {
    const content = `${arrayOf(2500, (index) => `{"deep": [${index}]}`).slice(0, -1)},{"deep": [1,]}]`;

    expect(() => parseJSONDocument(content)).toThrow(JSONSyntaxError);
    expect(() => JSON.parse(content)).toThrow(SyntaxError);
  });

  it("lets a repeat of a retained key past the cap update that key's value", () => {
    const tail = `"k0": "last"`;
    const content = `{${Array.from({ length: 3000 }, (_unused, index) => `"k${index}": ${index}`).join(",")},${tail}}`;
    const parsed = parseJSONDocument(content);

    expect(members(parsed)[0]).toEqual(["k0", { kind: "string", value: "last" }]);
    expect(members(parsed)).toHaveLength(MAX_CONTAINER_CHILDREN);
    // The repeat resolved into a member already counted, so it is not a member of its own.
    expect(containerCount(parsed)).toBe(3000);
    expect(JSON.parse(content).k0).toBe("last");
  });

  it("counts a key first seen past the cap without retaining it", () => {
    const content = `{${Array.from({ length: 2500 }, (_unused, index) => `"k${index}": ${index}`).join(",")}}`;
    const parsed = parseJSONDocument(content);

    expect(members(parsed).map(([key]) => key)).not.toContain("k2400");
    expect(containerCount(parsed)).toBe(2500);
  });
});

describe("parseJSONDocument: document retention budget", () => {
  /** Every model the parse built, at every depth: exactly what `MAX_DOCUMENT_NODES` bounds. */
  function retainedNodes(value: JSONValue): number {
    if (value.kind === "array") return 1 + value.items.reduce((total, item) => total + retainedNodes(item), 0);
    if (value.kind === "object") return 1 + value.entries.reduce((total, entry) => total + retainedNodes(entry.value), 0);
    return 1;
  }

  /** A 2000 x 2000 matrix of scalars, about 8 MiB of text in which every container sits inside the
   *  per-container cap while the document as a whole holds about four million values. */
  function matrixDocument(): string {
    const row = `[${Array.from({ length: 2000 }, (_unused, index) => String(index % 10)).join(",")}]`;
    return `[${Array.from({ length: 2000 }, () => row).join(",")}]`;
  }

  it("bounds a matrix whose every container is inside the per-container cap", () => {
    const parsed = parseJSONDocument(matrixDocument());

    expect(retainedNodes(parsed)).toBeLessThanOrEqual(MAX_DOCUMENT_NODES);
    expect(containerCount(parsed)).toBe(2000);
    // The budget stops the retention part way through the matrix, so the rows it did build are the
    // ones the tree shows and the outer note names the file's real row count against them.
    expect(itemsOf(parsed).length).toBeGreaterThan(0);
    expect(itemsOf(parsed).length).toBeLessThan(2000);
  });

  it("counts every member of a row it started, whether or not that member was retained", () => {
    const parsed = parseJSONDocument(matrixDocument());

    for (const row of itemsOf(parsed)) {
      expect(containerCount(row)).toBe(2000);
    }
  });

  it("still reports a syntax error that lies past the budget, at its offset", () => {
    const row = `[${Array.from({ length: 2000 }, (_unused, index) => String(index % 10)).join(",")}]`;
    // 200 rows keeps every container inside the per-container cap, so the budget is what stops the
    // retention, and the last row is well past the point where it did.
    const rows = [...Array.from({ length: 199 }, () => row), "[1,01]"];
    const content = `[${rows.join(",")}]`;
    let thrown: unknown;
    try {
      parseJSONDocument(content);
    } catch (error) {
      thrown = error;
    }

    expect(thrown).toBeInstanceOf(JSONSyntaxError);
    // The `1` that followed the leading zero, which JSON reads as a second token.
    expect((thrown as JSONSyntaxError).offset).toBe(content.length - 3);
    expect(() => JSON.parse(content)).toThrow(SyntaxError);
  });

  it("leaves a document inside the budget holding every value it wrote", () => {
    const parsed = parseJSONDocument('{"a": [1, 2, {"b": "c"}], "d": null}');

    expect(parsed).toEqual({
      kind: "object",
      entries: [
        {
          key: "a",
          value: {
            kind: "array",
            items: [
              { kind: "number", lexeme: "1" },
              { kind: "number", lexeme: "2" },
              { kind: "object", entries: [{ key: "b", value: { kind: "string", value: "c" } }], count: 1 },
            ],
            count: 3,
          },
        },
        { key: "d", value: { kind: "null" } },
      ],
      count: 2,
    });
    expect(retainedNodes(parsed)).toBe(7);
  });

  it("replaces a repeated key with a new scalar value once the document budget is exhausted", () => {
    // The matrix alone drives retainedNodes to MAX_DOCUMENT_NODES, so the repeat of "k" that follows
    // parses with the budget already spent.
    const content = `{"a": 0, "k": ${matrixDocument()}, "k": "last"}`;
    const parsed = parseJSONDocument(content);

    // Same two members, "k" still at the position it first appeared: replacing it in place, not
    // dropping it or appending a second "k" at the end.
    expect(members(parsed)).toEqual([
      ["a", { kind: "number", lexeme: "0" }],
      ["k", { kind: "string", value: "last" }],
    ]);
    expect(containerCount(parsed)).toBe(2);
    expect(JSON.parse(content).k).toBe("last");
  });

  it("replaces a repeated key with a container value once the document budget is exhausted", () => {
    const content = `{"a": 0, "k": ${matrixDocument()}, "k": [1, 2, 3]}`;
    const parsed = parseJSONDocument(content);

    expect(members(parsed)).toHaveLength(2);
    const [key, replacement] = members(parsed)[1]!;
    expect(key).toBe("k");
    // Past the budget the replacement's own children are skipped, the same as any other container
    // the budget did not admit: it renders empty but still carries its real member count.
    expect(replacement).toEqual({ kind: "array", items: [], count: 3 });
    expect(containerCount(parsed)).toBe(2);
  });
});

describe("parseJSONDocument: nesting", () => {
  it("parses a deeply nested document", () => {
    const depth = 500;
    let value = parseJSONDocument("[".repeat(depth) + "1" + "]".repeat(depth));

    for (let level = 0; level < depth; level += 1) {
      expect(value.kind).toBe("array");
      value = (value as { kind: "array"; items: JSONValue[] }).items[0]!;
    }
    expect(value).toEqual({ kind: "number", lexeme: "1" });
  });

  it("parses a document nested exactly MAX_NESTING_DEPTH levels deep", () => {
    let value = parseJSONDocument(nestedArray(MAX_NESTING_DEPTH));

    for (let level = 0; level < MAX_NESTING_DEPTH; level += 1) {
      expect(value.kind).toBe("array");
      value = (value as { kind: "array"; items: JSONValue[] }).items[0]!;
    }
    expect(value).toEqual({ kind: "number", lexeme: "1" });
  });

  it("refuses a document nested one level past MAX_NESTING_DEPTH with a JSONDepthError, not a JSONSyntaxError", () => {
    let thrown: unknown;
    try {
      parseJSONDocument(nestedArray(MAX_NESTING_DEPTH + 1));
    } catch (error) {
      thrown = error;
    }

    expect(thrown).toBeInstanceOf(JSONDepthError);
    expect(thrown).not.toBeInstanceOf(JSONSyntaxError);
  });

  it("refuses a document nested 20,000 levels deep with a JSONDepthError rather than a native RangeError", () => {
    let thrown: unknown;
    try {
      parseJSONDocument(nestedArray(20_000));
    } catch (error) {
      thrown = error;
    }

    expect(thrown).toBeInstanceOf(JSONDepthError);
    expect(thrown).not.toBeInstanceOf(RangeError);
  });

  it("enforces the same depth bound on the skip path, past a container's MAX_CONTAINER_CHILDREN cap", () => {
    // The first MAX_CONTAINER_CHILDREN items are retained trivially; the one past the cap is a
    // document nested 20,000 levels deep, which the parser only ever validates through skipValue /
    // skipArray, never building a model for it. That path has to carry its own depth bound, since a
    // container the retention budget skipped entirely would otherwise recurse all the way down.
    const retained = Array.from({ length: MAX_CONTAINER_CHILDREN }, () => "0").join(",");
    const content = `[${retained},${nestedArray(20_000)}]`;

    expect(() => parseJSONDocument(content)).toThrow(JSONDepthError);
  });
});
