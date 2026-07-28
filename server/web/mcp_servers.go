package web

import (
	"net/http"
	"strings"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// User-level MCP server registry pages. Registered servers surface as
// pseudo-plugins in the profile/conversation plugin pickers (the
// ListPluginTypes composition happens server-side), so this surface is
// pure CRUD over the registry rows.

type mcpServerVM struct {
	ID         string
	Name       string
	Transport  string
	Command    string
	Args       string
	URL        string
	ToolPrefix string
	HasEnv     bool
	HasHeaders bool
}

func mcpServerVMFromProto(s *psmithv1.MCPServer) mcpServerVM {
	return mcpServerVM{
		ID:         s.GetId(),
		Name:       s.GetName(),
		Transport:  s.GetTransport(),
		Command:    s.GetCommand(),
		Args:       s.GetArgs(),
		URL:        s.GetUrl(),
		ToolPrefix: s.GetToolPrefix(),
		HasEnv:     s.GetHasEnv(),
		HasHeaders: s.GetHasHeaders(),
	}
}

// mcpServerSummary is the secret-free one-liner under each row.
func mcpServerSummary(vm mcpServerVM) string {
	switch vm.Transport {
	case "http":
		return "http · " + vm.URL
	case "inproc":
		return "in-process"
	default:
		return "stdio · " + vm.Command
	}
}

func mcpServerFormTitle(vm mcpServerVM) string {
	if vm.ID == "" {
		return "Add MCP server"
	}
	return "Edit MCP server"
}

func (h *Handler) handleMCPServers(w http.ResponseWriter, r *http.Request) {
	resp, err := h.profiles.ListMCPServers(r.Context(), connect.NewRequest(&psmithv1.ListMCPServersRequest{}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	vms := make([]mcpServerVM, 0, len(resp.Msg.Servers))
	for _, s := range resp.Msg.Servers {
		vms = append(vms, mcpServerVMFromProto(s))
	}
	h.render(w, r, http.StatusOK, mcpServersPage(vms))
}

func (h *Handler) handleMCPServerNew(w http.ResponseWriter, r *http.Request) {
	h.render(w, r, http.StatusOK, mcpServerFormPage(mcpServerVM{Transport: "http"}, "", nil))
}

func (h *Handler) handleMCPServerEdit(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	resp, err := h.profiles.ListMCPServers(r.Context(), connect.NewRequest(&psmithv1.ListMCPServersRequest{}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	for _, s := range resp.Msg.Servers {
		if s.GetId() == id {
			h.render(w, r, http.StatusOK, mcpServerFormPage(mcpServerVMFromProto(s), "", nil))
			return
		}
	}
	http.NotFound(w, r)
}

func (h *Handler) handleMCPServerSave(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	req := &psmithv1.UpsertMCPServerRequest{
		Id:         strings.TrimSpace(r.PostFormValue("id")),
		Name:       strings.TrimSpace(r.PostFormValue("name")),
		Transport:  strings.TrimSpace(r.PostFormValue("transport")),
		Command:    strings.TrimSpace(r.PostFormValue("command")),
		Args:       r.PostFormValue("args"),
		Url:        strings.TrimSpace(r.PostFormValue("url")),
		ToolPrefix: strings.TrimSpace(r.PostFormValue("tool_prefix")),
	}
	// Secret fields follow the embedder convention: blank leaves the
	// stored value unchanged (the form never echoes secrets back), so
	// only non-blank input is sent.
	if v := r.PostFormValue("env"); strings.TrimSpace(v) != "" {
		req.Env = &v
	}
	if v := r.PostFormValue("headers"); strings.TrimSpace(v) != "" {
		req.Headers = &v
	}
	if _, err := h.profiles.UpsertMCPServer(r.Context(), connect.NewRequest(req)); err != nil {
		vm := mcpServerVM{
			ID: req.Id, Name: req.Name, Transport: req.Transport,
			Command: req.Command, Args: req.Args, URL: req.Url, ToolPrefix: req.ToolPrefix,
		}
		h.render(w, r, http.StatusOK, mcpServerFormPage(vm, err.Error(), nil))
		return
	}
	http.Redirect(w, r, "/settings/mcp-servers", http.StatusSeeOther)
}

func (h *Handler) handleMCPServerTest(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	testResp, err := h.profiles.TestMCPServer(r.Context(), connect.NewRequest(&psmithv1.TestMCPServerRequest{Id: id}))
	result := &testVM{}
	if err != nil {
		result.Message = err.Error()
	} else if testResp.Msg.Ok {
		result.OK = true
		if len(testResp.Msg.ToolNames) == 0 {
			result.Message = "Connected — no tools advertised"
		} else {
			result.Message = "Connected — " + strings.Join(testResp.Msg.ToolNames, ", ")
		}
	} else {
		result.Message = testResp.Msg.ErrorMessage
	}

	listResp, err := h.profiles.ListMCPServers(r.Context(), connect.NewRequest(&psmithv1.ListMCPServersRequest{}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	for _, srv := range listResp.Msg.Servers {
		if srv.GetId() == id {
			h.render(w, r, http.StatusOK, mcpServerFormPage(mcpServerVMFromProto(srv), "", result))
			return
		}
	}
	http.NotFound(w, r)
}

func (h *Handler) handleMCPServerDelete(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, err := h.profiles.DeleteMCPServer(r.Context(), connect.NewRequest(&psmithv1.DeleteMCPServerRequest{Id: id})); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/settings/mcp-servers", http.StatusSeeOther)
}
