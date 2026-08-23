import { CodePaneMode, DiffScope } from "../bridge/types";

/** Split vs unified rendering for the diff mode content, independent of `CodePaneMode` (diff vs editor). */
export type DiffLayout = "split" | "unified";

export interface CodePaneState {
  mode: CodePaneMode;
  scope: DiffScope;
  layout: DiffLayout;
  /** Path currently open in Editor mode; unset until a file is picked. */
  editorPath: string | undefined;
}

export type CodePaneAction =
  | { type: "setMode"; mode: CodePaneMode }
  | { type: "setScope"; scope: DiffScope }
  | { type: "setLayout"; layout: DiffLayout }
  | { type: "openFile"; path: string }
  | { type: "closeFile" };

/**
 * Pure state transition function for the pane's top-level mode/scope/layout,
 * kept free of DOM and bridge calls so it is unit-testable on its own (see
 * test/state.test.ts). `app/root.ts` is the only caller, and reacts to the
 * new state by re-fetching data and re-rendering.
 */
export function codePaneReducer(state: CodePaneState, action: CodePaneAction): CodePaneState {
  switch (action.type) {
    case "setMode":
      return { ...state, mode: action.mode };
    case "setScope":
      return { ...state, scope: action.scope };
    case "setLayout":
      return { ...state, layout: action.layout };
    case "openFile":
      return { ...state, editorPath: action.path };
    case "closeFile":
      return { ...state, editorPath: undefined };
    default:
      return state;
  }
}

export function initialState(mode: CodePaneMode, scope: DiffScope): CodePaneState {
  return { mode, scope, layout: "unified", editorPath: undefined };
}
