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
      "Get Spaces installed, permissions configured, and your environment verified. Spaces guides you through any missing prerequisites with a step-by-step in-app setup flow on first launch.",
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
      "Configure a codebase once so every workspace you create starts with all of the configured processes running on their reserved ports, and dedicated browser windows.",
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
      "Run servers, workers, and coding agents alongside each workspace with explicit Direct or Shell execution modes, including direct-mode Spaces variable interpolation.",
  },
  {
    href: "/docs/browser-sessions",
    title: "Browser Sessions",
    summary:
      "Attach Chrome URLs to a workspace so the pages you need reopen with it and stay focusable by keyboard shortcuts.",
  },
  {
    href: "/docs/coding-agents",
    title: "Coding Agents",
    summary:
      "Track Claude Code, Codex, and other coding agents per workspace, and wire up global hooks so each session reports its state to Spaces automatically.",
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
      "Use the minimal spaces CLI for import, update, start, restart, open, process-shell configuration, and explicit coding-agent signals.",
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
      "Single-repo frontend running directly on host with Spaces-managed ports.",
    stack: ["Next.js", "Host"],
  },
  {
    href: "/docs/guides/nextjs-docker",
    title: "Next.js (Docker Compose)",
    summary:
      "Single frontend service in Compose, with notes on stop vs down and container-level health checks.",
    stack: ["Next.js", "Docker"],
  },
  {
    href: "/docs/guides/nextjs-django-monorepo-host",
    title: "Next.js + Django Monorepo (No Docker)",
    summary:
      "Frontend and backend processes from one repo, each with dedicated reserved ports.",
    stack: ["Next.js", "Django", "Monorepo", "Host"],
  },
  {
    href: "/docs/guides/nextjs-django-monorepo-docker",
    title: "Next.js + Django Monorepo (Docker)",
    summary:
      "Containerized full-stack setup with host port mapping per workspace.",
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
];
