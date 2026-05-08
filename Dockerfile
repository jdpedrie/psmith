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
# into the reeve binary at compile time (cmd/reeve/install.go).
COPY . .

# Build both binaries. CGO disabled for a fully static link so the
# final image needs nothing beyond ca-certs at runtime. -trimpath
# strips host-specific paths from the binary so debug strings don't
# leak the build host.
ENV CGO_ENABLED=0 GOOS=linux
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -trimpath -ldflags='-s -w' -o /out/reeved ./cmd/reeved \
 && go build -trimpath -ldflags='-s -w' -o /out/reeve  ./cmd/reeve

# ---- Runtime stage -------------------------------------------------------
# Alpine (rather than distroless) so `docker exec -it … sh` lands the
# operator in a usable shell with the `reeve` CLI on PATH — matches the
# user request to keep both binaries available inside the container.
FROM alpine:3.20

# ca-certificates for outbound HTTPS to upstream LLM providers
# (Anthropic, OpenAI, Google, etc.). tzdata so wall-clock formatting
# in titles + grounding plugins matches the operator's expectation
# when REEVE_TZ is set.
RUN apk add --no-cache ca-certificates tzdata \
 && addgroup -S reeve && adduser -S -G reeve reeve

COPY --from=build /out/reeved /usr/local/bin/reeved
COPY --from=build /out/reeve  /usr/local/bin/reeve
COPY scripts/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

USER reeve
WORKDIR /home/reeve

# reeved listens on :8080 by default. The DSN + master key MUST come
# from env (no defaults are baked in — see cmd/reeved/main.go).
EXPOSE 8080

# Entrypoint wraps reeved with an idempotent `reeve install` so the
# container is self-bootstrapping on first run against a fresh DB.
# Override CMD to use the operator CLI: `docker run --rm reeve reeve
# useradd alice` etc — the entrypoint detects non-reeved commands
# and skips the install step.
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["reeved"]
