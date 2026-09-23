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
      "Install Spaces on your Mac or a Linux box, grant Chrome access, and pair a remote machine or cloud VM.",
  },
  {
    href: "/docs/remote-access",
    title: "Remote Access",
    summary:
      "Keep a remote machine reachable from your Mac and iPhone as you move between Wi-Fi and cellular.",
  },
  {
    href: "/docs/getting-started",
    title: "Getting Started",
    summary:
      "Connect your first project and launch a workspace in under five minutes.",
  },
  {
    href: "/docs/projects",
    title: "Projects",
    summary:
      "Configure a codebase once so every new workspace starts with its processes running and its services reachable.",
  },
  {
    href: "/docs/workspaces",
    title: "Workspaces",
    summary:
      "Create, name, and switch between isolated streams of work, each with its own branch, windows, and processes.",
  },
  {
    href: "/docs/workspace-lifecycle",
    title: "Workspace Lifecycle",
    summary:
      "How a workspace moves between stopped and running, and what deleting one removes.",
  },
  {
    href: "/docs/services",
    title: "Services",
    summary:
      "Give each named service a stable per-workspace URL through the bundled Caddy proxy.",
  },
  {
    href: "/docs/processes",
    title: "Processes",
    summary:
      "Run servers, workers, and coding agents alongside each workspace as shell commands.",
  },
  {
    href: "/docs/browser-sessions",
    title: "Browser Sessions",
    summary:
      "Attach Chrome URLs to a workspace and open them from the Mac app or the in-app web view on your iPhone.",
  },
  {
    href: "/docs/window-management",
    title: "Window Management",
    summary:
      "How Spaces tracks workspace Chrome tabs and terminal panes so shortcuts open, focus, and cycle the right windows.",
  },
  {
    href: "/docs/coding-agents",
    title: "Coding Agents",
    summary:
      "Track Claude Code, Codex, opencode, and other agents per workspace, and get alerted when one is blocked or done.",
  },
  {
    href: "/docs/orchestration",
    title: "Agent Orchestration",
    summary:
      "Let one lead agent spawn and coordinate children across worktrees, harnesses, and machines. Includes the orchestrator prompt.",
  },
  {
    href: "/docs/automations",
    title: "Automations",
    summary:
      "Run a coding agent or shell command on a schedule, on your Mac or a paired Linux box, and replay the runs later.",
  },
  {
    href: "/docs/shortcuts",
    title: "Keyboard Shortcuts",
    summary:
      "Jump between workspaces, focus windows, and trigger common actions with configurable shortcuts.",
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
      "Drive workspaces, terminal sessions, and pairing from the spaces command line.",
  },
  {
    href: "/docs/mcp",
    title: "Model Context Protocol",
    summary:
      "Connect Claude Code, Codex, or opencode to the spaces MCP server to list and drive your workspaces and terminals.",
  },
  {
    href: "/docs/ios",
    title: "iOS App",
    summary:
      "Pair your iPhone directly with a Mac or Linux device to watch and steer sessions, or tour the app in Demo Mode first.",
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
