---
name: release-by-tag
description: Prepare and publish a Spaces release through the repository's tag-triggered GitHub Actions workflow. Use when asked to choose or suggest a Spaces version tag, draft release notes, create a release tag, monitor a release, or repair the notes for an existing Spaces release.
---

# Release Spaces by tag

## Inspect release state

1. Read `AGENTS.md`, `docs/dev.md`, `.github/workflows/release.yml`, and the Version Metadata Rules before acting.
2. Confirm `gh` authentication and inspect the current branch, worktree, remote default branch, open PRs, existing releases, and local and remote tags.
3. Require the release commit to be on `main`, with a clean worktree and all required GitHub checks passing. Do not tag an unmerged branch or bypass a failed check.
4. Treat `apps/macos/AppVersion.plist` as the authored version source. Never hand-edit generated version files.

## Suggest and confirm a tag

1. Compare the version in `apps/macos/AppVersion.plist`, the highest published Spaces version, and the user-visible changes since the preceding release.
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
2. Create an annotated tag and push only that tag. The `Release` workflow is triggered by tags matching `v*`.
3. Monitor every job in the resulting workflow until completion. Do not report success while jobs are queued, running, skipped because a dependency failed, or failed.
4. If the workflow succeeds, apply the approved user-facing notes and read the release back.
5. Verify that the release has the expected macOS and both Linux architecture assets, is marked appropriately as latest/prerelease, and that the published appcast serves the released version.
6. If any step fails, preserve the tag and report the exact failure. Do not move or retry the tag workflow through destructive tag operations without explicit user approval.

## Existing failed releases

For an existing failed release, separate safe metadata repair from tag repair:

- Update its title or changelog when requested; this does not change shipped code.
- Report missing assets and the tag's current commit.
- Require explicit confirmation before moving or recreating the tag to point at a fixed commit.
