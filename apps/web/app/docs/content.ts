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
      "Get Spaces installed, its dependencies in place, and your environment verified, then grant permission to control Google Chrome on first launch.",
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
      "Configure a codebase once so every workspace you create starts with its processes running and its named services reachable at stable per-workspace URLs, with browser sessions ready to focus.",
  },
  {
    href: "/docs/workspaces",
    title: "Workspaces",
    summary:
      "Create, name, and switch between isolated streams of work, each with its own git branch, windows, processes, and settings.",
  },
  {
    href: "/docs/workspace-lifecycle",
    title: "Workspace Lifecycle",
    summary:
      "Understand how workspaces move between stopped, running, and archived states across the GUI and the minimal CLI runtime flow.",
  },
  {
    href: "/docs/window-management",
    title: "Window Management",
    summary:
      "Spaces automatically tracks the windows a workspace opens and lets you jump to any one of them with a keyboard shortcut or the command palette.",
  },
  {
    href: "/docs/processes",
    title: "Processes",
    summary:
      "Run servers, workers, and coding agents alongside each workspace as terminal-style shell commands with named-service and Spaces directory variables.",
  },
  {
    href: "/docs/browser-sessions",
    title: "Browser Sessions",
    summary:
      "Attach Chrome URLs to a workspace so the pages you need are one keyboard shortcut away while it runs.",
  },
  {
    href: "/docs/coding-agents",
    title: "Coding Agents",
    summary:
      "Track Claude Code, Codex, opencode, and other coding agents per workspace, and wire up hooks so each session reports its state to Spaces automatically.",
  },
  {
    href: "/docs/shortcuts",
    title: "Keyboard Shortcuts",
    summary:
      "Jump between workspaces, focus windows, and trigger common actions with shortcuts you can configure.",
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
      "Use the spaces CLI for same-machine workspace actions, pairing links, Spaces terminal session commands, owner-seeking terminal windows, and ownership takeover.",
  },
  {
    href: "/docs/mcp",
    title: "Model Context Protocol",
    summary:
      "Connect an MCP client such as Claude Code or Codex to the spaces mcp server so it can list and drive your projects, workspaces, and Spaces terminals.",
  },
  {
    href: "/docs/ios",
    title: "iOS Companion",
    summary:
      "Pair the Spaces iOS app with a Mac or Linux device to browse live terminal sessions, watch coding agents, run workspace processes, and create workspaces from your phone.",
  },
];

export type CookbookGuideLink = {
  href: string;
  title: string;
  summary: string;
  stack: readonly string[];
};

export const cookbookGuides: CookbookGuideLink[] = [
  {
    href: "/docs/guides/nextjs-host",
    title: "Next.js (No Docker)",
    summary:
      "Single-repo frontend running directly on host with a Spaces-managed named service on a stable per-workspace URL.",
    stack: ["Next.js", "Host"],
  },
  {
    href: "/docs/guides/nextjs-docker",
    title: "Next.js (Docker Compose)",
    summary:
      "Single frontend service in Compose, with workspace-isolated named services on stable per-workspace URLs and notes on stop vs down.",
    stack: ["Next.js", "Docker"],
  },
  {
    href: "/docs/guides/nextjs-django-monorepo-host",
    title: "Next.js + Django Monorepo (No Docker)",
    summary:
      "Frontend and backend processes from one repo, each a dedicated named service on its own stable per-workspace URL.",
    stack: ["Next.js", "Django", "Monorepo", "Host"],
  },
  {
    href: "/docs/guides/nextjs-django-monorepo-docker",
    title: "Next.js + Django Monorepo (Docker)",
    summary:
      "Containerized full-stack setup with named services on stable per-workspace URLs.",
    stack: ["Next.js", "Django", "Monorepo", "Docker"],
  },
  {
    href: "/docs/guides/nextjs-django-separate-repos",
    title: "Next.js + Django (Separate Repos)",
    summary:
      "Cross-project pattern using workspace overrides to run both services in one context.",
    stack: ["Next.js", "Django", "Multi-repo"],
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
  "Browser Sessions",
  "Coding Agents",
  "Keyboard Shortcuts",
  "Troubleshooting",
  "Cookbook Guides",
  "CLI Reference",
  "Model Context Protocol",
  "iOS Companion",
];
