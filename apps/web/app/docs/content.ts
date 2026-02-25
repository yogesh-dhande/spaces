export type DocsPageLink = {
  href: string;
  title: string;
  summary: string;
};

export const docsPageLinks: DocsPageLink[] = [
  {
    href: "/docs/installation",
    title: "Installation & Setup",
    summary:
      "Get Muxy installed, permissions configured, and your environment verified.",
  },
  {
    href: "/docs/getting-started",
    title: "Getting Started",
    summary: "Connect your first project and launch a workspace in under five minutes.",
  },
  {
    href: "/docs/projects",
    title: "Projects",
    summary:
      "Configure a codebase once so every workspace you create starts with the same processes, ports, and browser tabs.",
  },
  {
    href: "/docs/workspaces",
    title: "Workspaces",
    summary:
      "Create, name, and switch between isolated streams of work, each with its own windows, branch, and settings, with GUI sidebar metadata periodically syncing CLI edits.",
  },
  {
    href: "/docs/workspace-lifecycle",
    title: "Workspace Lifecycle",
    summary:
      "Launch, stop, restart, and archive workspaces—including automated bring-up from the CLI and AI agents.",
  },
  {
    href: "/docs/window-management",
    title: "Window Management",
    summary:
      "Capture the windows you need and switch your full context instantly with a single shortcut.",
  },
  {
    href: "/docs/processes",
    title: "Processes",
    summary:
      "Run app servers, workers, and AI agents alongside each workspace so they start and stop together, with iTerm2 launching one tab/session per process in a shared workspace window when possible.",
  },
  {
    href: "/docs/browser-sessions",
    title: "Browser Sessions",
    summary:
      "Tie browser tabs to a workspace so local routes and references reopen together, with missing sessions launched as tabs in a shared Chrome window when possible.",
  },
  {
    href: "/docs/status-checks",
    title: "Status Checks",
    summary:
      "Get instant passed/failed health feedback on running processes before you switch context.",
  },
  {
    href: "/docs/dashboard",
    title: "Dashboard",
    summary:
      "See failing processes/checks from running workspaces plus waiting/done coding agents, even when a workspace is stopped.",
  },
  {
    href: "/docs/shortcuts",
    title: "Keyboard Shortcuts",
    summary:
      "Jump between workspaces and trigger common actions, including the global workspace tooltip toggle, without lifting your hands from the keyboard; sidebar utility controls keep settings/reload one click away.",
  },
  {
    href: "/docs/troubleshooting",
    title: "Troubleshooting",
    summary:
      "Fix common launch, capture, process, and focus issues with step-by-step recovery playbooks.",
  },
  {
    href: "/docs/guides",
    title: "Cookbook Guides",
    summary:
      "Copy-and-adapt project setup recipes for common stacks.",
  },
  {
    href: "/docs/cli",
    title: "CLI Reference",
    summary:
      "Drive every Muxy action from the terminal or automate workspace management from scripts and AI pipelines, including Claude Code and Codex CLI session hooks.",
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
  "Cookbook Guides",
  "CLI Reference",
];
