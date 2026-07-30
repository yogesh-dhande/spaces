# App Store Connect Review Notes (Template)

Paste this into App Store Connect's **App Review Information → Notes** for the SpacesMobile submission. It is a template: replace `<REVIEW_CONTACT_NAME>`, `<REVIEW_CONTACT_EMAIL>`, and `<REVIEW_CONTACT_PHONE>` with real contact details at submission time. Never commit real contact details to this file.

For the review-support workflow (recording the demo bundle, running the pre-submission UI test, staging screenshots) see [`docs/dev.md`](dev.md#demo-mode-recording--app-review).

The pasteable block below (from "What Spaces is" through "Contact") is the text meant to go in the Notes field. Everything above this line is instructions for whoever fills in the template and is not meant to be pasted.

---

<!-- PASTEABLE BLOCK START -->
## What Spaces is

Spaces is a companion app for a developer's own Mac. The Mac runs the Spaces desktop app; the iPhone/iPad app pairs with it over the local network to view and control workspaces, terminals, and coding agents remotely. All computing happens on the user's own Mac — the app has no server backend and executes nothing of its own.

The app has no account, login, or server backend of ours to authenticate against, which is why App Review Information's **Sign-In Required** is **No**: the paywall on launch is an in-app-purchase gate, not a sign-in.

## How to review without a Mac

You do not need a paired Mac to evaluate the app. App Review's IAP sandbox is provisioned automatically, so the purchase below is free and repeatable there and needs no sandbox Apple ID or password from us. After purchasing, enable **Demo Mode** to tour the full app on bundled sample data.

1. Launch Spaces and complete the subscription purchase (yearly auto-renewable, `Spaces` group, free trial for eligible accounts) on the paywall.
2. Open **Settings → Demo Mode** and turn it on, or tap **Try Demo Mode** on the Spaces tab's empty state.
3. A "Demo Mode — sample data" banner stays pinned above every tab; tap **Turn Off** any time to leave it.

## Demo Mode tour

One sample project with three workspaces and their runtime rows, served from bundled recordings — **sample data only**; nothing executes and no real Mac is contacted.

- **Spaces tab**: `harbor-web`, `lantern-api`, and `atlas-docs` workspaces with process and agent rows. Start, Stop, and Restart work against the bundled data on both workspaces and rows.
- **Terminal viewing**: tap a running row (e.g. `harbor-web` frontend) for its recorded output, read-only and scrollable.
- **Agents tab**: the sample coding agent ("Fix checkout 500") waiting for input.
- **Alerts tab**: attention events, including that waiting agent, reflected in the tab badge.
- **Settings tab**: subscription status with working Manage Subscription and Restore Purchases, and a Paired Devices list holding one synthetic "Demo Mac" row.

## Intentionally unavailable, not defects

Deliberate, not bugs:

- **Terminal input, take-over, and the composer**: read-only with a persistent notice, since typing would run shell commands on a Mac not present during review.
- **QR pairing, device switching, and device renaming**: disabled — there is no real Mac to pair with.
- **New Workspace, New Terminal, workspace Hide, and row Rename**: hidden rather than shown and left to fail, since Demo Mode has no backend to serve them.

Turning Demo Mode off restores real paired devices exactly as they were.

## Permissions

Camera (QR pairing) and Local Network (reaching the user's Mac) are requested only on the real pairing path. Demo Mode needs neither — decline both prompts and still review the whole app.

## Subscription details

- Product `dev.usespaces.spacesmobile.yearly` (yearly auto-renewable, group `Spaces`), free introductory trial for eligible accounts.
- The paywall covers Guideline 3.1.2: app name ("Spaces"), price and length ("$29.00/year", or "7 days free, then $29.00/year" when trial-eligible), auto-renewal and cancellation terms, Restore Purchases, a Privacy Policy link (usespaces.dev/privacy), and a Terms of Use link to Apple's standard EULA.
- Unlocks the app shell only — no consumable or non-consumable content, no external purchase path.
- Manage/restore: **Settings → Subscription**.
- Checklist: because the paywall links Apple's standard EULA, leave App Store Connect's **License Agreement** on the default Apple EULA, not a custom one.

## Contact

For questions during review, contact `<REVIEW_CONTACT_NAME>` at `<REVIEW_CONTACT_EMAIL>` / `<REVIEW_CONTACT_PHONE>`.

<!-- PASTEABLE BLOCK END -->
