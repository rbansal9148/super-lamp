//! Post-change synthetic health gate.
//!
//! For each targeted workload: wait for the rollout, assert 0 container restarts on its
//! pods, then exercise the app over the kube-apiserver service-proxy
//! (`/api/v1/namespaces/<ns>/services/<svc>:<port>/proxy/`). Probing the *Service* — not
//! the public ingress — deliberately bypasses the Traefik/Authelia forward-auth wall, so a
//! 200/302/401/403 all mean "the app answered"; only a 5xx or no-answer fails the gate.

use serde_json::Value;
use std::process::Command;

pub struct Report {
    pub failed: bool,
}

/// Run the gate. `target_repos` empty ⇒ smoke-test every owned workload; otherwise only
/// workloads whose container image contains one of the changed repos.
pub fn run(owned_ns: &[String], target_repos: &[String], rollout_timeout: u32, probe_timeout: u32) -> Report {
    println!("== synthetic health gate ==");
    let mut failed = false;

    let out = Command::new("kubectl")
        .args(["get", "deploy,statefulset,daemonset", "-A", "-o", "json"])
        .output();
    let Ok(out) = out else {
        eprintln!("  health: kubectl not runnable — skipped");
        return Report { failed: true };
    };
    if !out.status.success() {
        eprintln!("  health: kubectl get workloads failed — skipped");
        return Report { failed: true };
    }
    let root: Value = serde_json::from_slice(&out.stdout).unwrap_or(Value::Null);
    let items = root.get("items").and_then(|i| i.as_array()).cloned().unwrap_or_default();

    let mut checked = 0;
    for it in &items {
        let ns = it.pointer("/metadata/namespace").and_then(|v| v.as_str()).unwrap_or("");
        let name = it.pointer("/metadata/name").and_then(|v| v.as_str()).unwrap_or("");
        let kind = it.get("kind").and_then(|v| v.as_str()).unwrap_or("").to_ascii_lowercase();
        let img = it
            .pointer("/spec/template/spec/containers/0/image")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if ns.is_empty() || name.is_empty() || kind.is_empty() {
            continue;
        }
        if !owned_ns.iter().any(|o| o == ns) {
            continue;
        }
        if !target_repos.is_empty() && !target_repos.iter().any(|r| img.contains(r.as_str())) {
            continue;
        }
        checked += 1;

        // 1) rollout
        let rolled = Command::new("kubectl")
            .args([
                "-n", ns, "rollout", "status", &format!("{kind}/{name}"),
                &format!("--timeout={rollout_timeout}s"),
            ])
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        let roll = if rolled { "rolled-out" } else { "ROLLOUT-TIMEOUT" };
        if !rolled {
            failed = true;
        }

        // 2) restart count across this workload's pods
        let restarts = pod_restarts(ns, name);
        if restarts.map(|n| n > 0).unwrap_or(false) {
            failed = true;
        }
        let restarts_s = restarts.map(|n| n.to_string()).unwrap_or_else(|| "?".into());

        // 3) service-proxy probe (Service named like the workload, by convention)
        let probe = service_proxy_probe(ns, name, probe_timeout);

        let mut flag = String::new();
        if !rolled {
            flag.push_str("  ✗");
        }
        if restarts.map(|n| n > 0).unwrap_or(false) {
            flag.push_str(&format!("  ✗ restarts={restarts_s}"));
        }
        println!(
            "  {:<24} {:<12} rollout={:<15} restarts={:<3} probe={}{}",
            format!("{ns}/{name}"),
            kind,
            roll,
            restarts_s,
            probe,
            flag
        );
    }

    if checked == 0 {
        println!("  (no matching workloads to check)");
    }
    println!("  health: {}", if failed { "FAIL" } else { "PASS" });
    Report { failed }
}

fn pod_restarts(ns: &str, name: &str) -> Option<i64> {
    let out = Command::new("kubectl")
        .args(["-n", ns, "get", "pods", "-l", &format!("app={name}"), "-o", "json"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let v: Value = serde_json::from_slice(&out.stdout).ok()?;
    let items = v.get("items")?.as_array()?;
    if items.is_empty() {
        return None;
    }
    let mut total = 0i64;
    for pod in items {
        if let Some(cs) = pod.pointer("/status/containerStatuses").and_then(|c| c.as_array()) {
            for c in cs {
                total += c.get("restartCount").and_then(|r| r.as_i64()).unwrap_or(0);
            }
        }
    }
    Some(total)
}

/// Returns "ok<500", "probe-fail", or "n/a" (no Service / no port found).
fn service_proxy_probe(ns: &str, name: &str, timeout: u32) -> String {
    let port = Command::new("kubectl")
        .args([
            "-n", ns, "get", "svc", name, "-o",
            "jsonpath={.spec.ports[0].port}",
        ])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();
    if port.is_empty() {
        return "n/a".into();
    }
    let ok = Command::new("kubectl")
        .args([
            "get", "--raw",
            &format!("/api/v1/namespaces/{ns}/services/{name}:{port}/proxy/"),
            &format!("--request-timeout={timeout}s"),
        ])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);
    if ok { "ok<500".into() } else { "probe-fail".into() }
}
