//! image-currency — digest-currency checker / applier / health gate for the GitOps image
//! pins under gitops/manifests.
//!
//! WHY (and why not argocd-image-updater / Renovate): this stack pins every image by
//! tag@sha256. Floating tags (:latest/:nightly/:dev/…) drift upstream; the pinned digest
//! is how we get reproducibility AND a human review gate on each bump. argocd-image-updater
//! auto-commits + auto-syncs, which removes exactly the gate that caught the authelia
//! /data-ownership crashloop and the stremthru nested-pgdata clobber. So this tool REPORTS
//! by default and only mutates on an explicit --apply.
//!
//! It complements the audit's 02-image-pins.sh (which asserts a digest *exists*); this
//! asserts the pinned digest is still *current* (floating) and that version-pinned tags
//! have NOT been re-pushed under us (supply-chain drift).
//!
//! Determinism: a resolution failure is reported as ERROR, never silently folded into
//! "current" — an unreachable registry must not read as a clean run.

mod discover;
mod health;
mod registry;

use clap::Parser;
use reqwest::blocking::Client;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::Duration;

#[derive(Parser, Debug)]
#[command(
    name = "image-currency",
    about = "Report / apply / health-gate the GitOps image-digest pins"
)]
struct Cli {
    /// Apply floating-tag digest UPDATEs in-file (drift & errors are never auto-applied)
    #[arg(long)]
    apply: bool,
    /// Also re-pin version-tag DRIFT (a re-pushed tag) to its current digest — explicit opt-in
    #[arg(long = "repin-drift")]
    repin_drift: bool,
    /// git add + commit the applied files (implies --apply already ran this invocation)
    #[arg(long)]
    commit: bool,
    /// Force-refresh the ArgoCD child app(s) owning the changed paths
    #[arg(long)]
    sync: bool,
    /// Post-change synthetic health gate (rollout + 0-restart + service-proxy probe)
    #[arg(long)]
    health: bool,
    /// Nonzero exit when updates are available / drift seen / health fails (CI gate)
    #[arg(long = "exit-code")]
    exit_code: bool,
    /// Override the manifest directory (default: <repo>/gitops/manifests)
    #[arg(long)]
    manifest_dir: Option<PathBuf>,
    /// Resolve one ref (`repo:tag` or `repo:tag@sha256:…`) to its current digest + version
    /// label and exit. Used to pin a new semver tag, or read the version behind a digest.
    #[arg(long)]
    resolve: Option<String>,
}

#[derive(PartialEq)]
enum Klass {
    Floating,
    Pinned,
}

struct Outcome {
    repo: String,
    tag: String,
    klass: Klass,
    pinned: String,      // sha256:…
    files: Vec<PathBuf>, // manifests pinning this ref
    current: Result<String, String>,
}

fn main() {
    let cli = Cli::parse();
    let root = repo_root();
    let manifest_dir = cli
        .manifest_dir
        .clone()
        .unwrap_or_else(|| root.join("gitops/manifests"));
    let owned_ns: Vec<String> = std::env::var("RESOURCE_OWNED_NAMESPACES")
        .unwrap_or_else(|_| "apps observability".into())
        .split_whitespace()
        .map(String::from)
        .collect();

    let refs: Vec<(String, Vec<PathBuf>)> = discover::discover(&manifest_dir).into_iter().collect();
    if refs.is_empty() {
        eprintln!("no @sha256-pinned images found under {}", manifest_dir.display());
        std::process::exit(2);
    }

    let client = Client::builder()
        .user_agent("image-currency/0.1")
        .timeout(Duration::from_secs(25))
        .build()
        .expect("http client");

    // One-off resolve mode: print `<ref>  version=…  digest=…` and exit. Accepts a bare tag
    // (resolves the tag) or a `@sha256:` pin (resolves by that digest — reads the version a
    // pinned digest already carries).
    if let Some(refstr) = &cli.resolve {
        let (name, pinned) = match refstr.split_once("@sha256:") {
            Some((n, d)) => (n, Some(format!("sha256:{d}"))),
            None => (refstr.as_str(), None),
        };
        let mut iref = registry::parse_ref(name);
        if let Some(d) = pinned {
            iref.tag = d;
        }
        let dig = registry::resolve_digest(&client, &iref).unwrap_or_else(|e| format!("ERR:{e}"));
        let ver = registry::resolve_version(&client, &iref)
            .ok()
            .flatten()
            .unwrap_or_else(|| "-".into());
        println!("{refstr}\tversion={ver}\tdigest={dig}");
        return;
    }

    // Resolve every ref concurrently (IO-bound). thread::scope borrows `client` safely.
    let outcomes: Vec<Outcome> = thread::scope(|s| {
        let handles: Vec<_> = refs
            .iter()
            .map(|(full, files)| {
                let client = &client;
                let full = full.clone();
                let files = files.clone();
                s.spawn(move || compute(client, full, files))
            })
            .collect();
        handles.into_iter().map(|h| h.join().expect("resolver thread panicked")).collect()
    });

    // ---- report ----
    println!(
        "\nimage-currency  —  {}",
        manifest_dir.strip_prefix(&root).unwrap_or(&manifest_dir).display()
    );
    println!("------------------------------------------------------------------------");

    let (mut n_ok, mut n_update, mut n_drift, mut n_err) = (0u32, 0u32, 0u32, 0u32);
    let mut changed_files: Vec<PathBuf> = Vec::new();
    let mut changed_repos: Vec<String> = Vec::new();

    for o in &outcomes {
        match &o.current {
            Err(e) => {
                println!("  ERROR    {:<46} ({e})", format!("{}:{}", o.repo, o.tag));
                n_err += 1;
            }
            Ok(cur) if *cur == o.pinned => n_ok += 1,
            Ok(cur) => match o.klass {
                Klass::Floating => {
                    n_update += 1;
                    println!(
                        "  UPDATE   {:<46} {}… → {}…",
                        format!("{}:{}", o.repo, o.tag),
                        &o.pinned[..19.min(o.pinned.len())],
                        &cur[..19.min(cur.len())]
                    );
                    if cli.apply {
                        changed_repos.push(health_repo(&o.repo));
                        for f in &o.files {
                            if apply_digest(f, &o.pinned, cur) {
                                changed_files.push(f.clone());
                            }
                        }
                        println!(
                            "             applied in: {}",
                            o.files
                                .iter()
                                .map(|f| rel(f, &root))
                                .collect::<Vec<_>>()
                                .join(", ")
                        );
                    }
                }
                Klass::Pinned => {
                    // Version tag re-pushed: supply-chain signal, re-pinned only on the
                    // explicit --repin-drift opt-in (never as part of --apply).
                    n_drift += 1;
                    println!(
                        "  ⚠ DRIFT  {:<46} {}… → {}…  (version tag re-pushed!)",
                        format!("{}:{}", o.repo, o.tag),
                        &o.pinned[..19.min(o.pinned.len())],
                        &cur[..19.min(cur.len())]
                    );
                    if cli.repin_drift {
                        for f in &o.files {
                            if apply_digest(f, &o.pinned, cur) {
                                changed_files.push(f.clone());
                            }
                        }
                        changed_repos.push(health_repo(&o.repo));
                        println!(
                            "             re-pinned in: {}",
                            o.files
                                .iter()
                                .map(|f| rel(f, &root))
                                .collect::<Vec<_>>()
                                .join(", ")
                        );
                    }
                }
            },
        }
    }
    println!("------------------------------------------------------------------------");
    println!("  {n_ok} current · {n_update} update · {n_drift} drift · {n_err} error\n");

    changed_files.sort();
    changed_files.dedup();

    // ---- commit ----
    if cli.commit && !changed_files.is_empty() {
        commit(&root, &changed_files);
    }

    // ---- sync ----
    if cli.sync && !changed_files.is_empty() {
        sync_argocd(&root, &changed_files);
    }

    // ---- health ----
    let mut health_failed = false;
    if cli.health {
        let report = health::run(&owned_ns, &changed_repos, 180, 10);
        health_failed = report.failed;
    }

    // ---- exit code ----
    if cli.exit_code {
        if health_failed {
            std::process::exit(1);
        }
        if n_drift > 0 {
            std::process::exit(20);
        }
        if n_update > 0 {
            std::process::exit(10);
        }
    }
}

fn compute(client: &Client, full: String, files: Vec<PathBuf>) -> Outcome {
    // full = "repo:tag@sha256:<hex>"
    let (name, dig) = full.split_once("@sha256:").expect("ref carries @sha256");
    let pinned = format!("sha256:{dig}");
    let iref = registry::parse_ref(name);
    let klass = if registry::is_floating(&iref.tag) {
        Klass::Floating
    } else {
        Klass::Pinned
    };
    let current = registry::resolve_digest(client, &iref).map_err(|e| e.to_string());
    Outcome {
        repo: iref.repo,
        tag: iref.tag,
        klass,
        pinned,
        files,
        current,
    }
}

/// Replace `@<old_digest>` with `@<new_digest>` in `path`. Returns true if the file changed.
fn apply_digest(path: &Path, old: &str, new: &str) -> bool {
    let Ok(content) = std::fs::read_to_string(path) else {
        return false;
    };
    let needle = format!("@{old}");
    if !content.contains(&needle) {
        return false;
    }
    let replaced = content.replace(&needle, &format!("@{new}"));
    std::fs::write(path, replaced).is_ok()
}

fn commit(root: &Path, files: &[PathBuf]) {
    let mut add = Command::new("git");
    add.arg("-C").arg(root).arg("add");
    for f in files {
        add.arg(f);
    }
    if !add.status().map(|s| s.success()).unwrap_or(false) {
        eprintln!("commit: git add failed");
        return;
    }
    let ok = Command::new("git")
        .arg("-C")
        .arg(root)
        .args([
            "commit",
            "-q",
            "-m",
            "chore(images): bump floating-tag images to current upstream digests",
        ])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if ok {
        println!("committed {} file(s)", files.len());
    }
}

fn sync_argocd(root: &Path, changed: &[PathBuf]) {
    let out = Command::new("kubectl")
        .args(["-n", "argocd", "get", "app", "-o", "json"])
        .output();
    let Ok(out) = out else {
        eprintln!("sync: kubectl not runnable");
        return;
    };
    if !out.status.success() {
        eprintln!("sync: kubectl get app failed");
        return;
    }
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap_or(serde_json::Value::Null);
    let apps = v.get("items").and_then(|i| i.as_array()).cloned().unwrap_or_default();

    let mut refreshed: Vec<String> = Vec::new();
    for cf in changed {
        let rel = rel(cf, root);
        for app in &apps {
            let name = app.pointer("/metadata/name").and_then(|x| x.as_str()).unwrap_or("");
            let path = app.pointer("/spec/source/path").and_then(|x| x.as_str()).unwrap_or("");
            if path.is_empty() || name.is_empty() {
                continue;
            }
            let prefix = format!("{}/", path.trim_end_matches('/'));
            if rel.starts_with(&prefix) && !refreshed.iter().any(|r| r == name) {
                let ok = Command::new("kubectl")
                    .args([
                        "-n", "argocd", "annotate", "app", name,
                        "argocd.argoproj.io/refresh=normal", "--overwrite",
                    ])
                    .output()
                    .map(|o| o.status.success())
                    .unwrap_or(false);
                if ok {
                    println!("refreshed argocd app: {name}");
                    refreshed.push(name.to_string());
                }
            }
        }
    }
}

fn repo_root() -> PathBuf {
    if let Ok(out) = Command::new("git").args(["rev-parse", "--show-toplevel"]).output() {
        if out.status.success() {
            let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !s.is_empty() {
                return PathBuf::from(s);
            }
        }
    }
    std::env::current_dir().expect("cwd")
}

fn rel(p: &Path, root: &Path) -> String {
    p.strip_prefix(root).unwrap_or(p).display().to_string()
}

/// Cluster image strings use Docker Hub short forms (`postgres:…`), but parse_ref
/// normalizes officials to `library/postgres`. Strip the prefix so the --health substring
/// filter matches the running container image.
fn health_repo(repo: &str) -> String {
    repo.strip_prefix("library/").unwrap_or(repo).to_string()
}
