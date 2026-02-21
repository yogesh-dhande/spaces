export type DocsPageLink = {
  href: string;
  title: string;
  summary: string;
  audience: string;
};

export const docsPageLinks: DocsPageLink[] = [
  {
    href: "/docs/installation",
    title: "Installation & Setup",
    summary:
      "Download Muxy, install dependencies, configure permissions, and verify your setup.",
    audience: "New users installing muxy for the first time.",
  },
  {
    href: "/docs/getting-started",
    title: "Getting Started",
    summary: "Install requirements, connect a project, and launch a first workspace.",
    audience: "New users onboarding muxy for the first time.",
  },
  {
    href: "/docs/projects",
    title: "Projects",
    summary:
      "Add and manage projects stored in the database, configure templates (processes, ports, scripts, named browser sessions), and understand default workspace creation for directory projects and git-url imports.",
    audience: "Developers setting up and managing project definitions.",
  },
  {
    href: "/docs/workspaces",
    title: "Workspaces",
    summary:
      "Workspace concepts, New Workspace form flow (+ / cmd+n, and cmd+n quick-create when the form is open), branch-first progressive disclosure in git workspace creation, local-cached default name/branch suggestions, non-blocking branch option loading for fast form display, inline metadata editing (header title + branch/tooltip labels with Escape/outside-click cancel), git branch rename-on-edit behavior, settings overrides, ports, env vars, switching, focus tooltip overlays, sidebar hierarchy cues, and git signals.",
    audience: "Developers creating and configuring workspaces within projects.",
  },
  {
    href: "/docs/workspace-lifecycle",
    title: "Workspace Lifecycle",
    summary:
      "Create, launch, ensure-running (`workspace up` with optional `--restart`), stop, restart, archive, and restore workspace behavior, including deferred setup during GUI create and launch waiting for setup completion.",
    audience: "Developers managing multiple long-lived workstreams.",
  },
  {
    href: "/docs/window-management",
    title: "Window Management",
    summary:
      "Capture and restore windows using yabai IDs with deterministic switching, including refresh-based terminal fallback title updates.",
    audience: "Users optimizing context switching and keyboard navigation.",
  },
  {
    href: "/docs/processes",
    title: "Processes",
    summary:
      "Configure process commands, runtime policies, logs, and restart behavior.",
    audience: "Teams running app servers, workers, and coding agents per workspace.",
  },
  {
    href: "/docs/browser-sessions",
    title: "Browser Sessions",
    summary:
      "Bind named URL sessions to workspace context so local routes and references reopen together.",
    audience: "Frontend and full-stack workflows that keep many task tabs open.",
  },
  {
    href: "/docs/status-checks",
    title: "Status Checks",
    summary:
      "Explain periodic health checks, stale-status avoidance, and on-fail restart behavior with clean stop-before-relaunch handling.",
    audience: "Developers who need fast health visibility before switching context.",
  },
  {
    href: "/docs/shortcuts",
    title: "Keyboard Shortcuts",
    summary:
      "Show global and workspace-level shortcuts for fast context switching and editor launch.",
    audience: "Keyboard-first users and heavy multitaskers.",
  },
  {
    href: "/docs/troubleshooting",
    title: "Troubleshooting",
    summary:
      "Common failure patterns with diagnosis and recovery playbooks, including additive database migration compatibility checks and transient SQLite lock handling guidance.",
    audience: "Anyone debugging launch, capture, process, or focus issues.",
  },
  {
    href: "/docs/faq",
    title: "FAQ",
    summary:
      "Answer common workflow questions and clarify boundaries and non-goals.",
    audience: "Teams evaluating fit and defining internal usage conventions.",
  },
  {
    href: "/docs/guides",
    title: "Cookbook Guides",
    summary:
      "End-to-end project setup recipes for common stacks you can copy and adapt.",
    audience:
      "Developers looking for ready-made configuration examples for real-world projects.",
  },
  {
    href: "/docs/cli",
    title: "CLI Reference",
    summary:
      "Complete mx command reference for managing projects, workspaces, config, settings, and worktree reconciliation (create missing, archive stale, refresh branches) from scripts and AI agent pipelines, plus contributor-focused automation hooks.",
    audience:
      "AI coding agents and developers who drive Muxy from the terminal or automated workflows.",
  },
];

export const docsPublishingOrder = [
  "Installation & Setup",
  "Getting Started",
  "Projects",
  "Workspaces",
  "Workspace Lifecycle",
  "Window Management",
  "Processes",
  "Status Checks",
  "Browser Sessions",
  "Keyboard Shortcuts",
  "Troubleshooting",
  "FAQ",
  "Cookbook Guides",
  "CLI Reference",
];
