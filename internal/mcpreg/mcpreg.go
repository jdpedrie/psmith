// Package mcpreg resolves pseudo-plugin references ("mcp:<id>") to the
// registered mcp plugin type plus a fully-populated config, by loading
// the referenced user_mcp_servers row. Shared by the profiles service
// (attach-time validation, ListPluginTypes composition) and the
// conversations service (pipeline build), so the reference semantics
// can't drift between the two.
package mcpreg

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/jdpedrie/psmith/internal/crypto"
	"github.com/jdpedrie/psmith/internal/store"
)

// Prefix namespaces registry references in pipeline plugin_name values.
// "mcp:<uuid>" rows resolve through the registry; the bare "mcp" name
// remains the inline-configured escape hatch.
const Prefix = "mcp:"

// BaseName is the statically-registered plugin type every reference
// resolves to.
const BaseName = "mcp"

// IsRef reports whether a pipeline plugin name is a registry reference.
func IsRef(name string) bool { return strings.HasPrefix(name, Prefix) }

// RefID extracts the registry row id from a reference name. ok is
// false when the name isn't a reference or the id doesn't parse.
func RefID(name string) (uuid.UUID, bool) {
	if !IsRef(name) {
		return uuid.Nil, false
	}
	id, err := uuid.Parse(strings.TrimPrefix(name, Prefix))
	if err != nil {
		return uuid.Nil, false
	}
	return id, true
}

// RefName builds the pipeline plugin name for a registry row id.
func RefName(id uuid.UUID) string { return Prefix + id.String() }

// SpecConfig is the registry row's stored JSON — deliberately the same
// shape as the mcp plugin's config blob so resolution is a straight
// merge, and the plugin constructor never learns about the registry.
type SpecConfig struct {
	Transport  string `json:"transport"`
	Command    string `json:"command"`
	Args       string `json:"args"`
	Env        string `json:"env"`
	URL        string `json:"url"`
	Headers    string `json:"headers"`
	ToolPrefix string `json:"tool_prefix"`
}

// ErrNotFound is returned by strict resolution when the reference
// points at a row that doesn't exist or belongs to another user.
// (Foreign rows read as not-found rather than forbidden so ids can't
// be probed.)
var ErrNotFound = errors.New("mcpreg: referenced MCP server not found")

// Load fetches and decrypts one registry row, owner-checked.
func Load(ctx context.Context, q store.Querier, cipher crypto.Cipher, owner uuid.UUID, id uuid.UUID) (store.UserMcpServer, SpecConfig, error) {
	row, err := q.GetUserMCPServer(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return store.UserMcpServer{}, SpecConfig{}, ErrNotFound
	}
	if err != nil {
		return store.UserMcpServer{}, SpecConfig{}, err
	}
	if row.UserID != owner {
		return store.UserMcpServer{}, SpecConfig{}, ErrNotFound
	}
	raw, err := crypto.ResolveSecret(cipher, row.ConfigEncrypted, row.Config)
	if err != nil {
		return store.UserMcpServer{}, SpecConfig{}, fmt.Errorf("decrypt user_mcp_servers.%s: %w", id, err)
	}
	var spec SpecConfig
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &spec); err != nil {
			return store.UserMcpServer{}, SpecConfig{}, fmt.Errorf("decode user_mcp_servers.%s: %w", id, err)
		}
	}
	return row, spec, nil
}

// Resolve maps a pipeline row's (plugin name, attach config) to the
// (constructor name, config) pair plugins.Build should receive.
// Non-reference names pass through untouched.
//
// For references, the registry spec is the base and NON-EMPTY values
// in the attach config override per-key (empty strings are skipped so
// a client form that serializes untouched fields as "" can't clear the
// registry's defaults).
//
// strict controls dangling-reference behavior: attach-time validation
// wants an error the user can act on; pipeline build wants the failure
// contained to the one plugin — a lenient resolve returns the empty
// config, which the mcp plugin's configValid() gate turns into a quiet
// no-op (tools vanish instead of every send on the profile breaking).
func Resolve(ctx context.Context, q store.Querier, cipher crypto.Cipher, owner uuid.UUID, name string, attachCfg json.RawMessage, strict bool) (string, json.RawMessage, error) {
	if !IsRef(name) {
		return name, attachCfg, nil
	}
	id, ok := RefID(name)
	if !ok {
		if strict {
			return "", nil, fmt.Errorf("malformed MCP server reference %q", name)
		}
		return BaseName, json.RawMessage(`{}`), nil
	}
	_, spec, err := Load(ctx, q, cipher, owner, id)
	if errors.Is(err, ErrNotFound) {
		if strict {
			return "", nil, fmt.Errorf("%w: %s", ErrNotFound, id)
		}
		return BaseName, json.RawMessage(`{}`), nil
	}
	if err != nil {
		return "", nil, err
	}

	base := map[string]any{}
	specBytes, err := json.Marshal(spec)
	if err != nil {
		return "", nil, err
	}
	if err := json.Unmarshal(specBytes, &base); err != nil {
		return "", nil, err
	}
	if len(attachCfg) > 0 {
		var overlay map[string]any
		if err := json.Unmarshal(attachCfg, &overlay); err == nil {
			for k, v := range overlay {
				if s, isStr := v.(string); isStr && s == "" {
					continue
				}
				base[k] = v
			}
		}
		// A malformed attach blob is ignored rather than failing the
		// build — the registry spec alone is a complete config.
	}
	merged, err := json.Marshal(base)
	if err != nil {
		return "", nil, err
	}
	return BaseName, merged, nil
}
