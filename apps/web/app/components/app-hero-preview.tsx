import { WorkspaceWindowMock } from "./workspace-window-mock";

type WorkspaceItem = {
  id: string;
  name: string;
  branch: string;
  status: "running" | "idle";
};

type ProjectGroup = {
  id: string;
  name: string;
  workspaces: WorkspaceItem[];
};

const primaryWorkspaces: WorkspaceItem[] = [
  { id: "a", name: "checkout-flow", branch: "feature/checkout", status: "running" },
  { id: "b", name: "pricing-update", branch: "feature/pricing", status: "running" },
  { id: "c", name: "bugfix-redirect", branch: "fix/auth-redirect", status: "idle" },
];

const secondaryWorkspaces: WorkspaceItem[] = [
  { id: "d", name: "admin-billing", branch: "feature/billing", status: "running" },
  // { id: "e", name: "release-prep", branch: "chore/release-notes", status: "idle" },
];

const projects: ProjectGroup[] = [
  { id: "p1", name: "storefront", workspaces: primaryWorkspaces },
  { id: "p2", name: "admin-console", workspaces: secondaryWorkspaces },
];

type WindowItem = {
  label: string;
  kind: "browser" | "editor" | "terminal";
};

const windowsByWorkspace: Record<string, WindowItem[]> = {
  a: [
    { label: "npm run dev", kind: "terminal" },
    { label: "pnpm test --watch", kind: "terminal" },
    { label: "localhost:3000/checkout", kind: "browser" },
    { label: "app/checkout/page.tsx", kind: "editor" },
  ],
  b: [
    { label: "pnpm test --watch", kind: "terminal" },
    { label: "localhost:3001/pricing", kind: "browser" },
    { label: "app/pricing/pricing-card.tsx", kind: "editor" },
  ],
  c: [
    { label: "codex --resume", kind: "terminal" },
    { label: "localhost:3002/login", kind: "browser" },
    { label: "app/auth/redirect-handler.ts", kind: "editor" },
  ],
};

function statusLabel(status: WorkspaceItem["status"]) {
  return status === "running" ? "Running" : "Stopped";
}

export function AppHeroPreview() {
  return (
    <div className="max-w-2xl mx-auto app-hero-preview rounded-2xl bg-surface p-3 shadow-[0_22px_45px_-34px_color-mix(in_oklab,var(--ink)_45%,transparent)]">
      <div className="app-hero-stage">
        <div className="app-hero-scene app-hero-scene-app">
          <div className="app-hero-topbar">
            <div className="app-hero-traffic">
              <span className="app-hero-dot app-hero-dot-red" />
              <span className="app-hero-dot app-hero-dot-yellow" />
              <span className="app-hero-dot app-hero-dot-green" />
            </div>
            <p className="app-hero-title">Spaceship</p>
          </div>
          <div className="app-hero-shell">
            <aside className="app-hero-sidebar">
              <p className="app-hero-label">Projects</p>
              <div className="app-hero-project-list">
                {projects.map((project) => (
                  <section key={project.id} className="app-hero-project-card">
                    <p className="app-hero-project-name">{project.name}</p>
                    <div className="app-hero-workspace-list">
                      {project.workspaces.map((workspace) => (
                        <article
                          key={workspace.id}
                          className={`app-workspace-row app-workspace-${workspace.id}`}
                        >
                          <div className="app-workspace-main">
                            <p className="app-workspace-name">{workspace.name}</p>
                            <p className="app-workspace-branch">{workspace.branch}</p>
                          </div>
                          <span className="app-workspace-status">
                            {statusLabel(workspace.status)}
                          </span>
                        </article>
                      ))}
                    </div>
                  </section>
                ))}
              </div>
            </aside>

            <section className="app-hero-detail">
              <div className="app-state-layer app-state-a">
                <WorkspaceState workspace={primaryWorkspaces[0]} windows={windowsByWorkspace.a} />
              </div>
              <div className="app-state-layer app-state-b">
                <WorkspaceState workspace={primaryWorkspaces[1]} windows={windowsByWorkspace.b} />
              </div>
              <div className="app-state-layer app-state-c">
                <WorkspaceState workspace={primaryWorkspaces[2]} windows={windowsByWorkspace.c} />
              </div>
            </section>
          </div>
        </div>

        <div className="app-hero-scene app-hero-scene-windows">
          <DetachedWindowSwitcher workspace={primaryWorkspaces[2]} windows={windowsByWorkspace.c} />
        </div>
      </div>

      <div className="app-shortcut-hud" aria-hidden>
        <div className="app-shortcut-chip app-shortcut-step-1">
          <p className="app-shortcut-keys">Cmd+Shift+=</p>
          <p className="app-shortcut-copy">Show Spaceship</p>
        </div>
        <div className="app-shortcut-chip app-shortcut-step-2">
          <p className="app-shortcut-keys">Cmd+Shift+[</p>
          <p className="app-shortcut-copy">Select next workspace</p>
        </div>
        <div className="app-shortcut-chip app-shortcut-step-3">
          <p className="app-shortcut-keys">Cmd+Shift+[</p>
          <p className="app-shortcut-copy">Select next workspace</p>
        </div>
        <div className="app-shortcut-chip app-shortcut-step-4">
          <p className="app-shortcut-keys">Cmd+2</p>
          <p className="app-shortcut-copy">Open workspace window</p>
        </div>
        <div className="app-shortcut-chip app-shortcut-step-5">
          <p className="app-shortcut-keys">Cmd+Shift+]</p>
          <p className="app-shortcut-copy">Switch workspace windows</p>
        </div>
      </div>
    </div>
  );
}

type WorkspaceStateProps = {
  workspace: WorkspaceItem;
  windows: WindowItem[];
};

function WorkspaceState({ workspace, windows }: WorkspaceStateProps) {
  return (
    <div className="app-state-card">
      <div className="app-state-head">
        <div className="app-state-main">
          <p className="app-state-name">{workspace.name}</p>
          <p className="app-state-subtitle">Branch: {workspace.branch}</p>
          <div className="app-state-actions">
            <button
              type="button"
              className="app-action-icon app-action-launch"
              aria-label="Launch workspace"
              title="Launch workspace"
            >
              <svg viewBox="0 0 16 16" aria-hidden>
                <path d="M5 3.5v9l7-4.5-7-4.5z" fill="currentColor" />
              </svg>
            </button>
            <button
              type="button"
              className="app-action-icon app-action-restart"
              aria-label="Restart workspace"
              title="Restart workspace"
            >
              <svg viewBox="0 0 16 16" aria-hidden>
                <path
                  d="M12 5.5A4.8 4.8 0 1 0 13 8.4"
                  fill="none"
                  stroke="currentColor"
                  strokeLinecap="round"
                  strokeWidth="1.6"
                />
                <path d="M11.6 2.8v3.2h3.2" fill="none" stroke="currentColor" strokeWidth="1.6" />
              </svg>
            </button>
            <button
              type="button"
              className="app-action-icon app-action-stop"
              aria-label="Stop workspace"
              title="Stop workspace"
            >
              <svg viewBox="0 0 16 16" aria-hidden>
                <rect x="4.1" y="4.1" width="7.8" height="7.8" rx="1" fill="currentColor" />
              </svg>
            </button>
          </div>
        </div>
        <span className="app-state-status">{statusLabel(workspace.status)}</span>
      </div>

      <div className="app-state-window-list">
        {windows.map((item, i) => (
          <div key={`${workspace.id}-${item.label}`} className="app-window-row">
            <span className={`app-window-kind app-window-kind-${item.kind}`}>
              {item.kind === "browser" && (
                <svg viewBox="0 0 16 16" width="14" height="14" aria-label="Browser">
                  <circle cx="8" cy="8" r="6.5" fill="none" stroke="currentColor" strokeWidth="1.2" />
                  <path d="M8 1.5 A6.5 6.5 0 0 1 14.5 8 M8 1.5 A6.5 6.5 0 0 0 1.5 8" fill="none" stroke="currentColor" strokeWidth="1.2" />
                  <ellipse cx="8" cy="8" rx="2.8" ry="6.5" fill="none" stroke="currentColor" strokeWidth="1.2" />
                </svg>
              )}
              {item.kind === "editor" && (
                <svg viewBox="0 0 16 16" width="14" height="14" aria-label="Editor">
                  <path d="M5 4.5 l-2 3.5 l2 3.5" fill="none" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round" />
                  <path d="M11 4.5 l2 3.5 l-2 3.5" fill="none" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round" />
                  <path d="M9.5 3.5 l-3 9" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
                </svg>
              )}
              {item.kind === "terminal" && (
                <svg viewBox="0 0 16 16" width="14" height="14" aria-label="Terminal">
                  <rect x="2" y="3" width="12" height="10" rx="1.5" fill="none" stroke="currentColor" strokeWidth="1.2" />
                  <path d="M4.5 6.5 l2 2 l-2 2" fill="none" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" strokeLinejoin="round" />
                  <path d="M8 10 h3" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round" />
                </svg>
              )}
            </span>
            <div className="flex justify-between items-center">
              <p className="app-window-label">{item.label}</p>
              <p className="text-[0.4rem] font-mono text-foreground-soft/90 px-2">CMD+{i + 1}</p>
            </div>
          </div>
        ))}
      </div>

      <div className="app-state-footer">
        <p>Switch windows in workspace order</p>
        <p>Cmd+1..9</p>
      </div>
    </div>
  );
}

function DetachedWindowSwitcher({ workspace, windows }: WorkspaceStateProps) {
  const browserWindow = windows.find((item) => item.kind === "browser");
  const editorWindow = windows.find((item) => item.kind === "editor");
  const terminalWindow = windows.find((item) => item.kind === "terminal");

  return (
    <div className="app-window-player app-window-player-detached">
      <div className="app-window-player-strip">
        <p className="app-window-player-title">{workspace.name}</p>
        <p className="app-window-player-copy">{workspace.branch}</p>
      </div>
      <div className="app-window-canvas app-window-canvas-detached">
        <WorkspaceWindowMock
          className="app-window-pane app-window-pane-browser app-window-pane-focus-1"
          kind="browser"
          label={browserWindow?.label.replace("Browser: ", "") ?? "localhost:3000"}
        />

        <WorkspaceWindowMock
          className="app-window-pane app-window-pane-editor app-window-pane-focus-2"
          kind="editor"
          label={editorWindow?.label.replace("Editor: ", "") ?? "app/feature/view.tsx"}
        />

        <WorkspaceWindowMock
          className="app-window-pane app-window-pane-terminal app-window-pane-focus-3"
          kind="terminal"
          label={terminalWindow?.label.replace("Terminal: ", "") ?? `pnpm dev --filter ${workspace.name}`}
        />
      </div>
    </div>
  );
}
