//! Deterministic discovery of `image: <ref>@sha256:<digest>` pins under the manifest tree.

use regex::Regex;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use walkdir::WalkDir;

/// Walk `dir` and return a map of full image ref (`repo:tag@sha256:…`) → sorted files that
/// pin it. BTreeMap gives a stable, sorted iteration order (determinism Pass 8).
pub fn discover(dir: &Path) -> BTreeMap<String, Vec<PathBuf>> {
    let re = Regex::new(r"image:\s+(\S+@sha256:[0-9a-f]+)").expect("valid regex");
    let mut map: BTreeMap<String, Vec<PathBuf>> = BTreeMap::new();

    for entry in WalkDir::new(dir).sort_by_file_name().into_iter().filter_map(|e| e.ok()) {
        let p = entry.path();
        if !p.is_file() {
            continue;
        }
        match p.extension().and_then(|e| e.to_str()) {
            Some("yaml") | Some("yml") => {}
            _ => continue,
        }
        let Ok(content) = std::fs::read_to_string(p) else {
            continue;
        };
        for line in content.lines() {
            // Skip commented-out manifest lines (e.g. a disabled `# image: …@sha256:…`),
            // which would otherwise match mid-line and resolve a stale/fake digest.
            if line.trim_start().starts_with('#') {
                continue;
            }
            if let Some(cap) = re.captures(line) {
                map.entry(cap[1].to_string()).or_default().push(p.to_path_buf());
            }
        }
    }
    for files in map.values_mut() {
        files.sort();
        files.dedup();
    }
    map
}
