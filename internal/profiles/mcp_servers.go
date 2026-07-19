package profiles

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"connectrpc.com/connect"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/internal/auth"
	"github.com/jdpedrie/psmith/internal/crypto"
	"github.com/jdpedrie/psmith/internal/mcpreg"
	"github.com/jdpedrie/psmith/internal/store"
	"github.com/jdpedrie/psmith/plugins"
)

// User-level MCP server registry handlers. A registered server is a
// named, encrypted transport spec (same JSON shape as the mcp plugin's
// config blob); it surfaces as a pseudo-plugin "mcp:<id>" in
// ListPluginTypes and is referenced — never copied — from pipeline
// rows. See internal/mcpreg for the resolution semantics.

var mcpTransports = map[string]bool{"stdio": true, "http": true, "inproc": true}

// --- ListMCPServers ---

func (s *Service) ListMCPServers(ctx context.Context, _ *connect.Request[psmithv1.ListMCPServersRequest]) (*connect.Response[psmithv1.ListMCPServersResponse], error) {
	caller := auth.MustFromContext(ctx)
	rows, err := s.queries.ListUserMCPServers(ctx, caller.ID)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	out := make([]*psmithv1.MCPServer, 0, len(rows))
	for _, row := range rows {
		spec, err := decodeMCPSpec(s.cipher, row)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		out = append(out, mcpServerToProto(row, spec))
	}
	return connect.NewResponse(&psmithv1.ListMCPServersResponse{Servers: out}), nil
}

// --- UpsertMCPServer ---

func (s *Service) UpsertMCPServer(ctx context.Context, req *connect.Request[psmithv1.UpsertMCPServerRequest]) (*connect.Response[psmithv1.UpsertMCPServerResponse], error) {
	caller := auth.MustFromContext(ctx)
	name := strings.TrimSpace(req.Msg.Name)
	if name == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("name is required"))
	}
	transport := strings.TrimSpace(req.Msg.Transport)
	if !mcpTransports[transport] {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("unknown transport %q (want stdio, http, or inproc)", transport))
	}

	// Update path starts from the stored spec so ABSENT env/headers
	// keep their values — the edit form never sees secrets and must be
	// able to save without wiping them.
	var existing mcpreg.SpecConfig
	var id uuid.UUID
	creating := req.Msg.Id == ""
	if creating {
		id = uuid.New()
	} else {
		var err error
		id, err = uuid.Parse(req.Msg.Id)
		if err != nil {
			return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid id: %w", err))
		}
		_, existing, err = mcpreg.Load(ctx, s.queries, s.cipher, caller.ID, id)
		if errors.Is(err, mcpreg.ErrNotFound) {
			return nil, connect.NewError(connect.CodeNotFound, err)
		}
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}

	spec := mcpreg.SpecConfig{
		Transport:  transport,
		Command:    strings.TrimSpace(req.Msg.Command),
		Args:       req.Msg.Args,
		Env:        existing.Env,
		URL:        strings.TrimSpace(req.Msg.Url),
		Headers:    existing.Headers,
		ToolPrefix: strings.TrimSpace(req.Msg.ToolPrefix),
	}
	if req.Msg.Env != nil {
		spec.Env = *req.Msg.Env
	}
	if req.Msg.Headers != nil {
		spec.Headers = *req.Msg.Headers
	}

	cfg, err := json.Marshal(spec)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	// Same pre-write check as SetProfilePlugins: the mcp constructor is
	// the authoritative validator for the spec shape.
	if _, err := plugins.Build(mcpreg.BaseName, cfg); err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, err)
	}
	encrypted, err := s.cipher.Encrypt(cfg)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("encrypt mcp server config: %w", err))
	}

	var row store.UserMcpServer
	if creating {
		row, err = s.queries.InsertUserMCPServer(ctx, store.InsertUserMCPServerParams{
			ID: id, UserID: caller.ID, Name: name, ConfigEncrypted: encrypted,
		})
	} else {
		row, err = s.queries.UpdateUserMCPServer(ctx, store.UpdateUserMCPServerParams{
			ID: id, UserID: caller.ID, Name: name, ConfigEncrypted: encrypted,
		})
	}
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, connect.NewError(connect.CodeAlreadyExists, fmt.Errorf("an MCP server named %q already exists", name))
		}
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeNotFound, mcpreg.ErrNotFound)
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&psmithv1.UpsertMCPServerResponse{Server: mcpServerToProto(row, spec)}), nil
}

// --- DeleteMCPServer ---

func (s *Service) DeleteMCPServer(ctx context.Context, req *connect.Request[psmithv1.DeleteMCPServerRequest]) (*connect.Response[psmithv1.DeleteMCPServerResponse], error) {
	caller := auth.MustFromContext(ctx)
	id, err := uuid.Parse(req.Msg.Id)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("invalid id: %w", err))
	}
	n, err := s.queries.DeleteUserMCPServer(ctx, store.DeleteUserMCPServerParams{ID: id, UserID: caller.ID})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if n == 0 {
		return nil, connect.NewError(connect.CodeNotFound, mcpreg.ErrNotFound)
	}
	return connect.NewResponse(&psmithv1.DeleteMCPServerResponse{}), nil
}

// --- pseudo-plugin descriptors -------------------------------------------

// mcpServerPluginTypes builds one PluginType per registered server for
// ListPluginTypes. Capabilities are copied from the compiled-in mcp
// entry (same constructor, same hooks); config fields shrink to the
// per-attachment overrides — everything else lives on the registry row.
func (s *Service) mcpServerPluginTypes(ctx context.Context, userID uuid.UUID, base *psmithv1.PluginType) ([]*psmithv1.PluginType, error) {
	rows, err := s.queries.ListUserMCPServers(ctx, userID)
	if err != nil {
		return nil, err
	}
	out := make([]*psmithv1.PluginType, 0, len(rows))
	for _, row := range rows {
		spec, err := decodeMCPSpec(s.cipher, row)
		if err != nil {
			return nil, err
		}
		pt := &psmithv1.PluginType{
			Name:        mcpreg.RefName(row.ID),
			DisplayName: row.Name,
			Description: mcpSpecSummary(spec),
			ConfigFields: []*psmithv1.ConfigField{{
				Name:        "tool_prefix",
				Display:     "Tool name prefix",
				Description: "Overrides the server's default prefix for this attachment. Leave empty to use the registry default.",
				Type:        psmithv1.ConfigField_TEXT,
			}},
		}
		if base != nil {
			pt.Capabilities = base.Capabilities
			pt.RequiredModelCapabilities = base.RequiredModelCapabilities
		}
		out = append(out, pt)
	}
	return out, nil
}

// decodeMCPSpec decrypts and decodes one registry row's stored spec.
func decodeMCPSpec(cipher crypto.Cipher, row store.UserMcpServer) (mcpreg.SpecConfig, error) {
	raw, err := crypto.ResolveSecret(cipher, row.ConfigEncrypted, row.Config)
	if err != nil {
		return mcpreg.SpecConfig{}, fmt.Errorf("decrypt user_mcp_servers.%s: %w", row.ID, err)
	}
	var spec mcpreg.SpecConfig
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &spec); err != nil {
			return mcpreg.SpecConfig{}, fmt.Errorf("decode user_mcp_servers.%s: %w", row.ID, err)
		}
	}
	return spec, nil
}

// mcpSpecSummary is the one-line, secret-free description shown in the
// plugin picker under the server's name.
func mcpSpecSummary(spec mcpreg.SpecConfig) string {
	switch spec.Transport {
	case "http":
		return "MCP server · http · " + spec.URL
	case "inproc":
		return "MCP server · in-process"
	default:
		return "MCP server · stdio · " + spec.Command
	}
}

func mcpServerToProto(row store.UserMcpServer, spec mcpreg.SpecConfig) *psmithv1.MCPServer {
	return &psmithv1.MCPServer{
		Id:         row.ID.String(),
		Name:       row.Name,
		Transport:  spec.Transport,
		Command:    spec.Command,
		Args:       spec.Args,
		HasEnv:     spec.Env != "",
		Url:        spec.URL,
		HasHeaders: spec.Headers != "",
		ToolPrefix: spec.ToolPrefix,
	}
}
