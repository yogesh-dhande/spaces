import "./styles/tokens.css";
import "./styles/app.css";
import { mountRoot } from "./app/root";
import { installGetComposedRangesCompat } from "./compat/getComposedRanges";
import { preloadCodePaneHighlighter } from "./theme";

async function main(): Promise<void> {
  installGetComposedRangesCompat();
  await preloadCodePaneHighlighter();
  const root = document.getElementById("root");
  if (!root) throw new Error("#root element is missing from index.html");
  await mountRoot(root);

  if (import.meta.env.DEV) {
    // Dev-harness-only control surface; tree-shaken out of the production
    // build along with everything it imports (mockBridge, fixtures) since
    // this branch is unreachable there. See bridge/index.ts's doc comment.
    const { installHarnessControls } = await import("./dev/harnessControls");
    installHarnessControls(document.body);
  }
}

void main();
