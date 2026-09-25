import type { ReactNode } from "react";
import { card, prose } from "./guide-styles";

const heading = "text-2xl font-semibold tracking-tight";

// `scroll-mt-24` keeps the fixed site header from covering the heading when the browser
// jumps to the card's anchor.
export function Card({ id, children }: { id?: string; children: ReactNode }) {
  return (
    <article id={id} className={`${card} scroll-mt-24`}>
      {children}
    </article>
  );
}

export function SectionHeading({ children }: { children: ReactNode }) {
  return <h2 className={heading}>{children}</h2>;
}

// A page whose heading sits inside custom layout (next to a badge or an image) composes
// Card and SectionHeading directly instead.
export function Section({
  id,
  title,
  children,
}: {
  id?: string;
  title: ReactNode;
  children: ReactNode;
}) {
  return (
    <Card id={id}>
      <SectionHeading>{title}</SectionHeading>
      {children}
    </Card>
  );
}

export function SubHeading({
  id,
  children,
}: {
  id?: string;
  children: ReactNode;
}) {
  return (
    <h3
      id={id}
      className="mt-6 scroll-mt-24 text-sm font-semibold text-foreground"
    >
      {children}
    </h3>
  );
}

export function Prose({ children }: { children: ReactNode }) {
  return <p className={prose}>{children}</p>;
}
