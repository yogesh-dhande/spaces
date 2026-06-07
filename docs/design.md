# Spaces UI Design Guide

This document defines app-wide visual and interaction guidelines for Spaces.

Use it when adding or updating UI anywhere in the app. The goal is consistency: new surfaces should feel like the same product, not isolated one-off screens.

The current macOS redesign in `apps/macos/Sources/gui` and `design-mocks/workspace-detail` is a strong reference point, but it should be treated as an example of these principles rather than the full definition of them.

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
- The current redesign provides a good baseline example:
  - Section header padding around `10` vertical and `14` horizontal.
  - Row padding around `9` vertical and `14` horizontal.
  - Section corner radius around `10`.
  - Small internal gaps around `6` to `10`.
  - Larger vertical rhythm between major sections around `20`.
- Treat those values as examples of the intended density, not rigid measurements for every screen.
- Avoid oversized empty regions, especially in information-dense workflows.

## Sections And Grouping
- Group related controls and data into clearly bounded sections when that improves scanability.
- Prefer one section per concern instead of mixing unrelated controls into one generic settings block.
- The standard section card pattern is:
  - `ColoredBackgroundView` card with `Theme.surface` fill and corner radius `10`.
  - Header row: semibold title (13pt), optional muted count label (11pt medium), flex spacer, trailing lightweight action — all with edge insets `top: 10, left: 14, bottom: 10, right: 14`.
  - 1pt `Theme.border` divider below the header.
  - Body: a vertical stack of row views with spacing `0` (dividers between rows, not stack spacing).
- Use section cards when they help related content read as one unit. Avoid card-on-card-on-card nesting.
- For single-value sections (e.g., Stop Script), the same card pattern applies with a collapsed preview row and an inline editing state that replaces the preview.
- Example: workspace detail uses separate section cards for processes, browser sessions, coding agents, ports, and stop script rather than one large editor.

## Rows And Lists
- Rows are the default unit for list-based interaction.
- A good row should make the primary label, current state, and next likely action easy to scan.
- The standard collapsed row layout uses edge insets `top: 9, left: 14, bottom: 9, right: 14` and horizontal spacing `10`:
  - Optional shortcut chip (leading).
  - Optional status dot (processes only).
  - 22×22 type icon tile.
  - Primary label (13pt medium, `Theme.text`) + secondary detail (12pt regular, `Theme.muted`) in a horizontal first-baseline stack with spacing `6`.
  - Flex spacer.
  - Trailing action buttons (pencil / xmark), icon-only, muted, borderless.
- Rows have two states: collapsed (summary) and editing (inline form). Clicking the pencil swaps the collapsed subtree for the editing form inside the same row container; Cancel restores the collapsed view.
- Keep repeated list patterns visually consistent across the app.
- Shared primitives live in `apps/macos/Sources/gui/RowPrimitives.swift`. Extend those before inventing unrelated visual treatments.
- Example: the workspace resource editors use this row pattern for processes, browser sessions, coding agents, and ports.

## Status And Feedback
- Status should usually be conveyed with compact iconography and placement, not verbose labels everywhere.
- Keep status indicators small, consistent, and easy to scan.
- Use color to reinforce meaning, not to carry meaning alone.
- Surface actionable state near the affected item.
- Setup recovery panels replace normal workspace detail content while setup is pending, running, or failed. Keep the panel compact: status and timestamps first, recovery actions in one row, and log tail in a monospaced inset area. Show inline setup script editing only after setup fails.
- While setup is running, refresh status and log output in place without exposing normal process, agent, browser, port, or stop-script controls.
- Example: the current status-dot language uses green for running, muted outline for idle, red outline for exited, and orange for waiting/attention.

## Icons And Chips
- Use icons for obvious actions and state.
- Use text labels when icon-only affordances would be ambiguous.
- Use compact chips for short metadata that benefits from separation but should not dominate the layout.
- Chips should stay small, low-contrast, and compact.
- Monospaced chips work well for shortcuts, branch names, and code-like metadata.
- Avoid large capsule badges for routine metadata.
- Example: the current redesign uses shortcut, project, and branch chips plus tinted type-icon tiles for row categories.

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
- Keep save and cancel actions close to the fields they affect.
- Utility panels, such as Mobile Connection, should use compact sections with label/value rows, icon-led primary actions, and dense device rows; QR codes are shown as functional content rather than decorative artwork.

## Inline Editing
- Prefer inline editing when the item being edited is already visible in a list or section.
- The collapsed and editing states should feel like two states of the same object.
- Draft items should enter editing immediately.
- Canceling a never-saved draft should remove the row rather than leaving placeholder data behind.
- Detached modal editors should be reserved for edits that are too large, risky, or complex for inline treatment.
- Inline editing forms use a labeled-field layout: right-aligned muted semibold labels (11pt, min-width `70`) paired with full-width inputs, vertical spacing `6`, edge insets `top: 10, left: 14, bottom: 10, right: 14`. Keep a predictable `Tab` key-view loop across the fields and action buttons. Save stays disabled until required fields are non-empty.
- Multiline or code-like content (e.g., stop script) uses an `NSTextView` inside a `ColoredBackgroundView` with `Theme.surface2` fill and corner radius `8`, at a fixed height of `88pt`.
- The collapsed/editing swap is animated with `NSAnimationContext` at `0.12s` duration.
- Example: the current workspace list editors expand a row into a compact edit form instead of opening a separate editor.

## Navigation
- Navigation should stay quiet, stable, and predictable.
- Selection should be obvious without becoming loud.
- Secondary actions in navigation should remain visually subordinate until hover or selection makes them relevant.
- Navigation rows should prioritize quick scanning over descriptive prose.
- Example: the current sidebar uses compact project rows and two-line workspace rows with muted secondary metadata.

## Command Palettes
- Command palettes should feel fast, compact, and keyboard-first.
- A palette row should keep one clear primary label and one quiet secondary line that adds workspace context and detail without crowding the scan path.
- The selected row should read as a lightweight accent wash, not as a heavy filled button.
- Palette surfaces should stay visually lighter than full windows: minimal chrome, one search field, one result list, and subdued supporting copy.
- Reuse the same icon and status language from workspace rows so the palette feels like an alternate navigation surface, not a separate feature.

## Overflow Menus
- Use a trailing `⋯` overflow button for contextual actions that do not deserve persistent visibility.
- Overflow menus should group low-frequency actions without hiding the primary workflow.
- Include keyboard equivalents where useful.
- Prefer stock AppKit menu behavior unless a richer interaction is clearly needed.
- Example: workspace detail uses overflow for copy-path and reveal-in-Finder actions instead of crowding the header.

## Motion And Hover Behavior
- Motion should be minimal and functional.
- Hover should mostly:
  - Reveal low-emphasis actions.
  - Increase action visibility.
  - Add subtle background feedback.
- Avoid decorative animation. Spaces is tooling-oriented and should feel responsive rather than ornamental.

## Empty, Missing, And Draft States
- Empty or missing values should use quiet placeholders such as `(none)` or `(unnamed)` rather than large empty-state treatments in dense views.
- Missing state should preserve context when possible so the user can act on it in place.
- Draft state should be obvious and easy to complete or cancel.

## Accessibility And Testability
- Add accessibility identifiers to important controls and fields.
- Reusable UI patterns should remain testable in isolation.
- When adding a new visual primitive, consider whether it should have focused tests alongside the implementation.

## Screen-Specific Applications
These are examples of how the general guidelines apply to important parts of the app. They are examples, not universal requirements.

### Main App Shell
- The main window should continue using a compact navigation-plus-detail structure.
- Navigation should feel stable and visually quiet.
- The selected area should be obvious without relying on heavy chrome.

### Workspace Detail
- Workspace detail is a good example of when a single scrollable page is better than multiple tabs.
- A compact header, thin metadata rows, and stacked sections work well for dense operational data.
- The current path row, notes editor, and resource sections are examples of how to surface detail without turning the page into a generic settings form.

### Sidebar Navigation
- Two-line rows are appropriate when an item has one clear identity and one important secondary piece of metadata.
- Inline status indicators and muted secondary metadata are preferred over noisy labels and badges.

### List Editors
- Inline row editing is the preferred pattern for small, repeatable resource collections.
- A collapsed summary state plus an expanded editing state is usually better than pushing users into a detached modal or separate inspector.
- The `+add` button appends a blank draft row and immediately enters editing. Canceling a draft removes the row; saving it commits and calls `onCommit`.
- The section controller owns transient form state; the host persists committed arrays through the orchestrator.
- The current process, browser-session, coding-agent, port, and stop-script editors are examples of this pattern.

## Cross-Platform (iOS)
- The iOS companion app uses the same brand language as the macOS GUI: warm-neutral surfaces, restrained teal accenting, and the status-dot / type-icon-tile / chip / section-card vocabulary.
- iOS mirrors the macOS `Theme` tokens as SwiftUI `Color`s in `apps/ios/Sources/Theme.swift`; the macOS `Theme` and `apps/web/app/globals.css` remain the source of truth, so token values are kept in sync rather than redefined independently.
- Shared iOS row and section primitives live in `apps/ios/Sources/RowPrimitives.swift` (status dot, type-icon tile, metadata chip, section card/header, primary button). Extend those before introducing one-off iOS styles.
- The iOS workspace home uses a compact search field beside an icon-only filter button. Filters are session-local and use grouped toggles for row type and run state rather than persistent settings.
- iOS workspace rows reuse the same status-dot, type-icon tile, chip, and trailing icon-action language as macOS list rows. Process and coding-agent state is conveyed by the status dot rather than a separate state chip. A row tap opens the terminal when a session exists; exited configured process rows with a retained session expose a trailing run icon so inspection and relaunch remain separate actions.
- iOS terminal detail keeps terminal lifecycle actions behind a compact trailing `...` menu so the title and terminal surface remain primary on narrow screens.
- Workspace creation on iOS uses a focused sheet with labeled fields and project-aware branch controls. Git-only fields are hidden for non-git projects so the form stays compact.
- Terminal surfaces stay dark in both appearances, so the iOS terminal view uses a fixed brand-dark background and light-on-dark text rather than the appearance-adaptive tokens, which would otherwise flip with the app's light/dark mode.

## Implementation Guidance
- Reuse `Theme` for color semantics and shared surface styling.
- Reuse `ColoredBackgroundView` for token-backed surfaces that must track appearance changes.
- Reuse `RowPrimitives` for status dots, icon tiles, and chips before introducing bespoke drawing code.
- Keep view-specific state local when it is purely presentational.
- Persist committed edits through the owning controller or orchestrator rather than from low-level visual primitives.
- When a new pattern becomes part of the product language, extract it into a shared primitive instead of re-implementing it ad hoc.

## Anti-Patterns To Avoid
- Adding navigation depth where a direct layout would work.
- Mixing unrelated concerns into one oversized form or panel.
- Creating one-off visual styles with different radii, spacing, button treatments, or color semantics for no strong reason.
- Using heavy borders, gradients, or saturated fills for routine controls.
- Replacing compact status patterns with verbose labels everywhere.
- Pushing simple edits into modal dialogs when inline editing is feasible.
- Hard-coding colors instead of using `Theme`.
- Hiding important state or actions behind unnecessary clicks.

## Current Source References
- Shared AppKit primitives: `apps/macos/Sources/gui/RowPrimitives.swift`
- Theme tokens: `apps/macos/Sources/gui/Theme.swift`
- Current AppKit integration: `apps/macos/Sources/gui/AppKitController.swift`
- Section card examples: `ProcessesSection.swift`, `BrowserSessionsSection.swift`, `AgentLaunchersSection.swift`, `PortsSection.swift`, `StopScriptSection.swift`
- iOS theme tokens: `apps/ios/Sources/Theme.swift`
- iOS row/section primitives: `apps/ios/Sources/RowPrimitives.swift`

When a new UI change does not fit these rules cleanly, update this guide in the same change rather than silently diverging.
