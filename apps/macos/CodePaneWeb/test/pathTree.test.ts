import { describe, expect, it } from "vitest";
import { buildPathTree, PathTreeDirNode, PathTreeFileNode, PathTreeNode } from "../src/app/pathTree";

function dirs(nodes: readonly PathTreeNode[]): PathTreeDirNode[] {
  return nodes.filter((n): n is PathTreeDirNode => n.kind === "dir");
}

function files(nodes: readonly PathTreeNode[]): PathTreeFileNode[] {
  return nodes.filter((n): n is PathTreeFileNode => n.kind === "file");
}

describe("buildPathTree", () => {
  it("returns root-level files with no wrapping directory for paths with no slash", () => {
    const tree = buildPathTree(["README.md", "package.json"]);

    expect(tree).toHaveLength(2);
    expect(files(tree).map((f) => f.name)).toEqual(["README.md", "package.json"]);
    expect(files(tree).map((f) => f.path)).toEqual(["README.md", "package.json"]);
    expect(dirs(tree)).toHaveLength(0);
  });

  it("nests a single file under its one parent directory", () => {
    const tree = buildPathTree(["src/main.ts"]);

    expect(tree).toHaveLength(1);
    const dir = tree[0] as PathTreeDirNode;
    expect(dir.kind).toBe("dir");
    expect(dir.label).toBe("src");
    expect(dir.path).toBe("src");
    expect(dir.children).toHaveLength(1);
    expect((dir.children[0] as PathTreeFileNode).name).toBe("main.ts");
    expect((dir.children[0] as PathTreeFileNode).path).toBe("src/main.ts");
  });

  it("compacts a chain of single-child directories into one row", () => {
    const tree = buildPathTree(["apps/ios/Sources/ViewerResync.swift"]);

    expect(tree).toHaveLength(1);
    const dir = tree[0] as PathTreeDirNode;
    expect(dir.label).toBe("apps/ios/Sources");
    expect(dir.path).toBe("apps/ios/Sources");
    expect(dir.children).toHaveLength(1);
    expect((dir.children[0] as PathTreeFileNode).name).toBe("ViewerResync.swift");
  });

  it("stops compaction at the first directory with more than one child", () => {
    const tree = buildPathTree([
      "apps/ios/Sources/ViewerResync.swift",
      "apps/ios/Sources/MobileRootView.swift",
      "apps/macos/Foo.swift",
    ]);

    // `apps` has two children (`ios`, `macos`), so the chain stops there instead of folding further.
    expect(tree).toHaveLength(1);
    const apps = tree[0] as PathTreeDirNode;
    expect(apps.label).toBe("apps");
    expect(dirs(apps.children).map((d) => d.label).sort()).toEqual(["ios/Sources", "macos"]);
  });

  it("does not compact a directory holding exactly one file (only directory chains compact)", () => {
    const tree = buildPathTree(["src/main.ts"]);

    const dir = tree[0] as PathTreeDirNode;
    expect(dir.label).toBe("src"); // not folded into "src/main.ts" — main.ts is a file, not a directory
  });

  it("keeps a directory with both files and subdirectories as siblings under one row", () => {
    const tree = buildPathTree(["apps/README.md", "apps/macos/Foo.swift"]);

    expect(tree).toHaveLength(1);
    const apps = tree[0] as PathTreeDirNode;
    expect(apps.label).toBe("apps"); // two children (a file and a directory), so it does not compact further
    expect(files(apps.children).map((f) => f.name)).toEqual(["README.md"]);
    expect(dirs(apps.children).map((d) => d.label)).toEqual(["macos"]);
  });

  it("preserves sibling order matching the input path list order", () => {
    const tree = buildPathTree(["b.ts", "a.ts", "dir/z.ts", "dir/y.ts"]);

    expect(files(tree).map((f) => f.name)).toEqual(["b.ts", "a.ts"]);
    const dir = dirs(tree)[0]!;
    expect(files(dir.children).map((f) => f.name)).toEqual(["z.ts", "y.ts"]);
  });

  it("groups a second file under an already-created directory instead of duplicating the row", () => {
    const tree = buildPathTree(["src/a.ts", "src/b.ts"]);

    expect(dirs(tree)).toHaveLength(1);
    const dir = tree[0] as PathTreeDirNode;
    expect(files(dir.children).map((f) => f.name)).toEqual(["a.ts", "b.ts"]);
  });

  it("handles multiple files across multiple nested directories", () => {
    const tree = buildPathTree([
      "apps/macos/Sources/a.swift",
      "apps/macos/Sources/b.swift",
      "apps/ios/Sources/c.swift",
    ]);

    expect(tree).toHaveLength(1);
    const apps = tree[0] as PathTreeDirNode;
    expect(apps.label).toBe("apps");
    expect(dirs(apps.children).map((d) => d.label).sort()).toEqual(["ios/Sources", "macos/Sources"]);
    const macosSources = dirs(apps.children).find((d) => d.label === "macos/Sources")!;
    expect(files(macosSources.children).map((f) => f.name)).toEqual(["a.swift", "b.swift"]);
    const iosSources = dirs(apps.children).find((d) => d.label === "ios/Sources")!;
    expect(files(iosSources.children).map((f) => f.name)).toEqual(["c.swift"]);
  });

  it("returns an empty tree for an empty path list", () => {
    expect(buildPathTree([])).toEqual([]);
  });
});
