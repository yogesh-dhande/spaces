import type { ReactNode } from "react";
import { card, prose } from "./guide-styles";

// Section-heading className repeated at the top of every docs card. Kept local (rather
// than in guide-styles.ts) since nothing needs the bare string outside this file.
const heading = "text-2xl font-semibold tracking-tight";

/** The border-topped card that wraps one section on a docs page. */
export function Card({ children }: { children: ReactNode }) {
  return <article className={card}>{children}</article>;
}

/** The `<h2>` title styling shared by every docs section. */
export function SectionHeading({ children }: { children: ReactNode }) {
  return <h2 className={heading}>{children}</h2>;
}

/**
 * A docs section: a Card whose first child is its title as an `<h2>`, followed by
 * whatever body content the section needs. Covers the common case of a plain
 * heading-then-content section. A page whose heading sits inside custom layout
 * (e.g. next to a badge, or beside an image) composes Card + SectionHeading
 * directly instead of Section.
 */
export function Section({
  title,
  children,
}: {
  title: ReactNode;
  children: ReactNode;
}) {
  return (
    <Card>
      <SectionHeading>{title}</SectionHeading>
      {children}
    </Card>
  );
}

/** Shared body-copy paragraph styling used throughout docs sections. */
export function Prose({ children }: { children: ReactNode }) {
  return <p className={prose}>{children}</p>;
}
