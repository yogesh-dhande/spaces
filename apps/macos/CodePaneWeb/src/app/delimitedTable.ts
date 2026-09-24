/**
 * CSV and TSV parsing for the Editor's read-only table preview.
 *
 * Follows RFC 4180's quoting rules, which is what a spreadsheet export actually writes: a field may
 * be wrapped in double quotes, inside which the delimiter, `"` doubled to escape itself, and line
 * breaks are all literal content. TSV files are parsed with the same rules and a tab delimiter,
 * since the exports that use tabs quote the same way.
 */

import { TableRetentionBudget } from "./tableLimits";

export type TableDelimiter = "," | "\t";

/** The delimiter a path's extension names. Only `.csv` and `.tsv` reach the table preview (see
 *  `previewKind`), and the two differ in nothing else. */
export function delimiterForPath(path: string): TableDelimiter {
  return path.toLowerCase().endsWith(".tsv") ? "\t" : ",";
}

/** What one parse produced: the part of the file the renderer can use, plus the whole file's shape. */
export interface DelimitedTable {
  /** The retained rows: the file's first `budget.rows` rows, each holding its first
   *  `budget.columns` fields. */
  rows: string[][];
  /** Every row the file holds, retained or not. */
  rowCount: number;
  /** The field count of the file's widest row, counted past the budget as well. */
  widestRowWidth: number;
}

/**
 * Splits `content` into rows of fields, keeping at most what `budget` allows.
 *
 * Row endings are `\n` or `\r\n`; a lone `\r` inside a quoted field is content, as is a line break
 * of either form. A trailing row ending closes the last row rather than opening an empty one, so a
 * file that ends in a newline does not get a phantom final row. A file that is entirely empty has
 * no rows at all, while a file holding only an empty quoted field (`""`) is one row of one empty
 * cell, which is what it says it is.
 *
 * A quoted field left unterminated at end of input is closed there: the parser reports the rows the
 * file does contain rather than refusing the whole file over its last line.
 *
 * Past the budget the scan continues but allocates nothing: a field the renderer can never show is
 * counted and dropped character by character rather than built into a string, so a near-10 MiB file
 * costs one pass and the bounded set of rows the table displays, instead of every field it holds.
 * `rowCount` and `widestRowWidth` are still the whole file's, which is what keeps the table's
 * trailing notes naming real totals.
 */
export function parseDelimitedTable(content: string, delimiter: TableDelimiter, budget: TableRetentionBudget): DelimitedTable {
  const rows: string[][] = [];
  let rowCount = 0;
  let widestRowWidth = 0;
  if (content === "") return { rows, rowCount, widestRowWidth };

  let row: string[] = [];
  let field = "";
  /** Whether the field being accumulated exists at all, as opposed to nothing having been read for
   *  it yet. `field !== ""` cannot answer that on its own: `""` is a present field whose content is
   *  empty, and without this a file holding only `""` would end with an empty `field` and an empty
   *  `row` and be reported as no rows rather than as one empty cell. It is also the only thing
   *  tracking a field past the retention budget, where nothing is accumulated at all. */
  let fieldPresent = false;
  /** Fields read for the current row, retained or not: the row's real width, and the cursor the
   *  column budget is measured against. */
  let rowFieldWidth = 0;
  let retainingRow = rows.length < budget.rows;
  let quoted = false;
  let index = 0;
  const appendChar = (char: string): void => {
    if (retainingRow && rowFieldWidth < budget.columns) field += char;
  };
  const pushField = (): void => {
    if (retainingRow && rowFieldWidth < budget.columns) row.push(field);
    rowFieldWidth += 1;
    field = "";
    fieldPresent = false;
  };
  const pushRow = (): void => {
    pushField();
    if (retainingRow) rows.push(row);
    row = [];
    rowCount += 1;
    widestRowWidth = Math.max(widestRowWidth, rowFieldWidth);
    rowFieldWidth = 0;
    retainingRow = rows.length < budget.rows;
  };
  while (index < content.length) {
    // Indexed inside the loop bound, so this is always a code unit; the parser reads one at a time.
    const char = content[index]!;
    if (quoted) {
      fieldPresent = true;
      if (char === '"') {
        if (content[index + 1] === '"') {
          appendChar('"');
          index += 2;
          continue;
        }
        quoted = false;
        index += 1;
        continue;
      }
      appendChar(char);
      index += 1;
      continue;
    }
    // A quote only opens a quoted field at the field's very start; anywhere else it is content.
    if (char === '"' && !fieldPresent) {
      quoted = true;
      fieldPresent = true;
      index += 1;
      continue;
    }
    if (char === delimiter) {
      pushField();
      index += 1;
      continue;
    }
    if (char === "\r" && content[index + 1] === "\n") {
      pushRow();
      index += 2;
      continue;
    }
    if (char === "\n" || char === "\r") {
      pushRow();
      index += 1;
      continue;
    }
    appendChar(char);
    fieldPresent = true;
    index += 1;
  }
  // Whatever is still being accumulated is the last row: a file with no trailing newline, or one
  // whose final quoted field was never closed.
  if (fieldPresent || rowFieldWidth > 0) pushRow();
  return { rows, rowCount, widestRowWidth };
}
