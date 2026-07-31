// Reusable CSS-only device shell for marketing screenshots.
//
// Non-obvious constraint: the iOS screenshots (ios-sessions.png,
// ios-terminal.png) already include the status bar and the Dynamic Island,
// so PhoneFrame deliberately draws no notch/island cutout — the frame is
// only the surrounding physical shell (rail + buttons) around artwork that
// is already "complete".
//
// Cool-grey Space Black palette for the iPhone rail. METAL_HILITE/METAL_LIGHT
// give the rail real top/bottom lift, METAL_MID is only dark enough to read
// as a mid-band shadow (not a second near-black), leaving a visible step
// down to BEZEL_COLOR where the metal actually ends — that step is what
// stops a dark rail on a dark page from reading as a flat plastic slab.
const METAL_HILITE = "#5a5d62";
const METAL_LIGHT = "#4a4d52";
const METAL_MID = "#35373b";
const METAL_DARK = "#1c1d1f";
// The phone rail's vertical gradient stops: brightest at the very top and
// bottom (and along the corner arcs), with a darker METAL_MID band through
// the middle of each long side — an approximation of how brushed aluminium
// actually catches light. Shared by the rail itself and its side buttons so
// both read as the same piece of metal.
const METAL_RAIL_GRADIENT = `linear-gradient(180deg, ${METAL_HILITE} 0%, ${METAL_LIGHT} 15%, ${METAL_MID} 50%, ${METAL_LIGHT} 85%, ${METAL_HILITE} 100%)`;
// Near-black bezel ring between the metal rail and the glass/screen — this
// is what actually makes the rail read as metal instead of as a flat
// colored border; without it the rail has no dark edge to contrast against.
const BEZEL_COLOR = "#080809";

type DeviceFrameProps = {
  src: string;
  alt: string;
  className?: string;
  priority?: boolean;
};

// PhoneFrame renders caller-supplied `className` on a root element that
// carries NO layout utilities of its own (no width, no position). A caller
// may need to pass `absolute` + a width, and a stray `w-full`/`relative`
// baked in here would collide with those in Tailwind's generated
// stylesheet — the cascade, not JSX prop order, decides the winner, so the
// built-in default can silently beat the caller's override. A bare
// block-level `<div>` already fills its parent's width, so no default is
// needed there; the "relative" positioning context the frame needs
// internally (for its rail/buttons) lives on an inner wrapper instead, where
// the caller's className can never reach it.
function frameImg(src: string, alt: string, priority?: boolean) {
  return priority ? (
    <img src={src} alt={alt} className="block h-auto w-full" fetchPriority="high" />
  ) : (
    <img src={src} alt={alt} className="block h-auto w-full" loading="lazy" />
  );
}

/**
 * An iPhone dark-aluminium rail around a screenshot that already contains
 * the status bar and Dynamic Island. Three nested layers, outside in: the
 * metal rail, a near-black bezel ring (what separates the metal from the
 * glass), then the screen itself.
 */
export function PhoneFrame({ src, alt, className = "", priority }: DeviceFrameProps) {
  return (
    <div className={className}>
      {/* container-type establishes a query context sized to this wrapper's
          rendered width, so the rail/bezel/screen corner radii below (in
          cqw) stay relative to the frame's own width instead of a fixed
          pixel value. */}
      <div
        className="relative drop-shadow-[0_30px_70px_rgba(0,0,0,0.5)]"
        style={{ containerType: "inline-size" }}
      >
        {/* Rail: vertical gradient approximates brushed aluminium's
            top/bottom + corner highlights and mid-side shadow band. The two
            inset shadows add a bright line catching the light along the
            rail's outermost edge and a slightly darker tone along its inner
            edge, where it meets the black bezel — that darker inner tone is
            what keeps the rail from merging into the bezel's near-black. */}
        <div
          className="rounded-[11cqw] p-[2.2%]"
          style={{
            background: METAL_RAIL_GRADIENT,
            boxShadow: `inset 0 0 0 1px rgba(255,255,255,0.55), inset 0 0 0 3px ${METAL_DARK}66`,
          }}
        >
          {/* Bezel: distinct near-black ring inside the rail. */}
          <div className="rounded-[8.5cqw] p-[2.5%]" style={{ background: BEZEL_COLOR }}>
            <div className="overflow-hidden rounded-[7cqw] bg-black">
              {frameImg(src, alt, priority)}
            </div>
          </div>
        </div>

        {/* Side buttons — same metal as the rail, thin bars protruding a
            hair beyond it with rounded outer ends. Positioned as
            percentages of the phone's height, matching real hardware. */}
        <span
          aria-hidden
          className="absolute w-[1.5%] rounded-full"
          style={{ left: "-0.7%", top: "19%", height: "4%", background: METAL_RAIL_GRADIENT }}
        />
        <span
          aria-hidden
          className="absolute w-[1.5%] rounded-full"
          style={{ left: "-0.7%", top: "26%", height: "6.5%", background: METAL_RAIL_GRADIENT }}
        />
        <span
          aria-hidden
          className="absolute w-[1.5%] rounded-full"
          style={{ left: "-0.7%", top: "34%", height: "6.5%", background: METAL_RAIL_GRADIENT }}
        />
        <span
          aria-hidden
          className="absolute w-[1.5%] rounded-full"
          style={{ right: "-0.7%", top: "30%", height: "9%", background: METAL_RAIL_GRADIENT }}
        />
      </div>
    </div>
  );
}
