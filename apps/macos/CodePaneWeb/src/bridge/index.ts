import { createRealBridge } from "./realBridge";
import { SpacesBridge } from "./types";

/** Common shape both bridge implementations expose beyond `SpacesBridge` itself: the "ready" lifecycle notification that triggers the host's (or mock's) `spaces:init` dispatch. See `app/root.ts` for the startup sequencing this enables. */
export type HostBridge = SpacesBridge & { notifyReady(): void };

/**
 * Selects the bridge implementation.
 *
 * `import.meta.env.DEV` is Vite's own dev/prod constant: true under
 * `vite`/`npm run dev`, false in a `vite build` production bundle. The dev
 * harness always runs in a plain browser tab (no `window.webkit`), so this
 * reuses that existing constant rather than inventing a separate flag. In
 * the production build this makes the mock branch statically unreachable,
 * so Rollup tree-shakes it (and the fixtures it imports) out of `dist`.
 */
export async function createBridge(): Promise<HostBridge> {
  if (import.meta.env.DEV) {
    const { createMockBridge } = await import("./mockBridge");
    return createMockBridge();
  }
  return createRealBridge();
}
