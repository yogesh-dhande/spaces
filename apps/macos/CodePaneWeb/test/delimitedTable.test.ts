import { describe, expect, it } from "vitest";
import { delimiterForPath, parseDelimitedTable } from "../src/app/delimitedTable";
import { TABLE_RETENTION_BUDGET } from "../src/app/tableLimits";

/** The rows a parse retained, for the cases about parsing itself rather than about the budget. */
function rowsOf(content: string, delimiter: "," | "\t"): string[][] {
  return parseDelimitedTable(content, delimiter, TABLE_RETENTION_BUDGET).rows;
}

describe("delimiterForPath", () => {
  it("splits a .tsv on tabs and everything else on commas", () => {
    expect(delimiterForPath("data/rows.tsv")).toBe("\t");
    expect(delimiterForPath("data/ROWS.TSV")).toBe("\t");
    expect(delimiterForPath("data/rows.csv")).toBe(",");
  });
});

describe("parseDelimitedTable", () => {
  it("splits plain rows and fields", () => {
    expect(rowsOf("name,role\nAda,engineer\n", ",")).toEqual([
      ["name", "role"],
      ["Ada", "engineer"],
    ]);
  });

  it("does not invent a row for a trailing newline, and keeps a last row without one", () => {
    expect(rowsOf("a\nb\n", ",")).toEqual([["a"], ["b"]]);
    expect(rowsOf("a\nb", ",")).toEqual([["a"], ["b"]]);
    expect(rowsOf("", ",")).toEqual([]);
  });

  it("accepts CRLF row endings", () => {
    expect(rowsOf("a,b\r\nc,d\r\n", ",")).toEqual([
      ["a", "b"],
      ["c", "d"],
    ]);
  });

  it("keeps a quoted field's delimiters, quotes, and line breaks as content", () => {
    const content = 'name,note\nGrace,"Two lines\nin one field"\nAda,"Writes ""the"" compiler"\nAlan,"a,b"\n';
    expect(rowsOf(content, ",")).toEqual([
      ["name", "note"],
      ["Grace", "Two lines\nin one field"],
      ["Ada", 'Writes "the" compiler'],
      ["Alan", "a,b"],
    ]);
  });

  it("keeps empty fields, including a trailing one", () => {
    expect(rowsOf('a,,c\n"",b,\n', ",")).toEqual([
      ["a", "", "c"],
      ["", "b", ""],
    ]);
  });

  it("parses a TSV with the same quoting rules", () => {
    expect(rowsOf('a\tb\n"has\ttab"\tc\n', "\t")).toEqual([
      ["a", "b"],
      ["has\ttab", "c"],
    ]);
  });

  it("closes a quoted field left unterminated at end of input rather than losing the file", () => {
    expect(rowsOf('a,b\nc,"unterminated', ",")).toEqual([
      ["a", "b"],
      ["c", "unterminated"],
    ]);
  });

  it("reads a file holding only an empty quoted field as one empty cell", () => {
    expect(rowsOf('""', ",")).toEqual([[""]]);
    expect(rowsOf('""\n', ",")).toEqual([[""]]);
  });

  it("keeps rows ragged rather than padding them", () => {
    expect(rowsOf("a,b,c\nd\n", ",")).toEqual([["a", "b", "c"], ["d"]]);
  });

  it("keeps only the budgeted rows and columns of a large file while counting all of them", () => {
    const wide = Array.from({ length: 300 }, (_, index) => `c${index}`).join(",");
    const content = Array.from({ length: 5000 }, () => wide).join("\n");

    const table = parseDelimitedTable(content, ",", TABLE_RETENTION_BUDGET);

    expect(table.rows).toHaveLength(2000);
    expect(table.rows.every((row) => row.length === 200)).toBe(true);
    expect(table.rows[0]![199]).toBe("c199");
    expect(table.rowCount).toBe(5000);
    expect(table.widestRowWidth).toBe(300);
  });

  it("counts a row past the budget at its real width without building its fields", () => {
    const table = parseDelimitedTable("a,b\nc,d\ne,f,g", ",", { rows: 2, columns: 1 });

    expect(table.rows).toEqual([["a"], ["c"]]);
    expect(table.rowCount).toBe(3);
    expect(table.widestRowWidth).toBe(3);
  });

  it("counts a quoted field past the budget whole, so a line break inside it is not a row", () => {
    const table = parseDelimitedTable('a\nb,"two\nlines",c', ",", { rows: 1, columns: 1 });

    expect(table.rows).toEqual([["a"]]);
    expect(table.rowCount).toBe(2);
    expect(table.widestRowWidth).toBe(3);
  });
});
