export type DocsPageLink = {
  href: string;
  title: string;
  summary: string;
  audience: string;
};

export const docsPageLinks: DocsPageLink[] = [
  {
    href: "/docs/getting-started",
    title: "Getting Started",
    summary: "Install requirements, connect a project, and launch a first workspace.",
    audience: "New users onboarding spaceship for the first time.",
  },
  {
    href: "/docs/projects",
    title: "Projects",
    summary:
      "Project configuration, templates, directory structure, and default workspace creation.",
    audience: "Developers setting up and managing project definitions.",
  },
  {
    href: "/docs/workspaces",
    title: "Workspaces",
    summary:
      "Workspace concepts, fields, settings overrides, ports, env vars, and switching.",
    audience: "Developers creating and configuring workspaces within projects.",
  },
  {
    href: "/docs/workspace-lifecycle",
    title: "Workspace Lifecycle",
    summary:
      "Create, launch, stop, restart, archive, and restore workspace behavior.",
    audience: "Developers managing multiple long-lived workstreams.",
  },
  {
    href: "/docs/window-management",
    title: "Window Management",
    summary:
      "Capture and restore windows using yabai IDs with deterministic switching.",
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
      "Bind URLs to workspace context so local routes and references reopen together.",
    audience: "Frontend and full-stack workflows that keep many task tabs open.",
  },
  {
    href: "/docs/status-checks",
    title: "Status Checks",
    summary:
      "Explain readiness checks for windows, processes, ports, and browser targets.",
    audience: "Developers who need fast health visibility before switching context.",
  },
  {
    href: "/docs/shortcuts",
    title: "Keyboard Shortcuts",
    summary:
      "Show global and workspace-level shortcuts for fast context switching.",
    audience: "Keyboard-first users and heavy multitaskers.",
  },
  {
    href: "/docs/troubleshooting",
    title: "Troubleshooting",
    summary:
      "Common failure patterns with diagnosis and recovery playbooks.",
    audience: "Anyone debugging launch, capture, process, or focus issues.",
  },
  {
    href: "/docs/faq",
    title: "FAQ",
    summary:
      "Answer common workflow questions and clarify boundaries and non-goals.",
    audience: "Teams evaluating fit and defining internal usage conventions.",
  },
];

export const docsPublishingOrder = [
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
];
