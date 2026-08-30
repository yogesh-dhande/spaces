/// <reference types="vitest/config" />
import { defineConfig } from "vitest/config";

// The bundle is loaded from a local `file://` URL inside a WKWebView (see
// README.md), so every asset reference must be relative — never rooted at
// `/` — and the build must not assume a dev server origin.
export default defineConfig({
  base: "./",
  build: {
    target: "es2022",
    // Emitted directly into the Swift package's resources, where it is checked in and
    // bundled into the app via `Bundle.module` (see apps/macos/Package.swift's `spacesui`
    // target and CodePaneWeb/README.md) — Swift builds never need node.
    outDir: "../Sources/spacesui/Resources/CodePane",
    emptyOutDir: true,
    assetsDir: "assets",
    // Keep the dev-harness-only mock bridge and fixtures out of the shipped
    // bundle: bridge/index.ts picks the bridge based on import.meta.env.DEV
    // (Vite's own dev/prod constant, true only under `vite`/`vite dev`), so
    // the mock branch is dead code in `vite build` and Rollup tree-shakes it
    // out of dist along with everything it imports.
    sourcemap: false,
  },
  test: {
    environment: "jsdom",
    include: ["test/**/*.test.ts"],
    css: false,
  },
});
