---
name: submit-ios
description: Prepare an iOS App Store submission for Spaces. Asks which version is being submitted, drafts the What's New summary from the commits since the last approved version, prints the submission steps, regenerates and uploads screenshots when the iOS UI changed, updates the App Store Connect drafts, and lists the checks before Submit for Review. Use when asked to submit, prepare, or update an iOS App Store version, or to draft App Store copy or screenshots for one.
---

# Submit the iOS app

This skill prepares a submission. It does not click Submit for Review; the user does that in App Store Connect after checking the list.

## 0. Prerequisites

- `~/.appstoreconnect/asc.py` exists and works: `python3 ~/.appstoreconnect/asc.py /v1/apps/6791713994/appStoreVersions limit=5`. The app id, key, and issuer are in `~/.appstoreconnect/config.env`. If the helper is missing, stop and say so.
- `gh` is authenticated.
- Read `.github/workflows/ios-release.yml` and the "Build, CI, release" notes in `docs/dev.md` before acting. TestFlight upload happens on the `v*` tag; App Store submission is manual.

## 1. Ask which version

Ask the user which version is being submitted (for example `0.22.0`). Do not guess it from the tag list. If the user named one already, confirm it.

## 2. Establish the baseline and state

1. Baseline: the newest App Store version with `appStoreState` `READY_FOR_SALE` (or the last one the user says was approved). Its `versionString` maps to the tag `v<version>`. Report it.
2. Target: the tag `v<target>`. If it does not exist, the target is `origin/main`; say so, since the Mac release train tags the same version. Report the target commit.
3. Existing work: list `/v1/apps/6791713994/reviewSubmissions` filtered to iOS. If a submission is `WAITING_FOR_REVIEW` or `IN_REVIEW`, stop: a new version cannot be added to it. Report what is in flight.
4. Build: confirm the `iOS Release` workflow run for the target tag concluded `success` (`gh run list --workflow ios-release.yml`). Confirm the build appears in App Store Connect as Ready to Submit (`/v1/builds` filtered to the app). If it is missing or still processing, stop and say which.

## 3. Wire compatibility

Read `SpacesWireProtocol.version` from `apps/macos/Sources/spacesterminalcore/SpacesWireProtocol.swift` at the target and at the Mac stable release tag (`gh release list`, the one marked Latest). The numbers must match exactly, because the client and daemon gate on exact equality. If they do not match, stop and report both numbers and which Mac versions the iOS build can pair with. Do not submit on a mismatch without the user's explicit approval.

## 4. Draft the What's New summary

1. List the changes since the baseline that users see on iPhone:
   `git log --no-merges --oneline <baseline>..<target> -- apps/ios apps/macos/Sources/spacesterminalcore apps/macos/Sources/spacesdevicecore docs/spec.md`
   Read the commit bodies for the ones that look user-facing. Use the Mac release notes on GitHub (`gh release view <tag>`) as a model for wording.
2. Drop internal-only work (refactors, tests, storage cleanups, daemon-only fixes). Name the Mac-only items in a scope note instead of the What's New text.
3. Write the text in plain, active language, one bullet per user-visible outcome. No em dashes. App Store What's New is limited to 4000 characters.
4. Save it to `~/Desktop/spaces-appstore-screenshots-<version>/copy/whats-new.txt`, and show it to the user.

## 5. Print the submission steps

Print the steps for this version, using the App Store Connect flow:

1. Create the version: App Store tab, iOS App, `+`, enter the version (or `POST /v1/appStoreVersions` after confirmation).
2. Fill What's New (from step 4), description, promotional text, keywords, and the review notes. Reuse the previous version's text unless it changed.
3. Select the build.
4. Confirm screenshots (step 6).
5. Confirm App Review Information: contact details, demo account or Demo Mode notes.
6. Add for Review, then Submit to App Review. Release type is manual or automatic, as the user chose before.

## 6. Screenshots (only if needed)

1. Decide whether the UI changed: `git diff --name-only <baseline>..<target> -- apps/ios/Sources apps/ios/Resources`. Screens to watch: `Alerts/`, `Spaces/`, `Agents/`, `TerminalDetailView.swift`, `Shared/`. If none of these changed, screenshots can carry over; say so, and skip to step 7.
2. If they changed, regenerate them with `~/.appstoreconnect/screenshots/stage-live2.sh` (staged daemon with seeded fixtures), then `shoot.sh iphone|ipad <name> <tab> [row]` for each screen. Those scripts contain hard-coded scratchpad and worktree paths from the last run, so check and adapt them before running. Capture with the simulator at the status bar time `9:41`.
3. Look at every image before uploading. Do not upload a shot that shows a demo banner, a stale state, or a placeholder.
4. Ask the user to confirm the set. Then upload with `python3 ~/.appstoreconnect/screenshots/upload-shots.py <localizationId> APP_IPHONE_67=<files> APP_IPAD_PRO_3GEN_129=<files>`. Screenshots can only change while the version is editable, so upload before submitting.

## 7. Update the drafts

Each write is outward-facing. Show the planned change and get the user's go-ahead before any PATCH, POST, or DELETE.

- Version localization: `appStoreVersionLocalizations` for the new version gets What's New, description, promotional text, and keywords. Copy the previous values as the starting point, and keep copies in `~/Desktop/spaces-appstore-screenshots-<version>/copy/`.
- Review detail: `appStoreReviewDetail` gets the review notes. Keep the Demo Mode instructions, because the reviewer uses them.
- Build: attach the processed build to the new version.
- Submission: add the version to a `reviewSubmission` as a READY_FOR_REVIEW item. Do not submit it yourself.
- Subscription: if its version or group changed, add it to the same submission. A first-time subscription must be submitted with the binary in the App Store Connect website; check the notes in `app-store-connect-api-access`.

API note: the Apple docs are JS-rendered. Read `https://developer.apple.com/tutorials/data/documentation/appstoreconnectapi/<slug>.json` to confirm an endpoint before using it.

## 8. Checks before Submit for Review

Print this list, filled in with the actual results:

- [ ] Build for `<version>` is Ready to Submit and attached to this version
- [ ] Wire version matches the Mac stable release (`<number>`)
- [ ] What's New text is final and reads correctly
- [ ] Description, promotional text, and keywords are current
- [ ] Screenshots match the current UI for iPhone 6.9" and iPad 13" (or are confirmed unchanged)
- [ ] Review notes include Demo Mode steps and a working path for the reviewer
- [ ] Subscription is in an approved state and included if its version changed
- [ ] Export compliance, content rights, and age rating are answered
- [ ] Release type is what the user chose (manual or automatic)
- [ ] No other iOS submission is in flight
- [ ] Mac-only changes are mentioned in the release notes, not the App Store text

Finish by stating what was verified, what was skipped, and what the user still has to do in App Store Connect.
