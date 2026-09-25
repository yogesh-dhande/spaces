import type { ReactNode } from "react";

type RefTableProps = {
  columns: string[];
  rows: ReactNode[][];
};

export function RefTable({ columns, rows }: RefTableProps) {
  return (
    <div className="mt-3 overflow-x-auto rounded-sm border border-line/70">
      <table className="min-w-full border-collapse text-left text-sm">
        <thead className="bg-background-soft/70 text-foreground">
          <tr>
            {columns.map((column) => (
              <th
                key={column}
                className="px-3 py-2 font-mono text-xs uppercase tracking-[0.12em]"
              >
                {column}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, rowIndex) => (
            <tr key={rowIndex} className="border-t border-line/70">
              {row.map((cell, cellIndex) => (
                <td key={cellIndex} className="px-3 py-2 text-foreground-soft">
                  {cell}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
