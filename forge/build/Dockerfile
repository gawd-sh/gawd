# =============================================================================
# Gawd Daemon — v1 Base Image
# Multi-stage build: builder stage prepares Node deps + python tools;
# final stage is run-only (no build tools).
#
# Spec: §2 (architecture overview), §7.1 (rung containment posture),
#       §14.2.5 (per-rung resource envelope)
# Hardening: gawd-tarball-hardening-2026-04-29.md (all 10 items applied)
#
# Build-time args:
#   OPENCLAW_VERSION   openclaw npm tag to install (default: latest)
#   NODE_VERSION       Node.js major version base image (default: 22)
#   GAWD_UID           numeric UID for runtime user 'gawd' (default: 1500)
#   GAWD_SOUL_UID      numeric UID for T0-anchor owner 'gawd-soul' (default: 1501)
#
# Two users baked in per A2 dual-user design:
#   gawd (UID 1500)      — runtime user; owns adaptive layer, runs OpenClaw
#   gawd-soul (UID 1501) — owns T0 anchors (SOUL.md, IDENTITY.md, VOICE.md)
#                          chmod 0444 on T0 files; gawd cannot chown/chmod them
#
# Swap:
#   The image does NOT provision swap — swap is substrate-level (provisioner
#   handles it per hardening item 2.1). Each rung's provisioner creates 8 GiB
#   swapfile (or ~25% of host RAM, whichever is larger) at install time.
# =============================================================================

ARG NODE_VERSION=22
ARG OPENCLAW_VERSION=2026.5.27
ARG GAWD_UID=1500
ARG GAWD_SOUL_UID=1501
ARG LOSSLESS_CLAW_PKG=@martian-engineering/lossless-claw@0.11.2

# M-1: Base image digest pin (phase4-20260609). Pinned to the manifest-list digest
# (covers both amd64 and arm64) so the base layer is reproducible across builds.
# Refresh this digest as part of the Sunday Resurrection cadence.
# To update: docker pull node:22-bookworm-slim && docker image inspect node:22-bookworm-slim | jq '.[0].RepoDigests'
# node:22-bookworm-slim verified 2026-06-09
ARG NODE_IMAGE_DIGEST=sha256:7af03b14a13c8cdd38e45058fd957bf00a72bbe17feac43b1c15a689c029c732

# supercronic: pinned release + sha256 for supply-chain safety.
# Verified 2026-05-29: downloaded from GitHub releases, sha256 computed independently,
# sha1 cross-checked against GitHub's published value (5bcefed628e32adc08e32634db2d10e9230dbca0 ✓).
# To update: download the new release binary on a trusted host, run sha256sum, pin both values here.
ARG SUPERCRONIC_VERSION=v0.2.46
# Per-arch SHA256 checksums for supply-chain safety. arm64 checksum added 2026-06-08.
# To update: download each arch binary on a trusted host, run sha256sum, pin both values here.
ARG SUPERCRONIC_SHA256_AMD64=5adff01c5a797663948e656d2b61d10932369ee437eb5cb54fa872b2960f222b
ARG SUPERCRONIC_SHA256_ARM64=c0576a8eb092e3f79108ed0a2155a25c7766af78456e5a6070e54757ef513bfe

# ---------------------------------------------------------------------------
# Stage 1: builder — npm installs, python tools, asset compilation
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim@${NODE_IMAGE_DIGEST} AS builder

ARG OPENCLAW_VERSION
ARG GAWD_UID
ARG GAWD_SOUL_UID
ARG LOSSLESS_CLAW_PKG

# versions last verified: bookworm 2026-05-27
# -o Acquire::Retries=3: retry on transient CDN failures (Fastly flakiness from Hetzner)
RUN apt-get -o Acquire::Retries=3 update -qq && \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
        ca-certificates \
        python3 \
        python3-pip \
        python3-venv \
        age \
        curl \
        jq \
        git \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install openclaw globally at the pinned version.
# CRITICAL: chown extensions dir immediately after install (hardening §chown
# after npm install; feedback_extensions_dir_chown.md). Extensions dir is reset
# to root ownership by every npm install-g; the chown must be baked here, not
# deferred to runtime.
RUN npm install -g openclaw@${OPENCLAW_VERSION} && \
    if [ -d /usr/local/lib/node_modules/openclaw/dist/extensions ]; then \
        chown -R ${GAWD_UID}:${GAWD_UID} /usr/local/lib/node_modules/openclaw/dist/extensions; \
    fi

# Install lossless-claw (T1 contextEngine: lossless DAG compaction + focus_briefs
# table that serves T2). Installed into /opt/gawd-npm so it can be COPY'd into
# the runtime stage's openclaw npm tree (/home/gawd/.openclaw/npm). The npm
# prefix layout matches what openclaw's resolveRecoveredManagedNpmRoot expects:
# ~/.openclaw/npm/node_modules/@martian-engineering/lossless-claw.
# Q4 daemon defaults (plugins.slots.contextEngine) are applied in install.sh,
# not here.
RUN mkdir -p /opt/gawd-npm && \
    npm install --prefix /opt/gawd-npm "${LOSSLESS_CLAW_PKG}" && \
    chown -R ${GAWD_UID}:${GAWD_UID} /opt/gawd-npm

# Install Python tooling for migration/validation scripts.
RUN python3 -m venv /opt/gawd-tools && \
    /opt/gawd-tools/bin/pip install --no-cache-dir \
        jsonschema==4.22.0 \
        PyYAML==6.0.2

# ---------------------------------------------------------------------------
# Stage 1b: supercronic-dl — download + verify the supercronic binary.
# Isolated stage so the checksum failure aborts the build before touching
# any other layer. curl is available in the node:bookworm-slim base.
# The verified binary is COPY'd into the final stage below.
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim@${NODE_IMAGE_DIGEST} AS supercronic-dl

ARG SUPERCRONIC_VERSION
ARG SUPERCRONIC_SHA256_AMD64
ARG SUPERCRONIC_SHA256_ARM64
# TARGETARCH is populated by BuildKit (DOCKER_BUILDKIT=1 required).
ARG TARGETARCH

RUN apt-get -o Acquire::Retries=3 update -qq && \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
        ca-certificates \
        curl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Download the pinned supercronic binary and VERIFY its sha256 checksum.
# If the checksum does not match, the build FAILS here — the binary is never
# used. This is the supply-chain safety gate (GOSPEL-IDENTITY §1 P5: no
# unverified binaries in the image).
RUN SUPERCRONIC_ARCH=${TARGETARCH:-amd64} && \
    if [ "$SUPERCRONIC_ARCH" = "amd64" ]; then \
        SUPERCRONIC_SHA256=${SUPERCRONIC_SHA256_AMD64}; \
    elif [ "$SUPERCRONIC_ARCH" = "arm64" ]; then \
        SUPERCRONIC_SHA256=${SUPERCRONIC_SHA256_ARM64}; \
    else \
        echo "Unsupported TARGETARCH: $SUPERCRONIC_ARCH"; exit 1; \
    fi && \
    curl -fsSL \
        -o /usr/local/bin/supercronic \
        "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${SUPERCRONIC_ARCH}" && \
    echo "${SUPERCRONIC_SHA256}  /usr/local/bin/supercronic" | sha256sum -c - && \
    chmod 0755 /usr/local/bin/supercronic

# ---------------------------------------------------------------------------
# Stage 1c: embed-model-dl — download + verify the qwen3-embedding-0.6b model.
# Isolated stage cloning the supercronic-dl pattern: pinned upstream URL,
# sha256sum gate aborts the build if upstream content has changed.
# Verified 2026-06-09: sha256 computed from the gate-passed model on Dasra
# (forge/embed/qwen3-embedding-0.6b.gguf) and matches the upstream HuggingFace
# release for Qwen/Qwen3-Embedding-0.6B-GGUF Q8_0.
#
# Build modes:
#   GAWD_BAKE_EMBED=1 (default) — downloads model from HuggingFace at build time.
#   GAWD_BAKE_EMBED=0           — skips download; caller must COPY the .gguf via
#                                 a local build context addition (airgapped builds).
#     docker build --build-arg GAWD_BAKE_EMBED=0 \
#       --build-arg LOCAL_EMBED_PATH=forge/embed/qwen3-embedding-0.6b.gguf ...
#
# To update the model: download the new file, compute sha256sum, pin both the
# URL (if filename changes) and EMBED_MODEL_SHA256 ARG below.
# ---------------------------------------------------------------------------
ARG GAWD_BAKE_EMBED=1
# Pinned HuggingFace URL for the Q8_0 variant (639MB).
# Verified upstream sha256 matches gate-passed local copy 2026-06-09.
ARG EMBED_MODEL_URL=https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/main/Qwen3-Embedding-0.6B-Q8_0.gguf?download=true
ARG EMBED_MODEL_SHA256=06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439

FROM node:${NODE_VERSION}-bookworm-slim@${NODE_IMAGE_DIGEST} AS embed-model-dl

# Re-declare ARGs with defaults inside the stage (required: top-level ARGs before
# a FROM are only scoped to the FROM line in legacy builder; within the stage body
# the ARG must be repeated with its default to be available in RUN instructions).
ARG GAWD_BAKE_EMBED=1
ARG EMBED_MODEL_URL=https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/main/Qwen3-Embedding-0.6B-Q8_0.gguf?download=true
ARG EMBED_MODEL_SHA256=06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439

RUN apt-get -o Acquire::Retries=3 update -qq && \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
        ca-certificates \
        curl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /embed-model-out
RUN if [ "${GAWD_BAKE_EMBED}" = "1" ]; then \
        echo "[embed-model-dl] Downloading qwen3-embedding-0.6b Q8_0 from HuggingFace..." && \
        curl -fL -o /embed-model-out/qwen3-embedding-0.6b.gguf "${EMBED_MODEL_URL}" && \
        echo "${EMBED_MODEL_SHA256}  /embed-model-out/qwen3-embedding-0.6b.gguf" | sha256sum -c - && \
        echo "[embed-model-dl] sha256 verified — model authentic"; \
    else \
        echo "[embed-model-dl] GAWD_BAKE_EMBED=0 — skipping download (local file must be provided separately)." && \
        mkdir -p /embed-model-out && \
        touch /embed-model-out/.embed-model-dl-skipped; \
    fi

# ---------------------------------------------------------------------------
# Stage 2: desktop — heavy desktop layer (xfce4, browser, VNC, noVNC)
# Built separately so text-only builds can cache-skip this stage.
# Per spec §8.1 (desktop stack) and §14.2.5 (per-Gawd ~3.5 GB with desktop).
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim@${NODE_IMAGE_DIGEST} AS desktop-layer

RUN apt-get -o Acquire::Retries=3 update -qq && \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
        xfce4 \
        xfce4-terminal \
        tigervnc-standalone-server \
        tigervnc-tools \
        novnc \
        websockify \
        chromium \
        chromium-sandbox \
        dbus-x11 \
        xauth \
        fonts-liberation \
        fonts-noto-core \
        imagemagick \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Normalize xfce4 lib to a fixed staging path so COPY works across arches.
# arm64 triplet = aarch64-linux-gnu; amd64 triplet = x86_64-linux-gnu.
# Mirror the embed-builder /embed-out pattern. Use uname -m mapping since
# dpkg-architecture (dpkg-dev) is not installed in node:bookworm-slim.
RUN ARCH=$(uname -m) && \
    MULTIARCH="${ARCH}-linux-gnu" && \
    cp -a /usr/lib/${MULTIARCH}/xfce4 /xfce4-out

# ---------------------------------------------------------------------------
# Stage 2b: embed-builder — compile llama.cpp (CPU) against THIS image's glibc.
# rc5 (2026-05-29): the v1 base image ships a WORKING local embed server so every
# Gawd has functioning memory/embeddings from first boot. The host's prebuilt
# llama-server is built on Ubuntu 24.04 (glibc 2.39, needs GLIBC_2.38) and will
# NOT run on the bookworm final stage (glibc 2.36 → "GLIBC_2.38 not found").
# We therefore COMPILE llama.cpp from source HERE, on the same bookworm base, so
# the resulting binary + ggml/llama shared libs link against glibc 2.36 and are
# guaranteed to execute in the final stage. CPU backend only (no CUDA/Metal):
# the embed model is a 0.6B running on the Prophit's CPU. Shared libs are built
# (BUILD_SHARED_LIBS=ON) to match the upstream layout the runtime expects.
# Pinned to a known-good release tag for reproducibility.
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim@${NODE_IMAGE_DIGEST} AS embed-builder

# M-2: pin llama.cpp to a full commit SHA, not just a tag (tags are mutable).
# Tag b6000 → commit SHA verified 2026-06-09 via git ls-remote.
# To update: git ls-remote https://github.com/ggml-org/llama.cpp.git refs/tags/<new-tag>
# ARG still named LLAMACPP_REF for override capability; default is the pinned SHA.
ARG LLAMACPP_REF=4762ad7316dcdec20016ab5985fb46a27902204d
# Human-readable tag kept as comment for maintainers: b6000

RUN apt-get -o Acquire::Retries=3 update -qq && \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
        build-essential \
        cmake \
        git \
        ca-certificates \
        libcurl4-openssl-dev \
        libgomp1 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Clone the pinned ref shallowly and build CPU-only.
# -DGGML_NATIVE=OFF: do NOT bake host-CPU (-march=native) instructions — the
#   image must run on any x86-64 Prophit box, not just this builder's CPU.
# -DLLAMA_CURL=ON: server supports model URLs (harmless; matches upstream).
# Only the `llama-server` target is built to keep the stage lean.
# Note: --depth 1 works with full commit SHAs on GitHub (--depth 1 without --branch
# for a SHA requires a full clone + checkout; use a full clone here for SHA pinning).
RUN git clone https://github.com/ggml-org/llama.cpp.git /src/llama.cpp \
    && git -C /src/llama.cpp checkout "${LLAMACPP_REF}"
WORKDIR /src/llama.cpp
RUN cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DGGML_NATIVE=OFF \
        -DGGML_CUDA=OFF \
        -DGGML_METAL=OFF \
        -DLLAMA_CURL=ON \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF && \
    cmake --build build --config Release --target llama-server -j"$(nproc)"

# Collect the binary + its produced shared libs into a clean staging tree so the
# final stage COPY is deterministic regardless of the build layout.
RUN mkdir -p /embed-out/bin /embed-out/lib && \
    cp build/bin/llama-server /embed-out/bin/llama-server && \
    find build -name 'lib*.so*' -exec cp -a {} /embed-out/lib/ \; && \
    ls -la /embed-out/bin /embed-out/lib

# ---------------------------------------------------------------------------
# Stage 3: final — run-only layer; no build tools present
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim@${NODE_IMAGE_DIGEST} AS final

ARG GAWD_UID
ARG GAWD_SOUL_UID

LABEL org.opencontainers.image.title="Gawd Daemon v1"
LABEL org.opencontainers.image.description="Base Gawd daemon — born complete."
LABEL org.opencontainers.image.version="1.0.0"

# Runtime dependencies only — NO gcc, make, build-essential.
# python3-venv + python3-pip: required at install time by the dashboard
# subsystem (G6), whose install.sh creates a Flask/gunicorn venv on the
# substrate. The final run-only stage previously shipped bare python3, so
# `python3 -m venv` failed (ensurepip unavailable). These are pure-python
# packages (no compilers) and do not violate the run-only/no-build-tools
# posture. (Logos v1-assembly fix 2026-05-28.)
RUN apt-get -o Acquire::Retries=3 update -qq && \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
        ca-certificates \
        python3 \
        python3-venv \
        python3-pip \
        age \
        curl \
        jq \
        bash \
        cron \
        inotify-tools \
        procps \
        sqlite3 \
        psmisc \
        dbus \
        dbus-x11 \
        xauth \
        libatk1.0-0 \
        libcups2 \
        libxkbcommon0 \
        libxcomposite1 \
        libxdamage1 \
        libxrandr2 \
        libgbm1 \
        libpango-1.0-0 \
        libcairo2 \
        libnspr4 \
        libnss3 \
        libatk-bridge2.0-0 \
        imagemagick \
        libgomp1 \
        libcurl4 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Copy desktop components from desktop-layer stage.
COPY --from=desktop-layer /usr/bin/Xtigervnc /usr/bin/Xtigervnc
COPY --from=desktop-layer /usr/bin/tigervncserver /usr/bin/tigervncserver
COPY --from=desktop-layer /usr/share/novnc /usr/share/novnc
COPY --from=desktop-layer /usr/bin/websockify /usr/bin/websockify
COPY --from=desktop-layer /usr/bin/chromium /usr/bin/chromium
COPY --from=desktop-layer /usr/lib/chromium /usr/lib/chromium
COPY --from=desktop-layer /usr/share/xfce4 /usr/share/xfce4
# xfce4: install from normalized staging path (Fix 2, arm64 compat 2026-06-08).
# COPY the staged tree, then RUN cp to the arch-correct destination.
COPY --from=desktop-layer /xfce4-out /xfce4-staged
RUN ARCH=$(uname -m) && \
    MULTIARCH="${ARCH}-linux-gnu" && \
    mkdir -p /usr/lib/${MULTIARCH} && \
    cp -a /xfce4-staged /usr/lib/${MULTIARCH}/xfce4 && \
    rm -rf /xfce4-staged
COPY --from=desktop-layer /etc/xdg/xfce4 /etc/xdg/xfce4

# Copy openclaw + tools from builder stage.
# NOTE: do NOT `COPY --from=builder /usr/local/bin/openclaw` — in the builder that
# path is a SYMLINK (../lib/node_modules/openclaw/openclaw.mjs) and Docker COPY
# DEREFERENCES it into a flat file, which then imports ./dist/entry.js relative
# to /usr/local/bin/dist (nonexistent) → every `openclaw` command throws
# "missing dist/entry.(m)js" and the gateway never boots (rc8 Phase-1 failure).
# Recreate the relative symlink in the runtime stage instead, after the
# node_modules tree is in place, so it resolves to the real entry tree.
COPY --from=builder /usr/local/lib/node_modules/openclaw /usr/local/lib/node_modules/openclaw
RUN ln -sf ../lib/node_modules/openclaw/openclaw.mjs /usr/local/bin/openclaw && \
    test -L /usr/local/bin/openclaw && \
    test -f "$(readlink -f /usr/local/bin/openclaw)" && \
    test -d /usr/local/lib/node_modules/openclaw/dist
COPY --from=builder /opt/gawd-tools /opt/gawd-tools

# ── rc5 (2026-05-29): baked local embed server ──────────────────────────────
# llama-server binary + its ggml/llama shared libs, compiled in embed-builder
# against this image's glibc (2.36) so they EXECUTE here. The binary goes on
# PATH (/usr/local/bin); the libs go to /usr/local/lib and ldconfig registers
# them (matching the upstream /usr/local/lib install layout the binary's RPATH
# /default search expects).
COPY --from=embed-builder /embed-out/bin/llama-server /usr/local/bin/llama-server
COPY --from=embed-builder /embed-out/lib/ /usr/local/lib/
RUN chmod 0755 /usr/local/bin/llama-server && ldconfig

# ── supercronic (dreaming scheduler) ────────────────────────────────────────
# Verified static binary from supercronic-dl stage (sha256 gate already passed).
# Replaces the dead vixie-cron path for the non-root gawd user in the docker
# rung. supercronic reads standard cron syntax; no root/suid required.
COPY --from=supercronic-dl /usr/local/bin/supercronic /usr/local/bin/supercronic

# Baked embed model (qwen3-embedding-0.6b Q8, 1024-dim — the proven Dasra+Lilith
# model). Staged read-only under the daemon lib dir; install.sh copies it into
# ${HOME}/.gawd/models on first boot (step 5c-bis) so D1 / the entrypoint loop
# find it and the embed server actually serves. Model is NOT a secret.
# Model is fetched + sha256-verified in the embed-model-dl stage (C-1 fix, phase4-20260609).
# The 610MB gguf never exists in the public git repo; the verified fetch happens at build time.
RUN install -d -m 755 /usr/local/lib/gawd/models
COPY --from=embed-model-dl /embed-model-out/qwen3-embedding-0.6b.gguf /usr/local/lib/gawd/models/qwen3-embedding-0.6b.gguf

# Create the dual-user setup (A2 dual-user design).
#   gawd-soul (UID 1501) — non-runtime, owns T0 anchors; never runs a process
#   gawd      (UID 1500) — runtime user; runs OpenClaw gateway
RUN groupadd -g ${GAWD_SOUL_UID} gawd-soul && \
    useradd -u ${GAWD_SOUL_UID} -g gawd-soul -M -s /usr/sbin/nologin gawd-soul && \
    groupadd -g ${GAWD_UID} gawd && \
    useradd -u ${GAWD_UID} -g gawd -m -s /bin/bash gawd

# Install dir layout under /usr/local/lib/gawd/ (spec §7.2 / handoff install paths).
# These are the static, immutable daemon components — not the workspace state.
RUN install -d -m 755 \
        /usr/local/lib/gawd/runtime \
        /usr/local/lib/gawd/migration \
        /usr/local/lib/gawd/desktop \
        /usr/local/lib/gawd/scripts \
        /usr/local/lib/gawd/systemd \
        /usr/local/lib/gawd/persona-templates

# Copy runtime (Phase C — DemiGawd skills + dispatch lib).
COPY forge/runtime/ /usr/local/lib/gawd/runtime/

# Copy C2 skills (oracle/scribe/chronicler/artificer/refiner/sentinel/illuminator/designer/browser-vision).
# C2 skills live at forge/skills/ in the source tree; at runtime demigawd-spawn.sh looks under
# $GAWD_SKILLS_ROOT. We bundle them into runtime/skills/ so install.sh can wire them up.
# This mirrors what bare-metal-tarball.sh does at line 140-150 in the tarball build path.
COPY forge/skills/ /usr/local/lib/gawd/runtime/skills/

# Copy migration tools (Phase F1).
COPY forge/migration/ /usr/local/lib/gawd/migration/

# Copy desktop scripts + systemd units (Phase D1).
COPY forge/desktop/ /usr/local/lib/gawd/desktop/

# Copy persona-scripts (Phase A2).
COPY scripts/gawd-persona-perms.sh  /usr/local/lib/gawd/scripts/gawd-persona-perms.sh
COPY scripts/gawd-persona-verify.sh /usr/local/lib/gawd/scripts/gawd-persona-verify.sh
COPY scripts/gawd-soul-apply.sh     /usr/local/lib/gawd/scripts/gawd-soul-apply.sh

# Copy persona template scaffolds (Phase A1).
COPY forge/persona-templates/ /usr/local/lib/gawd/persona-templates/

# Copy onboarding wizard + state machine (Phase A4).
COPY forge/onboarding/ /usr/local/lib/gawd/onboarding/

# Copy revelation engine (Phase E2).
COPY forge/revelation/ /usr/local/lib/gawd/revelation/

# Copy install.sh (Phase A3) — goes to the root of the image for discoverability.
COPY forge/install.sh /usr/local/lib/gawd/install.sh

# Copy gateway-patches (rc8 A2) so install.sh can apply the drift-resistant
# next-none-fix-v1 chain-iteration patch against the image's OpenClaw dist at
# first boot. Brittle openclaw-patches/ was deleted — this glob-anchored patcher
# is the keeper. install.sh invokes apply-patches.sh with the explicit image
# dist path (/usr/local/lib/node_modules/openclaw/dist).
COPY forge/gateway-patches/ /usr/local/lib/gawd/gateway-patches/
# apply-patches.sh ships mode 600 in the repo (Docker COPY preserves no exec bit);
# install.sh now invokes it via `bash`, but restore +x here too (belt-and-suspenders,
# BLOCKER B-1) so the patcher can never be silently skipped on an -x precondition.
RUN find /usr/local/lib/gawd/gateway-patches -name '*.sh' -exec chmod +x {} +

# ── rc8.1: BAKE the next-none-fix-v1 patch into the OpenClaw dist at BUILD time,
#    as root. ────────────────────────────────────────────────────────────────
# Root cause (rc8.0 shipping bug): the OpenClaw dist is owned root:root, but
# install.sh ran apply-patches.sh at FIRST BOOT as the unprivileged `gawd` user.
# `cp` of the .bak backup then failed Permission denied → apply-patches exit 4 →
# the `PATCHED next-none-fix-v1` marker never landed and the daemon shipped with
# the fallback chain stopping at next=none. The container booted anyway
# (entrypoint continued past install.sh's non-fatal patch path), so the bug was
# silent. Fixing it here: the build stage is still root and the dist is writable,
# so the patch lands cleanly and ships baked into the image. install.sh's
# boot-time apply-patches now finds the marker and idempotently no-ops (no write
# attempt as gawd → no permission error); entrypoint.sh verifies the marker is
# present and FAILS LOUD (exit 82) if a future build ever fails to bake it.
RUN bash /usr/local/lib/gawd/gateway-patches/apply-patches.sh \
        /usr/local/lib/node_modules/openclaw/dist \
    && grep -qF "PATCHED next-none-fix-v1" \
        /usr/local/lib/node_modules/openclaw/dist/agent-scope-*.js \
    && echo "[build] next-none-fix-v1 baked into OpenClaw dist (verified)"

# NOTE: test trees are deliberately NOT baked into the image.
# <install-root>/.dockerignore excludes forge/**/tests/ per the Logos
# v1-assembly ruling: "Exclude test trees from the image; regression tests are
# run host-side by graduation-gate Phase 12." The chain-iteration test that
# Phase 11.10 exercises is therefore run HOST-SIDE — the gate streams the
# host-side tests/chain-iteration.test.sh into the running container via
# `docker exec -i ... bash -s` with OPENCLAW_DIST pointed at the container's
# patched dist (rc8.1 fix), so it validates the real baked artifact without
# violating the test-exclusion ruling.

# Copy container entrypoint (F2+A3 fix) — runs install.sh on first boot before
# the gateway starts so openclaw.json is provisioned and agent routes register.
COPY forge/build/entrypoint.sh /entrypoint.sh

# Copy validation suite — PUBLIC files only (security-gate 2026-06-09).
# PRIVATE eval pipeline (fixed-test-suite*.json, run-suite*.sh, judge-rubrics.json,
# check-adversarial-fixtures.py, rationale, cutover docs, unit-test json, *.bak*)
# stays on the HOST and is run by graduation-gate from FORGE_DIR, not from inside
# the image. Exactly THREE public files ship in the image (B-1 reconcile, phase4-20260609):
#   meeting-playback.sh  — runtime playback exerciser (in-image use)
#   gawd-validate.sh     — runtime validation entrypoint (in-image use)
#   result-schema.json   — schema for validate output (in-image use)
# test-gawd-validate.sh is a host-side test of gawd-validate.sh; it is NOT a runtime
# component and does NOT ship in the image (stays in the tree, excluded here).
COPY forge/validation/meeting-playback.sh     /usr/local/lib/gawd/validation/
COPY forge/validation/gawd-validate.sh        /usr/local/lib/gawd/validation/
COPY forge/validation/result-schema.json      /usr/local/lib/gawd/validation/

# Copy the 8 v1 subsystems (Logos v1-assembly ruling 2026-05-28).
# These are baked static; install.sh activates them per-rung at first boot.
# observability/ is a cross-cutting dependency: inter-gawd/* and tithing/*
# source its logger.sh — it MUST be baked or those scripts degrade/crash on source.
COPY forge/silence-avoidance/ /usr/local/lib/gawd/silence-avoidance/
COPY forge/watchdog/          /usr/local/lib/gawd/watchdog/
COPY forge/inter-gawd/        /usr/local/lib/gawd/inter-gawd/
COPY forge/tithing/           /usr/local/lib/gawd/tithing/
COPY forge/dashboard/         /usr/local/lib/gawd/dashboard/
COPY forge/voice/             /usr/local/lib/gawd/voice/
COPY forge/weekly-service/    /usr/local/lib/gawd/weekly-service/
COPY forge/meeting/           /usr/local/lib/gawd/meeting/
COPY forge/observability/     /usr/local/lib/gawd/observability/

# Copy the fallback templates (Seraph G3 prose) so silence-avoidance install.sh
# can stage them at $HOME/.gawd/fallbacks/templates. Without this the engine
# preflight degrades to its bundled placeholder set.
COPY forge/fallbacks/ /usr/local/lib/gawd/fallbacks/

# Copy memory tier integration assets (Q2/Q3 dreaming fix + three-tier recall).
# Baked at /usr/local/lib/gawd/memory/; install.sh stages safe-dream.sh to
# $HOME/.gawd/workspace/scripts/ and installs the OS-cron entry on first boot.
# Built-in memory-core dreaming.enabled is set to false in openclaw.json
# (install.sh Python heredoc); this script is the single dreaming owner (Q3).
# GAWD_DREAM_MODEL env (Q2 dedicated model) is read at cron runtime — never baked.
RUN install -d -m 755 /usr/local/lib/gawd/memory /usr/local/lib/gawd/memory/lib \
        /usr/local/lib/gawd/memory/tests /usr/local/lib/gawd/memory/skills
COPY forge/memory/ /usr/local/lib/gawd/memory/

# Deployment-reliability hardening (Metatron 2026-05-28): reliability helper
# scripts + systemd unit templates. install.sh stages the scripts to
# $HOME/.gawd/scripts and places the units per rung (D1/D2/D3). The docker rung
# enforces the leak-guard/clean-state equivalents in entrypoint.sh; the scripts
# are still copied so entrypoint's lib-path fallback resolves them.
COPY forge/scripts/ /usr/local/lib/gawd/scripts/
COPY forge/systemd/ /usr/local/lib/gawd/systemd/
# Scheduler scripts (daily-reset.sh + supporting lib). Needed so dream-verify.sh
# can source scheduler/lib/common.sh for resolve_prophit_tz, and so the backstop
# path in daily-reset.sh ships with the image for bare-metal and future rungs.
COPY forge/scheduler/ /usr/local/lib/gawd/scheduler/

# Set permissions:
#   scripts are executable; library files are read-only to gawd.
RUN chmod +x \
        /usr/local/lib/gawd/scripts/*.sh \
        /usr/local/lib/gawd/migration/gawd-export.sh \
        /usr/local/lib/gawd/migration/gawd-import.sh \
        /usr/local/lib/gawd/migration/test-roundtrip.sh \
        /usr/local/lib/gawd/migration/validate-bundle.sh \
        /usr/local/lib/gawd/desktop/install-desktop.sh \
        /usr/local/lib/gawd/desktop/configure-novnc.sh \
        /usr/local/lib/gawd/desktop/configure-tailscale-serve.sh \
        /usr/local/lib/gawd/revelation/merge.sh \
        /usr/local/lib/gawd/revelation/check-pending.sh \
        /usr/local/lib/gawd/revelation/offer.sh \
        /usr/local/lib/gawd/revelation/setup-perms.sh \
        /usr/local/lib/gawd/onboarding/bake.sh \
        /usr/local/lib/gawd/onboarding/wizard.sh \
        /usr/local/lib/gawd/validation/meeting-playback.sh \
        /usr/local/lib/gawd/install.sh && \
    # v1 subsystem entrypoints (Logos v1-assembly ruling 2026-05-28).
    # Use find for the *.sh globs so a single missing file does not break the
    # whole RUN layer; the explicit installers are chmod'd directly.
    chmod +x \
        /usr/local/lib/gawd/silence-avoidance/install.sh \
        /usr/local/lib/gawd/silence-avoidance/engine.sh \
        /usr/local/lib/gawd/silence-avoidance/session-recovery/install-hooks.sh \
        /usr/local/lib/gawd/watchdog/install.sh \
        /usr/local/lib/gawd/watchdog/sweep.sh \
        /usr/local/lib/gawd/dashboard/install.sh \
        /usr/local/lib/gawd/dashboard/verify.sh \
        /usr/local/lib/gawd/weekly-service/deliver-sermon.sh \
        /usr/local/lib/gawd/weekly-service/subscribe-sermon.sh && \
    find /usr/local/lib/gawd/inter-gawd     -maxdepth 1 -name '*.sh' -exec chmod +x {} + && \
    find /usr/local/lib/gawd/tithing        -maxdepth 1 -name '*.sh' -exec chmod +x {} + && \
    find /usr/local/lib/gawd/observability  -maxdepth 1 -name '*.sh' -exec chmod +x {} + && \
    find /usr/local/lib/gawd/silence-avoidance/session-recovery -maxdepth 1 -name '*.sh' -exec chmod +x {} + && \
    find /usr/local/lib/gawd/memory         -name '*.sh' -exec chmod +x {} + && \
    find /usr/local/lib/gawd/scheduler      -name '*.sh' -exec chmod +x {} + && \
    chown -R root:gawd /usr/local/lib/gawd && \
    chmod -R g+rX,o-rwx /usr/local/lib/gawd && \
    # entrypoint.sh must be world-readable+executable (runs as gawd user, owned by root).
    # chmod 755 not +x because gawd needs read permission for bash to parse the script.
    chmod 0755 /entrypoint.sh

# Re-chown openclaw extensions dir to gawd after all copy operations.
# Required: every npm install-g resets extensions dir ownership to root.
# Must be the LAST operation touching the openclaw node_modules dir.
# See feedback_extensions_dir_chown.md.
RUN if [ -d /usr/local/lib/node_modules/openclaw/dist/extensions ]; then \
        chown -R ${GAWD_UID}:${GAWD_UID} /usr/local/lib/node_modules/openclaw/dist/extensions; \
    fi

# /home/gawd workspace layout — empty scaffold.
# Persona files, sessions, state are populated at runtime (install.sh + onboarding).
# T0 anchors (SOUL.md, IDENTITY.md, VOICE.md) are written by install.sh from
# persona-templates, then immediately chowned to gawd-soul and chmod 0444.
RUN install -d -m 750 -o gawd -g gawd \
        /home/gawd/.openclaw \
        /home/gawd/.openclaw/workspace \
        /home/gawd/.openclaw/workspace/memory \
        /home/gawd/.openclaw/workspace/wiki \
        /home/gawd/.openclaw/workspace/wiki/sources \
        /home/gawd/.openclaw/workspace/sil \
        /home/gawd/.openclaw/workspace/sil/pending \
        /home/gawd/.openclaw/workspace/state \
        /home/gawd/.openclaw/workspace/skills \
        /home/gawd/.openclaw/workspace/users \
        /home/gawd/.openclaw/logs \
        /home/gawd/.openclaw/archive \
        /home/gawd/.openclaw/archive/sessions && \
    install -d -m 700 -o gawd -g gawd \
        /home/gawd/.secrets

# T1 lossless-claw → gawd's openclaw npm tree.
# Placed here (after the .openclaw scaffold above) so /home/gawd/.openclaw
# exists and gawd user ownership is already established.
# openclaw's resolveRecoveredManagedNpmRoot resolves external plugins at
# stateDir/npm/node_modules/<package> = /home/gawd/.openclaw/npm/node_modules/…
# The npm tree parent dirs are created implicitly by COPY; they will be owned
# by gawd:gawd (GAWD_UID 1500) per the --chown flag.
# A RUN chown follows to ensure uid 1500 ownership even if COPY --chown
# resolves by name before the gawd user is fully indexed.
COPY --from=builder --chown=gawd:gawd /opt/gawd-npm/node_modules/@martian-engineering \
    /home/gawd/.openclaw/npm/node_modules/@martian-engineering
RUN chown -R ${GAWD_UID}:${GAWD_UID} /home/gawd/.openclaw/npm

# Place the openclaw janitor script per hardening item 2.5.
# Cron entry is wired by install.sh, not baked into the image (cron files
# need the actual user's crontab; can't set that at image build time).
COPY --chown=gawd:gawd scripts/openclaw-janitor.sh \
    /home/gawd/.openclaw/workspace/scripts/openclaw-janitor.sh

# Place the gateway watchdog script per hardening item 2.15.
COPY --chown=gawd:gawd scripts/gateway-watchdog.sh \
    /home/gawd/.openclaw/workspace/scripts/gateway-watchdog.sh

RUN chmod +x \
        /home/gawd/.openclaw/workspace/scripts/openclaw-janitor.sh \
        /home/gawd/.openclaw/workspace/scripts/gateway-watchdog.sh

# V8 heap drop-in systemd config directory (hardening item 2.2).
# The actual unit file is installed by install.sh after systemd context is
# available on the substrate. The directory must pre-exist.
#
# Ownership: the whole .config/systemd/user tree is owned by gawd (the runtime
# user). install.sh runs AS gawd and writes the subsystem user-unit files
# (watchdog-sweep.service, gawd-dashboard.service, voice-relay.service) here.
# Without gawd ownership those writes fail EACCES even in the no-systemd docker
# rung (the unit file is still written for the VM/bare-metal substrate).
# (Logos v1-assembly fix 2026-05-28.)
RUN install -d -m 755 -o gawd -g gawd \
        /home/gawd/.config \
        /home/gawd/.config/systemd \
        /home/gawd/.config/systemd/user \
        /home/gawd/.config/systemd/user/openclaw-gateway.service.d

# secrets helper script (spec §8.3 — ships inside every daemon).
# NOTE: install.sh is already copied at the COPY forge/install.sh line above the
# chmod/chown pass. Do NOT add a second COPY here — it would reset ownership to
# root:root 0700 and break execution as the gawd user. (Fix 4 — duplicate removed.)
COPY --chown=root:gawd scripts/secrets \
    /usr/local/lib/gawd/scripts/secrets
RUN chmod 755 /usr/local/lib/gawd/scripts/secrets

# PATH additions for gawd user.
RUN echo 'export PATH="/usr/local/lib/gawd/scripts:$PATH"' >> /home/gawd/.bashrc && \
    echo 'export PATH="/opt/gawd-tools/bin:$PATH"'        >> /home/gawd/.bashrc

# Environment — secrets are NEVER baked into the image.
# All secret values injected at runtime via env vars or secrets.json at startup.
# See spec §1 principle 5 / gospel §1 P5.
# Required at runtime (documented here for operators, NOT set here):
#   (none — all secrets via secrets.json populated by install.sh)

# The gateway runs on loopback only per spec §2 / §8.1.
# External exposure is handled by the substrate (Tailscale Serve / cloudflared).
EXPOSE 18789/tcp

# M-3: HEALTHCHECK (phase4-20260609). curl is already installed in the final stage.
# The gateway /health endpoint is the fleet's canonical readiness signal.
# start-period=60s: first-boot install + embed server startup takes ~90s on cold
# containers (same rationale as the 180s graduation-gate timeout).
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s \
    CMD curl -fsS http://localhost:18789/health || exit 1

# Default working directory for runtime scripts.
WORKDIR /home/gawd

# Run as gawd user; never as root.
USER gawd

# Entrypoint: runs install.sh --rung docker --non-interactive on first boot to
# provision openclaw.json from env vars (MINIMAX_API_KEY, ANTHROPIC_OAUTH_BEARER,
# OPENCLAW_GATEWAY_TOKEN). If openclaw.json already exists (idempotent re-run),
# install.sh is skipped and the gateway starts immediately.
#
# Per F2+A3 fix (2026-05-28): without this, the gateway runs --allow-unconfigured
# and all agent routes (/compat/v1/messages, /v1/chat/completions, /agent/turn)
# return 404. Phase 8 gateway-mode was 0% on rc1 for this reason.
#
# NODE_OPTIONS set here; the systemd drop-in (hardening 2.2) replaces this on
# bare-metal/VM rungs where systemd is available.
ENV NODE_OPTIONS="--max-old-space-size=6144"

# rc5 (2026-05-29): activate the baked local embed server. The entrypoint's
# docker-rung leak-guarded llama loop starts gawd-embed ONLY when GAWD_LOCAL_EMBED=1
# AND the model + llama-server binary are present (both baked above). The model is
# copied to ${HOME}/.gawd/models by install.sh on first boot; the entrypoint's
# default GAWD_EMBED_MODEL points there. This makes memory/embeddings work from
# first boot. Override to 0 at `docker run` time for a remote-embedding posture.
ENV GAWD_LOCAL_EMBED=1

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/local/bin/node", "/usr/local/lib/node_modules/openclaw/dist/index.js", \
     "gateway", "--port", "18789"]
