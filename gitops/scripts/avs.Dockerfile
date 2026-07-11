# Hardened build for the k3s homelab, side-loaded via `k3s ctr images import`.
# Mirrors the app repo's Dockerfile + non-root hardening: the app writes dashboard.html,
# dashboard.db and .cache/ into /app (ROOT = dir above src/) alongside baked code, so the
# runtime uid must own /app and the rootfs stays writable (rebuildable cache by design).
# Built by gitops/scripts/update-avs.sh. ENV defaults here are overridden by the k8s manifest.
FROM docker.io/oven/bun:1.3.14-slim
WORKDIR /app
COPY package.json tsconfig.json ./
COPY src ./src
RUN chown -R 65532:65532 /app
USER 65532:65532
# HOME=/tmp: bun's cache writes to $HOME; default /root is 0700 root-owned -> unwritable by 65532.
ENV PORT=8080 REFRESH_MINUTES=60 API_CONCURRENCY=6 HOME=/tmp
EXPOSE 8080
CMD ["bun", "run", "src/server.ts"]
