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
      "Get Spaces installed, its dependencies in place, and your environment verified, then grant permission to control Google Chrome on first launch. Includes installing and updating the daemon on Linux, plus the SSH access, network reachability, and background-service requirements a remote machine or cloud VM has to meet before it can pair.",
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
      "Understand how workspaces move between stopped and running, and how deleting removes one, across the GUI and the minimal CLI runtime flow.",
  },
  {
    href: "/docs/services",
    title: "Services",
    summary:
      "Declare named services once and reach each at a stable per-workspace URL through a bundled Caddy proxy — no manual port assignment, no cookie collisions between workspaces.",
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
      "Attach Chrome URLs to a workspace so the pages you need are one direct shortcut away while unopened sessions stay out of window cycling, and open the same sessions in an in-app web view from your iPhone.",
  },
  {
    href: "/docs/window-management",
    title: "Window Management",
    summary:
      "Spaces tracks workspace Chrome tabs and terminal panes so direct shortcuts can open or focus targets and cycling stays inside already-open windows.",
  },
  {
    href: "/docs/coding-agents",
    title: "Coding Agents",
    summary:
      "Track Claude Code, Codex, opencode, and other coding agents per workspace, and drive several of them from a single terminal — list, spawn, annotate, subscribe for blocked/done alerts, send keystrokes, and kill. Spaces offers to install lifecycle hooks for detected agent CLIs so each session reports its state automatically.",
  },
  {
    href: "/docs/orchestration",
    title: "Agent Orchestration",
    summary:
      "Talk to one agent to get all your work done: a lead agent spawns children in isolated worktrees across harnesses, models, and machines, and coordinates them to a verified finish. Includes the copy-paste orchestrator prompt.",
  },
  {
    href: "/docs/shortcuts",
    title: "Keyboard Shortcuts",
    summary:
      "Jump between workspaces, focus windows, and trigger common actions with shortcuts you can configure, plus the fixed keys that zoom terminal text.",
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
      "Use the spaces CLI for same-machine workspace actions, pairing links, Spaces terminal sessions, text and byte terminal input, and owner-seeking terminal windows.",
  },
  {
    href: "/docs/mcp",
    title: "Model Context Protocol",
    summary:
      "Connect an MCP client such as Claude Code, Codex, or opencode to the spaces mcp server so it can list and drive your projects, workspaces, and Spaces terminals.",
  },
  {
    href: "/docs/ios",
    title: "iOS App",
    summary:
      "Pair the Spaces iOS app directly with a Mac or Linux device — no desktop app in between — to browse live terminal sessions, watch coding agents, run workspace processes, open browser sessions in an in-app web view, and create workspaces from your phone, or tour the app with sample data in Demo Mode before you pair.",
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
