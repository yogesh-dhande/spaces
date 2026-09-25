# Spaces UI Design Guide

The visual system and reusable interaction patterns for the Spaces Mac and iOS apps. Use it when adding or changing UI so new surfaces read as the same product. What a feature does belongs in `docs/spec.md`; how it is built belongs in `docs/implementation.md`.

## Design Intent

- Spaces is a control plane for active coding work: compact, operational, and calm. Screens favor scanability, direct manipulation, and visible status over decorative chrome.
- Prefer calm density over sparse layouts. Information should fit without feeling cramped.
- Different surfaces share one visual language, so they read as related even when they solve different problems.

## Core Principles

- Keep navigation shallow. When a flow fits one screen or one continuous page, do not add tabs, drill-downs, or modal stacks.
- Put the most important controls inline, next to the data they affect.
- Build hierarchy with spacing, typography, tint, and dividers before adding borders or containers.
- Default to lightweight controls. Primary buttons are rare.
- Keep state next to the thing it describes, so what is live, idle, waiting, failed, selected, or actionable reads without opening another view.
- Edit inline whenever practical.

## Layout

- Lay out for top-to-bottom, left-to-right scanning.
- The main window is a compact navigation sidebar plus a detail area; smaller flows may use simpler layouts when that is clearer.
- Prefer scrollable content over fixed-height panels that hide information below the fold.
- Group to show structure, but avoid deep nesting.
- A secondary column beside a pane's own content (a coding agent's brief) is a fixed-width (300 pt) strip on `surface`, set off from the content by a 1 pt `border` on its leading edge rather than a shadow or gap, so it reads as its own region without competing with the pane's banner. It carries a small header (a title and a muted relative-time caption) over a read-only, selectable body, and has no controls of its own: showing and hiding it belongs to a footer glyph and an overflow-menu item.

## Color And Surfaces

- Colors come from the shared theme tokens, never from one-off values in a view. The values live in `ThemeRegistry` (`spacesterminalcore`): each theme defines one semantic token set per appearance plus the terminal colors exported to embedded Ghostty surfaces, so app chrome and terminals share one palette. `Theme` is the adapter on each platform (AppKit in `spacesui`, SwiftUI in `apps/ios`). Add a new color to the token set, not as an ad hoc color in an adapter or view.
- The shipped theme is `spaces-brand`: a single teal accent over neutral surfaces (warm off-white in light appearance, deep blue-green slate in dark). Both apps default to dark. Status colors carry state; the accent carries selection, focus, and primary actions.
- Surface tokens, from back to front:
  - `bg` (`background` in the token set): the app shell.
  - `surface2`: the secondary surface, for inputs, code-like content, subdued containers, and iOS list header bands.
  - `surface`: cards and grouped content.
  - `paletteSurface`: floating panels such as the command palette and confirmation panels.
- The iOS terminal and browser-session screens sit on a fixed dark terminal surface in both appearances.
- Borders (`border`, `borderStrong`) are soft and structural: they separate content without dominating it.
- Light and dark appearance come from the tokens, never from per-screen color decisions.

## Typography

- Keep type compact. Build hierarchy with weight, spacing, and color before size jumps.
- The type scale below is for the Mac app. There, chrome text is sized by role token, never by a font literal at the call site. Roles live in `TypographyRole` (`spacesterminalcore`) with `Typography` as the AppKit adapter. Type sizing sits outside the theme on purpose: switching themes recolors the interface without moving text.
- Pick a role by what the text is, not by the size you want. A role fixes size and weight together, so a call site never picks its own weight; a genuine variant gets its own role.
- The scale is 20, 16, 14, 13, 12, 11, and 10 pt, with no other sizes and no half points:
  - 20: `pageTitle` (a top-level pane or window). 16: `sheetTitle` (a sheet, form window, setup step, or the command palette).
  - 14: `cardTitle` (a card that leads a pane), `emptyStateTitle` (the centered headline of an empty or loading pane).
  - 13: `sectionTitle`, `rowLabel`, `body`, and the three button labels `primaryButtonLabel`, `secondaryButtonLabel`, `textButtonLabel`.
  - 12: `compactTitle` (a compact element's name, a labeled value's key), `controlLabel` (a control or dense row name), `rowDetail`.
  - 11: `metadataTitle`, `metadataEmphasis`, `metadata` for quiet headers, counts, and supporting text.
  - 10: `captionTitle` and `caption` for dense-row tags, shortcut hints, and footer legends.
- Use monospaced text only for paths, commands, branches, shortcuts, ports, and scripts. Its roles use the same scale: `monoRowLabel` and `monoBody` (12), `monoMetadata` (11), `monoCaption`, `monoBadge`, and `monoBadgeStrong` (10).
- Digits that must align rather than reflow, such as two version numbers side by side, take `Typography.tabularDigits(_:)` over the role already chosen; it changes only digit advance.
- Terminal content is not chrome: it follows the terminal's own font size setting.
- Prefer short labels. Omit helper text when the label and control already say what the input is for; keep it for behavior, constraints, or consequences the control does not show.

## Spacing And Density

- Keep spacing tight and intentional, using a small set of repeated rhythms.
- Avoid large empty regions in information-dense views.
- In wide tables, cap leading identity columns at a readable width and give spare width to a descriptive middle column, so fixed trailing controls do not bunch together.

## Sections And Grouping

- One section per concern; do not mix unrelated controls in a generic settings block.
- Use section cards when they help content read as one unit. Avoid card-on-card nesting.
- When each row of a card owns a piece of setup, expand that setup inline under its row: the panel shares the row's inset surface with no hairline between them and indents to the row's title column. Only one panel in a card is open at a time.

## Status And Feedback

- Convey status with compact glyphs, dots, and tint in a consistent position, not verbose labels. Color reinforces meaning and never carries it alone.
- Status dots speak one vocabulary everywhere:
  - haloed green: running
  - solid green: enabled and healthy but idle, or a run that finished cleanly
  - solid blue: a coding agent that finished its turn
  - solid orange: waiting (a blocked agent)
  - hollow red: stopped or failed
  - hollow muted: switched off or never started
- Compact identity rows (workspaces, automations) use the 10 pt filled/hollow dot; richer detail rows may use the larger dot with its halo.
- Operational sidebar rows tint the name and kind glyph instead of adding pills or row fills: green working or running, orange blocked, blue done, red exited, gray inactive. A workspace header rolls up its rows with priority red, orange, blue, green, gray. Selection uses its own neutral fill and accent rail without hiding that tint.
- An alert wears the same color as the row it came from and keeps that item's own kind glyph.
- When a state has exactly one recovery action, show the action alone, tinted with the state's color and with the detail in its tooltip, rather than a status label beside a button that says the same thing.
- Rows that belong to an unreachable device stay listed at 55% opacity, with the device named in the tooltip. The dimming is the whole marking; the device's own header reports the state.
- Progressive content reveals structure before detail (for example, a diff's file list appears before its patches) and never replaces a pane with a blank loading state.

### Banners

- A content pane can carry one compact, single-line banner in its top-trailing corner that overlays rather than blocks the content.
- A transient banner reports the pane's current action: progress with a Cancel control, an error, or a notice. Errors and notices dismiss themselves after a few seconds or on click; progress stays until its action ends or is cancelled.
- A persistent banner reports a lasting fact about the pane, has no dismiss affordance, and clears when the fact stops being true. A stopped or ended session's banner outlines itself in its state's tint. The connection-health banner (Reconnecting, Device unreachable) fills with the opaque `connectionBannerFill` red at both stages so a stalled connection is noticed at once.
- When the fact has exactly one recovery action, the banner carries it at its trailing end as a bold, underlined label.
- A pane has one banner: a transient banner temporarily replaces the persistent one. Only the banner's control takes clicks; the rest lets clicks through to the pane, except a transient notice, which dismisses on any click.
- When a pane still looks interactive but is not, acting on it pulses its banner rather than doing nothing silently.

### Version-gap surfaces

- A device whose daemon and client cannot talk because of a version gap gets a centered hero in place of that device's detail content, on every client: a small uppercase orange eyebrow naming the state, the two versions large with the side that must move muted and an accent arrow between them, one line on how the fix travels, and at most one action. No card frame, no warning icon. An unknown version renders as "?". A command the user must run on the device is a selectable monospaced block.
- A gap that blocks nothing uses a quiet variant: a muted caption, or a compact accent-outlined card with the one action, above content that stays usable.
- Badge an incompatible or update-pending device inline in device lists and selectors. Other devices stay fully interactive.

## Icons And Chips

- Use icons for status and obvious actions; use text where an icon alone would be ambiguous.
- Chips are small, low-contrast, and compact, for short metadata that benefits from separation. Monospaced chips suit shortcuts, branches, and code-like values. Avoid large capsule badges for routine metadata.

## Actions And Controls

- Keep frequent actions visible and secondary actions quiet; reserve strong emphasis for genuinely primary actions.
- Use icon-only buttons for obvious actions such as edit, remove, copy, reveal, launch, stop, and overflow. A setup action the user has to discover gets an accent-tinted text label beside its icon.
- Destructive row actions use the `trash` icon tinted `Theme.red` and always confirm first. The confirmation names the target in its title, says plainly what the action does and does not touch, marks the destructive button as destructive, and leaves Cancel as the default so Return dismisses it.
- Put infrequent or contextual actions in a trailing `⋯` overflow menu, grouped, with keyboard equivalents where useful. Prefer stock AppKit menu behavior.
- Controls that depend on state show only the actions that apply; an action that cannot fire in the current state is absent, not disabled. The exception is a rendering choice (below), which stays visible and disabled with its reason as the tooltip.
- A footer glyph that toggles a secondary view, rather than performing an action, has three states: accent while the view is showing, muted while it is available but hidden, and absent when there is nothing to show. Its tooltip names the action a click takes. A status glyph differs: it never disappears for having nothing to report.
- To switch among a small fixed set of renderings of one thing (for example, Rendered and Raw), use one segmented control, not separate screens, buttons, or menu items. In a sheet with a navigation bar it sits in the principal slot; in a surface with its own header (such as the Editor's open-file bar) it sits last at the trailing end, so it stays put as the labels before it change. Its segments name only the renderings this item supports, so an item with one rendering shows no control.
- A drag divider between two halves of a view is a hairline with a wider hit area. It tints to the accent on hover and while dragging, takes a tab stop, and moves with the arrow keys. A divider that splits a view evenly by default keeps its position while the view is open and does not persist it.

## Forms

- Keep forms compact and aligned, with a few clearly grouped fields rather than long generic forms.
- Inputs have subtle borders and an accent-colored focus state. Code-like or multiline input sits on `surface2`.

## Inline Editing

- The collapsed and editing states read as two states of the same object.
- A row is renamed by becoming the field: its label is swapped for a text field in place. Return commits, Escape cancels, an empty value cancels, and committing the unchanged value just closes the field. A refusal from the device shows as a line under the row with the field left open.
- A new item enters as a draft row, already editing, inside the container it will belong to. Canceling a never-saved draft removes the row.
- A single-value label, such as a device name, offers Rename from its context menu (long-press on iOS) and may also enter editing on double-click, with no separate Save and Cancel buttons.
- An open inline field outranks a refresh of the list behind it: the list holds the refreshed content back until the field commits or cancels.
- Keep a file's edit state attached to that file: its save status and conflict recovery sit in the file's own header, not in global chrome.
- Reserve detached modal editors for edits too large, risky, or complex to do inline.

## Navigation

- Navigation is quiet, stable, and predictable. Selection is obvious without being loud. Secondary actions in navigation stay subordinate until hover or selection.
- A selected expandable row reads as one selected region: the selection fill and border wrap the row together with its visible children. Persistent entries such as Alerts use the same selection fill and border.
- A pinned status row (a row that reports a state and opens a menu rather than navigating) is the exception: no selection fill or rail, no keyboard focus, skipped by arrow navigation, pinned to an edge rather than scrolling. It reads as one dense line (glyph, caption, the state in accent, a monospaced count, its shortcut hint), mutes its glyph when the state is empty, and drops the shortcut hint first when narrow.
- A nested list encodes depth twice: a leading glyph that says what the row is, and indentation that says where it sits. In the Mac sidebar, a project row leads with a type glyph (a commit-graph mark for a Git project, a folder for a plain directory, a house for the device's home row), a Git project's workspace rows indent one level and lead with a status dot, and target rows indent another level and lead with a `⌘`-number hint. A non-Git project is one flat row labeled with its folder name, aligned like a project header.
- A collapsible navigation row carries a muted chevron at its right edge (`chevron.down` expanded, `chevron.right` collapsed). Clicking the chevron toggles expansion without changing selection. Counts before chevrons share one trailing column with peer rows' counts.
- A row with optional content shown elsewhere (a coding-agent row whose agent has a brief) marks it with a small muted `doc.text` glyph at its own trailing edge, apart from the shortcut-hint and chevron column. The glyph is presence-only: shown exactly while the content exists, and not clickable.
- A file tree reserves one leading slot on every row: a directory with contents shows a chevron there (right when collapsed, down when expanded), and other rows leave it empty so names align. File rows then carry a 16 px file-type icon, 6 px before the name, in the icon set's own colors; the icon is presentational (hidden from assistive technology, no tooltip, no focus) and never changes row height.
- Flat tab strips place tabs flush with a neutral selected chip. Close glyphs appear on hover without changing tab width. Drag reorder shows a narrow accent insertion marker and stays within its strip.

## iOS Lists

- The app shell is a native bottom tab bar; each tab owns its navigation stack, and counts ride the tab item as badges.
- Lists use one header-band language: a full-bleed `surface2` band carries each group header and is the only separator. No section cards, borders, or per-row dividers; rows sit on `bg` below their band.
- Row anatomy matches the Mac sidebar: a leading status dot carries state on its own (no state chips), then a type-icon tile, a medium-weight title over a muted detail line (monospaced for paths, commands, and branches), and a trailing muted chevron, or an accent play glyph when the row's primary action is launching it. A coding-agent row with a brief adds the Mac sidebar's muted `doc.text` glyph just before that trailing chevron.
- A row with no run state (a browser session) keeps the dot's slot empty so icons stay aligned, and has no lifecycle context menu.
- Workspace bands lead with a branch glyph (a folder for non-Git workspaces, a house for the home row) and collapse with the trailing chevron. Row lifecycle actions (Run, Stop, Restart) live in long-press context menus, not trailing buttons.
- Group actions get a visible control bar: an expanded workspace starts with a strip of compact pill buttons with icon and text. Hide and Delete stay in the band's long-press menu and trailing swipe. Hide acts at once, since it only changes what the list shows; only Delete, which is irreversible, confirms.

## Web Content Menus

- Web content in a pane (the Editor) cannot extend WebKit's native context menu, so every right-click action there uses one in-page menu: a small panel at the pointer, clamped inside the pane and never wider than it, styled like the toolbar's menus, with an optional muted monospaced header naming the target. Where the system menu is the point (selected text, a live text field, empty space) the native menu is left alone.
- Focus moves to the first item on open and returns on close. Arrow keys move, Return or Space activates, and Escape, an outside click, scrolling, blur, resize, or focus moving elsewhere dismisses it.
- A destructive action there confirms in the same menu, reopened with the target in its header and offering the destructive verb and Cancel. Every destructive action confirms, even when its target looks empty on screen, because a list shows what the device reported, not everything the target holds.

## Motion And Hover

- Motion is minimal and functional; no decorative animation.
- Hover reveals low-emphasis actions, raises action visibility, and adds subtle background feedback.
- A confirmation the user triggered with a keystroke may briefly take the center of the detail pane: a small `paletteSurface` panel with a hairline border naming the state, one line on what it holds, and the chord that acts on it. It appears without animation, stays about a second, and lets clicks through. Everything else transient goes in the banner slot.

## Empty, Missing, And Draft States

- In dense views, show empty or missing values as muted placeholder text, not large empty-state treatments, and keep enough context to act in place.
- A pane whose only content is its recovery actions may center the subject's name, its path in a monospaced caption, and the pill actions that apply, with their shortcut hints beneath.
- Draft state is obvious and easy to complete or cancel. When a draft cannot be sent, explain the missing prerequisite directly under it; do not add a success hint when sending is available.

## Accessibility And Testability

- Give important controls and fields accessibility identifiers.
- Keep reusable UI primitives testable in isolation, and add focused tests for a new primitive where they add value.

## Anti-Patterns

- Navigation depth where a direct layout works.
- Unrelated concerns mixed into one oversized form or panel.
- One-off radii, spacing, button treatments, or color semantics.
- Heavy borders, gradients, or saturated fills on routine controls.
- Verbose labels in place of compact status.
- Modal dialogs for edits that fit inline.
- Colors hard-coded outside the theme tokens, or font sizes outside the type roles on the Mac.
- Important state or actions hidden behind extra clicks.
