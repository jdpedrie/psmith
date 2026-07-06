# syntax=docker/dockerfile:1.7

# ---- Build stage ---------------------------------------------------------
# Pinned to the same Go major as go.mod (1.25). Alpine keeps the build
# image small; we don't need cgo for either binary.
FROM golang:1.25-alpine AS build

WORKDIR /src

# Module layer: copy and prefetch deps before the source so a code-only
# change reuses the cached `go mod download` step.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go mod download

# Source. The migrations live under db/migrations and are embedded
# into the psmith binary at compile time (cmd/psmith/install.go).
COPY . .

# Build both binaries. CGO disabled for a fully static link so the
# final image needs nothing beyond ca-certs at runtime. -trimpath
# strips host-specific paths from the binary so debug strings don't
# leak the build host.
ENV CGO_ENABLED=0 GOOS=linux
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -trimpath -ldflags='-s -w' -o /out/psmithd ./cmd/psmithd \
 && go build -trimpath -ldflags='-s -w' -o /out/psmith  ./cmd/psmith

# ---- Runtime stage -------------------------------------------------------
# Alpine (rather than distroless) so `docker exec -it … sh` lands the
# operator in a usable shell with the `psmith` CLI on PATH — matches the
# user request to keep both binaries available inside the container.
FROM alpine:3.20

# ca-certificates for outbound HTTPS to upstream LLM providers
# (Anthropic, OpenAI, Google, etc.). tzdata so wall-clock formatting
# in titles + grounding plugins matches the operator's expectation
# when PSMITH_TZ is set.
RUN apk add --no-cache ca-certificates tzdata \
 && addgroup -S psmith && adduser -S -G psmith psmith

COPY --from=build /out/psmithd /usr/local/bin/psmithd
COPY --from=build /out/psmith  /usr/local/bin/psmith
COPY scripts/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# Default file-storage root (attachments). Created here owned by the
# runtime user so a fresh named volume mounted at /data inherits that
# ownership — Docker seeds a new volume from the mountpoint's perms.
RUN mkdir -p /data && chown psmith:psmith /data

USER psmith
WORKDIR /home/psmith

# psmithd listens on :8080 by default. The DSN + master key MUST come
# from env (no defaults are baked in — see cmd/psmithd/main.go).
EXPOSE 8080

# Entrypoint wraps psmithd with an idempotent `psmith install` so the
# container is self-bootstrapping on first run against a fresh DB.
# Override CMD to use the operator CLI: `docker run --rm psmith psmith
# useradd alice` etc — the entrypoint detects non-psmithd commands
# and skips the install step.
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["psmithd"]
