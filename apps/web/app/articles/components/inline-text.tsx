import type { ReactNode } from "react";
import { Cmd } from "../../docs/components/code-block";
import { DocLink } from "../../docs/components/doc-link";

const token = /(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^)]+\))/g;
const link = /^\[([^\]]+)\]\(([^)]+)\)$/;

// Article copy is written as plain strings with light inline markup, so the pages stay
// readable data and every article renders links, code, and emphasis the same way.
export function InlineText({ text }: { text: string }): ReactNode {
  return text.split(token).map((part, index) => {
    if (part.startsWith("**")) {
      return (
        <strong key={index} className="font-semibold text-foreground">
          {part.slice(2, -2)}
        </strong>
      );
    }
    if (part.startsWith("`")) {
      return <Cmd key={index}>{part.slice(1, -1)}</Cmd>;
    }
    const match = link.exec(part);
    if (match) {
      return (
        <DocLink key={index} href={match[2]}>
          {match[1]}
        </DocLink>
      );
    }
    return part;
  });
}
