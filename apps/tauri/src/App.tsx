import { startTransition, useCallback, useDeferredValue, useEffect, useMemo, useState } from "react";
import type { FormEvent } from "react";
import "./App.css";
import {
  addProjectFromDir,
  addWorkspaceBrowserSession,
  addWorkspaceProcess,
  checkPrereqs,
  createWorkspace,
  focusWorkspaceWindow,
  loadDashboard,
  loadGitBranches,
  loadProjects,
  loadSettings,
  loadWorkspace,
  loadWorkspaces,
  resolveMxPath,
  updateWorkspace,
  updateWorkspaceStopScript,
  workspaceAction,
  workspaceUp,
  loadWorkspaceRuntime,
  loadWorkspaceSettings,
} from "./lib/api";
import type {
  BranchOption,
  DashboardPayload,
  ProjectSummary,
  SettingsSnapshot,
  SystemCheck,
  WorkspaceRecord,
  WorkspaceRuntime,
  WorkspaceSettings,
  WorkspaceSummary,
} from "./lib/api";

type Selection =
  | { kind: "dashboard" }
  | { kind: "settings" }
  | { kind: "workspace"; dir: string };

function App() {
  const [mxPath, setMxPath] = useState("");
  const [projects, setProjects] = useState<ProjectSummary[]>([]);
  const [workspacesByProject, setWorkspacesByProject] = useState<Record<string, WorkspaceSummary[]>>({});
  const [dashboard, setDashboard] = useState<DashboardPayload | null>(null);
  const [settings, setSettings] = useState<SettingsSnapshot | null>(null);
  const [prereqs, setPrereqs] = useState<SystemCheck[]>([]);
  const [selection, setSelection] = useState<Selection>({ kind: "dashboard" });
  const [workspace, setWorkspace] = useState<WorkspaceRecord | null>(null);
  const [workspaceRuntime, setWorkspaceRuntime] = useState<WorkspaceRuntime | null>(null);
  const [workspaceSettings, setWorkspaceSettings] = useState<WorkspaceSettings | null>(null);
  const [branches, setBranches] = useState<BranchOption[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const [projectDirInput, setProjectDirInput] = useState("");
  const [workspaceNameInput, setWorkspaceNameInput] = useState("");
  const [workspaceBranchInput, setWorkspaceBranchInput] = useState("");
  const [workspaceTitleInput, setWorkspaceTitleInput] = useState("");
  const [workspaceTooltipInput, setWorkspaceTooltipInput] = useState("");
  const [stopScriptInput, setStopScriptInput] = useState("");
  const [processNameInput, setProcessNameInput] = useState("");
  const [processCommandInput, setProcessCommandInput] = useState("");
  const [browserSessionNameInput, setBrowserSessionNameInput] = useState("");
  const [browserSessionURLInput, setBrowserSessionURLInput] = useState("");

  const selectedProject = useMemo(() => {
    if (selection.kind !== "workspace" || !workspace) {
      return null;
    }
    return projects.find((project) => project.id === workspace.projectID) ?? null;
  }, [projects, selection.kind, workspace]);

  const deferredDashboard = useDeferredValue(dashboard);

  const refreshShell = useCallback(async () => {
    setError(null);
    const [nextMxPath, nextPrereqs, nextProjects, nextSettings, nextDashboard] = await Promise.all([
      resolveMxPath(),
      checkPrereqs(),
      loadProjects(),
      loadSettings(),
      loadDashboard(),
    ]);

    const workspaceEntries = await Promise.all(
      nextProjects.map(async (project) => [project.id, await loadWorkspaces(project.dir)] as const),
    );

    setMxPath(nextMxPath);
    setPrereqs(nextPrereqs);
    setProjects(nextProjects);
    setSettings(nextSettings);
    setDashboard(nextDashboard);
    setWorkspacesByProject(Object.fromEntries(workspaceEntries));
  }, []);

  const refreshSelection = useCallback(async (nextSelection: Selection) => {
    if (nextSelection.kind !== "workspace") {
      setWorkspace(null);
      setWorkspaceRuntime(null);
      setWorkspaceSettings(null);
      return;
    }

    const [nextWorkspace, nextRuntime, nextSettings] = await Promise.all([
      loadWorkspace(nextSelection.dir),
      loadWorkspaceRuntime(nextSelection.dir),
      loadWorkspaceSettings(nextSelection.dir),
    ]);

    setWorkspace(nextWorkspace);
    setWorkspaceRuntime(nextRuntime);
    setWorkspaceSettings(nextSettings);
    setWorkspaceTitleInput(nextWorkspace.title);
    setWorkspaceTooltipInput(nextWorkspace.tooltip ?? "");
    setStopScriptInput(nextSettings.stopScript ?? "");

    const owner = projects.find((project) => project.id === nextWorkspace.projectID);
    if (owner?.isGitRepo) {
      setBranches(await loadGitBranches(owner.dir));
    } else {
      setBranches([]);
    }
  }, [projects]);

  const refreshAll = useCallback(async (nextSelection: Selection) => {
    try {
      await refreshShell();
      await refreshSelection(nextSelection);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    } finally {
      setIsLoading(false);
    }
  }, [refreshSelection, refreshShell]);

  useEffect(() => {
    const timeout = window.setTimeout(() => {
      void refreshAll(selection);
    }, 0);
    return () => window.clearTimeout(timeout);
  }, [refreshAll, selection]);

  useEffect(() => {
    const interval = window.setInterval(() => {
      void refreshAll(selection);
    }, 8000);
    return () => window.clearInterval(interval);
  }, [refreshAll, selection]);

  useEffect(() => {
    if (selection.kind !== "workspace") {
      return;
    }

    startTransition(() => {
      void refreshSelection(selection).catch((caught) => {
        setError(caught instanceof Error ? caught.message : String(caught));
      });
    });
  }, [refreshSelection, selection]);

  async function runAction(label: string, action: () => Promise<unknown>, nextSelection = selection) {
    setError(null);
    setMessage(null);
    try {
      await action();
      setMessage(label);
      await refreshAll(nextSelection);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    }
  }

  async function handleAddProject(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!projectDirInput.trim()) {
      return;
    }
    await runAction(`Added project ${projectDirInput}.`, () => addProjectFromDir(projectDirInput.trim()));
    setProjectDirInput("");
  }

  async function handleCreateWorkspace(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!selectedProject || !workspaceNameInput.trim()) {
      return;
    }
    await runAction(
      `Created workspace ${workspaceNameInput}.`,
      () => createWorkspace(selectedProject.dir, workspaceNameInput.trim(), workspaceBranchInput.trim() || undefined),
      { kind: "dashboard" },
    );
    setWorkspaceNameInput("");
    setWorkspaceBranchInput("");
  }

  async function handleWorkspaceMetadata(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (selection.kind !== "workspace") {
      return;
    }
    await runAction("Updated workspace metadata.", () =>
      updateWorkspace(selection.dir, {
        title: workspaceTitleInput.trim() || undefined,
        tooltip: workspaceTooltipInput.trim() || undefined,
      }),
    );
  }

  async function handleStopScript(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (selection.kind !== "workspace") {
      return;
    }
    await runAction("Updated workspace stop script.", () =>
      updateWorkspaceStopScript(selection.dir, stopScriptInput.trim() ? stopScriptInput.trim() : null),
    );
  }

  async function handleAddProcess(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (selection.kind !== "workspace" || !processNameInput.trim() || !processCommandInput.trim()) {
      return;
    }
    await runAction("Added workspace process.", () =>
      addWorkspaceProcess(selection.dir, processNameInput.trim(), processCommandInput.trim()),
    );
    setProcessNameInput("");
    setProcessCommandInput("");
  }

  async function handleAddBrowserSession(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (selection.kind !== "workspace" || !browserSessionURLInput.trim()) {
      return;
    }
    await runAction("Added browser session.", () =>
      addWorkspaceBrowserSession(
        selection.dir,
        browserSessionNameInput.trim() || browserSessionURLInput.trim(),
        browserSessionURLInput.trim(),
      ),
    );
    setBrowserSessionNameInput("");
    setBrowserSessionURLInput("");
  }

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand-card">
          <div>
            <p className="eyebrow">Muxy Tauri</p>
            <h1>Proof of concept client</h1>
          </div>
          <p className="supporting-text">Uses only `mx --json` for Muxy-owned state and actions.</p>
        </div>

        <button
          className={`nav-button ${selection.kind === "dashboard" ? "selected" : ""}`}
          onClick={() => setSelection({ kind: "dashboard" })}
        >
          Dashboard
          <span>{dashboard?.groups.reduce((count, group) => count + group.items.length, 0) ?? 0}</span>
        </button>
        <button
          className={`nav-button ${selection.kind === "settings" ? "selected" : ""}`}
          onClick={() => setSelection({ kind: "settings" })}
        >
          Settings
          <span>mx</span>
        </button>

        <section className="sidebar-section">
          <div className="section-header">
            <h2>Projects</h2>
            <span>{projects.length}</span>
          </div>
          {projects.map((project) => (
            <div key={project.id} className="project-card">
              <div className="project-heading">
                <div>
                  <strong>{project.name}</strong>
                  <p>{project.dir}</p>
                </div>
                <span className="pill">{project.isGitRepo ? "git" : "local"}</span>
              </div>
              <div className="workspace-list">
                {(workspacesByProject[project.id] ?? []).map((entry) => (
                  <button
                    key={entry.id}
                    className={`workspace-button ${
                      selection.kind === "workspace" && selection.dir === entry.dir ? "selected" : ""
                    }`}
                    onClick={() => setSelection({ kind: "workspace", dir: entry.dir })}
                  >
                    <span>{entry.title}</span>
                    <small>
                      {entry.isRunning ? "running" : "stopped"}
                      {entry.branch ? ` · ${entry.branch}` : ""}
                    </small>
                  </button>
                ))}
              </div>
            </div>
          ))}
        </section>

        <form className="inline-form" onSubmit={handleAddProject}>
          <label>
            <span>Add project directory</span>
            <input
              value={projectDirInput}
              onChange={(event) => setProjectDirInput(event.target.value)}
              placeholder="/path/to/repo"
            />
          </label>
          <button type="submit">Add project</button>
        </form>

        {selectedProject ? (
          <form className="inline-form" onSubmit={handleCreateWorkspace}>
            <label>
              <span>Create workspace in {selectedProject.name}</span>
              <input
                value={workspaceNameInput}
                onChange={(event) => setWorkspaceNameInput(event.target.value)}
                placeholder="workspace title"
              />
            </label>
            <label>
              <span>Branch</span>
              <input
                list="branch-options"
                value={workspaceBranchInput}
                onChange={(event) => setWorkspaceBranchInput(event.target.value)}
                placeholder={selectedProject.isGitRepo ? "feature/new-client" : "optional"}
              />
            </label>
            <button type="submit">Create workspace</button>
            <datalist id="branch-options">
              {branches.map((branch) => (
                <option key={`${branch.scope}-${branch.name}`} value={branch.name} />
              ))}
            </datalist>
          </form>
        ) : null}
      </aside>

      <main className="content-panel">
        <header className="topbar">
          <div>
            <p className="eyebrow">Client-owned checks</p>
            <div className="check-row">
              {prereqs.map((check) => (
                <span key={check.kind} className={`status-pill ${check.ok ? "ok" : "warn"}`}>
                  {check.label}
                </span>
              ))}
            </div>
          </div>
          <div className="meta-block">
            <span className="meta-label">mx path</span>
            <code>{mxPath || "resolving..."}</code>
          </div>
        </header>

        {message ? <div className="callout success">{message}</div> : null}
        {error ? <div className="callout error">{error}</div> : null}
        {isLoading ? <div className="loading-card">Loading Muxy state…</div> : null}

        {!isLoading && selection.kind === "dashboard" && deferredDashboard ? (
          <section className="detail-grid">
            {deferredDashboard.groups.map((group) => (
              <article key={group.workspaceID} className="panel-card">
                <div className="panel-header">
                  <div>
                    <p className="eyebrow">{group.projectName}</p>
                    <h2>{group.workspaceName}</h2>
                  </div>
                  <button
                    disabled={!findWorkspaceDir(group.workspaceID, workspacesByProject)}
                    onClick={() => {
                      const dir = findWorkspaceDir(group.workspaceID, workspacesByProject);
                      if (dir) {
                        setSelection({ kind: "workspace", dir });
                      }
                    }}
                  >
                    Open workspace
                  </button>
                </div>
                <div className="dashboard-items">
                  {group.items.map((item) => (
                    <div key={item.attentionID} className="attention-card">
                      <div>
                        <strong>{item.label}</strong>
                        <p>{item.detail ?? item.kind}</p>
                      </div>
                      <small>{item.processStatus ?? item.agentStatus ?? "attention"}</small>
                    </div>
                  ))}
                </div>
              </article>
            ))}
          </section>
        ) : null}

        {!isLoading && selection.kind === "settings" && settings ? (
          <section className="panel-card settings-grid">
            <div className="panel-header">
              <div>
                <p className="eyebrow">Muxy settings</p>
                <h2>Shared mx configuration</h2>
              </div>
            </div>
            {Object.entries(settings).map(([key, value]) => (
              <div key={key} className="kv-row">
                <span>{key}</span>
                <code>{typeof value === "boolean" ? String(value) : value ?? "none"}</code>
              </div>
            ))}
          </section>
        ) : null}

        {!isLoading && selection.kind === "workspace" && workspace && workspaceRuntime && workspaceSettings ? (
          <section className="workspace-layout">
            <article className="panel-card hero-panel">
              <div className="panel-header">
                <div>
                  <p className="eyebrow">{selectedProject?.name ?? "Workspace"}</p>
                  <h2>{workspace.title}</h2>
                  <p className="supporting-text">{workspace.dir}</p>
                </div>
                <div className="action-row">
                  <button onClick={() => runAction("Workspace is running.", () => workspaceUp(workspace.dir))}>Up</button>
                  <button onClick={() => runAction("Launched workspace.", () => workspaceAction("launch", workspace.dir))}>Launch</button>
                  <button onClick={() => runAction("Restarted workspace.", () => workspaceAction("restart", workspace.dir))}>Restart</button>
                  <button onClick={() => runAction("Stopped workspace.", () => workspaceAction("stop", workspace.dir))}>Stop</button>
                </div>
              </div>
              <div className="stats-grid">
                <div className="stat-card">
                  <span>Status</span>
                  <strong>{workspaceRuntime.status.lifecycleState}</strong>
                  <small>{workspaceRuntime.status.runtimeHealth}</small>
                </div>
                <div className="stat-card">
                  <span>Processes</span>
                  <strong>{workspaceRuntime.status.runningProcessCount}</strong>
                  <small>{workspaceRuntime.status.exitedProcessCount} exited</small>
                </div>
                <div className="stat-card">
                  <span>Checks</span>
                  <strong>{workspaceRuntime.status.failedCheckCount}</strong>
                  <small>failed</small>
                </div>
                <div className="stat-card">
                  <span>Agents</span>
                  <strong>{workspaceRuntime.status.waitingAgentWindowCount}</strong>
                  <small>waiting</small>
                </div>
              </div>
              {workspaceRuntime.status.warningSummary ? (
                <div className="warning-strip">{workspaceRuntime.status.warningSummary}</div>
              ) : null}
            </article>

            <article className="panel-card">
              <div className="panel-header">
                <div>
                  <p className="eyebrow">Run</p>
                  <h2>Tracked windows</h2>
                </div>
              </div>
              <div className="table-list">
                {workspaceRuntime.windows.map((window, index) => (
                  <div key={window.id} className="table-row">
                    <div>
                      <strong>
                        {index + 1}. {window.title ?? window.targetURL ?? window.app}
                      </strong>
                      <p>{window.role}</p>
                    </div>
                    <button onClick={() => runAction("Focused window.", () => focusWorkspaceWindow(workspace.dir, index + 1))}>
                      Focus
                    </button>
                  </div>
                ))}
              </div>
            </article>

            <article className="panel-card">
              <div className="panel-header">
                <div>
                  <p className="eyebrow">Processes</p>
                  <h2>Runtime</h2>
                </div>
              </div>
              <div className="table-list">
                {workspaceRuntime.processes.map((process) => (
                  <div key={process.id} className="table-row stacked">
                    <div>
                      <strong>{process.templateName}</strong>
                      <p>{process.command}</p>
                    </div>
                    <small>{process.status}</small>
                    {(workspaceRuntime.statusResultsByProcessID[process.id] ?? []).map((result) => (
                      <div key={result.checkName} className={`sub-row ${result.status}`}>
                        <span>{result.checkName}</span>
                        <small>{result.status}</small>
                      </div>
                    ))}
                  </div>
                ))}
              </div>
            </article>

            <article className="panel-card">
              <div className="panel-header">
                <div>
                  <p className="eyebrow">Workspace settings</p>
                  <h2>Overrides</h2>
                </div>
              </div>
              <form className="editor-grid" onSubmit={handleWorkspaceMetadata}>
                <label>
                  <span>Title</span>
                  <input value={workspaceTitleInput} onChange={(event) => setWorkspaceTitleInput(event.target.value)} />
                </label>
                <label>
                  <span>Tooltip</span>
                  <input
                    value={workspaceTooltipInput}
                    onChange={(event) => setWorkspaceTooltipInput(event.target.value)}
                    placeholder="Visible from mx workspace up --tooltip"
                  />
                </label>
                <button type="submit">Save metadata</button>
              </form>

              <form className="editor-grid" onSubmit={handleStopScript}>
                <label>
                  <span>Stop script</span>
                  <textarea
                    rows={3}
                    value={stopScriptInput}
                    onChange={(event) => setStopScriptInput(event.target.value)}
                    placeholder="docker compose down --remove-orphans"
                  />
                </label>
                <button type="submit">Save stop script</button>
              </form>
            </article>

            <article className="panel-card">
              <div className="panel-header">
                <div>
                  <p className="eyebrow">Additions</p>
                  <h2>Processes and browser sessions</h2>
                </div>
              </div>

              <form className="editor-grid" onSubmit={handleAddProcess}>
                <label>
                  <span>Process name</span>
                  <input value={processNameInput} onChange={(event) => setProcessNameInput(event.target.value)} placeholder="frontend" />
                </label>
                <label>
                  <span>Command</span>
                  <input value={processCommandInput} onChange={(event) => setProcessCommandInput(event.target.value)} placeholder="npm run dev" />
                </label>
                <button type="submit">Add process</button>
              </form>

              <form className="editor-grid" onSubmit={handleAddBrowserSession}>
                <label>
                  <span>Session name</span>
                  <input value={browserSessionNameInput} onChange={(event) => setBrowserSessionNameInput(event.target.value)} placeholder="Frontend" />
                </label>
                <label>
                  <span>URL</span>
                  <input value={browserSessionURLInput} onChange={(event) => setBrowserSessionURLInput(event.target.value)} placeholder="http://localhost:3000" />
                </label>
                <button type="submit">Add browser session</button>
              </form>

              <div className="compact-columns">
                <div>
                  <h3>Stored processes</h3>
                  {workspaceSettings.processes.map((process) => (
                    <div key={`${process.name}-${process.command}`} className="mini-row">
                      <strong>{process.name ?? "unnamed"}</strong>
                      <p>{process.command}</p>
                    </div>
                  ))}
                </div>
                <div>
                  <h3>Stored browser sessions</h3>
                  {workspaceSettings.browserSessions.map((session) => (
                    <div key={`${session.name}-${session.url}`} className="mini-row">
                      <strong>{session.name ?? "session"}</strong>
                      <p>{session.url ?? "missing url"}</p>
                    </div>
                  ))}
                </div>
              </div>
            </article>
          </section>
        ) : null}
      </main>
    </div>
  );
}

function findWorkspaceDir(
  workspaceID: string,
  workspacesByProject: Record<string, WorkspaceSummary[]>,
) {
  for (const entries of Object.values(workspacesByProject)) {
    const match = entries.find((entry) => entry.id === workspaceID);
    if (match) {
      return match.dir;
    }
  }
  return null;
}

export default App;
