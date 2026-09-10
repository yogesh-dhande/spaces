import Foundation

/// A submodule pointer's change, for a workspace diff file whose entry is a gitlink (git object mode
/// `160000`) rather than ordinary file content. The Editor renders this as a read-only "submodule pointer"
/// summary instead of a text patch: a gitlink's "content" is just a commit id, and diffing it line-by-line
/// like a text file would be meaningless.
///
/// `oldCommit`/`newCommit` are the submodule pointer's full 40-character old/new commit shas, always
/// unabbreviated regardless of `core.abbrev`/`--abbrev`, read from the patch's `Subproject commit` lines
/// except for a pointer-preserving rename, whose patch carries none: that case reports the listing's
/// unchanged commit id on both sides instead. An added submodule has no prior pointer (`oldCommit == nil`);
/// a removed one has no new pointer (`newCommit == nil`). `dirty` is git's own `-dirty` suffix on a gitlink
/// patch's new-side `Subproject commit` line: the submodule's own worktree has uncommitted changes. When
/// the pointer commit itself did not move but the submodule worktree is merely dirty, or a rename left the
/// pointer untouched, `oldCommit == newCommit`, with `dirty` distinguishing the two cases.
///
/// `unmerged` is true when the superproject's index holds the pointer in an unresolved merge state (git
/// status `UU`/`AA`/`DD`/`AU`/`UA`/`DU`/`UD`); the reported commits are then the pointer the worktree
/// currently holds (HEAD's side until the user resolves), not a merged result. While `unmerged` is true,
/// `dirty` is always false: the checkout's own dirtiness is not reported until the conflict is resolved.
///
/// `checkedOut` is whether the diff looked inside the submodule's own repository, and so whether this
/// pointer row has the submodule's changed files nested beneath it. It is false for a submodule the user
/// never initialized (`git submodule update` was never run, so the directory is empty), for one whose
/// checkout does not hold a commit this comparison records (a shallow or unfetched clone), for a removed
/// submodule, whose worktree is gone by definition, and for one nested deeper than the eight levels the
/// diff descends, whose checkout may be perfectly readable but whose contents are not enumerated. The
/// pointer row still reports its commits in every case; what is absent is the nesting.
public struct SpacesDeviceWorkspaceDiffSubmoduleChange: Codable, Equatable, Sendable {
    public let oldCommit: String?
    public let newCommit: String?
    public let dirty: Bool
    public let unmerged: Bool
    public let checkedOut: Bool

    public init(oldCommit: String?, newCommit: String?, dirty: Bool, unmerged: Bool, checkedOut: Bool) {
        self.oldCommit = oldCommit
        self.newCommit = newCommit
        self.dirty = dirty
        self.unmerged = unmerged
        self.checkedOut = checkedOut
    }
}
