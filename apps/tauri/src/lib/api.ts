import { invoke } from "@tauri-apps/api/core";

type JsonEnvelope<T> = {
  ok: boolean;
  data: T;
};

type BrowserEnvelope<T> = {
  data: T;
};

export type ProjectSummary = {
  id: string;
  name: string;
  dir: string;
  isGitRepo: boolean;
  defaultBranch: string | null;
};

export type ProjectRecord = ProjectSummary & {
  setupScript: string | null;
  stopScript: string | null;
  ports: { name: string }[];
  processes: { name: string | null; command: string; on_exit?: string; onExit?: string }[];
  statusChecks: {
    name: string | null;
    process: string;
    command: string;
    interval: number;
    timeout: number;
    on_fail?: string;
    onFail?: string;
  }[];
  browserSessions: { name: string | null; url: string | null }[];
};

export type WorkspaceSummary = {
  id: string;
  title: string;
  branch: string | null;
  targetBranch: string | null;
  dir: string;
  isRunning: boolean;
  isArchived: boolean;
  isActive: boolean;
  isDefault: boolean;
  tooltip: string | null;
};

export type WorkspaceRecord = WorkspaceSummary & {
  projectID: string;
  dirname: string | null;
  lastLaunchedAt: string | null;
};

export type WorkspaceSettings = {
  stopScript: string | null;
  ports: { name: string }[];
  processes: { name: string | null; command: string; on_exit?: string; onExit?: string }[];
  statusChecks: {
    name: string | null;
    process: string;
    command: string;
    interval: number;
    timeout: number;
    on_fail?: string;
    onFail?: string;
  }[];
  browserSessions: { name: string | null; url: string | null }[];
};

export type WorkspaceRuntime = {
  status: {
    workspaceID: string;
    lifecycleState: string;
    runtimeHealth: string;
    hasTrackedRuntimeIndicators: boolean;
    runningProcessCount: number;
    exitedProcessCount: number;
    failedCheckCount: number;
    waitingAgentWindowCount: number;
    missingConfiguredProcessCount: number;
    missingConfiguredBrowserSessionCount: number;
    isDegraded: boolean;
    warningSummary: string | null;
  };
  processes: {
    id: string;
    templateName: string;
    command: string;
    status: string;
    pid: number | null;
    startedAt: string | null;
    exitedAt: string | null;
  }[];
  windows: {
    id: string;
    app: string;
    title: string | null;
    targetURL: string | null;
    role: string;
    orderIndex: number;
  }[];
  statusResultsByProcessID: Record<
    string,
    { checkName: string; status: string; message: string | null; lastRunAt: string | null }[]
  >;
  agentWindows: {
    id: string;
    provider: string;
    label: string | null;
    status: string;
    updatedAt: string;
  }[];
};

export type SettingsSnapshot = {
  editor: string | null;
  terminalHost: string;
  portRange: string;
  guiHotkey: string;
  guiLeaderHotkey: string;
  guiDashboardShortcut: string;
  guiAddProjectShortcut: string;
  guiAddWorkspaceShortcut: string;
  guiReloadShortcut: string;
  guiNextShortcut: string;
  guiPrevShortcut: string;
  guiOpenEditorShortcut: string;
  guiOpenTerminalShortcut: string;
  guiOpenFinderShortcut: string;
  guiOpenSettingsShortcut: string;
  guiTooltipShortcut: string;
  guiWindowShortcut: string;
  guiWindowSequenceShortcut: string;
  itermFocusPulseColor: string;
  itermFocusPulseEnabled: boolean;
};

export type DashboardPayload = {
  dismissedAttentionItemIDs: string[];
  groups: {
    projectName: string;
    workspaceID: string;
    workspaceName: string;
    latestDate: string | null;
    items: {
      attentionID: string;
      kind: string;
      icon: string;
      label: string;
      detail: string | null;
      processStatus: string | null;
      agentStatus: string | null;
      statusChecks: { checkName: string; status: string; message: string | null }[];
      eventDate: string | null;
      focusRequest: {
        kind: string;
        workspaceID: string;
        windowIndex: number | null;
        processID: string | null;
        agentWindowID: string | null;
        targetURL: string | null;
      } | null;
    }[];
  }[];
};

export type SystemCheck = {
  kind: string;
  label: string;
  ok: boolean;
  detail: string;
};

export type BranchOption = {
  name: string;
  scope: "local" | "remote";
};

declare global {
  interface Window {
    __TAURI_INTERNALS__?: {
      invoke: (cmd: string, args?: unknown, options?: unknown) => Promise<unknown>;
    };
  }
}

function isTauriRuntime() {
  return typeof window !== "undefined" && typeof window.__TAURI_INTERNALS__?.invoke === "function";
}

async function browserBridge<T>(path: string, body?: unknown, init?: RequestInit): Promise<T> {
  const response = await fetch(`/__muxy${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: body === undefined ? undefined : { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
    ...init,
  });

  const payload = (await response.json()) as BrowserEnvelope<T> | { error?: string };
  if (!response.ok || !("data" in payload)) {
    throw new Error(("error" in payload && payload.error) || `Bridge request failed: ${path}`);
  }
  return payload.data;
}

async function tauriInvoke<T>(command: string, args: unknown) {
  return invoke<T>(command, (args ?? {}) as Record<string, unknown>);
}

async function bridgeInvoke<T>(command: string, args: unknown, path: string) {
  if (isTauriRuntime()) {
    return tauriInvoke<T>(command, args);
  }
  return browserBridge<T>(path, args);
}

async function callMx<T>(command: string, args: string[] = []): Promise<T> {
  if (isTauriRuntime()) {
    const envelope = await tauriInvoke<JsonEnvelope<T>>("mx_read", { command, args });
    return envelope.data;
  }
  return browserBridge<T>("/mx-read", { command, args });
}

async function mutateMx<T>(command: string, args: string[] = []): Promise<T> {
  if (isTauriRuntime()) {
    const envelope = await tauriInvoke<JsonEnvelope<T>>("mx_mutate", { command, args });
    return envelope.data;
  }
  return browserBridge<T>("/mx-mutate", { command, args });
}

export async function resolveMxPath() {
  if (isTauriRuntime()) {
    return tauriInvoke<string>("resolve_mx_path", {});
  }
  return browserBridge<string>("/resolve-mx-path");
}

export async function loadProjects() {
  return callMx<ProjectSummary[]>("project", ["list"]);
}

export async function loadProject(dir: string) {
  return callMx<ProjectRecord>("project", ["get", "--dir", dir]);
}

export async function loadWorkspaces(projectDir: string) {
  return callMx<WorkspaceSummary[]>("workspace", ["list", "--project-dir", projectDir]);
}

export async function loadWorkspace(dir: string) {
  return callMx<WorkspaceRecord>("workspace", ["get", "--dir", dir]);
}

export async function loadWorkspaceRuntime(dir: string) {
  return callMx<WorkspaceRuntime>("workspace", ["runtime", "--dir", dir]);
}

export async function loadWorkspaceSettings(dir: string) {
  return callMx<WorkspaceSettings>("workspace", ["settings", "get", "--dir", dir]);
}

export async function loadSettings() {
  return callMx<SettingsSnapshot>("settings", ["get", "--all"]);
}

export async function loadDashboard() {
  return callMx<DashboardPayload>("dashboard");
}

export async function addProjectFromDir(dir: string) {
  return mutateMx("project", ["add", "--dir", dir]);
}

export async function createWorkspace(projectDir: string, name: string, branch?: string) {
  const args = ["create", "--project-dir", projectDir, "--name", name];
  if (branch) {
    args.push("--branch", branch);
  }
  return mutateMx("workspace", args);
}

export async function updateWorkspace(dir: string, updates: { title?: string; tooltip?: string }) {
  const args = ["update", "--dir", dir];
  if (updates.title) {
    args.push("--title", updates.title);
  }
  if (updates.tooltip) {
    args.push("--tooltip", updates.tooltip);
  }
  return mutateMx("workspace", args);
}

export async function updateWorkspaceStopScript(dir: string, stopScript: string | null) {
  const args = ["settings", "update", "--dir", dir];
  if (stopScript === null) {
    args.push("--clear-stop-script");
  } else {
    args.push("--stop-script", stopScript);
  }
  return mutateMx("workspace", args);
}

export async function addWorkspaceProcess(dir: string, name: string, command: string) {
  return mutateMx("workspace", ["process", "add", "--dir", dir, "--name", name, "--command", command]);
}

export async function addWorkspaceBrowserSession(dir: string, name: string, url: string) {
  return mutateMx("workspace", ["browser-session", "add", "--dir", dir, "--name", name, "--url", url]);
}

export async function workspaceAction(action: "launch" | "restart" | "stop" | "archive", dir: string) {
  return mutateMx("workspace", [action, "--dir", dir]);
}

export async function workspaceUp(dir: string) {
  return mutateMx("workspace", ["up", "--dir", dir]);
}

export async function focusWorkspaceWindow(dir: string, index: number) {
  return mutateMx("workspace", ["focus", "--dir", dir, "--window", String(index)]);
}

export async function checkPrereqs() {
  return bridgeInvoke<SystemCheck[]>(
    "system_check",
    {
      kind: "prereqs",
      args: [],
    },
    "/system-check",
  );
}

export async function loadGitBranches(repoDir: string) {
  return bridgeInvoke<BranchOption[]>(
    "git_read",
    {
      command: "branch_options",
      args: [repoDir],
    },
    "/git-read",
  );
}
