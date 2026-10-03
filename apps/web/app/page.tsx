import Link from "next/link";
import { SiteHeader } from "./components/site-header";
import { SiteFooter } from "./components/site-footer";
import { PrimaryButton } from "./components/primary-button";
import { PhoneFrame } from "./components/device-frames";
import { Key } from "./components/key";
import {
  type AgentAlert,
  type AutomationRow,
  type ComparisonItem,
  type Feature,
  type HeroDevice,
  agentAlerts,
  automationPoints,
  automationRows,
  faqItems,
  githubReleasesURL,
  heroDevices,
  keyFeatures,
  localhostPains,
  remoteNodes,
  spacesFixes,
  workflow,
} from "./content";

export default function HomePage() {
  return (
    <div className="lp relative min-h-screen overflow-x-clip">
      <SiteHeader />

      {/* ── Hero ── */}
      <section className="relative">
        <div className="mx-auto w-full max-w-7xl px-6 pt-14 md:pt-20">
          <div className="mx-auto flex max-w-4xl flex-col items-center text-center">
            <h1 className="text-balance text-[clamp(2rem,4vw,3.5rem)] font-semibold leading-[1.04] tracking-[-0.01em]">
              Your coding agents, <span className="text-accent">reachable from anywhere</span>
            </h1>
            <p className="mt-4 flex items-center justify-center gap-2 font-mono text-[clamp(1rem,1.6vw,1.2rem)] text-accent-2">
              <span className="font-bold text-accent" aria-hidden>
                ❯
              </span>
              on your Mac, a Linux server, or your iPhone
              <span className="hero-caret" aria-hidden />
            </p>
            <p className="mt-7 max-w-[660px] text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Run Claude Code, Codex, and opencode on any of your machines. Check on them from your Mac or iPhone,
              and let them work together.
            </p>
            <div className="mt-8 flex flex-wrap items-center justify-center gap-3">
              <PrimaryButton
                href={githubReleasesURL}
                data-download-placement="hero"
                target="_blank"
                rel="noopener noreferrer"
              >
                Download
              </PrimaryButton>
              <Link
                href="/docs"
                className="inline-flex items-center gap-1.5 rounded-sm border border-line px-5 py-3 text-sm font-semibold transition-colors hover:border-accent hover:text-accent"
              >
                Read Docs
                <span aria-hidden>→</span>
              </Link>
            </div>
          </div>

          <HeroDevices />
        </div>
      </section>

      {/* ── Remote machines ── */}
      <section id="remote" className="mt-24 border-t border-line/70">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="max-w-3xl">
            <h2 className="text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
              Run agents on <span className="text-accent whitespace-nowrap">any of your machines</span>
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Pair another Mac or a Linux server. Each machine runs the Spaces
              service and shows up as its own section in the sidebar, with its
              projects, workspaces, terminals, and agents, all reachable from
              your Mac or iPhone.
            </p>
          </div>

          <div className="mt-14 grid gap-10 lg:grid-cols-[1.1fr_0.9fr] lg:items-center">
            <RemoteDiagram />

            <div className="rounded-sm border border-accent-2/45 bg-[color:color-mix(in_oklab,var(--accent-2)_8%,var(--surface))] p-6 md:p-8">
              <p className="inline-flex items-center gap-2 font-mono text-[0.7rem] uppercase tracking-[0.18em] text-accent-2">
                <span className="h-1.5 w-1.5 rounded-full bg-accent-2" />
                Sessions outlive your laptop
              </p>
              <p className="mt-4 text-lg font-semibold leading-snug tracking-tight text-foreground md:text-xl">
                Like tmux, for everything a session runs.
              </p>
              <p className="mt-3 text-sm leading-6 text-foreground-soft md:text-base md:leading-7">
                Terminals and coding agents run on the Spaces service on that
                machine, not on your laptop. Kick off a build or an agent on a
                remote machine, close the lid, and it keeps running. Reattach
                later from your Mac or iPhone, right where it left off.
              </p>
              <Link
                href="/articles/run-coding-agents-on-a-remote-server"
                className="mt-5 flex w-fit items-center gap-1.5 text-sm font-semibold text-accent transition-colors hover:underline"
              >
                Read the article
                <span aria-hidden>→</span>
              </Link>
            </div>
          </div>
        </div>
      </section>

      {/* ── Take it with you (mobile) ── */}
      <section id="mobile" className="border-t border-line/70 bg-background-soft/40">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="grid gap-10 lg:grid-cols-2 lg:items-center">
            <div className="max-w-xl">
              <p className="inline-flex items-center gap-2 font-mono text-[0.7rem] uppercase tracking-[0.18em] text-foreground-soft">
                <span className="rounded-full border border-accent-2/50 px-2 py-0.5 text-[0.62rem] text-accent-2">
                  TestFlight beta
                </span>
              </p>
              <h2 className="mt-5 text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
                A full client <span className="text-accent whitespace-nowrap">on your iPhone</span>
              </h2>
              <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
                Pair it with a QR code and it connects straight to your Mac or Linux server, even with the Mac app
                closed. See which agent is waiting, answer it in the same terminal, and restart processes.
              </p>
              <p className="mt-4 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
                Invite only for now.{" "}
                <a
                  href="https://github.com/yogesh-dhande/spaces/issues"
                  className="text-accent hover:underline"
                >
                  Ask for an invite
                </a>
                .
              </p>
              <Link
                href="/docs/ios"
                className="mt-6 inline-flex items-center gap-1.5 text-sm font-semibold text-accent transition-colors hover:underline"
              >
                Read the iOS docs
                <span aria-hidden>→</span>
              </Link>
              <Link
                href="/articles/run-coding-agents-from-your-iphone"
                className="mt-3 flex w-fit items-center gap-1.5 text-sm font-semibold text-accent transition-colors hover:underline"
              >
                Read the article
                <span aria-hidden>→</span>
              </Link>
            </div>

            <div className="mx-auto grid w-full max-w-[34rem] grid-cols-2 gap-4 sm:gap-6">
              <PhoneFrame
                src="/media/ios-sessions.png"
                alt="The Spaces iOS app listing each workspace's browser tabs, dev servers, and a Claude Code agent waiting for you"
              />
              <PhoneFrame
                src="/media/ios-terminal.png"
                alt="A Claude Code session open in the Spaces iOS app, with a terminal key row for answering it in the same session"
              />
            </div>
          </div>
        </div>
      </section>

      {/* ── Agent orchestration ── */}
      <section id="orchestrate" className="border-t border-line/70">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="max-w-3xl">
            <h2 className="text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
              Let one agent{" "}
              <span className="text-accent whitespace-nowrap">run the others</span>
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Use the Spaces MCP to put one agent in front of everything you have going: a fix in this repo, a
              feature on that branch, an experiment on the Linux server. It spawns Claude Code, Codex, or opencode
              as children and hears back when one finishes or needs you. Point it at the{" "}
              <Link href="/docs/orchestration" className="text-accent hover:underline">
                orchestration guide
              </Link>{" "}
              and it follows your workflow.
            </p>
          </div>

          <div className="mt-14 grid gap-10 lg:grid-cols-[1.1fr_0.9fr] lg:items-center">
            <OrchestrationDiagram />

            <div className="rounded-sm border border-accent-2/45 bg-[color:color-mix(in_oklab,var(--accent-2)_8%,var(--surface))] p-6 md:p-8">
              <p className="inline-flex items-center gap-2 font-mono text-[0.7rem] uppercase tracking-[0.18em] text-accent-2">
                <span className="h-1.5 w-1.5 rounded-full bg-accent-2" />
                Cross-harness · cross-model · cross-device
              </p>
              <p className="mt-4 text-lg font-semibold leading-snug tracking-tight text-foreground md:text-xl">
                The right agent for every piece of work.
              </p>
              <ul className="mt-4 space-y-3 text-sm leading-6 text-foreground-soft md:text-base md:leading-7">
                <li>
                  <strong className="font-semibold text-foreground">Mix harnesses.</strong>{" "}
                  Claude Code, Codex, and opencode: any of them can lead, any can
                  be a child.
                </li>
                <li>
                  <strong className="font-semibold text-foreground">Mix models.</strong>{" "}
                  Each agent runs whatever model its harness supports, so you pick
                  the right brain for each job.
                </li>
                <li>
                  <strong className="font-semibold text-foreground">Mix machines.</strong>{" "}
                  Children run wherever you have them: a Linux server does the
                  heavy lifting while you drive from your Mac.
                </li>
              </ul>
              <p className="mt-5 text-sm leading-6 text-foreground-soft md:text-base md:leading-7">
                Every child is a real terminal in the app. Alerts surface whoever
                needs you, and one shortcut jumps you to any agent&apos;s pane.
              </p>
              <Link
                href="/docs/orchestration"
                className="mt-6 inline-flex items-center gap-1.5 text-sm font-semibold text-accent transition-colors hover:underline"
              >
                Read the orchestration guide
                <span aria-hidden>→</span>
              </Link>
              <Link
                href="/articles/coding-agents-working-together"
                className="mt-3 flex w-fit items-center gap-1.5 text-sm font-semibold text-accent transition-colors hover:underline"
              >
                Read the article
                <span aria-hidden>→</span>
              </Link>
            </div>
          </div>
        </div>
      </section>

      {/* ── Automations ── */}
      <section id="automations" className="border-t border-line/70 bg-background-soft/40">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="grid gap-10 lg:grid-cols-[0.9fr_1.1fr] lg:items-center lg:gap-14">
            <div>
              <h2 className="text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
                Put agents on <span className="text-accent whitespace-nowrap">a schedule</span>
              </h2>
              <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
                An automation starts any agent with a prompt, or runs a script, in one of your
                workspaces, on demand or on a schedule. It runs on the machine it belongs to, your Mac or a Linux
                server, even while the Spaces app is closed.
              </p>
              <ul className="mt-8 grid gap-x-8 gap-y-6 sm:grid-cols-2">
                {automationPoints.map((point) => (
                  <li key={point.title}>
                    <h3 className="text-base font-semibold tracking-tight text-foreground">{point.title}</h3>
                    <p className="mt-1.5 text-sm leading-6 text-foreground-soft">{point.description}</p>
                  </li>
                ))}
              </ul>
              <Link
                href="/docs/automations"
                className="mt-8 inline-flex items-center gap-1.5 text-sm font-semibold text-accent transition-colors hover:underline"
              >
                Read the automations docs
                <span aria-hidden>→</span>
              </Link>
            </div>

            <AutomationsPanel />
          </div>
        </div>
      </section>

      {/* ── Agent alerts ── */}
      <section id="agents" className="border-t border-line/70">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="max-w-3xl">
            <h2 className="text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
              Know which agent needs you,{" "}
              <span className="text-accent whitespace-nowrap">
                and jump straight to it
              </span>
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Run agents across a dozen workspaces and
              it&apos;s easy to lose track of who&apos;s waiting. Each agent
              reports working, waiting on you, or done. Alerts gathers the ones that
              need you into a single list, so you see what&apos;s stuck or
              finished at a glance and jump to its terminal or workspace with a
              keystroke.
            </p>
          </div>

          <div className="mt-14 grid gap-10 lg:grid-cols-[1.1fr_0.9fr] lg:items-center">
            <AlertsPanel />

            <div className="rounded-sm border border-accent-2/45 bg-[color:color-mix(in_oklab,var(--accent-2)_8%,var(--surface))] p-6 md:p-8">
              <p className="inline-flex items-center gap-2 font-mono text-[0.7rem] uppercase tracking-[0.18em] text-accent-2">
                <span className="h-1.5 w-1.5 rounded-full bg-accent-2" />
                One list, every agent
              </p>
              <p className="mt-4 text-lg font-semibold leading-snug tracking-tight text-foreground md:text-xl">
                Open Alerts, jump to whoever needs you.
              </p>
              <p className="mt-3 text-sm leading-6 text-foreground-soft md:text-base md:leading-7">
                Press <Key>⌘⌥A</Key> in Spaces to open Alerts. Agents
                waiting on you clear the moment they move again, and finished agents stay
                until you dismiss them, so the list is always exactly what needs
                your attention. Select one to focus its terminal, or jump to its
                workspace to see everything around it.
              </p>
              <div className="mt-6 flex flex-wrap items-center gap-2">
                <span className="font-mono text-[0.62rem] uppercase tracking-[0.16em] text-foreground-soft">
                  Works with
                </span>
                {["Claude Code", "Codex", "opencode"].map((name) => (
                  <span
                    key={name}
                    className="rounded-full border border-line/80 bg-surface/60 px-2.5 py-1 text-xs text-foreground"
                  >
                    {name}
                  </span>
                ))}
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* ── Workspace model ── */}
      <section className="border-t border-line/70 bg-background-soft/40">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="max-w-3xl">
            <h2 className="text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
              One workspace per task.{" "}
              <span className="text-accent">Open, switch, and close as a unit.</span>
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Every agent above runs inside a workspace. A workspace is one feature, branch, or experiment with its own
              directory, named services on stable URLs, processes, browser
              sessions, and coding-agent terminals. Starting it launches every
              configured process and tracks every window. Stopping it shuts
              everything down. Starting it again brings the configured
              processes back.
            </p>
          </div>

          <div className="mt-14 grid gap-12 lg:grid-cols-[1fr_0.82fr] lg:items-start">
            <ol className="max-w-2xl">
            {workflow.map((step, i) => (
              <li
                key={step.n}
                className="grid grid-cols-[auto_1fr] gap-x-6 gap-y-2"
              >
                <div className="flex flex-col items-center">
                  <span className="font-mono text-2xl font-semibold leading-none text-accent-2 tabular-nums md:text-3xl">
                    {step.n}
                  </span>
                  {i < workflow.length - 1 ? (
                    <span aria-hidden className="mt-2 w-px flex-1 bg-line/70" />
                  ) : null}
                </div>
                <div className={i < workflow.length - 1 ? "pb-10" : ""}>
                  <h3 className="text-xl font-semibold tracking-tight md:text-2xl">
                    {step.label}
                  </h3>
                  <p className="mt-2 max-w-2xl text-xs leading-6 text-foreground-soft md:text-sm md:leading-7">
                    {step.body}
                  </p>
                </div>
              </li>
            ))}
            </ol>

            <WorkspaceSidebarMock />
          </div>
        </div>
      </section>

      {/* ── Ports & cookies ── */}
      <section id="proxy" className="border-t border-line/70">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="max-w-3xl">
            <h2 className="text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
              One localhost, one cookie jar, <span className="text-accent">every branch colliding</span>
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Three worktrees, one <code>localhost</code>: the ports collide, and since browsers scope
              cookies to hostname (not port), logging into one logs you into all three. Spaces routes each
              workspace through its own hostname, so every branch gets its own port and its own cookie jar.
            </p>
          </div>

          <div className="mt-14 grid gap-6 lg:grid-cols-2">
            <ComparisonColumn tone="negative" label="Plain localhost" items={localhostPains} />
            <ComparisonColumn tone="accent" label="Spaces with a reverse proxy" items={spacesFixes} />
          </div>
        </div>
      </section>

      {/* ── Built for the keyboard ── */}
      <section className="border-t border-line/70 bg-background-soft/40">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="max-w-3xl">
            <h2 className="text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
              Built for <span className="text-accent">the keyboard</span>
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Context switching is a keystroke, not a window hunt. Focus any
              session (browser or terminal) in the active workspace, cycle
              through one workspace, your alerts, or your agents to stay in flow, or
              jump to any window of any workspace from the global command palette,
              all without lifting your hands off the keyboard. <Link href="/docs/shortcuts" className="text-accent hover:underline">
                Spaces&apos; own shortcuts are configurable.
              </Link>
            </p>
            <p className="mt-6 flex flex-wrap items-center gap-x-2.5 gap-y-2 text-sm text-foreground-soft">
              <Key>⌘1–0</Key>
              <span>focus</span>
              <Key>⌘⌥]</Key>
              <span>cycle</span>
              <Key>⌘⌥-</Key>
              <span>command palette</span>
            </p>
          </div>

          {/* <figure className="mt-12 overflow-hidden rounded-sm border border-line/80 bg-surface/70 p-2 md:p-3">
            <video
              src="/media/demo_nav_palette.mp4"
              autoPlay
              loop
              muted
              playsInline
              className="h-auto w-full rounded-sm"
            />
          </figure> */}
        </div>
      </section>

      {/* ── Features ── */}
      <section id="features" className="border-t border-line/70">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="flex flex-col gap-2 md:flex-row md:items-end md:justify-between">
            <h2 className="text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
              Features
            </h2>
          </div>

          <ol className="mt-12 grid border-t border-line/70 md:grid-cols-2">
            {keyFeatures.map((feature, i) => (
              <FeatureRow key={feature.title} feature={feature} index={i} />
            ))}
          </ol>
        </div>
      </section>

      {/* ── FAQ ── */}
      <section id="faq" className="border-t border-line/70 bg-background-soft/40">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="max-w-3xl">
            <h2 className="text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
              FAQ
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Common questions about setup, tools, and the app. Still stuck?{" "}
              <a
                href="https://github.com/yogesh-dhande/spaces/issues"
                className="text-accent hover:underline"
              >
                Open an issue on GitHub.
              </a>
            </p>
          </div>

          <div className="mt-12 max-w-3xl">
            <div className="divide-y divide-line/70 border-y border-line/70">
              {faqItems.map((item) => (
                <details key={item.question} className="group py-2">
                  <summary className="flex cursor-pointer select-none list-none items-center justify-between py-3 text-base font-semibold text-foreground md:text-lg">
                    {item.question}
                    <span
                      aria-hidden
                      className="ml-4 shrink-0 font-mono text-xs text-accent-2 transition-transform duration-200 group-open:rotate-45"
                    >
                      +
                    </span>
                  </summary>
                  <div className="pb-4 pr-8 text-sm leading-7 text-foreground-soft md:text-base">
                    {item.answer}
                  </div>
                </details>
              ))}
            </div>
          </div>
        </div>
      </section>

      {/* ── CTA ── */}
      <section className="border-t border-line/70">
        <div className="mx-auto w-full max-w-7xl px-6 py-24 md:py-28">
          <h2 className="max-w-2xl text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
            Run it on your Mac
          </h2>
          <p className="mt-4 max-w-2xl text-base leading-7 text-foreground-soft md:text-lg">
            Native macOS, signed DMG, in-app updates via Sparkle. Free and
            open source.
          </p>
          <div className="mt-8 flex flex-wrap gap-3">
            <PrimaryButton
              href={githubReleasesURL}
              data-download-placement="bottom_cta"
              target="_blank"
              rel="noopener noreferrer"
            >
              Download
            </PrimaryButton>
            <Link
              href="/docs"
              className="inline-flex items-center gap-1.5 rounded-sm border border-line px-5 py-3 text-sm font-semibold transition-colors hover:border-accent hover:text-accent"
            >
              Read Docs
              <span aria-hidden>→</span>
            </Link>
          </div>
        </div>
      </section>

      <SiteFooter />
    </div>
  );
}

const sessionTone = {
  waiting: { dot: "bg-accent-2", text: "text-accent-2" },
  working: { dot: "bg-accent", text: "text-accent" },
  done: { dot: "bg-foreground-soft", text: "text-foreground-soft" },
} as const;

function HeroDeviceCard({ device, className = "" }: { device: HeroDevice; className?: string }) {
  return (
    <div className={`w-full rounded-sm border border-line bg-surface text-left ${className}`}>
      <div className="flex items-baseline justify-between gap-3 border-b border-line/70 px-4 py-3">
        <span className="text-sm font-semibold tracking-tight">{device.name}</span>
        <span className="font-mono text-[0.62rem] uppercase tracking-[0.16em] text-foreground-soft">
          {device.kind}
        </span>
      </div>
      <ul className="divide-y divide-line/60">
        {device.workspaces.map((workspace) => (
          <li key={workspace.name} className="px-4 py-3">
            <p className="flex items-center gap-2.5 text-sm">
              <span className="h-2 w-2 shrink-0 rounded-full bg-accent" aria-hidden />
              <span className="truncate font-mono text-foreground">{workspace.name}</span>
            </p>
            <ul className="ml-[0.2rem] mt-2 space-y-1.5 border-l border-line pl-4">
              {workspace.agents.map((agent) => {
                const tone = sessionTone[agent.status];
                return (
                  <li key={agent.agent} className="flex items-center gap-2 font-mono text-xs text-foreground-soft">
                    <span className={`h-1.5 w-1.5 shrink-0 rounded-full ${tone.dot}`} aria-hidden />
                    <span className="text-foreground">{agent.agent}</span>
                    <span aria-hidden>·</span>
                    <span className={tone.text}>{agent.statusLabel}</span>
                    {agent.elapsed ? (
                      <>
                        <span aria-hidden>·</span>
                        <span>{agent.elapsed}</span>
                      </>
                    ) : null}
                  </li>
                );
              })}
            </ul>
          </li>
        ))}
      </ul>
    </div>
  );
}

// Left: the machines agents run on. Right: the Mac app screenshot with the iPhone app
// overlapping its bottom-right corner. The screenshot's right padding (2/3 of the phone
// width) is what the phone overlaps; the bottom padding holds the part that hangs below.
// Below lg the connectors drop out and the right side stacks first.
function HeroDevices() {
  return (
    <figure className="mx-auto mt-14 md:mt-16">
      <figcaption className="sr-only">
        A Mac and a Linux server each running coding agents, driven from the Spaces Mac app and iPhone app.
      </figcaption>
      <div className="grid gap-10 lg:grid-cols-[330px_80px_minmax(0,1fr)] lg:gap-0">
        <div className="order-2 text-left lg:order-none lg:self-center">
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-1">
            {heroDevices.map((device) => (
              <div key={device.name} className="relative">
                <HeroDeviceCard device={device} />
                {/* Spans the 80px grid gap so the line ends at the screenshot's left edge. */}
                <span
                  aria-hidden
                  className="absolute left-full top-1/2 hidden w-20 border-t border-dashed border-line lg:block"
                />
              </div>
            ))}
          </div>
        </div>
        <div aria-hidden className="hidden lg:block" />
        <div className="order-1 text-left lg:order-none">
          {/* Below sm the phone and its gutter scale with the visual's width so the bottom-anchored phone never grows taller than the screenshot and rises over the hero buttons. */}
          <div className="relative pb-10 pr-[20%] sm:pr-[93px] lg:pr-[140px]">
            <div className="overflow-hidden rounded-sm border border-line/80 bg-surface/70 shadow-[0_40px_100px_-60px_color-mix(in_oklab,var(--ink)_55%,transparent)]">
              <img
                src="/media/hero.png"
                alt="The Spaces Mac app with workspaces, terminals, and agent status side by side"
                className="block h-auto w-full"
                fetchPriority="high"
              />
            </div>
            <PhoneFrame
              src="/media/ios-terminal.png"
              alt="A Claude Code session open in the Spaces iPhone app, waiting for an answer"
              className="absolute bottom-0 right-0 w-[30%] sm:w-[140px] lg:w-[210px]"
              priority
            />
          </div>
        </div>
      </div>
    </figure>
  );
}

function RemoteDiagram() {
  return (
    <figure className="rounded-sm border border-line/80 bg-surface/50 p-6 md:p-10">
      <div className="mx-auto flex max-w-md flex-col items-center">
        {/* Hub: your Mac */}
        <div className="w-full max-w-[15rem] rounded-sm border border-accent/45 bg-accent/10 px-5 py-4 text-center">
          <p className="font-mono text-[0.62rem] uppercase tracking-[0.16em] text-accent">
            Your Mac or iPhone
          </p>
        </div>

        {/* Vertical spine from the hub */}
        <span aria-hidden className="h-8 w-px bg-line/80" />

        {/* Horizontal bus + drop ticks (sm+) */}
        <div className="relative w-full">
          <span
            aria-hidden
            className="absolute left-[16.666%] right-[16.666%] top-0 hidden h-px bg-line/80 sm:block"
          />
          <div className="grid gap-4 sm:grid-cols-3">
            {remoteNodes.map((node) => (
              <div key={node} className="flex flex-col items-center">
                <span
                  aria-hidden
                  className="hidden h-6 w-px bg-line/80 sm:block"
                />
                <div className="w-full rounded-sm border border-line/80 bg-background/60 px-4 py-3 text-center">
                  <p className="text-sm font-semibold tracking-tight text-foreground">
                    {node}
                  </p>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
      <figcaption className="mt-8 text-center font-mono text-[0.7rem] uppercase tracking-[0.16em] text-foreground-soft">
        One sidebar · every machine
      </figcaption>
    </figure>
  );
}

// Diagram for the orchestration section: you converse with one orchestrator
// agent, which fans real feature work out to child agents grouped inside the
// machine each one runs on.
function OrchestrationDiagram() {
  const machines: {
    name: string;
    agents: { harness: string; model?: string; task: string }[];
  }[] = [
    {
      name: "Local",
      agents: [
        { harness: "claude", model: "opus", task: "Redesign settings UI" },
        { harness: "opencode", task: "Research auth libraries" },
      ],
    },
    {
      name: "Remote VM",
      agents: [
        { harness: "codex", model: "gpt-5.6-sol", task: "Refactor sync backend" },
      ],
    },
  ];
  return (
    <figure className="rounded-sm border border-line/80 bg-surface/50 p-6 md:p-10">
      <div className="flex flex-col items-center gap-2 sm:flex-row sm:items-center sm:justify-center sm:gap-0">
        {/* You ↔ orchestrator: prompts flow down, results and questions come back */}
        <div className="flex flex-col items-center">
          <div className="w-full max-w-[11rem] rounded-sm border border-accent-2/50 bg-accent-2/10 px-6 py-3 text-center">
            <p className="font-mono text-[0.62rem] uppercase tracking-[0.16em] text-accent-2">
              You
            </p>
          </div>
          <div className="flex flex-col items-center gap-1 py-1 text-foreground-soft">
            <svg width="34" height="30" viewBox="0 0 34 30" aria-hidden="true">
              <line x1="12" y1="2" x2="12" y2="24" stroke="currentColor" strokeWidth="1" />
              <path d="M12 29 L8.5 23 L15.5 23 Z" fill="currentColor" />
              <line x1="22" y1="28" x2="22" y2="6" stroke="currentColor" strokeWidth="1" />
              <path d="M22 1 L18.5 7 L25.5 7 Z" fill="currentColor" />
            </svg>
            <p className="font-mono text-[0.56rem] uppercase tracking-[0.12em]">
              prompts ↓ · results ↑
            </p>
          </div>
          {/* The elbow into the machine rail leaves from the orchestrator box
              itself (sm+); the invisible leading spacer mirrors it so the box
              stays centered under the You box. */}
          <div className="flex items-center">
            <span aria-hidden className="hidden w-7 sm:block" />
            <div className="rounded-sm border border-accent/45 bg-accent/10 px-5 py-3 text-center">
              <p className="font-mono text-[0.62rem] uppercase tracking-[0.16em] text-accent">
                Orchestrator agent
              </p>
            </div>
            <span aria-hidden className="hidden h-px w-7 bg-line/80 sm:block" />
          </div>
        </div>

        {/* Machine branches: rows touch (no gap) so the vertical rail segments
            in each row's connector cell join into one continuous rail. */}
        <div className="flex w-full flex-col sm:w-auto">
          {machines.map((machine, i) => (
            <div
              key={machine.name}
              className="flex flex-col items-center sm:flex-row sm:items-stretch"
            >
              {/* Connector: horizontal tick into the card at its vertical
                  center, plus the rail segment for this row (bottom half on
                  the first row, top half on the last). */}
              <div aria-hidden className="relative hidden w-7 sm:block">
                <span className="absolute left-0 right-0 top-1/2 h-px bg-line/80" />
                <span
                  className={`absolute left-0 w-px bg-line/80 ${
                    i === 0 ? "top-1/2 bottom-0" : "top-0 bottom-1/2"
                  }`}
                />
              </div>
              {/* Vertical drop for the stacked mobile layout */}
              <span aria-hidden className="h-5 w-px bg-line/80 sm:hidden" />
              <div className="w-full py-2 sm:max-w-[24rem]">
                <div className="overflow-hidden rounded-sm border border-line/80 bg-background/40">
                  <div className="flex items-center gap-2 border-b border-line/80 bg-surface/90 px-3 py-2">
                    <span className="h-1.5 w-1.5 rounded-full bg-accent/80" />
                    <p className="font-mono text-[0.58rem] uppercase tracking-[0.14em] text-foreground-soft">
                      {machine.name}
                    </p>
                  </div>
                  <div
                    className={`grid gap-2.5 p-3 ${
                      machine.agents.length > 1 ? "sm:grid-cols-2" : ""
                    }`}
                  >
                    {machine.agents.map((agent) => (
                      <div
                        key={agent.harness}
                        className="rounded-sm border border-line/80 px-3 py-2.5 text-center"
                      >
                        <p className="text-sm font-semibold tracking-tight text-foreground">
                          {agent.harness}
                          {agent.model && (
                            <span className="ml-1.5 font-mono text-[0.58rem] font-normal uppercase tracking-[0.1em] text-accent">
                              {agent.model}
                            </span>
                          )}
                        </p>
                        <p className="mt-1 text-xs leading-5 text-foreground-soft">
                          {agent.task}
                        </p>
                      </div>
                    ))}
                  </div>
                </div>
              </div>
            </div>
          ))}
        </div>
      </div>
      <figcaption className="mt-8 text-center font-mono text-[0.7rem] uppercase tracking-[0.16em] text-foreground-soft">
        One orchestrator, every agent, every machine
      </figcaption>
    </figure>
  );
}

// A muted keycap used inside the app mocks, distinct from the amber marketing
// <Key>. Mirrors the subtle shortcut chips in the real sidebar.
function NumKey({ children }: { children: React.ReactNode }) {
  return (
    <kbd className="inline-flex min-w-[1.35rem] items-center justify-center rounded border border-line bg-foreground/[0.06] px-1.5 py-0.5 font-mono text-[0.62rem] leading-none text-foreground-soft">
      {children}
    </kbd>
  );
}

// Three dimmed traffic-light dots, the window-chrome cue that reads these
// panels as the native app, not a web widget.
function WindowChrome({ children }: { children?: React.ReactNode }) {
  return (
    <div className="flex items-center gap-1.5 border-b border-line/70 px-4 py-3">
      <span className="h-2.5 w-2.5 rounded-full bg-negative/60" />
      <span className="h-2.5 w-2.5 rounded-full bg-accent-2/60" />
      <span className="h-2.5 w-2.5 rounded-full bg-accent/60" />
      {children ? <div className="ml-2 min-w-0">{children}</div> : null}
    </div>
  );
}

function BellIcon({ className = "h-4 w-4" }: { className?: string }) {
  return (
    <svg viewBox="0 0 20 20" fill="none" aria-hidden className={className}>
      <path
        d="M6 8a4 4 0 1 1 8 0c0 3 1 4 1.5 4.5H4.5C5 12 6 11 6 8Z"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinejoin="round"
      />
      <path d="M8.5 15a1.5 1.5 0 0 0 3 0" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
    </svg>
  );
}

function ProjectIcon({ className = "h-4 w-4" }: { className?: string }) {
  return (
    <svg viewBox="0 0 20 20" fill="none" aria-hidden className={className}>
      <circle cx="5" cy="5" r="1.8" stroke="currentColor" strokeWidth="1.4" />
      <circle cx="5" cy="15" r="1.8" stroke="currentColor" strokeWidth="1.4" />
      <circle cx="15" cy="10" r="1.8" stroke="currentColor" strokeWidth="1.4" />
      <path d="M6.8 5H11a2 2 0 0 1 2 2v1M6.8 15H11a2 2 0 0 0 2-2v-1" stroke="currentColor" strokeWidth="1.4" />
    </svg>
  );
}

function GlobeIcon({ className = "h-4 w-4" }: { className?: string }) {
  return (
    <svg viewBox="0 0 20 20" fill="none" aria-hidden className={className}>
      <circle cx="10" cy="10" r="7" stroke="currentColor" strokeWidth="1.4" />
      <path d="M3 10h14M10 3c2 2.2 2 11.8 0 14M10 3c-2 2.2-2 11.8 0 14" stroke="currentColor" strokeWidth="1.4" />
    </svg>
  );
}

function TerminalIcon({ className = "h-4 w-4" }: { className?: string }) {
  return (
    <svg viewBox="0 0 20 20" fill="none" aria-hidden className={className}>
      <rect x="3" y="4" width="14" height="12" rx="1.6" stroke="currentColor" strokeWidth="1.4" />
      <path d="M6 8.5 8.5 11 6 13.5M10.5 13.5H14" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function SparkleIcon({ className = "h-4 w-4" }: { className?: string }) {
  return (
    <svg viewBox="0 0 20 20" fill="none" aria-hidden className={className}>
      <path
        d="M10 3.2c.5 3 1.8 4.3 4.8 4.8-3 .5-4.3 1.8-4.8 4.8-.5-3-1.8-4.3-4.8-4.8 3-.5 4.3-1.8 4.8-4.8Z"
        stroke="currentColor"
        strokeWidth="1.3"
        strokeLinejoin="round"
      />
      <path d="M15 12.5c.2 1.2.7 1.7 1.9 1.9-1.2.2-1.7.7-1.9 1.9-.2-1.2-.7-1.7-1.9-1.9 1.2-.2 1.7-.7 1.9-1.9Z" stroke="currentColor" strokeWidth="1.2" strokeLinejoin="round" />
    </svg>
  );
}

// Sidebar mock for the "One workspace per task" section. Mirrors the real app:
// Alerts entry, a Projects header, and a selected workspace expanded into its
// numbered targets (browser, process, agent), with sibling workspaces below.
function WorkspaceSidebarMock() {
  return (
    <figure className="overflow-hidden rounded-sm border border-line/80 bg-surface/70 shadow-[0_40px_100px_-60px_color-mix(in_oklab,var(--ink)_55%,transparent)]">
      <span className="sr-only">
        The Spaces sidebar: a project with a selected workspace listing its browser session, process, and agent, and other workspaces below.
      </span>
      <WindowChrome />
      <div className="p-2.5" aria-hidden>
        <p className="px-2.5 pb-1 pt-3 font-mono text-[0.62rem] uppercase tracking-[0.16em] text-foreground-soft">
          Projects
        </p>

        <div className="flex items-center gap-2 px-2.5 py-1.5 text-sm font-semibold text-foreground">
          <ProjectIcon />
          <span>spaces</span>
        </div>

        {/* Selected, active workspace, expanded into its targets. */}
        <div className="mt-0.5 rounded-sm border border-accent/40 bg-accent/[0.06]">
          <div className="flex items-center gap-2 px-2.5 py-2 text-sm font-semibold text-foreground">
            <span className="h-2 w-2 rounded-full bg-accent" />
            <span>main</span>
          </div>
          <ul className="space-y-0.5 pb-1.5 pl-2 pr-2.5">
            <TargetRow shortcut="⌘1" icon={<GlobeIcon className="h-3.5 w-3.5" />} label="web" />
            <TargetRow shortcut="⌘2" icon={<TerminalIcon className="h-3.5 w-3.5" />} label="npm:dev" />
            <TargetRow shortcut="⌘3" icon={<SparkleIcon className="h-3.5 w-3.5" />} label="codex" />
          </ul>
        </div>

        <WorkspaceRow name="schema-cleanup" active />
        <WorkspaceRow name="website-updates" />
      </div>
    </figure>
  );
}

function TargetRow({
  shortcut,
  icon,
  label,
}: {
  shortcut: string;
  icon: React.ReactNode;
  label: string;
}) {
  return (
    <li className="flex items-center gap-2.5 rounded-sm px-2 py-1.5">
      <NumKey>{shortcut}</NumKey>
      <span className="text-foreground-soft">{icon}</span>
      <span className="text-sm text-foreground">{label}</span>
    </li>
  );
}

function WorkspaceRow({ name, active }: { name: string; active?: boolean }) {
  return (
    <div className="flex items-center gap-2 px-2.5 py-2 text-sm text-foreground">
      <span
        className={
          active
            ? "h-2 w-2 rounded-full bg-accent"
            : "h-2 w-2 rounded-full border border-foreground-soft/50"
        }
      />
      <span>{name}</span>
    </div>
  );
}

const automationTone = {
  running: { dot: "bg-accent", text: "text-accent" },
  done: { dot: "bg-foreground-soft", text: "text-foreground-soft" },
  skipped: { dot: "bg-accent-2", text: "text-accent-2" },
} as const;

// Decorative Automations list mock: name, then kind, device, and schedule, with the last run's status.
function AutomationsPanel() {
  return (
    <figure className="overflow-hidden rounded-sm border border-line bg-surface text-left">
      <span className="sr-only">
        A list of automations across a Mac and a Linux server, with their schedules and last run status.
      </span>
      <div className="flex items-baseline justify-between gap-3 border-b border-line/70 px-4 py-3">
        <span className="text-sm font-semibold tracking-tight">Automations</span>
        <span className="font-mono text-[0.62rem] uppercase tracking-[0.16em] text-foreground-soft">All devices</span>
      </div>
      <ul className="divide-y divide-line/60" aria-hidden>
        {automationRows.map((row) => (
          <AutomationListRow key={row.name} row={row} />
        ))}
      </ul>
    </figure>
  );
}

function AutomationListRow({ row }: { row: AutomationRow }) {
  const tone = automationTone[row.status];
  return (
    <li className="flex items-start justify-between gap-3 px-4 py-3">
      <div className="min-w-0">
        <p className="truncate text-sm text-foreground">{row.name}</p>
        <p className="mt-1 font-mono text-xs text-foreground-soft">
          {row.kind} · {row.device} · {row.schedule}
        </p>
        {row.note ? <p className="mt-1 font-mono text-xs text-foreground-soft">{row.note}</p> : null}
      </div>
      <p className="flex shrink-0 items-center gap-2 pt-0.5 font-mono text-xs">
        <span className={`h-1.5 w-1.5 shrink-0 rounded-full ${tone.dot}`} aria-hidden />
        <span className={tone.text}>{row.statusLabel}</span>
        {row.elapsed ? <span className="text-foreground-soft">{row.elapsed}</span> : null}
      </p>
    </li>
  );
}

// Alerts panel mock for the agents section. Each row is one agent that raised
// an alert, blocked (amber) or done (teal), with its workspace, agent name,
// and a jump affordance.
function AlertsPanel() {
  return (
    <figure className="overflow-hidden rounded-sm border border-line/80 bg-surface/70 shadow-[0_40px_100px_-60px_color-mix(in_oklab,var(--ink)_55%,transparent)]">
      <span className="sr-only">
        An Alerts list of agents waiting on you or finished, each with its workspace and agent.
      </span>
      <div className="flex items-center border-b border-line/70 px-4 py-3.5">
        <span className="inline-flex items-center gap-2 text-sm font-semibold tracking-tight text-foreground">
          <BellIcon />
          Alerts
        </span>
      </div>
      <ul className="divide-y divide-line/60" aria-hidden>
        {agentAlerts.map((alert, index) => (
          <AlertRow key={alert.workspace} alert={alert} shortcut={`⌘${index + 1}`} />
        ))}
      </ul>
    </figure>
  );
}

function AlertRow({ alert, shortcut }: { alert: AgentAlert; shortcut: string }) {
  const blocked = alert.status === "blocked";
  const tone = blocked ? { dot: "bg-accent-2" } : { dot: "bg-accent" };
  return (
    <li className="flex items-center gap-3 px-4 py-3 sm:px-5">
      <NumKey>{shortcut}</NumKey>
      <span className={`h-2 w-2 shrink-0 rounded-full ${tone.dot}`} aria-hidden />
      <div className="min-w-0 flex-1">
        <p className="flex items-center gap-2 truncate text-sm">
          <span className="font-mono text-foreground">{alert.workspace}</span>
          <span className="text-foreground-soft">{alert.agent}</span>
        </p>
      </div>
    </li>
  );
}

function ComparisonColumn({
  tone,
  label,
  items,
}: {
  tone: "negative" | "accent";
  label: string;
  items: ComparisonItem[];
}) {
  const toneClasses =
    tone === "negative"
      ? {
          border: "border-negative/35",
          bg: "bg-[color:color-mix(in_oklab,var(--negative)_6%,var(--surface))]",
          text: "text-negative",
          dot: "bg-negative",
        }
      : {
          border: "border-accent/35",
          bg: "bg-[color:color-mix(in_oklab,var(--accent)_6%,var(--surface))]",
          text: "text-accent",
          dot: "bg-accent",
        };

  return (
    <div className={`rounded-sm border ${toneClasses.border} ${toneClasses.bg} p-6 md:p-8`}>
      <p
        className={`inline-flex items-center gap-2 font-mono text-[0.7rem] uppercase tracking-[0.18em] ${toneClasses.text}`}
      >
        <span className={`h-1.5 w-1.5 rounded-full ${toneClasses.dot}`} />
        {label}
      </p>
      <ul className="mt-6 space-y-6">
        {items.map((item) => (
          <li key={item.title}>
            <h3 className="text-base font-semibold tracking-tight text-foreground">
              {item.title}
            </h3>
            <p className="mt-1.5 text-sm leading-6 text-foreground-soft">{item.body}</p>
          </li>
        ))}
      </ul>
    </div>
  );
}

type FeatureRowProps = {
  feature: Feature;
  index: number;
};

function FeatureRow({ feature, index }: FeatureRowProps) {
  return (
    <li
      className={`flex gap-5 border-b border-line/70 py-7 md:py-8 ${
        index % 2 === 0 ? "md:border-r md:border-line/70 md:pr-10" : "md:pl-10"
      }`}
    >
      <span className="shrink-0 pt-0.5 font-mono text-xs text-accent tabular-nums">
        {String(index + 1).padStart(2, "0")}
      </span>
      <div className="min-w-0">
        <h3 className="text-base font-semibold tracking-tight">
          {feature.title}
        </h3>
        <p className="mt-2 text-sm leading-6 text-foreground-soft">
          {feature.description}
        </p>
      </div>
    </li>
  );
}
