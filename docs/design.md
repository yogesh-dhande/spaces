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
- For single-value labels such as a workspace title or a connected-device name, rename in place: a right-click context menu (long-press on iOS) offers Rename, which swaps the label for a text field seeded with the current value. Return commits, Esc reverts, and there are no separate Save/Cancel buttons. A title may also enter this state on double-click.

## Navigation
- Navigation should stay quiet, stable, and predictable.
- Selection should be obvious without becoming loud.
- Secondary actions in navigation should remain visually subordinate until hover or selection makes them relevant.
- Navigation rows should prioritize quick scanning over descriptive prose.
- Example: the current sidebar uses compact single-line project and workspace rows, reserving secondary metadata such as the git branch for the detail views.

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