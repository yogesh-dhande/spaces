---
name: prune-merged
description: Prune everything left behind by merged PRs — their worktrees, local and remote branches, dev profiles with their daemon stacks, staged simulators and remote daemons. Use when asked to clean up after merged PRs or prune worktrees/profiles.
---

# Prune merged-PR leftovers

Remove what merged PRs left behind, and nothing else. Open PRs, branches with no PR, dirty worktrees, live sessions, and anything belonging to the installed app are out of scope: list them in the final report instead of touching them.

## Ground rules

- Never touch the installed profile: `~/.spaces`, its daemon `dev.usespaces.spacesd`, `/Applications/Spaces.app`, or any process whose command line points there.
- Kill a process only after reading its command line and matching it to the profile being pruned; a bare pid from an earlier listing may have been reused.
- Never select anything for deletion by mtime.
- A guard refusing is an answer, not an obstacle: when a safety check fails, keep the item and report it.
- The git stash stack is shared across worktrees; do not touch it.

## Inventory

1. Worktrees: `git worktree list --porcelain` from the main checkout.
2. PR states: `gh pr list --state all --limit 200 --json number,state,headRefName,headRefOid` (raise the limit or paginate if the repo outgrows it) — save it; later decisions read this list.
3. All branches, with and without worktrees: `git for-each-ref refs/heads refs/remotes/origin --format='%(refname:short)'`.
4. Running processes: `ps ax -o pid,command | grep -E "spacesd|SpacesApp|spaces-caddy"`. Map each hit to a profile by the path in its command line.
5. Dev profiles: `ls ~/.spaces-dev/profiles/spaces/`. Each directory is `<branch-slug>-<checkout-hash>`. The slug is lossy — if one slug matches branches with different dispositions, keep the profile.
6. Staged review surfaces from the session: simulators booted for manual review, and — when a review staged Linux — the remote `spacesd@<profile>` service (source `scripts/spaces-e2e-env.sh` and the repo-root `.env` to see the remote config before concluding none exists).

## What qualifies as prunable

- The branch's newest PR is `MERGED` and no PR for it is `OPEN`. A `CLOSED`-but-unmerged PR means committed work would be discarded — ask the user per branch.
- The local head equals the merged PR's `headRefOid`. A branch that advanced, was rebased, or was reused after the merge does not qualify — keep and report.
- Its worktree (if any) is clean — `git -C <wt> status --porcelain` empty, Ghostty submodule too — and holds no human-authored gitignored files. Check at least for a repo-root `.env` (remote host credentials); preserve it aside if present.

## Prune, in this order

Per prunable branch:

1. **Processes.** Quit the profile's dev `SpacesApp` (identity-checked). Stop the daemon only through the stop-if-idle helper in `scripts/spaces-profile-helpers.sh`; if the daemon is still alive afterwards it was not idle — keep the profile and worktree and report. Then kill any leftover `spaces-caddy` whose config path is under the profile, and confirm the signalled pids are gone.
2. **Worktree.** `git -C <wt> submodule deinit apps/macos/vendor/ghostty`, then `git worktree remove <wt>`. If removal refuses specifically because of contained submodules, re-check the tree is clean and `rm -rf` it. Finish with `git worktree prune`.
3. **Branches.** `git branch -D <branch>`. Delete the remote branch only if it still exists and still points at the merged `headRefOid` (GitHub usually auto-deletes it on merge).
4. **Profile.** `rm -rf ~/.spaces-dev/profiles/spaces/<dir>` after confirming nothing has it open (`lsof` on its `spaces.db`, `pgrep -f` on the dir). Also sweep profiles of older merged branches that no longer have worktrees.
5. **Staged review surfaces.** Simulators: `simctl terminate` + `simctl uninstall dev.usespaces.spacesmobile` + `simctl shutdown`, only for the UDID this session staged — other booted simulators may belong to another run. Remote daemons: `spacese2e profile remove --remote <name>` (it refuses live profiles; a refusal means keep and report). Never stop the remote unit with raw systemd commands.

Ephemeral leftovers — `detached-head-*` / `agent-fixture-*` profiles and `spaces-caddy` processes serving `/var/folders/**/spaces-*` temp profiles — are deleted only when the run that created them is known to be finished; otherwise keep and report.

If the session is running inside a worktree being pruned, prune it last and `cd` out first.

## Report

End with two lists: what was pruned, and what was kept with the reason per item (`OPEN PR`, `no PR`, `closed-unmerged`, `head advanced`, `dirty`, `live sessions`, `in use`, `ambiguous slug`).
