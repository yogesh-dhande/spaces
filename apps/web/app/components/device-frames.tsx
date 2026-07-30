// Reusable CSS-only device shells for marketing screenshots.
//
// Non-obvious constraint: the screenshots these frames wrap already bake in
// their own device chrome — /media/hero.png has the macOS traffic-light
// dots painted into its top-left corner, and the iOS screenshots
// (ios-sessions.png, ios-terminal.png) already include the status bar and
// the Dynamic Island. So MacFrame deliberately draws no titlebar/dots, and
// PhoneFrame deliberately draws no notch/island cutout — each frame is only
// the surrounding physical shell (lid + base, or rail + buttons) around
// artwork that is already "complete".
//
// Cool-grey Space Black palette shared by BOTH frames — a MacBook lid/base
// and an iPhone rail are the same dark aluminium, not two different device
// materials. Keeping one palette is also what stops a dark rail on a dark
// page from reading as a flat plastic slab: METAL_HILITE/METAL_LIGHT give
// the rail real top/bottom lift, METAL_MID is only dark enough to read as a
// mid-band shadow (not a second near-black), leaving a visible step down to
// BEZEL_COLOR where the metal actually ends.
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

// Both frames render caller-supplied `className` on a root element that
// carries NO layout utilities of its own (no width, no position). A caller
// may need to pass `absolute` + a width (the hero's overlapping phone does)
// and a stray `w-full`/`relative` baked in here would collide with those in
// Tailwind's generated stylesheet — the cascade, not JSX prop order, decides
// the winner, so the built-in default can silently beat the caller's
// override. A bare block-level `<div>` already fills its parent's width, so
// no default is needed there; the "relative" positioning context each frame
// needs internally (for its base/buttons) lives on an inner wrapper instead,
// where the caller's className can never reach it.
function frameImg(src: string, alt: string, priority?: boolean) {
  return priority ? (
    <img src={src} alt={alt} className="block h-auto w-full" fetchPriority="high" />
  ) : (
    <img src={src} alt={alt} className="block h-auto w-full" loading="lazy" />
  );
}

// Base silhouette: top edge flush with the lid, bottom edge flared to 116%
// width (8% overhang each side), with a shallow rounded scoop cut upward
// into the bottom (front) edge. Coordinates are in viewBox units where 1
// unit = 1% of the lid's width, so pairing this viewBox with an SVG
// `aspect-ratio` of the same ratio makes the whole base — including its
// height — scale purely off the lid's rendered width.
const MAC_BASE_VIEWBOX_WIDTH = 116;
const MAC_BASE_VIEWBOX_HEIGHT = 3.6;
const MAC_BASE_PATH =
  "M8,0 L108,0 L116,3.6 L67.88,3.6 Q67.28,3.6 67.28,3 L67.28,2.76 Q67.28,2.16 66.68,2.16 " +
  "L49.32,2.16 Q48.72,2.16 48.72,2.76 L48.72,3 Q48.72,3.6 48.12,3.6 L0,3.6 Z";

/** A MacBook lid + base around a screenshot that already contains its own titlebar dots. */
export function MacFrame({ src, alt, className = "", priority }: DeviceFrameProps) {
  return (
    <div className={className}>
      {/* container-type establishes a query context sized to this wrapper's
          rendered width (== the lid's own width, since both stretch to the
          same parent), so the lid's corner radius below (in cqw) stays
          relative to the frame's own width instead of a fixed pixel value. */}
      <div
        className="relative drop-shadow-[0_50px_110px_rgba(0,0,0,0.55)]"
        style={{ containerType: "inline-size" }}
      >
        {/* Lid: even bezel, thicker chin at the bottom, rounded only at the top
            so it sits flush against the base directly beneath it. The second
            (negative-offset) inset shadow is a thin darker hinge line at the
            very bottom edge — what makes the lid and base read as two hinged
            pieces instead of one continuous slab. */}
        <div
          className="rounded-t-[1.6cqw] p-[1.5%] pb-[2%] shadow-[inset_0_1px_0_rgba(255,255,255,0.1),inset_0_-2px_0_rgba(0,0,0,0.55)]"
          style={{ background: `linear-gradient(180deg, ${METAL_LIGHT} 0%, ${METAL_DARK} 100%)` }}
        >
          <div className="overflow-hidden rounded-[0.4rem] bg-black">
            {frameImg(src, alt, priority)}
          </div>
        </div>

        {/* Base: a hair wider than the lid on each side. Drawn as a single SVG
            path (rather than a div + clip-path) so the thumb-scoop can cut
            into the outer silhouette instead of sitting on top of it, and so
            the drop-shadow above follows the true tapered/notched shape. */}
        <div aria-hidden className="relative w-[116%] -ml-[8%]">
          <svg
            viewBox={`0 0 ${MAC_BASE_VIEWBOX_WIDTH} ${MAC_BASE_VIEWBOX_HEIGHT}`}
            preserveAspectRatio="none"
            className="block w-full"
            style={{ aspectRatio: `${MAC_BASE_VIEWBOX_WIDTH} / ${MAC_BASE_VIEWBOX_HEIGHT}` }}
          >
            <defs>
              {/* Thin hinge highlight right at the top edge, a flat deck
                  mid-tone through the body, then darker toward the bottom
                  front edge — a broad top-to-bottom wash reads as a seam
                  under the screen rather than as a metal deck. */}
              <linearGradient id="mac-base-gradient" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stopColor={METAL_HILITE} />
                <stop offset="15%" stopColor={METAL_LIGHT} />
                <stop offset="85%" stopColor={METAL_LIGHT} />
                <stop offset="100%" stopColor={METAL_DARK} />
              </linearGradient>
            </defs>
            <path d={MAC_BASE_PATH} fill="url(#mac-base-gradient)" />
          </svg>
        </div>
      </div>
    </div>
  );
}

/**
 * An iPhone dark-aluminium rail around a screenshot that already contains
 * the status bar and Dynamic Island. Three nested layers, outside in: the
 * metal rail (same METAL_* palette as MacFrame), a near-black bezel ring
 * (what separates the metal from the glass), then the screen itself.
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
