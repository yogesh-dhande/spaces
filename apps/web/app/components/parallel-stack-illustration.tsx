import { WorkspaceWindowMock, type WorkspaceWindowKind } from "./workspace-window-mock";

type Layer = {
  id: string;
  kind: WorkspaceWindowKind;
  label: string;
};

const layers: Layer[] = [
  {
    id: "checkout",
    kind: "browser",
    label: "localhost:3000/checkout",
  },
  {
    id: "pricing",
    kind: "terminal",
    label: "pnpm dev",
  },
  {
    id: "redirect",
    kind: "browser",
    label: "localhost:3001/login",
  },
  {
    id: "billing",
    kind: "editor",
    label: "app/admin/billing-panel.tsx",
  },
  {
    id: "release-notes",
    kind: "editor",
    label: "docs/release/v0.3.md",
  },
  {
    id: "auth-modal",
    kind: "terminal",
    label: "codex --resume",
  },
  {
    id: "search-perf",
    kind: "browser",
    label: "localhost:3000/search",
  },
  {
    id: "repo-cleanup",
    kind: "editor",
    label: "scripts/cleanup.ts",
  },
  {
    id: "orders-ui",
    kind: "browser",
    label: "localhost:3002/orders",
  },
  {
    id: "agent-test",
    kind: "terminal",
    label: "pnpm test --watch",
  },
  {
    id: "discount-rule",
    kind: "editor",
    label: "app/cart/discount-rules.ts",
  },
  {
    id: "settings-auth",
    kind: "browser",
    label: "localhost:5173/settings",
  },
];

export function ParallelStackIllustration() {
  return (
    <div className="parallel-stack">
      <div className="parallel-stack-frame">
        <div className="parallel-stack-scene" aria-hidden>
          {layers.map((layer, index) => (
            <article key={layer.id} className={`parallel-layer parallel-layer-${index + 1}`}>
              <WorkspaceWindowMock
                className="parallel-layer-window"
                kind={layer.kind}
                label={layer.label}
              />
            </article>
          ))}
        </div>
        <div className="parallel-stack-base" aria-hidden />
      </div>

      <p className="parallel-stack-caption">
      </p>
    </div>
  );
}
