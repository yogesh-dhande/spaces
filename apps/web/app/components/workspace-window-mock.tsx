export type WorkspaceWindowKind = "browser" | "editor" | "terminal";

type WorkspaceWindowMockProps = {
  kind: WorkspaceWindowKind;
  label: string;
  className?: string;
};

function joinClasses(...parts: Array<string | undefined>) {
  return parts.filter(Boolean).join(" ");
}

export function WorkspaceWindowMock({ kind, label, className }: WorkspaceWindowMockProps) {
  if (kind === "browser") {
    return (
      <article className={joinClasses("workspace-window", className)}>
        <div className="app-pane-browser-top">
          <span className="app-pane-dot app-pane-dot-red" />
          <span className="app-pane-dot app-pane-dot-yellow" />
          <span className="app-pane-dot app-pane-dot-green" />
          <p className="app-pane-address">{label}</p>
        </div>
        <div className="app-pane-browser-body">
          <div className="app-pane-browser-banner" />
          <div className="app-pane-browser-row">
            <div className="app-pane-browser-card app-pane-browser-card-tall" />
            <div className="app-pane-browser-card" />
          </div>
          <div className="app-pane-browser-line" />
          <div className="app-pane-browser-line app-pane-browser-line-short" />
        </div>
      </article>
    );
  }

  if (kind === "editor") {
    return (
      <article className={joinClasses("workspace-window", className)}>
        <div className="app-pane-editor-top">
          <p>{label}</p>
        </div>
        <div className="app-pane-editor-body">
          <div className="app-pane-editor-gutter">
            <span>18</span>
            <span>19</span>
            <span>20</span>
            <span>21</span>
            <span>22</span>
          </div>
          <div className="app-pane-editor-code">
            <div className="app-pane-editor-line app-pane-editor-line-1" />
            <div className="app-pane-editor-line app-pane-editor-line-2" />
            <div className="app-pane-editor-line app-pane-editor-line-3" />
            <div className="app-pane-editor-line app-pane-editor-line-4" />
            <div className="app-pane-editor-line app-pane-editor-line-5" />
          </div>
        </div>
      </article>
    );
  }

  return (
    <article className={joinClasses("workspace-window", className)}>
      <div className="app-pane-terminal-top">
        <p>{label}</p>
      </div>
      <div className="app-pane-terminal-body">
        <p>$ {label}</p>
        <p>ready on :3001</p>
        <p>watching changes...</p>
        <p className="app-pane-terminal-cursor">_</p>
      </div>
    </article>
  );
}
