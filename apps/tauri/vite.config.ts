import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";
import react from "@vitejs/plugin-react";
import { defineConfig, type Plugin } from "vite";

const execFileAsync = promisify(execFile);

function repoRoot() {
  return path.resolve(__dirname, "..", "..");
}

function mxPath() {
  return path.join(repoRoot(), "apps", "macos", ".build", "debug", "mx");
}

function respondJSON(response: import("node:http").ServerResponse, status: number, payload: unknown) {
  response.statusCode = status;
  response.setHeader("Content-Type", "application/json");
  response.end(JSON.stringify(payload));
}

async function readJSONBody(request: import("node:http").IncomingMessage) {
  const chunks: Buffer[] = [];
  for await (const chunk of request) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  if (chunks.length === 0) {
    return {};
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8")) as Record<string, unknown>;
}

function appExists(appName: string) {
  return execFileAsync("/usr/bin/open", ["-Ra", appName])
    .then(() => true)
    .catch(() => false);
}

function commandExists(command: string) {
  return execFileAsync("/usr/bin/which", [command])
    .then(() => true)
    .catch(() => false);
}

function devBridge(): Plugin {
  return {
    name: "muxy-dev-bridge",
    configureServer(server) {
      server.middlewares.use("/__muxy/resolve-mx-path", async (_request, response) => {
        respondJSON(response, 200, { data: mxPath() });
      });

      server.middlewares.use("/__muxy/mx-read", async (request, response) => {
        try {
          const body = await readJSONBody(request);
          const command = String(body.command ?? "");
          const args = Array.isArray(body.args) ? body.args.map(String) : [];
          const { stdout, stderr } = await execFileAsync(mxPath(), [command, ...args, "--json"], {
            cwd: repoRoot(),
          });
          if (stderr.trim()) {
            console.warn(stderr);
          }
          const parsed = JSON.parse(stdout) as { data: unknown };
          respondJSON(response, 200, { data: parsed.data });
        } catch (error) {
          respondJSON(response, 500, { error: error instanceof Error ? error.message : String(error) });
        }
      });

      server.middlewares.use("/__muxy/mx-mutate", async (request, response) => {
        try {
          const body = await readJSONBody(request);
          const command = String(body.command ?? "");
          const args = Array.isArray(body.args) ? body.args.map(String) : [];
          const { stdout, stderr } = await execFileAsync(mxPath(), [command, ...args, "--json"], {
            cwd: repoRoot(),
          });
          if (stderr.trim()) {
            console.warn(stderr);
          }
          const parsed = JSON.parse(stdout) as { data: unknown };
          respondJSON(response, 200, { data: parsed.data });
        } catch (error) {
          respondJSON(response, 500, { error: error instanceof Error ? error.message : String(error) });
        }
      });

      server.middlewares.use("/__muxy/system-check", async (_request, response) => {
        try {
          const [hasIterm, hasGhostty, hasTmux, hasYabai, yabaiReady] = await Promise.all([
            appExists("iTerm"),
            appExists("Ghostty"),
            commandExists("tmux"),
            commandExists("yabai"),
            execFileAsync("yabai", ["-m", "query", "--windows", "--window"]).then(() => true).catch(() => false),
          ]);

          respondJSON(response, 200, {
            data: [
              {
                kind: "iterm2_or_ghostty",
                label: "Terminal host",
                ok: hasIterm || hasGhostty,
                detail: "Client-owned app detection for supported terminal hosts.",
              },
              {
                kind: "tmux",
                label: "tmux",
                ok: hasTmux,
                detail: "Checks whether tmux is available on PATH.",
              },
              {
                kind: "yabai_installed",
                label: "yabai",
                ok: hasYabai,
                detail: "Checks whether yabai is installed.",
              },
              {
                kind: "yabai_ready",
                label: "yabai ready",
                ok: yabaiReady,
                detail: "Client-owned readiness check for yabai service and permissions.",
              },
            ],
          });
        } catch (error) {
          respondJSON(response, 500, { error: error instanceof Error ? error.message : String(error) });
        }
      });

      server.middlewares.use("/__muxy/git-read", async (request, response) => {
        try {
          const body = await readJSONBody(request);
          const command = String(body.command ?? "");
          const args = Array.isArray(body.args) ? body.args.map(String) : [];

          if (command !== "branch_options" || args.length === 0) {
            respondJSON(response, 400, { error: "Unsupported git-read command." });
            return;
          }

          const repoDir = args[0];
          const [localBranches, remoteBranches] = await Promise.all([
            execFileAsync("git", ["-C", repoDir, "for-each-ref", "--format=%(refname:short)", "refs/heads"]),
            execFileAsync("git", ["-C", repoDir, "for-each-ref", "--format=%(refname:short)", "refs/remotes"]),
          ]);

          const merged = [
            ...localBranches.stdout
              .split("\n")
              .map((line) => line.trim())
              .filter(Boolean)
              .map((name) => ({ name, scope: "local" })),
            ...remoteBranches.stdout
              .split("\n")
              .map((line) => line.trim())
              .filter((line) => line && !line.includes("HEAD"))
              .map((name) => ({ name, scope: "remote" })),
          ].sort((left, right) => left.name.localeCompare(right.name));

          const deduped = merged.filter(
            (entry, index) => index === 0 || merged[index - 1].name !== entry.name,
          );
          respondJSON(response, 200, { data: deduped });
        } catch (error) {
          respondJSON(response, 500, { error: error instanceof Error ? error.message : String(error) });
        }
      });
    },
  };
}

export default defineConfig({
  plugins: [react(), devBridge()],
});
