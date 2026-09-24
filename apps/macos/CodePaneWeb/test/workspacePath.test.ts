import { describe, expect, it } from "vitest";
import { resolveWorkspaceReference } from "../src/app/workspacePath";

describe("resolveWorkspaceReference", () => {
  it("resolves a reference against the referring file's own directory", () => {
    expect(resolveWorkspaceReference("docs/notes.md", "shot.png")).toBe("docs/shot.png");
    expect(resolveWorkspaceReference("docs/notes.md", "./img/shot.png")).toBe("docs/img/shot.png");
    expect(resolveWorkspaceReference("docs/guide/notes.md", "../shot.png")).toBe("docs/shot.png");
    expect(resolveWorkspaceReference("notes.md", "shot.png")).toBe("shot.png");
  });

  it("reads a leading slash as the workspace root", () => {
    expect(resolveWorkspaceReference("docs/guide/notes.md", "/assets/shot.png")).toBe("assets/shot.png");
  });

  it("decodes percent-encoded path segments", () => {
    expect(resolveWorkspaceReference("docs/notes.md", "my%20shot.png")).toBe("docs/my shot.png");
  });

  it("drops a query string or fragment from an otherwise ordinary path", () => {
    expect(resolveWorkspaceReference("docs/notes.md", "shot.png#fig-1")).toBe("docs/shot.png");
    expect(resolveWorkspaceReference("docs/notes.md", "shot.png?v=2")).toBe("docs/shot.png");
  });

  it("names nothing for a reference that points outside the workspace", () => {
    expect(resolveWorkspaceReference("docs/notes.md", "https://example.com/shot.png")).toBeUndefined();
    expect(resolveWorkspaceReference("docs/notes.md", "http://example.com/shot.png")).toBeUndefined();
    expect(resolveWorkspaceReference("docs/notes.md", "mailto:someone@example.com")).toBeUndefined();
    expect(resolveWorkspaceReference("docs/notes.md", "data:image/png;base64,AAAA")).toBeUndefined();
    expect(resolveWorkspaceReference("docs/notes.md", "//example.com/shot.png")).toBeUndefined();
  });

  it("names nothing for a reference that climbs above the workspace root", () => {
    expect(resolveWorkspaceReference("docs/notes.md", "../../secrets.png")).toBeUndefined();
    expect(resolveWorkspaceReference("notes.md", "../secrets.png")).toBeUndefined();
    expect(resolveWorkspaceReference("docs/notes.md", "/../secrets.png")).toBeUndefined();
  });

  it("names nothing for a reference that is not a path at all", () => {
    expect(resolveWorkspaceReference("docs/notes.md", "#section")).toBeUndefined();
    expect(resolveWorkspaceReference("docs/notes.md", "")).toBeUndefined();
    expect(resolveWorkspaceReference("docs/notes.md", "   ")).toBeUndefined();
    expect(resolveWorkspaceReference("docs/notes.md", "%zz")).toBeUndefined();
    expect(resolveWorkspaceReference("docs/notes.md", "./")).toBeUndefined();
  });
});
