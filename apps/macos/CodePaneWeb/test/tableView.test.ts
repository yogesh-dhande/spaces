import { describe, expect, it } from "vitest";
import { DelimitedTable, parseDelimitedTable } from "../src/app/delimitedTable";
import { MAX_RENDERED_COLUMNS, MAX_RENDERED_ROWS, TABLE_RETENTION_BUDGET } from "../src/app/tableLimits";
import { planDelimitedTable, renderDelimitedTable } from "../src/app/tableView";

/** The parse of a file holding exactly `rows`: retained under the same budget
 *  `parseDelimitedTable` applies, and reporting the same totals it would report. */
function parsed(rows: string[][]): DelimitedTable {
  return {
    rows: rows.slice(0, MAX_RENDERED_ROWS).map((row) => row.slice(0, MAX_RENDERED_COLUMNS)),
    rowCount: rows.length,
    widestRowWidth: rows.reduce((max, row) => Math.max(max, row.length), 0),
  };
}

function render(host: HTMLElement, rows: string[][]): void {
  renderDelimitedTable(host, parsed(rows));
}

function plan(rows: string[][]) {
  return planDelimitedTable(parsed(rows));
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

  it("renders exactly the rows and notes the plan names", () => {
    const host = document.createElement("div");
    // A parse that dropped rows and columns the file has: the DOM carries the plan's rows padded to
    // its column count, then one note line per truncation.
    renderDelimitedTable(host, {
      rows: [["a", "b"], ["1"], ["2", "3"]],
      rowCount: 40,
      widestRowWidth: 9,
    });

    expect(host.querySelectorAll("tr")).toHaveLength(3);
    expect(headerCells(host)).toEqual(["a", "b"]);
    expect(bodyRows(host)).toEqual([
      ["1", ""],
      ["2", "3"],
    ]);
    expect([...host.querySelectorAll(".preview-table-note")].map((el) => el.textContent)).toEqual([
      "Showing first 3 of 40 rows",
      "Showing first 2 of 9 columns",
    ]);
  });

  it("plans a file with no rows as nothing to render", () => {
    expect(plan([])).toEqual({ rows: [], columnCount: 0, notes: [] });
  });

  it("plans 2000 rows on a longer file and says how many the file has", () => {
    const planned = plan([["name"], ...Array.from({ length: 2499 }, (_, index) => [`row-${index}`])]);

    expect(planned.rows).toHaveLength(2000);
    expect(planned.notes).toEqual(["Showing first 2000 of 2500 rows"]);
  });

  it("plans a file at the cap whole, with no note", () => {
    const planned = plan([["name"], ...Array.from({ length: 1999 }, (_, index) => [`row-${index}`])]);

    expect(planned.rows).toHaveLength(2000);
    expect(planned.notes).toEqual([]);
  });

  it("sizes the columns from the rows it plans, not from a wider one past the cap", () => {
    const planned = plan([["a", "b"], ...Array.from({ length: 1999 }, () => ["1", "2"]), ["1", "2", "3", "4"]]);

    expect(planned.columnCount).toBe(2);
  });

  it("names the planned column count when the file's widest row was dropped by the row cap", () => {
    // The 300-field row sits past the row cap, so nothing 300 fields wide is retained and the table
    // renders two columns. The note has to say two, not the 200-column cap that never bit.
    const planned = plan([
      ["name", "count"],
      ...Array.from({ length: 1999 }, (_, index) => [`row-${index}`, "1"]),
      Array.from({ length: 300 }, (_, index) => `c${index}`),
    ]);

    expect(planned.columnCount).toBe(2);
    expect(planned.notes).toEqual(["Showing first 2000 of 2001 rows", "Showing first 2 of 300 columns"]);
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
    const wide = Array.from({ length: 300 }, (_, index) => `c${index}`);
    const planned = plan(Array.from({ length: 2500 }, () => wide));

    // 200 planned columns (the column cap) x 250 planned rows = 50,000 cells, the budget's
    // limit; the row cap alone (2000) would have let this multiply to 400,000 cells.
    expect(planned.rows).toHaveLength(250);
    expect(planned.columnCount).toBe(200);
    expect(planned.notes).toEqual(["Showing first 250 of 2500 rows", "Showing first 200 of 300 columns"]);
  });

  it("caps a 2500-row by 200-column file to 250 rendered rows under the cell budget, with both notes", () => {
    const wide = Array.from({ length: 200 }, (_, index) => `c${index}`);
    // One row wider than the 200-column cap forces columnCount to the cap itself, so the column
    // note fires too, exactly as it would for any file whose real width exceeds 200.
    const planned = plan([wide, ...Array.from({ length: 2499 }, () => [...wide, "extra"])]);

    expect(planned.rows).toHaveLength(250);
    expect(planned.notes).toEqual(["Showing first 250 of 2500 rows", "Showing first 200 of 201 columns"]);
  });

  it("still renders all 2000 capped rows of a 2500-row by 10-column file: the cell budget never bites a narrow file", () => {
    const narrow = Array.from({ length: 10 }, (_, index) => `c${index}`);
    const planned = plan(Array.from({ length: 2500 }, () => narrow));

    expect(planned.rows).toHaveLength(2000);
    expect(planned.notes).toEqual(["Showing first 2000 of 2500 rows"]);
  });

  it("plans a 5000-row by 300-column file within the retention budget while naming its real totals", () => {
    const wide = Array.from({ length: 300 }, (_, index) => `c${index}`).join(",");
    const content = Array.from({ length: 5000 }, () => wide).join("\n");

    const planned = planDelimitedTable(parseDelimitedTable(content, ",", TABLE_RETENTION_BUDGET));

    // 200 planned columns (the column cap) x 250 planned rows = the 50,000-cell budget.
    expect(planned.rows).toHaveLength(250);
    expect(planned.columnCount).toBe(200);
    expect(planned.notes).toEqual(["Showing first 250 of 5000 rows", "Showing first 200 of 300 columns"]);
  });
});
