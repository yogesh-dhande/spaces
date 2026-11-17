import { onTestFailed, onTestFinished } from "vitest";
import type * as Pierre from "@pierre/diffs";

/**
 * A completion signal for Pierre's asynchronous rendering (Shiki highlight, header, editor
 * takeover), so a test awaits the render that produces what it asserts instead of polling the DOM
 * against a wall-clock limit that a loaded machine overruns.
 *
 * Use it from a test file as
 * `vi.mock("@pierre/diffs", async (importOriginal) => withRenderSignal(await importOriginal<typeof import("@pierre/diffs")>()))`.
 * Every `CodeView` the product builds then reports each `onPostRender` pass (the same hook
 * `DiffView` uses for its own post-render work) to `untilRendered`.
 */

type Listener = () => void;
type DropFirst<T extends unknown[]> = T extends [unknown?, ...infer Rest] ? Rest : never;

const listeners = new Set<Listener>();

export function withRenderSignal(actual: typeof Pierre): typeof Pierre {
  class SignalingCodeView<LAnnotation = undefined, Caret = undefined> extends actual.CodeView<LAnnotation, Caret> {
    constructor(options?: Pierre.CodeViewOptions<LAnnotation, Caret>, ...rest: DropFirst<ConstructorParameters<typeof Pierre.CodeView>>) {
      const original = options?.onPostRender;
      super(
        {
          ...options,
          onPostRender: ((...args: unknown[]) => {
            (original as ((...a: unknown[]) => void) | undefined)?.(...args);
            for (const listener of [...listeners]) listener();
          }) as NonNullable<Pierre.CodeViewOptions<LAnnotation, Caret>["onPostRender"]>,
        },
        ...rest,
      );
    }
  }
  return { ...actual, CodeView: SignalingCodeView } as typeof Pierre;
}

/**
 * Runs `check` once immediately, so a render that finished before the call does not wait for an
 * event that will never come, then again each time `subscribe`'s callback fires. `subscribe`
 * returns its own teardown, which runs once the check passes and when the test finishes (pass,
 * fail or timeout), so no listener or observer outlives its test.
 *
 * With no deadline of its own, a check that never passes surfaces as the bare test timeout, so the
 * last error `check` threw is attached to the failing test's errors.
 */
function awaitCheck<T>(check: () => T, subscribe: (rerun: () => void) => () => void): Promise<T> {
  let lastError: unknown;
  const attempt = (resolve: (value: T) => void): boolean => {
    try {
      resolve(check());
      lastError = undefined; // a later, unrelated failure must not be blamed on this wait
      return true;
    } catch (error) {
      lastError = error;
      return false;
    }
  };
  return new Promise<T>((resolve) => {
    if (attempt(resolve)) return;
    let unsubscribe: (() => void) | undefined;
    const release = () => {
      unsubscribe?.();
      unsubscribe = undefined;
    };
    unsubscribe = subscribe(() => {
      if (attempt(resolve)) release();
    });
    onTestFinished(release);
    onTestFailed((context) => {
      const errors = context.task.result?.errors;
      if (lastError !== undefined && errors !== undefined) errors.push(lastError as (typeof errors)[number]);
    });
  });
}

/**
 * Resolves with `check`'s value as soon as it stops throwing, re-evaluating it after every Pierre
 * post-render pass (and once up front). There is no time limit of its own: a render that never
 * lands fails the test at the test timeout, not at a polling deadline that load can overrun.
 */
export function untilRendered<T>(check: () => T): Promise<T> {
  return awaitCheck(check, (rerun) => {
    listeners.add(rerun);
    return () => listeners.delete(rerun);
  });
}

/**
 * Like `untilRendered`, for state that product code derives from a DOM mutation outside a Pierre
 * render pass (a hover inserting the gutter utility, an editor id assigned a frame after the
 * render). Pierre renders every file into an open shadow root, so the observer follows each one
 * it finds under `root` as they appear. A product observer on the same tree is registered first,
 * so by the time `check` runs it has already reacted to the mutation.
 */
export function untilMutated<T>(root: ParentNode, check: () => T): Promise<T> {
  return awaitCheck(check, (rerun) => {
    const observed = new Set<ParentNode>();
    const observer = new MutationObserver(() => {
      watch(root);
      rerun();
    });
    function watch(parent: ParentNode): void {
      if (!observed.has(parent)) {
        observed.add(parent);
        observer.observe(parent, { attributes: true, childList: true, subtree: true });
      }
      for (const element of parent.querySelectorAll<HTMLElement>("*")) {
        if (element.shadowRoot !== null) watch(element.shadowRoot);
      }
    }
    watch(root);
    return () => observer.disconnect();
  });
}
