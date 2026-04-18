type ScreenshotFrameProps = {
  title: string;
  caption: string;
};

export function ScreenshotFrame({ title, caption }: ScreenshotFrameProps) {
  return (
    <figure className="rounded-2xl border border-line/70 bg-surface/80 p-3">
      <div className="mb-3 flex items-center gap-1.5">
        <span className="h-2.5 w-2.5 rounded-full bg-[#ff6f5b]" />
        <span className="h-2.5 w-2.5 rounded-full bg-[#f8c84f]" />
        <span className="h-2.5 w-2.5 rounded-full bg-[#35cf7a]" />
      </div>
      <div className="rounded-xl border border-dashed border-line bg-background-soft p-5">
        <p className="font-mono text-[0.68rem] uppercase tracking-[0.14em] text-foreground-soft">
          Screenshot Placeholder
        </p>
        <p className="mt-2 text-base font-semibold tracking-tight">{title}</p>
        <p className="mt-1 text-sm leading-6 text-foreground-soft">{caption}</p>
      </div>
    </figure>
  );
}
