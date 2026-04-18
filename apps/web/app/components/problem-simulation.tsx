type FlowStep = {
  title: string;
  text: string;
};

const beforeSteps: FlowStep[] = [
  { title: "Find UI Tab", text: "Track down the browser tab for the right feature/project." },
  { title: "Find Editor", text: "Locate the matching editor window." },
  { title: "Find Agent", text: "Figure out which terminal/agent session made the change." },
  { title: "Port Collisions", text: "Resolve :3000 collisions and update port references for related services." },
];

const afterSteps: FlowStep[] = [
  { title: "Open Workspace", text: "Jump straight to the workspace for this feature." },
  { title: "Open Window", text: "Bring up its browser/editor/terminal/agent with a keyboard shortcut." },
  { title: "Cycle Fast", text: "Switch within that workspace using keyboard shortcuts." },
  { title: "Stable Ports", text: "Use workspace-owned ports and env without drift." },
];

export function ProblemSimulation() {
  return (

      <div className="mt-4 grid gap-4 md:grid-cols-2">
        <FlowColumn
          tone="before"
          title="Without Muxy"
          steps={beforeSteps}
          outcome="Result: context hunt before real progress begins."
        />
        <FlowColumn
          tone="after"
          title="With Muxy"
          steps={afterSteps}
          outcome="Result: stay within context, faster development loop."
        />
      </div>
  );
}

type FlowColumnProps = {
  tone: "before" | "after";
  title: string;
  steps: FlowStep[];
  outcome: string;
};

function FlowColumn({ tone, title, steps, outcome }: FlowColumnProps) {
  const isBefore = tone === "before";

  const cardClass = isBefore
    ? "border-rose-400/45 bg-rose-400/8"
    : "border-accent/50 bg-accent/10";

  const badgeClass = isBefore
    ? "border-rose-400/60 bg-rose-500/10 text-rose-300"
    : "border-accent/60 bg-accent/15 text-accent";

  return (
    <section className={`rounded-xl border p-3 md:p-4 ${cardClass}`}>
      <p className="text-sm font-semibold tracking-tight">{title}</p>
      <ol className="mt-3 space-y-2">
        {steps.map((step, index) => (
          <li
            key={step.title}
            className="flex items-start gap-2 rounded-lg p-2.5"
          >
            <span
              className={`mt-0.5 inline-flex min-w-7 items-center justify-center rounded-full border px-1.5 py-0.5 text-[0.62rem] font-mono tracking-[0.08em] ${badgeClass}`}
            >
              {index + 1}
            </span>
            <div>
              <p className="text-xs font-mono uppercase tracking-[0.1em] text-foreground-soft">
                {step.title}
              </p>
              <p className="mt-0.5 text-sm leading-5 text-foreground">{step.text}</p>
            </div>
          </li>
        ))}
      </ol>
      <p className="mt-3 rounded-lg border border-dashed border-line/85 bg-surface/60 px-2.5 py-2 text-xs text-foreground-soft">
        {outcome}
      </p>
    </section>
  );
}
