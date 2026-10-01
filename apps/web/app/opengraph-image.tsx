import { readFileSync } from "node:fs";
import { join } from "node:path";
import { ImageResponse } from "next/og";

export const dynamic = "force-static";
export const alt = "Spaces: manage parallel coding sessions, from anywhere, on any machine.";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

// This image is rendered outside the page's CSS, so the globals.css token
// values are repeated here.
const colors = {
  background: "#0a0f10",
  line: "#2f4547",
  foreground: "#eaf0ef",
  foregroundSoft: "#adc0c4",
  accent: "#59dbcd",
  accent2: "#ffc24d",
};

function dataURI(path: string, mime: string) {
  return `data:${mime};base64,${readFileSync(join(process.cwd(), path)).toString("base64")}`;
}

export default function Image() {
  const logo = dataURI("app/spaces.svg", "image/svg+xml");
  const mac = dataURI("public/media/hero.png", "image/png");
  const phone = dataURI("public/media/ios-terminal.png", "image/png");
  const grid = `rgba(47, 69, 71, 0.18)`;

  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          position: "relative",
          overflow: "hidden",
          background: colors.background,
          backgroundImage: `linear-gradient(${grid} 1px, transparent 1px), linear-gradient(90deg, ${grid} 1px, transparent 1px)`,
          backgroundSize: "48px 48px",
          color: colors.foreground,
        }}
      >
        <div style={{ position: "absolute", left: 66, top: 72, display: "flex", alignItems: "center" }}>
          <img src={logo} width={55} height={55} alt="" />
          <div style={{ marginLeft: 16, fontSize: 31, fontWeight: 600 }}>Spaces</div>
        </div>

        <div
          style={{
            position: "absolute",
            left: 66,
            top: 192,
            width: 480,
            display: "flex",
            flexWrap: "wrap",
            fontSize: 58,
            fontWeight: 600,
            lineHeight: 1.04,
          }}
        >
          <span style={{ marginRight: 16 }}>Manage</span>
          {["parallel", "coding", "sessions"].map((word) => (
            <span key={word} style={{ color: colors.accent, marginRight: 16 }}>
              {word}
            </span>
          ))}
        </div>

        <div
          style={{
            position: "absolute",
            left: 66,
            top: 420,
            display: "flex",
            alignItems: "center",
            fontSize: 28,
            color: colors.accent2,
          }}
        >
          {/* A drawn chevron: the default font has no U+276F glyph. */}
          <svg width="16" height="26" viewBox="0 0 16 26" style={{ marginRight: 14 }}>
            <path
              d="M3 3 L13 13 L3 23"
              fill="none"
              stroke={colors.accent}
              strokeWidth="3.5"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
          <span>from anywhere, on any machine</span>
        </div>

        <div
          style={{
            position: "absolute",
            left: 66,
            top: 564,
            display: "flex",
            fontSize: 22,
            color: colors.foregroundSoft,
          }}
        >
          usespaces.dev · macOS + iOS
        </div>

        <div
          style={{
            position: "absolute",
            left: 600,
            top: 108,
            width: 672,
            height: 444,
            display: "flex",
            overflow: "hidden",
            border: `3px solid ${colors.line}`,
            borderRadius: 14,
            boxShadow: "0 24px 60px rgba(0, 0, 0, 0.55)",
          }}
        >
          <img
            src={mac}
            alt=""
            width={666}
            height={438}
            style={{ objectFit: "cover", objectPosition: "left top" }}
          />
        </div>

        <div
          style={{
            position: "absolute",
            left: 960,
            top: 204,
            width: 180,
            height: 384,
            display: "flex",
            overflow: "hidden",
            border: "7px solid #1c1d1f",
            borderRadius: 38,
            background: "#080809",
            boxShadow: "0 24px 60px rgba(0, 0, 0, 0.6)",
          }}
        >
          <img
            src={phone}
            alt=""
            width={166}
            height={370}
            style={{ objectFit: "cover", objectPosition: "left top" }}
          />
        </div>
      </div>
    ),
    size,
  );
}
