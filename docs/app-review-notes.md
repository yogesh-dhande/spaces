# App Store Connect Review Notes (Template)

Paste this into App Store Connect's **App Review Information → Notes** for the SpacesMobile submission. It is a template: replace every `<PLACEHOLDER>` with a real value at submission time. Never commit real credentials, tokens, or sandbox passwords to this file.

For the review-support workflow (recording the demo bundle, running the pre-submission UI test, staging screenshots) see [`docs/dev.md`](dev.md#demo-mode-recording--app-review).

---

## What Spaces is

Spaces is a companion app for a developer's own Mac. The Mac runs the Spaces desktop app; the iPhone/iPad app pairs with it over the local network and lets the developer view and control their own workspaces, terminals, and coding agents remotely. All computing happens on the user's own Mac — the app has no server backend and executes nothing of its own.

## How to review without a Mac

You do not need a paired Mac to evaluate the app. After the subscription purchase, enable **Demo Mode**, which tours the full app using bundled sample data.

1. Sign in to the sandbox account on the test device: **Settings → App Store → Sandbox Account** with Apple ID `<SANDBOX_APPLE_ID>` (password `<SANDBOX_APPLE_ID_PASSWORD>`).
2. Launch Spaces. The subscription paywall appears (this is the yearly auto-renewable subscription in the `Spaces` group, with a free trial). Complete the purchase — sandbox purchases are free and repeatable.
3. Once subscribed, open **Settings → Demo Mode** and turn it on, **or** on the Spaces tab's empty state tap **Try Demo Mode**.
4. A banner reading "Demo Mode — sample data" stays pinned above every tab; tap **Turn Off** at any time to leave it.

## Demo Mode tour

Demo Mode shows one sample project with several workspaces and their runtime rows. It shows **sample data only** — nothing is executed and no real Mac is contacted.

- **Devices**: the device list shows a single synthetic "Demo Mac". Real pairing (QR scan) is intentionally disabled while Demo Mode is on.
- **Spaces**: browse the sample workspaces (`harbor-web`, `lantern-api`, `atlas-docs`), each with process and agent rows.
- **Terminal viewing**: tap a running row (for example the `harbor-web` frontend) to open its terminal. The recorded output renders read-only and scrollable. Terminals show a notice that **terminal input requires a paired Mac**: input, take-over, and the message composer are unavailable in Demo Mode because typing into a terminal runs commands on the user's real Mac, which is not present during review. This is expected behavior, not a defect.
- **Agents**: the Agents tab lists the sample coding agent ("Fix checkout 500") waiting for input.
- **Alerts**: the Alerts tab (and its tab badge) shows attention events — an agent waiting for input and an exited process.

## Subscription details

- Product: `<SUBSCRIPTION_PRODUCT_ID>` (yearly auto-renewable, subscription group `Spaces`), with a free introductory trial.
- The subscription unlocks the app shell. Demo Mode and real Mac pairing are both available only once subscribed.
- Manage/restore purchases are in **Settings → Subscription**.

## Contact

For any questions during review, contact `<REVIEW_CONTACT_NAME>` at `<REVIEW_CONTACT_EMAIL>` / `<REVIEW_CONTACT_PHONE>`.
