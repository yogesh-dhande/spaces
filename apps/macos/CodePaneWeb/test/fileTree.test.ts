import { describe, expect, it } from "vitest";
import { DiffFileEntry } from "../src/bridge/types";
import { buildFileTree, FileTreeDirNode, FileTreeFileNode, FileTreeNode } from "../src/app/fileTree";

function makeFile(path: string, overrides: Partial<DiffFileEntry> = {}): DiffFileEntry {
  return {
    path,
    status: "modified",
    isBinary: false,
    truncated: false,
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
