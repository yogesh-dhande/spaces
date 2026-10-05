import type { Metadata } from "next";
import { ArticlePage } from "../components/article-page";
import type { ArticleData } from "../components/article-types";

export const metadata: Metadata = {
  title: { absolute: "Run Claude Code, Codex, and opencode from your iPhone | Spaces" },
  description: "See which of your Claude Code, Codex, and opencode agents is waiting for you, and answer it in the same terminal from your iPhone.",
};

const article: ArticleData = {
  "pagePath": "/articles/run-coding-agents-from-your-iphone",
  "title": "Run coding agents from your iPhone",
  "description": "See which of your Claude Code, Codex, and opencode agents is waiting for you, and answer it in the same terminal from your iPhone.",
  "shortAnswer": "To run a coding agent from your iPhone, the agent keeps running on a computer you own and your phone connects to that computer to show you its terminal. Claude Code's Remote Control and Codex Remote in the ChatGPT app each do this for their own agent, and an SSH app with tmux does it for any agent but can't tell you which one is waiting. Spaces runs Claude Code, Codex, and opencode on your Mac or a Linux server and shows every one of them, working, waiting for you, or done, in one iPhone app.",
  "glance": {
    "columns": [
      "",
      "Agents it covers",
      "Where the agent runs",
      "What has to stay up",
      "Push notifications"
    ],
    "rows": [
      [
        "Remote Control",
        "Claude Code",
        "Your computer",
        "The computer, and the `claude` process",
        "Yes"
      ],
      [
        "Codex Remote",
        "Codex",
        "Your Mac or Windows PC, or an SSH host it reaches",
        "The host, awake and running the Codex app",
        "Yes"
      ],
      [
        "SSH app + tmux",
        "Any",
        "Your computer",
        "The computer, and tmux on it",
        "Add brrr, ntfy, or similar"
      ],
      [
        "Spaces",
        "Claude Code, Codex, opencode",
        "Your Mac or a Linux server",
        "That machine, awake, with its Spaces service running",
        "No"
      ]
    ],
    "highlightRow": 3
  },
  "sections": [
    {
      "title": "What you need from a phone",
      "blocks": [
        {
          "type": "p",
          "text": "On a phone, the job is mostly unblocking agents, not writing code. Most of what you do away from your desk comes down to four things:"
        },
        {
          "type": "ul",
          "items": [
            "See which agent is waiting for you, across every machine and every agent you run.",
            "Read enough of its terminal to answer: the permission prompt, the question, the plan it wants approved.",
            "Type the answer into the same session the agent is running in.",
            "Start the next task when one finishes."
          ]
        },
        {
          "type": "p",
          "text": "Reviewing a large diff or untangling a merge is still easier at a desk. The goal is to keep an agent from sitting idle for an hour because it asked a yes-or-no question while you were at lunch."
        }
      ]
    },
    {
      "title": "Your options today",
      "blocks": [
        {
          "type": "h3",
          "text": "Claude Code Remote Control"
        },
        {
          "type": "p",
          "text": "Remote Control connects the Claude app (iOS and Android) or claude.ai/code to a Claude Code session running on your machine. It is available on Pro, Max, Team, and Enterprise plans (on Team and Enterprise, an Owner turns it on first), and it can send push notifications when a long task finishes or Claude needs a decision. Anthropic's docs note that \"your computer has to stay on and the `claude` process has to keep running.\" It covers Claude Code only."
        },
        {
          "type": "h3",
          "text": "Codex Remote in the ChatGPT app"
        },
        {
          "type": "p",
          "text": "Codex Remote lets the ChatGPT app on iOS or Android start, steer, and approve Codex tasks on a connected Mac or Windows PC, including work on an SSH host that computer reaches. You get notified when a task completes or needs your attention. The host has to stay awake, online, and running the app: \"If that computer sleeps, loses network access, or closes the app, remote access stops until it's available again.\" It covers Codex only."
        },
        {
          "type": "h3",
          "text": "An SSH app, tmux, and Tailscale"
        },
        {
          "type": "p",
          "text": "The most-shared guides on this topic, such as Simon B. Støvring's and Quan Nguyen's, use the same stack: Tailscale to reach the computer, tmux to keep sessions alive, an SSH client like Prompt or Termius on the phone, and a push service like brrr or ntfy wired to agent hooks so you know when to look. It works with any agent and costs little, but you assemble and maintain it yourself, and the alert and the terminal are separate: a push tells you something needs you, then you find the right tmux window. Some phone terminals, such as Moshi, add agent status and push notifications on top of SSH."
        },
        {
          "type": "h3",
          "text": "opencode's web interface"
        },
        {
          "type": "p",
          "text": "`opencode web` serves opencode's own interface. Bind it to your network, set `OPENCODE_SERVER_PASSWORD`, and you can open it in a phone browser. It covers opencode only."
        },
        {
          "type": "h3",
          "text": "Cloud agents"
        },
        {
          "type": "p",
          "text": "Claude Code on the web and Codex Cloud run tasks on the vendor's machines, so they keep working while your laptop is closed. You can start Claude's cloud sessions from the Code tab in the Claude app. In exchange, the work runs in the vendor's environment rather than on your machine with your tools and credentials, and both are built around GitHub repositories."
        }
      ]
    },
    {
      "title": "How Spaces does it",
      "blocks": [
        {
          "type": "p",
          "text": "The Spaces service runs on each machine you use: your Mac, and any Linux server or second Mac you pair. It hosts every terminal session on that machine, including the ones running coding agents. The Mac app and the iPhone app are windows onto those sessions. Closing the Mac app, locking your phone, or losing signal disconnects a viewer; the agent keeps running in the Spaces service and is there when you come back."
        },
        {
          "type": "p",
          "text": "The iPhone app connects straight to each paired machine, over your local network or Tailscale. There is no Mac in the path: when you open an agent on a Linux server, the phone talks to the server."
        },
        {
          "type": "p",
          "text": "Spaces gets each agent's state from small hooks it installs into Claude Code, Codex, and opencode, from Settings → Coding Agents on the Mac, for the Mac or any paired machine. The hooks report when an agent is working, blocked (waiting on a permission prompt or your answer), or done. See [Agent status](/docs/coding-agents#states)."
        },
        {
          "type": "figure",
          "src": "/media/hero.png",
          "width": 2200,
          "height": 1458,
          "alt": "The Spaces Mac app with a sidebar listing a Local section and a build-server section, agents in blocked, done, and working states, and Claude Code split beside a shell.",
          "caption": "The Mac app lists each machine's workspaces and agents. The iPhone app connects to the same machines directly."
        }
      ]
    },
    {
      "title": "Walkthrough: three agents, two machines, one phone",
      "blocks": [
        {
          "type": "p",
          "text": "This example has Claude Code running on a Mac, and Codex and opencode on a Linux server paired with it. Setting up the server is covered in [Run coding agents on a remote server](/articles/run-coding-agents-on-a-remote-server)."
        },
        {
          "type": "h3",
          "text": "1. Pair the phone with each machine"
        },
        {
          "type": "p",
          "text": "On the Mac, open Settings → Devices, find a machine's row, and press Pair iPhone to show its QR code. Scan it with the Spaces app. Do it for the Mac and again for the server, so the phone can reach each one on its own. Without a Mac nearby, running `spaces device pair` on the server prints a `spaces://pair` link to open on the phone."
        },
        {
          "type": "p",
          "text": "To reach your machines from outside your home network, put the Mac, the server, and the phone on one Tailscale tailnet. The pairing code lists each machine's local address and its Tailscale address, and the phone tries them in that order. See [Pair your iPhone](/docs/remote-access#pair-your-iphone) and [Tailscale](/docs/remote-access#tailscale)."
        },
        {
          "type": "h3",
          "text": "2. See every agent in one list"
        },
        {
          "type": "p",
          "text": "The Agents tab lists the running agents on every paired machine, grouped Blocked, Done, then Working. Here, Claude Code on the Mac is blocked on a permission prompt, opencode on the server is done, and Codex on the server is working. With more than one machine paired, each row names its machine."
        },
        {
          "type": "figure",
          "src": "/media/ios-agents.png",
          "width": 1320,
          "height": 2868,
          "phone": true,
          "alt": "The Agents tab on iPhone with Claude Code under Blocked on a MacBook Pro, opencode under Done, and Codex under Working, both on build-server.",
          "caption": "The Agents tab groups the agents on every paired machine by state."
        },
        {
          "type": "p",
          "text": "The Alerts tab lists only what needs you, across every paired machine, with a badge count. Opening a finished agent's terminal for about two seconds clears its alert, and a blocked agent stays listed until you answer it or swipe it away. See [Visiting clears finished work](/docs/alerts#visiting)."
        },
        {
          "type": "figure",
          "src": "/media/ios-alerts.png",
          "width": 1320,
          "height": 2868,
          "phone": true,
          "alt": "The Alerts tab on iPhone listing opencode on build-server and Claude Code on a MacBook Pro, with a badge count of 2.",
          "caption": "The Alerts tab: what is waiting on you, from every paired machine."
        },
        {
          "type": "h3",
          "text": "3. Open the one that's waiting"
        },
        {
          "type": "p",
          "text": "Tap the Claude Code row and its terminal opens: the same session that is running on the Mac. Opening it on the phone makes the phone the session's owner, so what you type goes in. The Mac's pane for that session shows that the iPhone has it and offers Take Over for when you're back at your desk."
        },
        {
          "type": "p",
          "text": "The keyboard comes up on its own, with a row of terminal keys above it. A modifier key applies to the next character, arrow, Return, or Backspace you type, so Shift then Return sends Shift+Enter without a hardware keyboard. For a longer answer, the composer lets you write a full message, attach an image such as a screenshot of the bug, and send it in one go."
        },
        {
          "type": "figure",
          "src": "/media/ios-terminal.png",
          "width": 1320,
          "height": 2868,
          "phone": true,
          "alt": "iPhone showing a Claude Code session that has finished a turn by asking which one to start with, a reply typed at its prompt, and the terminal key row above the keyboard.",
          "caption": "Answer an agent in its own terminal, from wherever you are."
        },
        {
          "type": "h3",
          "text": "4. Read the brief instead of scrolling"
        },
        {
          "type": "p",
          "text": "An agent can keep a brief: a short status page it writes about its own work, with what it is doing, questions for you, and its task list. When an agent has one, the iPhone opens it in a sheet as you enter its terminal. On a small screen that is usually faster than scrolling back through a long transcript. See [Agent briefs](/docs/coding-agents#briefs)."
        },
        {
          "type": "figure",
          "src": "/media/ios-brief.png",
          "width": 1320,
          "height": 2868,
          "phone": true,
          "alt": "Claude Code's brief in a sheet over its terminal on iPhone: a headline about adding a delivery estimate, a Status line, and a Tasks checklist with the first item checked.",
          "caption": "The brief opens as you enter the agent's terminal."
        },
        {
          "type": "h3",
          "text": "5. Start the next task"
        },
        {
          "type": "p",
          "text": "On the Spaces tab, a workspace's menu offers New Terminal. Type `codex`, `claude`, or `opencode`, and the agent starts in that workspace on that machine, showing up in the Agents tab like any other. You can also create a workspace from the phone (it takes a branch name and branches from the project's default branch), and run an automation on demand by opening it and using Run Now from its Next run sheet (automations are created on the Mac)."
        },
        {
          "type": "figure",
          "src": "/media/ios-sessions.png",
          "width": 1320,
          "height": 2868,
          "phone": true,
          "alt": "The Spaces tab on iPhone for a MacBook Pro, listing workspaces with browser sessions, dev servers, and a claude agent with an orange waiting dot.",
          "caption": "The Spaces tab shows each workspace's processes and agents on the selected machine."
        }
      ]
    },
    {
      "title": "What keeps running when you walk away",
      "blocks": [
        {
          "type": "p",
          "text": "**On a Linux server**, agents keep running whatever your laptop and phone are doing. The installer runs the Spaces service as a systemd user service with lingering enabled, so it doesn't need anyone logged in. Restarting the server ends its sessions; when it comes back, Spaces offers to restore every agent that was cut short, resuming each conversation where the agent supports it. See [What survives a restart](/docs/restarts)."
        },
        {
          "type": "p",
          "text": "**On your Mac**, agents run while the Mac is awake. Quitting the Spaces app keeps them running (\"Quit and Keep Running\" is the default). A Mac that goes to sleep pauses everything on it, and your phone can't reach it until it wakes. If you want agents to keep going while your laptop is in a bag, run them on a Linux server."
        },
        {
          "type": "p",
          "text": "**On the phone**, lists update live while the app is open. In the background the app stops updating, and it catches up as soon as you return. A machine that is unreachable keeps its rows listed, dimmed, with their last-known state."
        }
      ]
    },
    {
      "title": "Limits to know before you start",
      "blocks": [
        {
          "type": "ul",
          "items": [
            "**No push notifications.** Spaces does not notify your phone when an agent finishes or gets stuck. The Alerts tab lists blocked and finished agents, exited processes and terminals, terminal bells, failed or timed-out automation runs, and rows you marked Come Back Later across every paired machine, with a badge count, but you see it when you open the app. If push matters most to you, Remote Control, Codex Remote, and the SSH-plus-push setups all have it.",
            "**A question in plain text reads as done.** An agent that asks you something in its output, rather than through a permission prompt, shows as done instead of blocked, because no hook fires for a plain-text question. Check Done as well as Blocked.",
            "**Invite-only TestFlight beta.** The app runs on iPhone and iPad with iOS 17 or later. [Ask for an invite](/docs/ios#availability) by opening an issue on GitHub.",
            "**Apple clients only.** The clients are the Mac app and the iPhone and iPad app. There is no Android, Windows, or web client. Agents run on Macs and Linux servers (Ubuntu 24.04).",
            "**Some things stay on the Mac.** Installing the status hooks and creating or editing automations happen in the Mac app."
          ]
        }
      ]
    },
    {
      "title": "When something else is the better choice",
      "blocks": [
        {
          "type": "ul",
          "items": [
            "**You use only Claude Code and want push notifications with nothing new to install:** use Remote Control. It is part of Claude's Pro, Max, Team, and Enterprise plans, and the Claude app runs on iOS and Android.",
            "**You use only Codex, or your host is a Windows PC:** use Codex Remote in the ChatGPT app.",
            "**Your phone runs Android:** use one of the vendor apps or an SSH app.",
            "**You want work to continue with every computer of yours switched off, and your code is on GitHub:** use Claude Code on the web or Codex Cloud.",
            "**You run one agent on one machine and tmux plus push already works:** keep it."
          ]
        },
        {
          "type": "p",
          "text": "Spaces fits when you run more than one kind of agent, or agents on more than one machine, and want one place on your phone that shows which one needs you."
        }
      ]
    }
  ],
  "readNext": [
    "[iPhone app docs](/docs/ios)",
    "[Remote machines: install, pair, and Tailscale](/docs/remote-access)",
    "[Run coding agents on a remote server and keep them running](/articles/run-coding-agents-on-a-remote-server)",
    "[Let Claude Code, Codex, and opencode work together](/articles/coding-agents-working-together)"
  ],
  "sources": [
    {
      "note": "Remote Control plans (Pro, Max, Team, Enterprise; Owner toggle on Team and Enterprise), iOS and Android Claude app plus claude.ai/code, push notifications when a task finishes or needs a decision, and the quote \"your computer has to stay on and the `claude` process has to keep running\"",
      "href": "https://code.claude.com/docs/en/remote-control",
      "fetched": "2026-10-01"
    },
    {
      "note": "Codex Remote on a connected Mac or Windows PC, pairing by scanning a code",
      "href": "https://learn.chatgpt.com/docs/remote",
      "fetched": "2026-10-01; developers.openai.com/codex/remote redirects here"
    },
    {
      "note": "Codex Remote on iOS or Android, SSH hosts reached through the desktop host, notifications when a task completes or needs attention, and the quote \"If that computer sleeps, loses network access, or closes the app, remote access stops until it's available again\"",
      "href": "https://learn.chatgpt.com/docs/remote-connections",
      "fetched": "2026-10-01"
    },
    {
      "note": "Claude Code cloud sessions run on Anthropic-managed infrastructure, keep running after you close your laptop, start from the Code tab in the Claude app, and require GitHub for cloning and pull requests",
      "href": "https://code.claude.com/docs/en/claude-code-on-the-web",
      "fetched": "2026-10-01"
    },
    {
      "note": "Codex Cloud tasks run in OpenAI-managed containers, keep working while your computer is asleep, and set up from GitHub repositories",
      "href": "https://learn.chatgpt.com/docs/cloud",
      "fetched": "2026-10-01"
    },
    {
      "note": "DIY stack with Tailscale, tmux, Prompt, and brrr push notifications, Mac must stay running",
      "href": "https://simonbs.dev/posts/put-your-coding-agents-in-your-pocket/",
      "fetched": "2026-10-01"
    },
    {
      "note": "DIY stack with Tailscale, tmux, Termius, and ntfy push notifications",
      "href": "https://www.qu8n.com/posts/running-claude-code-from-my-phone",
      "fetched": "2026-10-01"
    },
    {
      "note": "Moshi's agent status (working / needs you / done), push notifications, and approvals over SSH, per its own comparison page",
      "href": "https://getmoshi.app/compare",
      "fetched": "2026-10-01"
    },
    {
      "note": "`opencode web`, binding to the network with `--hostname`, and `OPENCODE_SERVER_PASSWORD`",
      "href": "https://opencode.ai/docs/web/",
      "fetched": "2026-10-01"
    }
  ]
};

export default function Page() {
  return <ArticlePage article={article} />;
}
