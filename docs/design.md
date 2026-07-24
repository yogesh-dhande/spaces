# Spaces UI Design Guide

This document defines app-wide visual and interaction guidelines for Spaces Mac and iOS apps.

Use it when adding or updating UI anywhere in the app. The goal is consistency: new surfaces should feel like the same product, not isolated one-off screens.

## Scope
- This guide is for product UI patterns and visual rules.
- `docs/spec.md` remains the source of truth for user-visible behavior.
- `docs/implementation.md` remains the source of truth for structure and data flow.

## Design Intent
- Spaces should feel compact, modern, and operational.
- The app is a control plane for active coding work, so screens should privilege scanability, direct manipulation, and clear status over decorative chrome.
- Prefer calm density over sparse layouts. Information should fit without feeling cramped.
- Use a consistent visual language so different parts of the app feel related even when they solve different problems.

## Core Principles
- Prefer shallow navigation and direct access to context. When a flow can be handled in one screen or one continuous page, prefer that over unnecessary tabs, drill-downs, or modal stacks.
- Show the most important controls inline near the data they affect.
- Use visual hierarchy through spacing, typography, tint, and dividers before introducing more borders or containers.
- Default to lightweight controls. Primary buttons and prominent controls should be rare.
- Keep state visible near the thing it describes so users can scan what is live, idle, waiting, failed, selected, or actionable without opening secondary views.
- Editing should happen inline whenever practical. Avoid sending users to detached modal editors for simple items or short lists.

## Layout
- Prefer layouts that are easy to scan top-to-bottom and left-to-right.
- The main app shell should remain compact and stable rather than decorative.
- Scrollable content areas are preferred over fixed-height panels that hide important information below the fold.
- Use grouping to clarify structure, but avoid excessive nesting.
- The default main-window pattern is a compact navigation area plus a detail area, but smaller flows can use simpler layouts when that is the clearer choice.

## Color And Surfaces
- Use the shared `Theme` tokens as the source of truth. Do not hard-code one-off colors for production UI.
- Token values live in the theme system (`ThemeRegistry` in `spacesterminalcore`): each theme defines one semantic token set per appearance plus the terminal colors exported to embedded Ghostty surfaces, so the app chrome and terminals always share one palette. `Theme` (AppKit) is an adapter over the active descriptor — add new tokens to the descriptor, not as ad-hoc colors in an adapter or view.
- The palette should remain warm-neutral with restrained accenting, not pure grayscale and not loud by default.
- Use a small number of semantic surface layers:
  - Background for the app shell.
  - Secondary/background-soft surface for contrast between regions.
  - Primary surface for cards, grouped content, or elevated panels.
  - Inset surface for editing areas, code-like content, and subdued containers.
- Borders should be soft and structural. They should separate content, not dominate it.
- Respect light and dark mode through semantic tokens rather than per-screen custom color decisions.

## Typography
- Keep typography compact.
- Use weight, spacing, and color to create hierarchy before using large size jumps.
- A typical hierarchy should include:
  - Compact but prominent page titles.
  - Small semibold section titles.
  - Medium-weight primary row labels.
  - Muted secondary detail text.
  - Quiet metadata labels only when they add structure.
- Use monospaced text selectively for paths, commands, branches, shortcuts, ports, and scripts.
- Favor short labels and concise helper text over long explanatory copy inside the interface.

## Spacing And Density
- Preserve tight, intentional spacing.
- Use a small set of repeated spacing rhythms so the app feels coherent.
- Avoid oversized empty regions, especially in information-dense workflows.

## Sections And Grouping
- Group related controls and data into clearly bounded sections when that improves scanability.
- Prefer one section per concern instead of mixing unrelated controls into one generic settings block.
- Use section cards when they help related content read as one unit. Avoid card-on-card-on-card nesting.

## Status And Feedback
- Status should usually be conveyed with compact iconography and placement, not verbose labels everywhere.
- Keep status indicators small, consistent, and easy to scan.
- Use color to reinforce meaning, not to carry meaning alone.
- Surface actionable state near the affected item.
- Daemon-compatibility uses two distinct surfaces scoped to a single device. A blocking surface replaces that device's detail content with an orange-accented card: warning icon, title, and one-line explanation, plus one of a single Restart action, a selectable install-command block (when the fix is reinstalling a Linux daemon rather than restarting it), or no action (when the fix is updating the app instead). A quiet variant is a muted "update pending" caption that never blocks. Badge an incompatible or update-pending device inline in the device list/selector so it reads before the user navigates into it. Keep other paired devices fully interactive.
- Rows belonging to an unreachable device stay listed and are dimmed to 55% opacity, with the device named in the row's tooltip. The dimming is the whole marking — the device's own header caption already reports the state and carries the recovery action, so the rows themselves take no extra icon or label. The same treatment marks any row that stands for an unreachable device, including one that cannot be picked.
- A compact single-line banner may overlay the top-trailing corner of a content pane, rather than blocking it, in two variants. A transient banner carries state tied to that pane's current action: an indeterminate progress state with a Cancel affordance, a transient error, or an informational notice. Progress stays until the triggering action clears it or is cancelled; error and notice variants auto-dismiss after a few seconds or on click. A persistent banner carries a lasting fact about the pane itself, has no Cancel or click-to-dismiss affordance, and clears only when the fact stops being true; it outlines itself in the tint of the state it reports, so it separates from the content behind it instead of reading as one more transient overlay. A pane has one banner: a transient banner overrides the persistent one while it is up, and dismissing it restores the persistent one.
- When a pane's content still looks interactive but is not, the banner is the only thing distinguishing the two, so acting on the pane should pulse it rather than leave the action silently inert.

## Icons And Chips
- Use icons for obvious actions and state.
- Use text labels when icon-only affordances would be ambiguous.
- Use compact chips for short metadata that benefits from separation but should not dominate the layout.
- Chips should stay small, low-contrast, and compact.
- Monospaced chips work well for shortcuts, branch names, and code-like metadata.
- Avoid large capsule badges for routine metadata.

## Actions And Controls
- Prefer lightweight control chrome in dense contexts.
- Reserve strong emphasis for genuinely primary actions.
- Keep frequent actions visible and secondary actions quieter.
- Use icon-only buttons for obvious actions such as edit, remove, copy, reveal, launch, stop, and overflow.
- Use text buttons where clarity matters more than compactness.
- Put infrequent or contextual actions behind an overflow menu instead of overcrowding the main UI.
- Use a segmented control in a sheet's or view's toolbar/navigation-bar principal position to switch between a small, fixed set of content-rendering modes (e.g. Rendered/Raw) instead of separate screens, buttons, or menu items.

## Forms
- Keep forms compact and aligned.
- For simple editors, prefer a small number of clearly grouped fields over long generic forms.
- Inputs should use subtle borders and a clear focus state tied to the accent color.
- Use inset surfaces for code-like or multiline content.

## Inline Editing
- Prefer inline editing when the item being edited is already visible in a list or section.
- The collapsed and editing states should feel like two states of the same object.
- Draft items should enter editing immediately.
- Canceling a never-saved draft should remove the row rather than leaving placeholder data behind.
- Detached modal editors should be reserved for edits that are too large, risky, or complex for inline treatment.
- For single-value labels such as a connected-device name, rename in place: a right-click context menu (long-press on iOS) offers Rename, which swaps the label for a text field seeded with the current value. Return commits, Esc reverts, and there are no separate Save/Cancel buttons. The label may also enter this state on double-click. Workspace names are not renamed this way: a git workspace shows its branch and a non-git workspace shows its folder name, both read-only.

## Navigation
- Navigation should stay quiet, stable, and predictable.
- Selection should be obvious without becoming loud.
- Secondary actions in navigation should remain visually subordinate until hover or selection makes them relevant.
- Navigation rows should prioritize quick scanning over descriptive prose.
- A selected expandable workspace should read as one selected region: the selected-row fill and border wrap the workspace row together with any visible child rows instead of highlighting only the title row.
- Persistent navigation entries such as Alerts use the same selected-row fill and border when active, so the sidebar has one selection language.
- Example: the current sidebar uses compact single-line project and workspace rows. A git workspace row is labeled with its branch; a non-git project owns a single workspace and collapses to one flat row labeled with its folder name, with no nested workspace row, so the folder name is not duplicated across a header and a child. That flat row still reads as a project — title left-aligned like a git project header, sitting in the project rows' leading glyph column — rather than as a nested workspace of the project above it.
- A nested list encodes depth two ways at once: a leading glyph that identifies the row's kind and progressive indentation that shows the nesting. In the sidebar, a project row leads with a project-type glyph (a commit-graph mark for a git repository, a run-state-tinted folder for a plain directory), a git project's workspace rows indent one level under it and lead with a run-state status dot, and runtime-target rows indent a further level and lead with a compact `⌘`-number hint slot. The glyph says what the row is; the indent says where it sits.
- A collapsible navigation row carries its disclosure affordance as a muted right-edge chevron (`chevron.down` when expanded, `chevron.right` when collapsed), kept visually subordinate to the row's own actions. Clicking the chevron toggles expansion without changing the selection, so a row that is both selectable and collapsible (a workspace) keeps the two gestures separate.
- Flat tab strips use subtle separators between neighboring tabs. Close glyphs are contextual actions and should appear on tab hover while preserving stable tab width.

## iOS List Pattern
- The iOS navigation shell is a native bottom tab bar; each tab owns its navigation stack, and badge counts (the Alerts unread count) ride the tab item.
- iOS lists speak one header-band language: a full-bleed secondary-surface (`surface2`) band carries the group header and is the only separation device — no section cards, borders, or per-row dividers. Rows sit directly on the app background beneath their band.
- Row anatomy is shared with the Mac sidebar: a leading status dot carries state on its own (no state chips), followed by a type-icon tile, a medium-weight title over a muted detail line (monospaced for paths, commands, and branches), and a trailing muted chevron — or an accent play glyph when the row's primary action is launching it.
- A row family with no run state (a browser session is a URL, not a process) holds the dot's slot empty rather than drawing a dot or dropping the slot, so the icon column stays aligned down the list. Such a row also carries no lifecycle context menu, since it has nothing to run, stop, or restart.
- Workspace bands lead with a branch glyph (folder for non-git workspaces) and toggle collapse with the standard muted right-edge chevron. Row lifecycle actions (Run, Stop, Restart) live in long-press context menus rather than persistent trailing buttons.
- Group-level actions get a visible control bar rather than a hidden gesture: an expanded workspace leads its rows with a strip of compact pill buttons (icon plus text label, since an icon alone cannot say what Start starts). Destructive or irreversible group actions — Hide — stay in the long-press menu behind a confirmation that names what it will interrupt.
- State-dependent controls render only the actions that currently apply instead of showing disabled ones: a stopped workspace offers Start alone, a running one offers Restart and Stop. A control that can never fire in the current state is absent, not greyed.

## Overflow Menus
- Use a trailing `⋯` overflow button for contextual actions that do not deserve persistent visibility.
- Overflow menus should group low-frequency actions without hiding the primary workflow.
- Include keyboard equivalents where useful.
- Prefer stock AppKit menu behavior unless a richer interaction is clearly needed.

## Motion And Hover Behavior
- Motion should be minimal and functional.
- Hover should mostly:
  - Reveal low-emphasis actions.
  - Increase action visibility.
  - Add subtle background feedback.
- Avoid decorative animation. Spaces is tooling-oriented and should feel responsive rather than ornamental.

## Empty, Missing, And Draft States
- Empty or missing values should use muted text placeholders rather than large empty-state treatments in dense views.
- Missing state should preserve context when possible so the user can act on it in place.
- Draft state should be obvious and easy to complete or cancel.

## Accessibility And Testability
- Add accessibility identifiers to important controls and fields.
- Reusable UI patterns should remain testable in isolation.
- When adding a new visual primitive, consider whether it should have focused tests alongside the implementation.

## Anti-Patterns To Avoid
- Adding navigation depth where a direct layout would work.
- Mixing unrelated concerns into one oversized form or panel.
- Creating one-off visual styles with different radii, spacing, button treatments, or color semantics for no strong reason.
- Using heavy borders, gradients, or saturated fills for routine controls.
- Replacing compact status patterns with verbose labels everywhere.
- Pushing simple edits into modal dialogs when inline editing is feasible.
- Hard-coding colors instead of using `Theme`.
- Hiding important state or actions behind unnecessary clicks.
- Unnecessary card-based layouts that add visual noise.
