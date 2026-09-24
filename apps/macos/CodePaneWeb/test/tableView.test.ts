import { describe, expect, it } from "vitest";
import { DelimitedTable, parseDelimitedTable } from "../src/app/delimitedTable";
import { MAX_RENDERED_COLUMNS, MAX_RENDERED_ROWS, TABLE_RETENTION_BUDGET } from "../src/app/tableLimits";
import { renderDelimitedTable } from "../src/app/tableView";

/** Renders `rows` as the parse of a file holding exactly them: retained under the same budget
 *  `parseDelimitedTable` applies, and reporting the same totals it would report. */
function render(host: HTMLElement, rows: string[][]): void {
  const table: DelimitedTable = {
    rows: rows.slice(0, MAX_RENDERED_ROWS).map((row) => row.slice(0, MAX_RENDERED_COLUMNS)),
    rowCount: rows.length,
    widestRowWidth: rows.reduce((max, row) => Math.max(max, row.length), 0),
  };
  renderDelimitedTable(host, table);
}

function headerCells(host: HTMLElement): string[] {
  return [...host.querySelectorAll("thead th")].map((c) => c.textContent ?? "");
}

function bodyRows(host: HTMLElement): string[][] {
  return [...host.querySelectorAll("tbody tr")].map((tr) => [...tr.querySelectorAll("td")].map((c) => c.textContent ?? ""));
}

describe("renderDelimitedTable", () => {
  it("builds the header from the first row and the body from the rest", () => {
    const host = document.createElement("div");
    render(host, [
      ["name", "count"],
      ["apples", "3"],
      ["pears", "1"],
    ]);

    expect(headerCells(host)).toEqual(["name", "count"]);
    expect(bodyRows(host)).toEqual([
      ["apples", "3"],
      ["pears", "1"],
    ]);
  });

  it("pads a ragged row to the widest row's column count", () => {
    const host = document.createElement("div");
    render(host, [
      ["a", "b", "c"],
      ["1"],
      ["2", "3"],
    ]);

    expect(headerCells(host)).toEqual(["a", "b", "c"]);
    expect(bodyRows(host)).toEqual([
      ["1", "", ""],
      ["2", "3", ""],
    ]);
  });

  it("pads header cells past the widest header when a later row is wider", () => {
    const host = document.createElement("div");
    render(host, [
      ["a"],
      ["1", "2", "3"],
    ]);

    expect(headerCells(host)).toEqual(["a", "", ""]);
  });

  it("shows a muted empty-state message instead of a table when there are no rows", () => {
    const host = document.createElement("div");
    render(host, []);

    expect(host.querySelector("table")).toBeNull();
    expect(host.querySelector(".preview-table-empty")!.textContent).toBe("This file has no rows.");
  });

  it("renders a cell containing markup as plain text, never as HTML", () => {
    const host = document.createElement("div");
    render(host, [["col"], ["<b>bold</b>"]]);

    const cell = host.querySelector("tbody td")!;
    expect(cell.textContent).toBe("<b>bold</b>");
    expect(cell.querySelector("b")).toBeNull();
  });

  it("replaces the host's previous content on re-render", () => {
    const host = document.createElement("div");
    render(host, [["a"], ["1"]]);
    render(host, []);

    expect(host.querySelector("table")).toBeNull();
    expect(host.querySelector(".preview-table-empty")).not.toBeNull();
  });

  it("stops at 2000 rows on a longer file and says how many the file has", () => {
    const host = document.createElement("div");
    const rows = [["name"], ...Array.from({ length: 2499 }, (_, index) => [`row-${index}`])];
    render(host, rows);

    expect(host.querySelectorAll("tr")).toHaveLength(2000);
    expect(host.querySelectorAll("tbody tr")).toHaveLength(1999);
    expect(host.querySelector(".preview-table-note")!.textContent).toBe("Showing first 2000 of 2500 rows");
  });

  it("renders a file at the cap whole, with no note", () => {
    const host = document.createElement("div");
    render(host, [["name"], ...Array.from({ length: 1999 }, (_, index) => [`row-${index}`])]);

    expect(host.querySelectorAll("tr")).toHaveLength(2000);
    expect(host.querySelector(".preview-table-note")).toBeNull();
  });

  it("sizes the columns from the rows it renders, not from a wider one past the cap", () => {
    const host = document.createElement("div");
    const rows = [["a", "b"], ...Array.from({ length: 1999 }, () => ["1", "2"]), ["1", "2", "3", "4"]];
    render(host, rows);

    expect(headerCells(host)).toEqual(["a", "b"]);
  });

  it("names the rendered column count when the file's widest row was dropped by the row cap", () => {
    const host = document.createElement("div");
    // The 300-field row sits past the row cap, so nothing 300 fields wide is retained and the table
    // renders two columns. The note has to say two, not the 200-column cap that never bit.
    const rows = [
      ["name", "count"],
      ...Array.from({ length: 1999 }, (_, index) => [`row-${index}`, "1"]),
      Array.from({ length: 300 }, (_, index) => `c${index}`),
    ];
    render(host, rows);

    expect(headerCells(host)).toEqual(["name", "count"]);
    expect([...host.querySelectorAll(".preview-table-note")].map((el) => el.textContent)).toEqual([
      "Showing first 2000 of 2001 rows",
      "Showing first 2 of 300 columns",
    ]);
  });

  it("stops at 200 columns on a wider file and says how many the file has", () => {
    const host = document.createElement("div");
    const wide = Array.from({ length: 300 }, (_, index) => `c${index}`);
    render(host, [wide, wide]);

    expect(headerCells(host)).toHaveLength(200);
    expect(bodyRows(host)[0]).toHaveLength(200);
    expect(host.querySelector(".preview-table-note")!.textContent).toBe("Showing first 200 of 300 columns");
  });

  it("gives a file that is both too long and too wide one note line each, further capping rows to the cell budget", () => {
    const host = document.createElement("div");
    const wide = Array.from({ length: 300 }, (_, index) => `c${index}`);
    render(host, Array.from({ length: 2500 }, () => wide));

    // 200 rendered columns (the column cap) x 250 rendered rows = 50,000 cells, the budget's
    // limit; the row cap alone (2000) would have let this multiply to 400,000 cells.
    expect(host.querySelectorAll("tr")).toHaveLength(250);
    expect([...host.querySelectorAll(".preview-table-note")].map((el) => el.textContent)).toEqual([
      "Showing first 250 of 2500 rows",
      "Showing first 200 of 300 columns",
    ]);
  });

  it("caps a 2500-row by 200-column file to 250 rendered rows under the cell budget, with both notes", () => {
    const host = document.createElement("div");
    const wide = Array.from({ length: 200 }, (_, index) => `c${index}`);
    // One row wider than the 200-column cap forces columnCount to the cap itself, so the column
    // note fires too, exactly as it would for any file whose real width exceeds 200.
    const rows = [wide, ...Array.from({ length: 2499 }, () => [...wide, "extra"])];
    render(host, rows);

    expect(host.querySelectorAll("tr")).toHaveLength(250);
    expect([...host.querySelectorAll(".preview-table-note")].map((el) => el.textContent)).toEqual([
      "Showing first 250 of 2500 rows",
      "Showing first 200 of 201 columns",
    ]);
  });

  it("still renders all 2000 capped rows of a 2500-row by 10-column file: the cell budget never bites a narrow file", () => {
    const host = document.createElement("div");
    const narrow = Array.from({ length: 10 }, (_, index) => `c${index}`);
    render(host, Array.from({ length: 2500 }, () => narrow));

    expect(host.querySelectorAll("tr")).toHaveLength(2000);
    expect(host.querySelector(".preview-table-note")!.textContent).toBe("Showing first 2000 of 2500 rows");
  });

  it("renders a 5000-row by 300-column file within the retention budget while naming its real totals", () => {
    const host = document.createElement("div");
    const wide = Array.from({ length: 300 }, (_, index) => `c${index}`).join(",");
    const content = Array.from({ length: 5000 }, () => wide).join("\n");

    renderDelimitedTable(host, parseDelimitedTable(content, ",", TABLE_RETENTION_BUDGET));

    // 200 rendered columns (the column cap) x 250 rendered rows = the 50,000-cell budget.
    expect(host.querySelectorAll("tr")).toHaveLength(250);
    expect(headerCells(host)).toHaveLength(200);
    expect([...host.querySelectorAll(".preview-table-note")].map((el) => el.textContent)).toEqual([
      "Showing first 250 of 5000 rows",
      "Showing first 200 of 300 columns",
    ]);
  });
});
