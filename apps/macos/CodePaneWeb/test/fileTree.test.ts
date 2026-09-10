import { describe, expect, it } from "vitest";
import { DiffFileEntry } from "../src/bridge/types";
import { buildFileTree, FileTreeDirNode, FileTreeFileNode, FileTreeNode } from "../src/app/fileTree";

function makeFile(path: string, overrides: Partial<DiffFileEntry> = {}): DiffFileEntry {
  return {
    path,
    status: "modified",
    isBinary: false,
    ...overrides,
  };
}

function dirs(nodes: readonly FileTreeNode[]): FileTreeDirNode[] {
  return nodes.filter((n): n is FileTreeDirNode => n.kind === "dir");
}

function files(nodes: readonly FileTreeNode[]): FileTreeFileNode[] {
  return nodes.filter((n): n is FileTreeFileNode => n.kind === "file");
}

describe("buildFileTree", () => {
  it("returns root-level files with no wrapping directory for paths with no slash", () => {
    const tree = buildFileTree([makeFile("README.md"), makeFile("package.json")]);

    expect(tree).toHaveLength(2);
    expect(files(tree).map((f) => f.name)).toEqual(["README.md", "package.json"]);
    expect(dirs(tree)).toHaveLength(0);
  });

  it("nests a single file under its one parent directory", () => {
    const tree = buildFileTree([makeFile("src/main.ts")]);

    expect(tree).toHaveLength(1);
    const dir = tree[0] as FileTreeDirNode;
    expect(dir.kind).toBe("dir");
    expect(dir.label).toBe("src");
    expect(dir.path).toBe("src");
    expect(dir.children).toHaveLength(1);
    expect((dir.children[0] as FileTreeFileNode).name).toBe("main.ts");
  });

  it("compacts a chain of single-child directories into one row", () => {
    const tree = buildFileTree([makeFile("apps/ios/Sources/ViewerResync.swift")]);

    expect(tree).toHaveLength(1);
    const dir = tree[0] as FileTreeDirNode;
    expect(dir.label).toBe("apps/ios/Sources");
    expect(dir.path).toBe("apps/ios/Sources");
    expect(dir.children).toHaveLength(1);
    expect((dir.children[0] as FileTreeFileNode).name).toBe("ViewerResync.swift");
  });

  it("stops compaction at the first directory with more than one child", () => {
    const tree = buildFileTree([
      makeFile("apps/ios/Sources/ViewerResync.swift"),
      makeFile("apps/ios/Sources/MobileRootView.swift"),
      makeFile("apps/macos/Foo.swift"),
    ]);

    // `apps` has two children (`ios`, `macos`), so the chain stops there instead of folding further.
    expect(tree).toHaveLength(1);
    const apps = tree[0] as FileTreeDirNode;
    expect(apps.label).toBe("apps");
    expect(dirs(apps.children).map((d) => d.label).sort()).toEqual(["ios/Sources", "macos"]);
  });

  it("does not compact a directory holding exactly one file (only directory chains compact)", () => {
    const tree = buildFileTree([makeFile("src/main.ts")]);

    const dir = tree[0] as FileTreeDirNode;
    expect(dir.label).toBe("src"); // not folded into "src/main.ts" — main.ts is a file, not a directory
  });

  it("keeps a directory with both files and subdirectories as siblings under one row", () => {
    const tree = buildFileTree([
      makeFile("apps/README.md"),
      makeFile("apps/macos/Foo.swift"),
    ]);

    expect(tree).toHaveLength(1);
    const apps = tree[0] as FileTreeDirNode;
    expect(apps.label).toBe("apps"); // two children (a file and a directory), so it does not compact further
    expect(files(apps.children).map((f) => f.name)).toEqual(["README.md"]);
    expect(dirs(apps.children).map((d) => d.label)).toEqual(["macos"]);
  });

  it("preserves sibling order matching the input file list order", () => {
    const tree = buildFileTree([makeFile("b.ts"), makeFile("a.ts"), makeFile("dir/z.ts"), makeFile("dir/y.ts")]);

    expect(files(tree).map((f) => f.name)).toEqual(["b.ts", "a.ts"]);
    const dir = dirs(tree)[0]!;
    expect(files(dir.children).map((f) => f.name)).toEqual(["z.ts", "y.ts"]);
  });

  it("groups a second file under an already-created directory instead of duplicating the row", () => {
    const tree = buildFileTree([makeFile("src/a.ts"), makeFile("src/b.ts")]);

    expect(dirs(tree)).toHaveLength(1);
    const dir = tree[0] as FileTreeDirNode;
    expect(files(dir.children).map((f) => f.name)).toEqual(["a.ts", "b.ts"]);
  });

  it("places a renamed file at its new path while keeping oldPath on the file entry", () => {
    const renamed = makeFile("apps/macos/NewName.swift", { status: "renamed", oldPath: "apps/macos/OldName.swift" });
    const tree = buildFileTree([renamed]);

    const dir = tree[0] as FileTreeDirNode;
    expect(dir.label).toBe("apps/macos");
    const fileNode = dir.children[0] as FileTreeFileNode;
    expect(fileNode.name).toBe("NewName.swift");
    expect(fileNode.file.oldPath).toBe("apps/macos/OldName.swift");
    expect(fileNode.file.path).toBe("apps/macos/NewName.swift");
  });

  it("returns an empty tree for an empty file list", () => {
    expect(buildFileTree([])).toEqual([]);
  });
});

/** A git submodule (gitlink) pointer entry, in the flat order the daemon sends: the pointer first,
 *  then every entry nested under it. */
function makeSubmodule(path: string, overrides: Partial<DiffFileEntry> = {}): DiffFileEntry {
  return makeFile(path, {
    isSubmodule: true,
    submodule: { oldCommit: "a".repeat(40), newCommit: "b".repeat(40), dirty: false, unmerged: false, checkedOut: true },
    ...overrides,
  });
}

describe("buildFileTree: submodule pointer entries (PR D, nested submodules)", () => {
  it("makes the pointer the directory node for its own path, with its changed files as children", () => {
    const pointer = makeSubmodule("sbc_hal");
    const tree = buildFileTree([pointer, makeFile("sbc_hal/.bumpversion.cfg", { submodulePath: "sbc_hal" })]);

    expect(tree).toHaveLength(1);
    const dir = tree[0] as FileTreeDirNode;
    expect(dir.kind).toBe("dir");
    expect(dir.path).toBe("sbc_hal");
    expect(dir.label).toBe("sbc_hal");
    expect(dir.submodule).toBe(pointer);
    // The pointer contributes no leaf row of its own: it IS the directory row.
    expect(files(dir.children).map((f) => f.name)).toEqual([".bumpversion.cfg"]);
  });

  it("nests a submodule checked out inside another under its parent submodule's node", () => {
    const outer = makeSubmodule("sbc_hal");
    const inner = makeSubmodule("sbc_hal/api_commands", { submodulePath: "sbc_hal" });
    const tree = buildFileTree([
      outer,
      makeFile("sbc_hal/.bumpversion.cfg", { submodulePath: "sbc_hal" }),
      inner,
      makeFile("sbc_hal/api_commands/uart.c", { submodulePath: "sbc_hal/api_commands" }),
    ]);

    const outerDir = tree[0] as FileTreeDirNode;
    expect(outerDir.submodule).toBe(outer);
    const innerDir = dirs(outerDir.children)[0]!;
    expect(innerDir.path).toBe("sbc_hal/api_commands");
    expect(innerDir.label).toBe("api_commands");
    expect(innerDir.submodule).toBe(inner);
    expect(files(innerDir.children).map((f) => f.name)).toEqual(["uart.c"]);
  });

  it("does not fold a submodule directory into the single-child chain above it", () => {
    const tree = buildFileTree([
      makeSubmodule("vendor/lib"),
      makeFile("vendor/lib/src/parser.c", { submodulePath: "vendor/lib" }),
    ]);

    // Without the boundary, `vendor` -> `lib` would compact into one "vendor/lib" row and the
    // submodule would have no row of its own to carry its commit chip.
    expect(tree).toHaveLength(1);
    const vendor = tree[0] as FileTreeDirNode;
    expect(vendor.label).toBe("vendor");
    expect(vendor.submodule).toBeUndefined();
    const lib = dirs(vendor.children)[0]!;
    expect(lib.label).toBe("lib");
    expect(lib.path).toBe("vendor/lib");
    expect(lib.submodule?.path).toBe("vendor/lib");
    expect(dirs(lib.children)[0]!.label).toBe("src");
  });

  it("does not fold a submodule's own single-child directory chain into the submodule row", () => {
    const tree = buildFileTree([makeSubmodule("sbc_hal"), makeFile("sbc_hal/src/uart.c", { submodulePath: "sbc_hal" })]);

    const sbcHal = tree[0] as FileTreeDirNode;
    expect(sbcHal.label).toBe("sbc_hal"); // not "sbc_hal/src"
    expect(dirs(sbcHal.children).map((d) => d.label)).toEqual(["src"]);
  });

  it("gives a pointer that was never checked out a directory node with nothing inside it", () => {
    const pointer = makeSubmodule("documentation", {
      submodule: { oldCommit: "c".repeat(40), newCommit: "d".repeat(40), dirty: false, unmerged: false, checkedOut: false },
    });
    const tree = buildFileTree([pointer]);

    const dir = tree[0] as FileTreeDirNode;
    expect(dir.path).toBe("documentation");
    expect(dir.submodule).toBe(pointer);
    expect(dir.children).toEqual([]);
  });

  it("gives a checked-out submodule whose own files are unchanged a childless directory node too", () => {
    const pointer = makeSubmodule("sbc_hal");
    const tree = buildFileTree([pointer, makeFile("src/main.ts")]);

    const dir = tree[0] as FileTreeDirNode;
    expect(dir.path).toBe("sbc_hal");
    expect(dir.children).toEqual([]);
    // The unrelated top-level file still lands beside it, in input order.
    expect(dirs(tree).map((d) => d.path)).toEqual(["sbc_hal", "src"]);
  });

  it("keeps superproject files out of a removed pointer's folder, giving the path two rows", () => {
    // A submodule removed and replaced by ordinary files at the same path: the pointer entry and the
    // `A/foo` entry are in different repositories, which only `submodulePath` says. By path prefix
    // alone `A/foo` would land inside the deleted pointer, making a pointer with no checkout behind
    // it look expandable.
    const pointer = makeSubmodule("A", {
      status: "deleted",
      submodule: { oldCommit: "a".repeat(40), dirty: false, unmerged: false, checkedOut: false },
    });
    const tree = buildFileTree([pointer, makeFile("A/foo")]);

    const nodes = dirs(tree);
    expect(nodes).toHaveLength(2);
    const [pointerNode, plainNode] = nodes as [FileTreeDirNode, FileTreeDirNode];
    expect(pointerNode.path).toBe("A");
    expect(pointerNode.submodule).toBe(pointer);
    expect(pointerNode.children).toEqual([]);
    expect(plainNode.path).toBe("A");
    expect(plainNode.submodule).toBeUndefined();
    expect(files(plainNode.children).map((f) => f.name)).toEqual(["foo"]);
  });

  it("keeps an owned entry in the pointer's folder rather than splitting off a plain one", () => {
    const pointer = makeSubmodule("A");
    const tree = buildFileTree([pointer, makeFile("A/foo", { submodulePath: "A" })]);

    // One node for the path: the entry declared the pointer as its owner, so nothing else is needed.
    expect(dirs(tree)).toHaveLength(1);
    const node = tree[0] as FileTreeDirNode;
    expect(node.submodule).toBe(pointer);
    expect(files(node.children).map((f) => f.name)).toEqual(["foo"]);
  });

  it("groups a nested chain by its declared owner at every level", () => {
    const outer = makeSubmodule("A");
    const inner = makeSubmodule("A/B", { submodulePath: "A" });
    const tree = buildFileTree([
      outer,
      makeFile("A/own.c", { submodulePath: "A" }),
      inner,
      makeFile("A/B/deep.c", { submodulePath: "A/B" }),
      // Same prefix, superproject-owned: it belongs beside the pointer, not inside it.
      makeFile("A/B/stale.c"),
    ]);

    const outerNode = dirs(tree).find((d) => d.submodule === outer)!;
    expect(files(outerNode.children).map((f) => f.name)).toEqual(["own.c"]);
    const innerNode = dirs(outerNode.children).find((d) => d.submodule === inner)!;
    expect(innerNode.path).toBe("A/B");
    expect(files(innerNode.children).map((f) => f.name)).toEqual(["deep.c"]);

    // The superproject-owned entry is not inside submodule `A` at any depth: it gets its own
    // compacted chain, since for the workspace's repository `A` is a tree rather than a gitlink.
    const plainChain = dirs(tree).find((d) => d.submodule === undefined)!;
    expect(plainChain.label).toBe("A/B");
    expect(plainChain.path).toBe("A/B");
    expect(files(plainChain.children).map((f) => f.name)).toEqual(["stale.c"]);
    expect(dirs(tree)).toHaveLength(2);
  });

  it("places the pointer from the manifest flag alone, before its metadata-only chunk arrives", () => {
    const pointer = makeFile("sbc_hal", { isSubmodule: true, patchState: "queued" });
    const tree = buildFileTree([pointer, makeFile("sbc_hal/.bumpversion.cfg", { submodulePath: "sbc_hal" })]);

    const dir = tree[0] as FileTreeDirNode;
    expect(dir.submodule).toBe(pointer);
    expect(files(dir.children).map((f) => f.name)).toEqual([".bumpversion.cfg"]);
  });
});
