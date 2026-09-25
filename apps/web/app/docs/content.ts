export type DocsPageLink = {
  href: string;
  title: string;
  summary: string;
};

export type DocsNavGroup = {
  label: string;
  pages: DocsPageLink[];
};

export const docsNavGroups: DocsNavGroup[] = [
  {
    label: "Get started",
    pages: [
      {
        href: "/docs",
        title: "Overview and concepts",
        summary: "What Spaces is and the terms the rest of the docs use.",
      },
      {
        href: "/docs/installation",
        title: "Install on your Mac",
        summary:
          "Requirements, installing the Mac app and its command-line tools, updates, and uninstalling.",
      },
      {
        href: "/docs/getting-started",
        title: "Quickstart",
        summary:
          "Add a project, create a workspace, start it, and open a coding agent.",
      },
    ],
  },
  {
    label: "Workspaces",
    pages: [
      {
        href: "/docs/projects",
        title: "Projects",
        summary:
          "Add a folder or Git repository on your Mac or a paired device, and set how its workspaces run.",
      },
      {
        href: "/docs/workspaces",
        title: "Workspaces",
        summary: "Create, set up, start, stop, hide, and delete workspaces.",
      },
      {
        href: "/docs/terminals",
        title: "Terminals, tabs, and panes",
        summary:
          "Open terminals, arrange them in tabs, split panes, and separate windows, and what happens when you close one.",
      },
      {
        href: "/docs/editor",
        title: "The Editor",
        summary:
          "Review a workspace's changes, edit files with previews, and send line comments to a coding agent.",
      },
      {
        href: "/docs/window-management",
        title: "Finding your way around",
        summary:
          "The sidebar, numbered targets, the command palette, and cycling through windows.",
      },
      {
        href: "/docs/alerts",
        title: "Alerts",
        summary:
          "One list of what needs you: blocked and finished agents, exited processes, bells, and failed automation runs.",
      },
    ],
  },
  {
    label: "Run your app",
    pages: [
      {
        href: "/docs/services",
        title: "Services and URLs",
        summary:
          "Named services get a port per workspace and a stable URL that stays the same across restarts.",
      },
      {
        href: "/docs/processes",
        title: "Processes",
        summary:
          "The long-running commands a workspace starts, and what happens when one exits.",
      },
      {
        href: "/docs/browser-sessions",
        title: "Browser sessions",
        summary:
          "Named Chrome tabs a workspace opens on focus and closes when it stops.",
      },
    ],
  },
  {
    label: "Coding agents",
    pages: [
      {
        href: "/docs/coding-agents",
        title: "Agent status",
        summary:
          "How Spaces knows whether Claude Code, Codex, or opencode is working, waiting for you, or done.",
      },
      {
        href: "/docs/orchestration",
        title: "Orchestrate agents",
        summary:
          "Let one agent spawn, watch, and stop other agents across your workspaces and devices.",
      },
      {
        href: "/docs/automations",
        title: "Automations",
        summary:
          "Run a script or an agent on any device, by hand or on a schedule, and review each run.",
      },
      {
        href: "/docs/restarts",
        title: "What survives a restart",
        summary:
          "What keeps running when you quit Spaces, restart your Mac, or update, and how agents come back.",
      },
    ],
  },
  {
    label: "Devices",
    pages: [
      {
        href: "/docs/remote-access",
        title: "Remote machines",
        summary:
          "Install Spaces on a Linux machine or another Mac, pair it, and reach it from anywhere.",
      },
      {
        href: "/docs/ios",
        title: "iPhone app",
        summary:
          "A full Spaces client for iPhone and iPad that connects straight to your Mac or Linux machines.",
      },
    ],
  },
  {
    label: "Reference",
    pages: [
      {
        href: "/docs/cli",
        title: "CLI",
        summary: "Every `spaces` command and flag.",
      },
      {
        href: "/docs/mcp",
        title: "MCP tools",
        summary:
          "Connect Claude Code, Codex, or opencode to Spaces and see the tools they get.",
      },
      {
        href: "/docs/spaces-yaml",
        title: "spaces.yaml",
        summary:
          "The file that describes a project's setup, services, processes, and browser sessions.",
      },
      {
        href: "/docs/shortcuts",
        title: "Keyboard shortcuts",
        summary:
          "Spaces' shortcuts, which ones work from any app, and how to change them.",
      },
      {
        href: "/docs/settings",
        title: "Settings",
        summary: "The Mac and iPhone settings, and where each is explained.",
      },
      {
        href: "/docs/environment-variables",
        title: "Environment variables",
        summary:
          "The variables Spaces sets for processes, terminals, and scripts in a workspace.",
      },
    ],
  },
  {
    label: "Help",
    pages: [
      {
        href: "/docs/troubleshooting",
        title: "Troubleshooting",
        summary:
          "Fixes for Chrome permission, setup, shortcut, device, and agent status problems.",
      },
      {
        href: "/docs/guides",
        title: "Recipes",
        summary:
          "Worked setups for common stacks, as a `spaces.yaml` and in project settings.",
      },
    ],
  },
];

export const docsPageLinks: DocsPageLink[] = docsNavGroups.flatMap(
  (group) => group.pages,
);

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
