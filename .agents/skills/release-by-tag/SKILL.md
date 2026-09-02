---
name: release-by-tag
description: Prepare and publish a Spaces release through the repository's tag-triggered GitHub Actions workflow, and promote a tested pre-release to everyone. Use when asked to choose or suggest a Spaces version tag, draft release notes, create a release tag, monitor a release, promote a release, or repair the notes for an existing Spaces release.
---

# Release Spaces by tag

## Inspect release state

1. Read `AGENTS.md`, `docs/dev.md`, `.github/workflows/release.yml` (a thin caller of the shared `.github/workflows/release-build.yml`), `.github/workflows/release-promote.yml`, `.github/workflows/ios-release.yml`, and the Version Metadata Rules before acting.
2. Know the two phases before starting: pushing a tag publishes a GitHub **pre-release** served by the pre-release Sparkle feed, and selecting **Latest** on that release afterwards promotes it onto the stable feed. Tagging alone does not ship a release to everyone.
3. Confirm `gh` authentication and inspect the current branch, worktree, remote default branch, open PRs, existing releases, and local and remote tags.
4. Require the release commit to be on `main`, with a clean worktree and all required GitHub checks passing. Do not tag an unmerged branch or bypass a failed check.
5. Treat `apps/macos/AppVersion.plist` as the authored version source. Never hand-edit generated version files.

## Suggest and confirm a tag

1. Compare the version in `apps/macos/AppVersion.plist`, the highest published Spaces version, and the user-visible changes since the preceding release. Every release is tagged `vMAJOR.MINOR.PATCH`, so count unpromoted pre-releases as published versions: the next tag follows the newest release, not the newest promoted one.
2. Suggest one SemVer tag in `vMAJOR.MINOR.PATCH` form. Explain briefly whether the scope supports a patch, minor, or major increment.
3. Show the exact tag and commit SHA that would be tagged.
4. Ask the user for explicit confirmation before creating or pushing the tag. Do not treat a general request to make a release as confirmation of the suggested tag.
5. If the tag or release already exists, stop and report where it points. Never delete, recreate, or move an existing tag without separate explicit confirmation that names the tag and target commit.

## Draft user-facing release notes

Draft the changelog before tagging so the user can review what will be published.

- Derive content from the actual commit range between the preceding Spaces release tag and the proposed release commit.
- Write concise bullets about outcomes users can see: features, workflow improvements, important fixes, compatibility changes, and installation or upgrade implications.
- Consolidate related commits into one benefit-oriented bullet. Use plain language and active voice.
- Group bullets under short headings such as `Highlights`, `Improvements`, and `Fixes` only when grouping improves scanning.
- Exclude commit hashes, PR-by-PR narration, contributor boilerplate, dependency chores, test-only work, refactors, and the generated full Git log.
- Call out breaking changes, migrations, or required user action prominently. Do not invent impact that the source changes do not support.
- End with a comparison link only when it adds useful detail; do not label the commit list itself as the changelog.

Present the complete proposed notes alongside the tag confirmation. Apply the approved notes to the GitHub release with `gh release edit <tag> --notes-file <file>` after the workflow creates or updates the release.

## Publish and verify

1. Fetch the remote and re-confirm that the selected commit is still the verified `main` tip.
2. Create an annotated tag and push only that tag. A tag matching `v*` triggers two independent workflows: `Release` (`release.yml`) builds and publishes the macOS and Linux artifacts as a GitHub pre-release, and `iOS Release` (`ios-release.yml`) archives the iOS app and uploads it to TestFlight. Neither workflow's result implies the other's, and neither reports the other's failure.
3. Monitor every job in both workflows until completion. Do not report success while jobs are queued, running, skipped because a dependency failed, or failed. Enumerate the tag's workflow runs rather than watching only the one that was expected.
4. If the `Release` workflow succeeds, apply the approved user-facing notes and read the release back.
5. Verify that the release has the expected macOS assets (DMG, Sparkle zip, `appcast.xml`) and both Linux architecture assets, is still flagged as a pre-release, and that `https://usespaces.dev/releases/prerelease/appcast.xml` serves the released version. The website build stages both feeds from GitHub release state, so a release missing `appcast.xml` or the Sparkle zip breaks the next website deploy.
6. Verify that the iOS build reached TestFlight. `iOS Release` signs against Apple Developer account state — a stored distribution certificate that expires yearly, an App Store Connect API key, a provisioning profile Apple issues — so it fails with nothing wrong in the repository and no failing check on the release commit. Read the workflow's run history across the preceding release tags as well: a signing failure persists until the account is repaired, so a first failure and a standing outage are indistinguishable from a single run.
7. Report a macOS release that publishes while the iOS upload fails as a partial release, naming the last version that reached TestFlight. Do not describe the release as published on the strength of the `Release` workflow alone.
8. If any step fails, preserve the tag and report the exact failure. Do not move or retry the tag workflow through destructive tag operations without explicit user approval. Re-running a failed `iOS Release` after the account is repaired needs no new tag.

## Promote a tested pre-release

Promotion is a separate, explicitly requested step. A pre-release stays a pre-release until the user says it has been tested.

1. Confirm with the user which tag is being promoted, and that it has been tested.
2. Promote it by editing the release and selecting **Latest**: the releases UI offers pre-release and latest as one radio choice, so that single selection clears the pre-release flag and pins `latest` in one update. The CLI equivalent is `gh release edit <tag> --prerelease=false --latest`, which must pass both flags to match what the radio does. `latest` is what the stable feed and `install.sh` resolve through. Do not promote a release older than the newest one without the user saying so.
3. The `released` event runs `Release Promote` (`release-promote.yml`), which redeploys the website from the release's commit and confirms the stable feed serves the promoted version. Monitor that run to completion.
4. Verify that `gh api repos/yogesh-dhande/spaces/releases/latest --jq .tag_name` reports the promoted tag (`gh release view` has no `isLatest` field) and that `https://usespaces.dev/releases/appcast.xml` serves the promoted version. If the workflow failed because `latest` had not moved, select **Latest** on the release (or `gh release edit <tag> --latest`) and re-run the workflow by hand: editing an already-promoted release fires `edited`, not `released`, so it does not restart on its own.
5. A pre-release that failed testing is left alone; the fix ships under the next patch tag, and Macs on the pre-release feed pick it up automatically. Do not delete a superseded pre-release to "clean up" without explicit approval.

## Existing failed releases

For an existing failed release, separate safe metadata repair from tag repair:

- Update its title or changelog when requested; this does not change shipped code.
- Report missing assets and the tag's current commit.
- Require explicit confirmation before moving or recreating the tag to point at a fixed commit.
