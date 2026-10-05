import { InlineText } from "./inline-text";
import type { ArticleData } from "./article-types";

const eyebrow = "font-mono text-[0.62rem] uppercase tracking-[0.18em]";

export function slugify(title: string): string {
  return title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

export function ShortAnswer({ text }: { text: string }) {
  return (
    <div className="rounded-sm border border-line bg-surface p-5 md:p-6">
      <p className={`${eyebrow} text-accent-2`}>Short answer</p>
      <p className="mt-3 text-base leading-7 text-foreground md:text-lg md:leading-8">
        <InlineText text={text} />
      </p>
    </div>
  );
}

export function GlanceTable({ glance }: { glance: ArticleData["glance"] }) {
  return (
    <div>
      <p className={`${eyebrow} text-foreground-soft`}>At a glance</p>
      <div className="mt-3 overflow-x-auto rounded-sm border border-line/70">
        <table className="min-w-full border-collapse text-left text-sm">
          <thead className="bg-background-soft/70 text-foreground">
            <tr>
              {glance.columns.map((column, index) => (
                <th
                  key={index}
                  className="px-3 py-2 align-bottom font-mono text-xs uppercase tracking-[0.12em]"
                >
                  {column}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {glance.rows.map((row, rowIndex) => {
              const isSpaces = rowIndex === glance.highlightRow;
              return (
                <tr
                  key={rowIndex}
                  className={`border-t border-line/70 ${isSpaces ? "bg-accent/10" : ""}`}
                >
                  {row.map((cell, cellIndex) => (
                    <td
                      key={cellIndex}
                      className={`min-w-40 px-3 py-2 align-top ${
                        cellIndex === 0 && isSpaces
                          ? "font-semibold text-accent"
                          : cellIndex === 0
                            ? "font-semibold text-foreground"
                            : "text-foreground-soft"
                      }`}
                    >
                      <InlineText text={cell} />
                    </td>
                  ))}
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}

export function SectionChips({ titles }: { titles: string[] }) {
  return (
    <nav aria-label="Sections in this article" className="flex flex-wrap gap-2">
      {titles.map((title) => (
        <a
          key={title}
          href={`#${slugify(title)}`}
          className="rounded-full border border-line/70 bg-background-soft/60 px-3 py-1 font-mono text-[0.68rem] text-foreground-soft transition-colors hover:border-accent/60 hover:text-foreground"
        >
          {title}
        </a>
      ))}
    </nav>
  );
}
