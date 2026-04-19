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
      "Get Muxy installed, permissions configured, and your environment verified. Muxy guides you through any missing prerequisites (iTerm2 or Ghostty, yabai, Accessibility) with a step-by-step in-app setup flow on first launch.",
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
      "Configure a codebase once so every workspace you create starts with the same processes, ports, and dedicated browser windows.",
  },
  {
    href: "/docs/workspaces",
    title: "Workspaces",
    summary:
      "Create, name, activate/deactivate, and switch between isolated streams of work, each with its own windows, branch, and settings, with GUI sidebar metadata periodically syncing CLI edits.",
  },
  {
    href: "/docs/workspace-lifecycle",
    title: "Workspace Lifecycle",
    summary:
      "Launch, stop, restart, and archive workspaces—including automated bring-up from the CLI and AI agents, with restart paths reopening dedicated tracked terminal and browser windows when needed.",
  },
  {
    href: "/docs/window-management",
    title: "Window Management",
    summary:
      "Capture the windows you need and switch context quickly, with next/previous shortcuts cycling workspaces in-app and cycling tracked dedicated workspace windows with low-latency yabai focus paths and DEBUG=1 timing logs for the full cycle path.",
  },
  {
    href: "/docs/processes",
    title: "Processes",
    summary:
      "Run app servers, workers, and AI agents alongside each workspace so they start and stop together, with tracked terminal windows that can be focused directly and cleaned up on stop.",
  },
  {
    href: "/docs/browser-sessions",
    title: "Browser Sessions",
    summary:
      "Tie browser routes to a workspace so local references reopen together, with dedicated tracked Chrome windows used for fast focus and stale window mappings recovered lazily.",
  },
  {
    href: "/docs/status-checks",
    title: "Status Checks",
    summary:
      "Get instant passed/failed health feedback on running processes before you switch context.",
  },
  {
    href: "/docs/shortcuts",
    title: "Keyboard Shortcuts",
    summary:
      "Jump between workspaces, cycle tracked workspace windows, and trigger common actions, including the global workspace tooltip toggle, without lifting your hands from the keyboard; window-focus shortcuts and row clicks dispatch through detached focus helpers to keep activation handoff snappy, and a full-width app footer shows live shortcut hints for navigation, Settings, and tooltip toggle.",
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
      "Drive every Muxy action from the terminal or automate workspace management from scripts and AI pipelines, including terminal-agent hooks for Claude Code and Codex CLI.",
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
