import { describe, expect, it } from "vitest";
import { workspaceFolderPaths } from "../src/app/folderPicker";

describe("workspaceFolderPaths", () => {
  it("lists the workspace root and every folder a listed file sits under, sorted by path", () => {
    expect(workspaceFolderPaths(["src/app/a.ts", "src/b.ts", "root.ts"], [], [])).toEqual(["", "src", "src/app"]);
  });

  it("lists an empty directory and its own ancestors, which no file's path would reveal", () => {
    expect(workspaceFolderPaths([], ["logs/archive"], [])).toEqual(["", "logs", "logs/archive"]);
  });

  it("lists a childless submodule checkout and its own ancestors, which no file's path or emptyDirectories entry would reveal", () => {
    // A submodule with nothing listable inside it (an empty checkout, or one this listing's cap
    // dropped everything from) names no path in `paths` and isn't one of `emptyDirectories` either,
    // so only `submodulePaths` can put it, and the folder above it, in front of Move to….
    expect(workspaceFolderPaths(["root.ts"], [], ["vendor/lib"])).toEqual(["", "vendor", "vendor/lib"]);
  });

  it("lists a workspace with no files at all as the root alone", () => {
    expect(workspaceFolderPaths([], [], [])).toEqual([""]);
  });
});
