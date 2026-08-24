FROM rust:1.96-bookworm@sha256:a339861ae23e9abb272cea45dfafde21760d2ce6577a70f8a926153677902663 AS builder

WORKDIR /app
COPY components/nexus-platform/control-plane/Cargo.toml components/nexus-platform/control-plane/Cargo.lock ./
COPY components/nexus-platform/control-plane/src ./src
COPY components/nexus-rustdesk /nexus-rustdesk
RUN cargo build --locked --release --bin nexus-web-relay

FROM debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --no-create-home --shell /usr/sbin/nologin nexus
COPY --from=builder /app/target/release/nexus-web-relay /usr/local/bin/nexus-web-relay
USER nexus
EXPOSE 3010
HEALTHCHECK --interval=15s --timeout=5s --retries=3 CMD curl -fsS http://127.0.0.1:3010/health || exit 1
ENTRYPOINT ["/usr/local/bin/nexus-web-relay"]
