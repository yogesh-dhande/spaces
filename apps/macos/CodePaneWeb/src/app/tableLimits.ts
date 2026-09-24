/**
 * The bounds the Editor's CSV/TSV table preview is built to.
 *
 * They live in their own module because two stages share them: `tableView.ts` renders within them,
 * and `delimitedTable.ts` retains only what can ever be rendered. A parser budget derived from a
 * second copy of these numbers would silently start dropping rows the renderer still wants (or keep
 * ones it never asks for) the moment one copy moved.
 */

/**
 * The most rows the table puts in the DOM, the header row included. A delimited file is bounded only
 * by the editor's 10 MiB read limit, which is hundreds of thousands of rows; one `<tr>` of `<td>`s
 * per row costs orders of magnitude more than the text itself and would freeze the pane on open.
 */
export const MAX_RENDERED_ROWS = 2000;

/**
 * The most columns the table puts in the DOM. The row cap alone bounds nothing on a wide file: every
 * rendered row pays the widest row's column count in cells, so a few hundred columns multiply into
 * hundreds of thousands of `<td>`s at the row cap.
 */
export const MAX_RENDERED_COLUMNS = 200;

/**
 * The most cells (rendered rows x rendered columns) the table puts in the DOM. The row and column
 * caps above are independent, so a file at both caps at once would otherwise still put
 * `MAX_RENDERED_ROWS * MAX_RENDERED_COLUMNS` (400,000) cells in the DOM. This budget bounds that
 * combination directly by shrinking the rendered row count on a wide file; it never shrinks the
 * column count, so every row that does render stays fully populated, and it never grows the row
 * count past `MAX_RENDERED_ROWS` on a narrow file.
 */
export const MAX_RENDERED_CELLS = 50000;

/** How much of a delimited file the parser keeps as strings. Everything past it is counted but never
 *  built, so the totals the trailing notes report stay the file's real ones. */
export interface TableRetentionBudget {
  /** Rows to keep, the header row included. */
  rows: number;
  /** Fields to keep per retained row. */
  columns: number;
}

/**
 * What the table preview asks the parser to retain: exactly the most the renderer can ever show.
 * The cell budget only ever shrinks the rendered row count below `MAX_RENDERED_ROWS`, and it depends
 * on a column count the parse has not produced yet, so the row budget is the un-shrunk cap.
 */
export const TABLE_RETENTION_BUDGET: TableRetentionBudget = {
  rows: MAX_RENDERED_ROWS,
  columns: MAX_RENDERED_COLUMNS,
};
