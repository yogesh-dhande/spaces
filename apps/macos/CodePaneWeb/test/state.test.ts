import { describe, expect, it } from "vitest";
import { codePaneReducer, initialState } from "../src/app/state";

describe("codePaneReducer", () => {
  it("starts from the given initial mode and scope, with unified layout and no open file", () => {
    const state = initialState("diff", { kind: "uncommitted" });
    expect(state).toEqual({
      mode: "diff",
      scope: { kind: "uncommitted" },
      layout: "unified",
      editorPath: undefined,
    });
  });

  it("setMode switches mode without touching scope, layout, or editorPath", () => {
    const state = initialState("diff", { kind: "uncommitted" });
    const next = codePaneReducer(state, { type: "setMode", mode: "editor" });
    expect(next).toEqual({ ...state, mode: "editor" });
  });

  it("setScope replaces the scope, including switching to a named ref", () => {
    const state = initialState("diff", { kind: "uncommitted" });
    const next = codePaneReducer(state, { type: "setScope", scope: { kind: "ref", refName: "main" } });
    expect(next.scope).toEqual({ kind: "ref", refName: "main" });
  });

  it("setLayout toggles split/unified independently of mode", () => {
    const state = initialState("diff", { kind: "uncommitted" });
    const next = codePaneReducer(state, { type: "setLayout", layout: "split" });
    expect(next.layout).toBe("split");
    expect(next.mode).toBe("diff");
  });

  it("openFile sets editorPath", () => {
    const state = initialState("editor", { kind: "uncommitted" });
    const opened = codePaneReducer(state, { type: "openFile", path: "src/main.ts" });
    expect(opened.editorPath).toBe("src/main.ts");
  });

  it("returns a new object (never mutates the input state)", () => {
    const state = initialState("diff", { kind: "uncommitted" });
    const next = codePaneReducer(state, { type: "setLayout", layout: "split" });
    expect(next).not.toBe(state);
    expect(state.layout).toBe("unified");
  });
});
