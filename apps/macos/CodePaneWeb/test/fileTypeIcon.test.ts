import { beforeEach, describe, expect, it, vi } from "vitest";
import { DiffFileEntry, WorkspaceFileListResult } from "../src/bridge/types";
import { ContextMenu } from "../src/app/contextMenu";
import { renderFileList } from "../src/app/fileList";
import { createFileTypeIconSprite, fileTypeIconID } from "../src/app/fileTypeIcon";
import { FILE_TYPE_ICON_BY_EXTENSION, FILE_TYPE_ICON_BY_NAME } from "../src/app/fileTypeIconTable";
import { renderFilesTree } from "../src/app/filesTree";
import { FolderPicker } from "../src/app/folderPicker";
import { QuickOpen } from "../src/app/quickOpen";
import { WorkspaceFileListCache } from "../src/app/workspaceFileListCache";

// jsdom has no scrollIntoView; the quick-open overlay calls it on its highlighted row.
beforeEach(() => {
  Element.prototype.scrollIntoView = vi.fn();
});

/** The `<use>` targets of every file-type icon a container rendered, in document order. */
function iconTargets(container: HTMLElement): string[] {
  return [...container.querySelectorAll(".ficon use")].map((use) => use.getAttribute("href") ?? "");
}

function renderTree(
  container: HTMLElement,
  paths: string[],
  options: { emptyDirectories?: string[]; expandedPaths?: string[] } = {},
): void {
  renderFilesTree({
    container,
    listing: { paths, submodules: [], emptyDirectories: options.emptyDirectories ?? [] },
    selectedPath: undefined,
    expandedPaths: options.expandedPaths,
    callbacks: { onSelect: vi.fn(), onMutated: vi.fn() },
    contextMenu: { show: vi.fn(), hide: vi.fn(), isOpen: () => false } as ContextMenu,
    folderPicker: new FolderPicker(document.createElement("div")),
    actions: {
      createFile: vi.fn().mockResolvedValue(undefined),
      createFolder: vi.fn().mockResolvedValue(undefined),
      move: vi.fn().mockResolvedValue(undefined),
      remove: vi.fn().mockResolvedValue(undefined),
      openInSystemViewer: vi.fn().mockResolvedValue(undefined),
      isUnopenable: () => false,
    },
    canOpenInSystemViewer: true,
  });
}

function makeChange(path: string): DiffFileEntry {
  return { path, status: "modified", isBinary: false };
}

describe("fileTypeIconID: the pack's mapping", () => {
  it("maps an extension to the pack's icon for it", () => {
    expect(fileTypeIconID("main.ts")).toBe("typescript");
    expect(fileTypeIconID("App.tsx")).toBe("reactts");
    expect(fileTypeIconID("build.sh")).toBe("shell");
    expect(fileTypeIconID("shot.png")).toBe("image");
    expect(fileTypeIconID("styles.css")).toBe("css");
  });

  it("prefers an exact file name over the extension it ends with", () => {
    // Both are `.json`; the pack names them as files, so they are npm's, not JSON's.
    expect(fileTypeIconID("package.json")).toBe("npm");
    expect(fileTypeIconID("package-lock.json")).toBe("npm");
    expect(fileTypeIconID("data.json")).toBe("json");
  });

  it("matches names and extensions without regard to case", () => {
    expect(fileTypeIconID("Dockerfile")).toBe("docker");
    expect(fileTypeIconID("dockerfile")).toBe("docker");
    expect(fileTypeIconID("LICENSE")).toBe("license");
    expect(fileTypeIconID("license")).toBe("license");
    expect(fileTypeIconID("README.MD")).toBe("markdown");
    expect(fileTypeIconID("Main.JAVA")).toBe("java");
  });

  it("generates only lower-case keys, since a lookup always lowercases the name first", () => {
    for (const key of Object.keys(FILE_TYPE_ICON_BY_EXTENSION)) expect(key).toBe(key.toLowerCase());
    for (const key of Object.keys(FILE_TYPE_ICON_BY_NAME)) expect(key).toBe(key.toLowerCase());
  });

  it("resolves a mixed-case manifest extension like a TextMate grammar file", () => {
    expect(fileTypeIconID("foo.JSON-tmLanguage")).toBe("json");
    expect(fileTypeIconID("foo.yaml-tmlanguage")).toBe("yaml");
  });

  it("maps a dotfile by its name rather than reading the leading dot as an extension", () => {
    expect(fileTypeIconID(".gitignore")).toBe("git");
    expect(fileTypeIconID(".gitmodules")).toBe("git");
    // Not a name the pack knows, and its leading dot starts no extension.
    expect(fileTypeIconID(".spacesrc")).toBe("default_file");
  });

  it("falls back to the pack's default icon for an unknown extension or an extensionless name", () => {
    expect(fileTypeIconID("notes.wibble")).toBe("default_file");
    expect(fileTypeIconID("Makefile")).toBe("default_file");
    expect(fileTypeIconID("CHANGELOG")).toBe("default_file");
    expect(fileTypeIconID("deps.lock")).toBe("default_file");
    expect(fileTypeIconID("constructor")).toBe("default_file");
    expect(fileTypeIconID("__proto__")).toBe("default_file");
    expect(fileTypeIconID("foo.constructor")).toBe("default_file");
    expect(fileTypeIconID("foo.hasOwnProperty")).toBe("default_file");
  });

  it("covers the file kinds the Editor's trees are expected to name", () => {
    expect(fileTypeIconID("spaces.yaml")).toBe("yaml");
    expect(fileTypeIconID("Cargo.lock")).toBe("cargo");
    expect(fileTypeIconID("README.md")).toBe("markdown");
    expect(fileTypeIconID("notebook.ipynb")).toBe("jupyter");
    expect(fileTypeIconID("rows.csv")).toBe("text");
    expect(fileTypeIconID("paper.pdf")).toBe("pdf");
    expect(fileTypeIconID("main.h")).toBe("cheader");
  });

  it("ships a sprite symbol for every icon it can return", () => {
    const sprite = createFileTypeIconSprite();
    const shipped = new Set([...sprite.querySelectorAll("symbol")].map((symbol) => symbol.getAttribute("id")));
    for (const name of ["main.ts", "package.json", ".gitignore", "Cargo.lock", "LICENSE", "Makefile", "paper.pdf"]) {
      expect(shipped).toContain(`file-type-icon-${fileTypeIconID(name)}`);
    }
  });
});

describe("Files tree rows", () => {
  it("gives a file row its icon and a folder row none", () => {
    const container = document.createElement("div");
    renderTree(container, ["src/main.ts"], { expandedPaths: ["src"] });

    const dirrow = container.querySelector(".dirrow") as HTMLElement;
    expect(dirrow.querySelector(".ficon")).toBeNull();
    expect(iconTargets(container)).toEqual(["#file-type-icon-typescript"]);
  });

  it("gives an empty folder row no icon, only its disclosure slot", () => {
    const container = document.createElement("div");
    renderTree(container, [], { emptyDirectories: ["logs"] });

    const dirrow = container.querySelector(".dirrow") as HTMLElement;
    expect(dirrow.querySelector(".tri")).not.toBeNull();
    expect(dirrow.querySelector(".ficon")).toBeNull();
    expect(iconTargets(container)).toEqual([]);
  });

  it("renders the icon between the disclosure slot and the name", () => {
    const container = document.createElement("div");
    renderTree(container, ["notes.md"]);

    const row = container.querySelector(".row") as HTMLElement;
    expect([...row.children].map((child) => child.getAttribute("class"))).toEqual(["tri", "ficon", "fn"]);
  });

  it("reads the icon from the file's own name, not the folders above it", () => {
    const container = document.createElement("div");
    renderTree(container, ["styles.css/notes.md"], { expandedPaths: ["styles.css"] });

    expect(iconTargets(container)).toEqual(["#file-type-icon-markdown"]);
  });

  it("hides the icon from assistive technology, which reads the row's name instead", () => {
    const container = document.createElement("div");
    renderTree(container, ["main.ts"]);

    const icon = container.querySelector(".ficon") as SVGElement;
    expect(icon.getAttribute("aria-hidden")).toBe("true");
    expect(icon.querySelector("title")).toBeNull();
    expect(icon.hasAttribute("tabindex")).toBe(false);
  });
});

describe("Changes list rows", () => {
  it("gives every changed file its icon, directly before the name", () => {
    const container = document.createElement("div");
    renderFileList(container, [makeChange("spaces.yaml"), makeChange("src/main.ts")], undefined, {
      onSelect: vi.fn(),
    });

    expect(iconTargets(container)).toEqual(["#file-type-icon-yaml", "#file-type-icon-typescript"]);
    const row = container.querySelector('.row[data-path="spaces.yaml"]') as HTMLElement;
    expect([...row.children].map((child) => child.getAttribute("class"))).toEqual(["tri", "status modified", "ficon", "fn"]);
  });

  it("gives a directory row none", () => {
    const container = document.createElement("div");
    renderFileList(container, [makeChange("src/main.ts")], undefined, { onSelect: vi.fn() });

    expect((container.querySelector(".dirrow") as HTMLElement).querySelector(".ficon")).toBeNull();
  });
});

describe("Quick-open rows", () => {
  it("stay text-only", async () => {
    const listing: WorkspaceFileListResult = {
      paths: ["src/main.ts", "spaces.yaml"],
      truncated: false,
      submodules: [],
      emptyDirectories: [],
    };
    const cache = new WorkspaceFileListCache({ workspaceFileList: vi.fn().mockResolvedValue(listing) });
    const host = document.createElement("div");
    const quickOpen = new QuickOpen(host, cache, () => ["src/main.ts", "spaces.yaml"], {
      getMode: () => "editor",
      isInDiff: () => false,
      openInDiff: vi.fn(),
      openInEditor: vi.fn(),
    });

    quickOpen.show();
    await vi.waitFor(() => expect(host.querySelectorAll(".row").length).toBe(2));
    expect(host.querySelectorAll(".ficon").length).toBe(0);
  });
});
