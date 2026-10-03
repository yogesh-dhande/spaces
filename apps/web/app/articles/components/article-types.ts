export type ArticleBlock =
  | { type: "p"; text: string }
  | { type: "h3"; text: string }
  | { type: "ul" | "ol"; items: string[] }
  | { type: "code"; text: string }
  | { type: "table"; columns: string[]; rows: string[][] }
  | {
      type: "figure";
      src: string;
      width: number;
      height: number;
      alt: string;
      caption: string;
      // Phone screenshots are tall; they render in a device frame at phone width.
      phone?: boolean;
    };

export type ArticleSection = {
  title: string;
  blocks: ArticleBlock[];
};

// Inline text in every string field supports `code`, **bold**, and [label](href).
export type ArticleData = {
  pagePath: string;
  title: string;
  description: string;
  shortAnswer: string;
  glance: {
    columns: string[];
    rows: string[][];
    // The row that is Spaces, highlighted.
    highlightRow: number;
  };
  sections: ArticleSection[];
  readNext: string[];
  sources: { note: string; href: string; fetched: string }[];
};
