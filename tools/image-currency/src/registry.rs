//! OCI registry digest resolution via the generic Www-Authenticate challenge flow.
//!
//! No per-registry special-casing: HEAD the manifest, and if the registry answers 401 we
//! parse the `Www-Authenticate: Bearer realm=…,service=…,scope=…` header, fetch an
//! anonymous pull token from `realm`, and retry. This works identically for ghcr.io,
//! docker.io (incl. `library/` officials) and registry.k8s.io.

use anyhow::{anyhow, Result};
use reqwest::blocking::Client;
use reqwest::header::{HeaderMap, HeaderValue, ACCEPT, AUTHORIZATION, WWW_AUTHENTICATE};

/// Manifest media types we accept, widest (multi-arch index) first. The digest a
/// `tag@sha256:` pin stores is the index/manifest-list digest, which is exactly what the
/// registry returns in `Docker-Content-Digest` for these accepts.
const ACCEPTS: &[&str] = &[
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
];

#[derive(Debug)]
pub struct ImageRef {
    /// Hostname to hit the registry v2 API on (docker.io is remapped to registry-1.docker.io).
    pub api_host: String,
    pub repo: String,
    pub tag: String,
}

/// Parse a `name[:tag]` (digest already stripped) into registry host + repo + tag,
/// normalizing Docker Hub short forms (`postgres` → `library/postgres`).
pub fn parse_ref(name: &str) -> ImageRef {
    // A leading segment with a dot/colon (or "localhost") is a registry host; otherwise
    // this is a Docker Hub reference.
    let (host, remainder) = match name.split_once('/') {
        Some((first, rest))
            if first.contains('.') || first.contains(':') || first == "localhost" =>
        {
            (first.to_string(), rest.to_string())
        }
        _ => ("docker.io".to_string(), name.to_string()),
    };

    // Host is gone, so any remaining ':' separates the tag (no port to confuse it with).
    let (mut repo, tag) = match remainder.rsplit_once(':') {
        Some((r, t)) => (r.to_string(), t.to_string()),
        None => (remainder.clone(), "latest".to_string()),
    };

    if host == "docker.io" && !repo.contains('/') {
        repo = format!("library/{repo}"); // official image lives under library/
    }
    let api_host = if host == "docker.io" {
        "registry-1.docker.io".to_string()
    } else {
        host
    };
    ImageRef { api_host, repo, tag }
}

/// Resolve the current `sha256:` digest the tag points at, following one auth challenge.
pub fn resolve_digest(client: &Client, r: &ImageRef) -> Result<String> {
    let url = format!("https://{}/v2/{}/manifests/{}", r.api_host, r.repo, r.tag);

    let mut accept = HeaderMap::new();
    for a in ACCEPTS {
        accept.append(ACCEPT, HeaderValue::from_static(a));
    }

    let resp = client.head(&url).headers(accept.clone()).send()?;
    let resp = if resp.status().as_u16() == 401 {
        let challenge = resp
            .headers()
            .get(WWW_AUTHENTICATE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or_default()
            .to_string();
        let token = fetch_token(client, &challenge, &r.repo)?;
        let mut h = accept.clone();
        h.insert(AUTHORIZATION, HeaderValue::from_str(&format!("Bearer {token}"))?);
        client.head(&url).headers(h).send()?
    } else {
        resp
    };

    if !resp.status().is_success() {
        return Err(anyhow!("HTTP {} for {}", resp.status().as_u16(), url));
    }
    let dig = resp
        .headers()
        .get("docker-content-digest")
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| anyhow!("no Docker-Content-Digest header"))?;
    if !dig.starts_with("sha256:") {
        return Err(anyhow!("unexpected digest form: {dig}"));
    }
    Ok(dig.to_string())
}

fn fetch_token(client: &Client, challenge: &str, repo: &str) -> Result<String> {
    let realm = kv(challenge, "realm").ok_or_else(|| anyhow!("no realm in auth challenge"))?;
    let service = kv(challenge, "service").unwrap_or_default();
    let scope = kv(challenge, "scope").unwrap_or_else(|| format!("repository:{repo}:pull"));

    let mut query: Vec<(&str, String)> = vec![("scope", scope)];
    if !service.is_empty() {
        query.push(("service", service));
    }
    let body: serde_json::Value = client.get(&realm).query(&query).send()?.json()?;
    body.get("token")
        .or_else(|| body.get("access_token"))
        .and_then(|t| t.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| anyhow!("no token in auth response"))
}

/// Extract `key="value"` from a Www-Authenticate header value.
fn kv(s: &str, key: &str) -> Option<String> {
    let needle = format!("{key}=\"");
    let start = s.find(&needle)? + needle.len();
    let end = s[start..].find('"')? + start;
    Some(s[start..end].to_string())
}

const FLOATING: &[&str] = &[
    "latest", "nightly", "dev", "edge", "main", "master", "develop", "public", "stable",
    "rolling", "canary",
];

/// A floating tag is a moving label expected to drift; everything else is a version pin
/// whose digest must be immutable (a change there is supply-chain drift, not an update).
pub fn is_floating(tag: &str) -> bool {
    FLOATING.contains(&tag.to_ascii_lowercase().as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_docker_official() {
        let r = parse_ref("postgres:18.4");
        assert_eq!(r.api_host, "registry-1.docker.io");
        assert_eq!(r.repo, "library/postgres");
        assert_eq!(r.tag, "18.4");
    }

    #[test]
    fn parse_docker_user_no_tag() {
        let r = parse_ref("qmcgaw/gluetun");
        assert_eq!(r.repo, "qmcgaw/gluetun");
        assert_eq!(r.tag, "latest");
    }

    #[test]
    fn parse_ghcr() {
        let r = parse_ref("ghcr.io/immich-app/immich-server:v2.7.5");
        assert_eq!(r.api_host, "ghcr.io");
        assert_eq!(r.repo, "immich-app/immich-server");
        assert_eq!(r.tag, "v2.7.5");
    }

    #[test]
    fn parse_k8s_registry() {
        let r = parse_ref("registry.k8s.io/external-dns/external-dns:v0.21.0");
        assert_eq!(r.api_host, "registry.k8s.io");
        assert_eq!(r.repo, "external-dns/external-dns");
    }

    #[test]
    fn floating_classification() {
        assert!(is_floating("latest"));
        assert!(is_floating("NIGHTLY"));
        assert!(!is_floating("v2.7.5"));
        assert!(!is_floating("18.4"));
    }

    #[test]
    fn kv_extract() {
        let c = r#"Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:x/y:pull""#;
        assert_eq!(kv(c, "realm").unwrap(), "https://ghcr.io/token");
        assert_eq!(kv(c, "service").unwrap(), "ghcr.io");
        assert_eq!(kv(c, "scope").unwrap(), "repository:x/y:pull");
    }
}
