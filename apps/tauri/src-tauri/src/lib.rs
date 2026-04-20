use serde::Serialize;
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Serialize)]
struct SystemCheck {
    kind: String,
    label: String,
    ok: bool,
    detail: String,
}

#[derive(Serialize)]
struct BranchOption {
    name: String,
    scope: String,
}

fn repo_root() -> Result<PathBuf, String> {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(3)
        .map(Path::to_path_buf)
        .ok_or_else(|| {
            "Failed to resolve repository root from Cargo manifest directory.".to_string()
        })
}

fn default_mx_path() -> Result<PathBuf, String> {
    Ok(repo_root()?.join("apps/macos/.build/debug/mx"))
}

fn run_json_command(binary: &Path, args: &[String]) -> Result<Value, String> {
    let output = Command::new(binary)
        .args(args)
        .output()
        .map_err(|error| format!("Failed to launch {}: {error}", binary.display()))?;

    if output.status.success() {
        let stdout = String::from_utf8(output.stdout).map_err(|error| error.to_string())?;
        serde_json::from_str::<Value>(&stdout)
            .map_err(|error| format!("Invalid JSON from mx stdout: {error}"))
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        if let Ok(parsed) = serde_json::from_str::<Value>(&stderr) {
            let message = parsed
                .get("error")
                .and_then(|error| error.get("message"))
                .and_then(Value::as_str)
                .unwrap_or("mx command failed");
            Err(message.to_string())
        } else {
            Err(stderr.if_empty("mx command failed").to_string())
        }
    }
}

trait EmptyFallback {
    fn if_empty<'a>(&'a self, fallback: &'a str) -> &'a str;
}

impl EmptyFallback for str {
    fn if_empty<'a>(&'a self, fallback: &'a str) -> &'a str {
        if self.is_empty() {
            fallback
        } else {
            self
        }
    }
}

fn command_exists(binary: &str) -> bool {
    Command::new("/usr/bin/which")
        .arg(binary)
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

fn app_exists(app_name: &str) -> bool {
    Command::new("/usr/bin/open")
        .args(["-Ra", app_name])
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

fn yabai_ready() -> bool {
    Command::new("yabai")
        .args(["-m", "query", "--windows", "--window"])
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

#[tauri::command]
fn resolve_mx_path() -> Result<String, String> {
    default_mx_path().map(|path| path.display().to_string())
}

#[tauri::command]
fn mx_read(command: String, args: Vec<String>) -> Result<Value, String> {
    let binary = default_mx_path()?;
    let mut command_args = vec![command];
    command_args.extend(args);
    command_args.push("--json".to_string());
    run_json_command(&binary, &command_args)
}

#[tauri::command]
fn mx_mutate(command: String, args: Vec<String>) -> Result<Value, String> {
    mx_read(command, args)
}

#[tauri::command]
fn system_check(kind: String, _args: Vec<String>) -> Result<Vec<SystemCheck>, String> {
    if kind != "prereqs" {
        return Err(format!("Unsupported system check kind: {kind}"));
    }

    Ok(vec![
        SystemCheck {
            kind: "iterm2_or_ghostty".into(),
            label: "Terminal host".into(),
            ok: app_exists("iTerm") || app_exists("Ghostty"),
            detail: "Client-owned app detection for supported terminal hosts.".into(),
        },
        SystemCheck {
            kind: "tmux".into(),
            label: "tmux".into(),
            ok: command_exists("tmux"),
            detail: "Checks whether tmux is available on PATH.".into(),
        },
        SystemCheck {
            kind: "yabai_installed".into(),
            label: "yabai".into(),
            ok: command_exists("yabai"),
            detail: "Checks whether yabai is installed.".into(),
        },
        SystemCheck {
            kind: "yabai_ready".into(),
            label: "yabai ready".into(),
            ok: yabai_ready(),
            detail: "Client-owned readiness check for yabai service and permissions.".into(),
        },
    ])
}

#[tauri::command]
fn git_read(command: String, args: Vec<String>) -> Result<Vec<BranchOption>, String> {
    match command.as_str() {
        "branch_options" => {
            let repo_dir = args
                .first()
                .ok_or_else(|| "Missing repo directory for git branch_options.".to_string())?;

            let local_output = Command::new("git")
                .args([
                    "-C",
                    repo_dir,
                    "for-each-ref",
                    "--format=%(refname:short)",
                    "refs/heads",
                ])
                .output()
                .map_err(|error| format!("Failed to read local branches: {error}"))?;

            let remote_output = Command::new("git")
                .args([
                    "-C",
                    repo_dir,
                    "for-each-ref",
                    "--format=%(refname:short)",
                    "refs/remotes",
                ])
                .output()
                .map_err(|error| format!("Failed to read remote branches: {error}"))?;

            let mut branches: Vec<BranchOption> = String::from_utf8_lossy(&local_output.stdout)
                .lines()
                .filter(|line| !line.trim().is_empty())
                .map(|line| BranchOption {
                    name: line.trim().to_string(),
                    scope: "local".into(),
                })
                .collect();

            branches.extend(
                String::from_utf8_lossy(&remote_output.stdout)
                    .lines()
                    .filter(|line| !line.trim().is_empty())
                    .filter(|line| !line.contains("HEAD"))
                    .map(|line| BranchOption {
                        name: line.trim().to_string(),
                        scope: "remote".into(),
                    }),
            );

            branches.sort_by(|left, right| left.name.cmp(&right.name));
            branches.dedup_by(|left, right| left.name == right.name);
            Ok(branches)
        }
        _ => Err(format!("Unsupported git_read command: {command}")),
    }
}

#[tauri::command]
fn register_shortcuts() -> Value {
    serde_json::json!({
        "registered": false,
        "detail": "Shortcut registration is not wired yet in the Tauri proof of concept."
    })
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            resolve_mx_path,
            mx_read,
            mx_mutate,
            system_check,
            git_read,
            register_shortcuts
        ])
        .setup(|app| {
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
