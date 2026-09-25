/**
 * The Editor's read-only CSV/TSV table preview. `delimitedTable.ts` turns the file's bytes into a
 * `DelimitedTable`; this module only lays it out. Reachable for `.csv`/`.tsv` files (see
 * `previewKind`).
 *
 * The parse already retained no more than the caps below allow, so the rows reaching here are the
 * candidates for rendering rather than the whole file. The file's real row count and widest row
 * travel alongside them, which is what the trailing notes name.
 */

import { DelimitedTable } from "./delimitedTable";
import { MAX_RENDERED_CELLS } from "./tableLimits";

/** Builds one `<tr>` padded out to `columnCount` cells, so a ragged file's shorter rows still line
 *  up under the widest row's columns. */
function buildRow(row: string[], columnCount: number, cellTag: "th" | "td"): HTMLTableRowElement {
  const tr = document.createElement("tr");
  for (let i = 0; i < columnCount; i += 1) {
    const cell = document.createElement(cellTag);
    cell.textContent = row[i] ?? "";
    tr.appendChild(cell);
  }
  return tr;
}

/** The first row is the header and stays visible while the body scrolls. */
export function renderDelimitedTable(host: HTMLElement, table: DelimitedTable): void {
  host.textContent = "";

  const retained = table.rows;
  if (retained.length === 0) {
    const empty = document.createElement("div");
    empty.className = "preview-table-empty";
    empty.textContent = "This file has no rows.";
    host.appendChild(empty);
    return;
  }

  // The widest RETAINED row sets the column count: a ragged file (a header with fewer fields than a
  // data row, or vice versa) still gets every column represented, with the shorter rows padded to
  // fill it out, and a wide row the parse dropped does not add columns nothing fills. The parse
  // already held each row to MAX_RENDERED_COLUMNS fields, so this is at most the column cap.
  const columnCount = retained.reduce((max, row) => Math.max(max, row.length), 0);

  // A wide file (many rendered columns) is capped to fewer rows so the row and column caps can't
  // multiply past the cell budget; a narrow file keeps every retained row, since the budget divided
  // by a small column count is always well above the row cap.
  const rowCountByCellBudget = Math.max(1, Math.floor(MAX_RENDERED_CELLS / Math.max(1, columnCount)));
  const rendered = retained.slice(0, Math.min(retained.length, rowCountByCellBudget));

  const tableEl = document.createElement("table");
  tableEl.className = "preview-table";

  const thead = document.createElement("thead");
  thead.appendChild(buildRow(rendered[0]!, columnCount, "th"));
  tableEl.appendChild(thead);

  const tbody = document.createElement("tbody");
  for (const row of rendered.slice(1)) {
    tbody.appendChild(buildRow(row, columnCount, "td"));
  }
  tableEl.appendChild(tbody);

  host.appendChild(tableEl);

  // A file wide enough and long enough to hit both caps says so on its own line for each, rather
  // than folding two different truncations into one sentence. Both notes report what was actually
  // rendered: the cell budget can push the row count below the row cap on a wide file, and the
  // column count comes from the widest RETAINED row, which the row cap can leave narrower than the
  // column cap when the file's widest row sits past the last retained one. Naming the cap instead
  // would claim 200 columns for a table showing three.
  const notes: string[] = [];
  if (rendered.length < table.rowCount) notes.push(`Showing first ${rendered.length} of ${table.rowCount} rows`);
  if (columnCount < table.widestRowWidth) {
    notes.push(`Showing first ${columnCount} of ${table.widestRowWidth} columns`);
  }
  for (const text of notes) {
    const note = document.createElement("div");
    note.className = "preview-table-note";
    note.textContent = text;
    host.appendChild(note);
  }
}
