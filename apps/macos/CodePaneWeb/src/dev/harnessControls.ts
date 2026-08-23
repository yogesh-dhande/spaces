import { getMockBridgeForHarness } from "../bridge/mockBridge";

/**
 * `npm run dev`-only control: a floating button that simulates a git state
 * change made outside the pane (e.g. the agent committing), so the live
 * refresh path (scope-signature push event -> re-fetch -> scroll-preserving
 * re-render) is exercisable without a real daemon. Not part of the product
 * bridge contract — see `MockSpacesBridge.simulateSignatureChange`.
 */
export function installHarnessControls(container: HTMLElement): void {
  const bar = document.createElement("div");
  bar.style.position = "fixed";
  bar.style.bottom = "10px";
  bar.style.left = "10px";
  bar.style.zIndex = "1000";
  bar.style.font = "12px -apple-system, sans-serif";

  const button = document.createElement("button");
  button.type = "button";
  button.textContent = "Simulate remote change";
  button.style.padding = "6px 10px";
  button.style.borderRadius = "6px";
  button.style.border = "1px solid #888";
  button.style.background = "#222";
  button.style.color = "#fff";
  button.style.cursor = "pointer";
  button.addEventListener("click", () => {
    getMockBridgeForHarness()?.simulateSignatureChange();
  });

  const agentsButton = document.createElement("button");
  agentsButton.type = "button";
  agentsButton.textContent = "Cycle agents";
  agentsButton.style.padding = "6px 10px";
  agentsButton.style.marginLeft = "8px";
  agentsButton.style.borderRadius = "6px";
  agentsButton.style.border = "1px solid #888";
  agentsButton.style.background = "#222";
  agentsButton.style.color = "#fff";
  agentsButton.style.cursor = "pointer";
  agentsButton.addEventListener("click", () => {
    getMockBridgeForHarness()?.simulateAgentsChange();
  });

  bar.appendChild(button);
  bar.appendChild(agentsButton);
  container.appendChild(bar);
}
