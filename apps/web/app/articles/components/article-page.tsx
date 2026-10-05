import Image from "next/image";
import { PhoneFrame } from "../../components/device-frames";
import { CodeBlock } from "../../docs/components/code-block";
import { DocsShell } from "../../docs/components/docs-shell";
import { RefTable } from "../../docs/components/ref-table";
import { Section, SubHeading } from "../../docs/components/section";
import { list, prose } from "../../docs/components/guide-styles";
import { GlanceTable, SectionChips, ShortAnswer, slugify } from "./answer-first";
import type { ArticleBlock, ArticleData } from "./article-types";
import { InlineText } from "./inline-text";

function Figure({ block }: { block: Extract<ArticleBlock, { type: "figure" }> }) {
  return (
    <figure className="mt-5">
      {block.phone ? (
        <div className="max-w-[15rem]">
          <PhoneFrame src={block.src} alt={block.alt} />
        </div>
      ) : (
        <Image
          src={block.src}
          width={block.width}
          height={block.height}
          alt={block.alt}
          className="h-auto w-full rounded-sm border border-line/80"
        />
      )}
      <figcaption className="mt-2 text-xs leading-6 text-foreground-soft">
        {block.caption}
      </figcaption>
    </figure>
  );
}

function Block({ block }: { block: ArticleBlock }) {
  switch (block.type) {
    case "p":
      return (
        <p className={prose}>
          <InlineText text={block.text} />
        </p>
      );
    case "h3":
      return <SubHeading>{block.text}</SubHeading>;
    case "ul":
    case "ol": {
      const Tag = block.type;
      return (
        <Tag
          className={`${list} ${block.type === "ul" ? "list-disc" : "list-decimal"} pl-5`}
        >
          {block.items.map((item, index) => (
            <li key={index}>
              <InlineText text={item} />
            </li>
          ))}
        </Tag>
      );
    }
    case "code":
      return <CodeBlock>{block.text}</CodeBlock>;
    case "table":
      return (
        <RefTable
          columns={block.columns}
          rows={block.rows.map((row) =>
            row.map((cell, index) => <InlineText key={index} text={cell} />),
          )}
        />
      );
    case "figure":
      return <Figure block={block} />;
  }
}

export function ArticlePage({ article }: { article: ArticleData }) {
  return (
    <DocsShell
      title={article.title}
      description={article.description}
      pagePath={article.pagePath}
      breadcrumbRoot={{ label: "Articles", href: "/articles" }}
    >
      <ShortAnswer text={article.shortAnswer} />
      <GlanceTable glance={article.glance} />
      <SectionChips
        titles={[
          ...article.sections.map((section) => section.title),
          "Read next",
          "Sources",
        ]}
      />

      <div className="space-y-10 border-t border-line/70 pt-10">
        {article.sections.map((section) => (
          <Section key={section.title} id={slugify(section.title)} title={section.title}>
            {section.blocks.map((block, index) => (
              <Block key={index} block={block} />
            ))}
          </Section>
        ))}

        <Section id="read-next" title="Read next">
          <ul className={`${list} list-disc pl-5`}>
            {article.readNext.map((item) => (
              <li key={item}>
                <InlineText text={item} />
              </li>
            ))}
          </ul>
        </Section>

        <Section id="sources" title="Sources">
          <ol className={`${list} list-decimal pl-5`}>
            {article.sources.map((source) => (
              <li key={source.href} className="break-words">
                <InlineText text={source.note} />:{" "}
                <a
                  href={source.href}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="break-all text-accent hover:underline"
                >
                  {source.href}
                </a>{" "}
                (fetched {source.fetched})
              </li>
            ))}
          </ol>
        </Section>
      </div>
    </DocsShell>
  );
}
