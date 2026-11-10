package web

import (
	"context"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// User-level MCP server registry pages. Registered servers surface as
// pseudo-plugins in the profile and conversation plugin pickers (the
// ListPluginTypes composition happens server-side). Status is never stored:
// the list and detail pages test each server as they load.

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
		return "in-process · " + vm.Command
	default:
		return strings.TrimSpace("stdio · " + vm.Command + " " + strings.Join(strings.Fields(vm.Args), " "))
	}
}

func stdioCommand(vm mcpServerVM) string {
	return strings.TrimSpace(vm.Command + " " + strings.Join(strings.Fields(vm.Args), " "))
}

func secretNote(vm mcpServerVM) string {
	if vm.Transport == "http" {
		return "Headers are write-only. To change them, edit the server and type new ones."
	}
	return "The environment is write-only. To change it, edit the server and type it again."
}

func secretPlaceholder(set bool, placeholder string) string {
	if set {
		return placeholder
	}
	return ""
}

func mcpFormHeading(vm mcpFormVM) string {
	if vm.Server.ID == "" {
		return "Add server"
	}
	return "Edit " + vm.Server.Name
}

func mcpFormCrumb(vm mcpFormVM) string {
	if vm.Server.ID == "" {
		return "New server"
	}
	return vm.Server.Name
}

func transportLabel(t string) string {
	switch t {
	case "http":
		return "HTTP"
	case "inproc":
		return "In-process"
	default:
		return "Stdio"
	}
}

// mcpTest is one live probe's outcome.
type mcpTest struct {
	OK    bool
	Tools []string
	Err   string
}

// shortErr is an MCP error's lead, "exit status 1" from
// "exit status 1: FIRECRAWL_API_KEY is not set".
func shortErr(s string) string {
	if i := strings.Index(s, ":"); i > 0 {
		return s[:i]
	}
	return s
}

// mcpTestBudget bounds a page load's probes; a server that hasn't answered
// by then reads as failing rather than holding the page.
const mcpTestBudget = 8 * time.Second

func (h *Handler) testMCPServer(ctx context.Context, id string) mcpTest {
	ctx, cancel := context.WithTimeout(ctx, mcpTestBudget)
	defer cancel()
	resp, err := h.profiles.TestMCPServer(ctx, connect.NewRequest(&psmithv1.TestMCPServerRequest{Id: id}))
	switch {
	case err != nil:
		return mcpTest{Err: errMessage(err)}
	case !resp.Msg.GetOk():
		return mcpTest{Err: resp.Msg.GetErrorMessage()}
	default:
		return mcpTest{OK: true, Tools: resp.Msg.GetToolNames()}
	}
}

// testMCPServers probes every server at once.
func (h *Handler) testMCPServers(ctx context.Context, servers []*psmithv1.MCPServer) map[string]mcpTest {
	out := make(map[string]mcpTest, len(servers))
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, s := range servers {
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			res := h.testMCPServer(ctx, id)
			mu.Lock()
			out[id] = res
			mu.Unlock()
		}(s.GetId())
	}
	wg.Wait()
	return out
}

func (h *Handler) listMCPServers(ctx context.Context) ([]*psmithv1.MCPServer, error) {
	resp, err := h.profiles.ListMCPServers(ctx, connect.NewRequest(&psmithv1.ListMCPServersRequest{}))
	if err != nil {
		return nil, err
	}
	return resp.Msg.GetServers(), nil
}

// --- list ---

type mcpRowVM struct {
	ID      string
	Name    string
	Summary string
	Error   string
	Tools   int
	OK      bool
}

func (h *Handler) handleMCPServers(w http.ResponseWriter, r *http.Request) {
	servers, err := h.listMCPServers(r.Context())
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	tests := h.testMCPServers(r.Context(), servers)
	rows := make([]mcpRowVM, 0, len(servers))
	for _, s := range servers {
		t := tests[s.GetId()]
		rows = append(rows, mcpRowVM{ID: s.GetId(), Name: s.GetName(), Summary: mcpServerSummary(mcpServerVMFromProto(s)), Error: t.Err, Tools: len(t.Tools), OK: t.OK})
	}
	n := h.loadSnav(r.Context(), r, "servers")
	h.render(w, r, http.StatusOK, mcpServersScreen(n, rows))
}

// --- detail ---

type mcpDetailVM struct {
	Server mcpServerVM
	Status *testVM
	Tools  []string
	Delete sbConfirmVM
}

func mcpDeleteConfirm(s mcpServerVM, open bool) sbConfirmVM {
	base := "/settings/mcp-servers/" + s.ID
	return sbConfirmVM{
		ID: "sb-delete", Open: open,
		Label: "Delete " + s.Name, LabelDetail: "Profiles that attach it keep the attachment but stop getting its tools.",
		Question: "Delete " + s.Name + "?", Detail: "Profiles that attach it keep the attachment but stop getting its tools.",
		Verb: "Delete", OpenHref: base + "?delete=1", CancelHref: base, Action: base + "/delete",
	}
}

func (h *Handler) findMCPServer(w http.ResponseWriter, r *http.Request) (*psmithv1.MCPServer, []*psmithv1.MCPServer, bool) {
	servers, err := h.listMCPServers(r.Context())
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return nil, nil, false
	}
	for _, s := range servers {
		if s.GetId() == r.PathValue("id") {
			return s, servers, true
		}
	}
	http.NotFound(w, r)
	return nil, nil, false
}

func (h *Handler) handleMCPServerDetail(w http.ResponseWriter, r *http.Request) {
	s, _, ok := h.findMCPServer(w, r)
	if !ok {
		return
	}
	vm := mcpDetailVM{Server: mcpServerVMFromProto(s), Delete: mcpDeleteConfirm(mcpServerVMFromProto(s), r.URL.Query().Get("delete") == "1")}
	if fragmentFor(r, vm.Delete.ID) {
		h.render(w, r, http.StatusOK, sbConfirm(vm.Delete))
		return
	}
	t := h.testMCPServer(r.Context(), s.GetId())
	vm.Tools = t.Tools
	switch {
	case r.URL.Query().Get("error") != "":
		vm.Status = &testVM{Message: r.URL.Query().Get("error")}
	case t.OK:
		vm.Status = &testVM{OK: true, Message: "Connected and listed " + sbPlural(len(t.Tools), "tool") + ", just now"}
	default:
		vm.Status = connectFailed(t.Err)
	}
	n := h.loadSnav(r.Context(), r, "servers")
	h.render(w, r, http.StatusOK, mcpDetailScreen(n, vm))
}

func sbPlural(n int, word string) string {
	if n == 1 {
		return "1 " + word
	}
	return strconv.Itoa(n) + " " + word + "s"
}

// --- add and edit ---

type mcpFormVM struct {
	Server  mcpServerVM
	Headers string // typed but not saved, shown again after a failed save
	Env     string
	// ClearHeaders and ClearEnv: Clear was pressed on the stored value.
	ClearHeaders bool
	ClearEnv     bool
	Error        string
}

// secretUpdate is a write-only field's update: nil keeps what is stored,
// "" clears it, anything typed replaces it.
func secretUpdate(typed string, clear bool) *string {
	if strings.TrimSpace(typed) != "" {
		return &typed
	}
	if clear {
		empty := ""
		return &empty
	}
	return nil
}

func (h *Handler) handleMCPServerNew(w http.ResponseWriter, r *http.Request) {
	h.render(w, r, http.StatusOK, mcpFormScreen(h.loadSnav(r.Context(), r, "servers"), mcpFormVM{Server: mcpServerVM{Transport: "http"}}))
}

func (h *Handler) handleMCPServerEdit(w http.ResponseWriter, r *http.Request) {
	s, _, ok := h.findMCPServer(w, r)
	if !ok {
		return
	}
	h.render(w, r, http.StatusOK, mcpFormScreen(h.loadSnav(r.Context(), r, "servers"), mcpFormVM{Server: mcpServerVMFromProto(s)}))
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
	if req.Transport == "inproc" {
		req.Command = strings.TrimSpace(r.PostFormValue("inproc_server"))
	}
	// The form never shows stored secrets, so blank leaves them alone and
	// Clear sends an empty value, which the service takes as "remove".
	// Something typed replaces what is stored either way.
	req.Env = secretUpdate(r.PostFormValue("env"), r.PostFormValue("clear_env") == "true")
	req.Headers = secretUpdate(r.PostFormValue("headers"), r.PostFormValue("clear_headers") == "true")
	resp, err := h.profiles.UpsertMCPServer(r.Context(), connect.NewRequest(req))
	if err != nil {
		vm := mcpFormVM{Error: errMessage(err), Headers: r.PostFormValue("headers"), Env: r.PostFormValue("env"),
			ClearHeaders: r.PostFormValue("clear_headers") == "true", ClearEnv: r.PostFormValue("clear_env") == "true", Server: mcpServerVM{
				ID: req.Id, Name: req.Name, Transport: req.Transport,
				Command: req.Command, Args: req.Args, URL: req.Url, ToolPrefix: req.ToolPrefix,
			}}
		if req.Id != "" {
			// What is stored still is, so the secret fields keep saying so.
			if servers, lerr := h.listMCPServers(r.Context()); lerr == nil {
				for _, s := range servers {
					if s.GetId() == req.Id {
						vm.Server.HasEnv, vm.Server.HasHeaders = s.GetHasEnv(), s.GetHasHeaders()
					}
				}
			}
		}
		at := "/settings/mcp-servers/new"
		if req.Id != "" {
			at = "/settings/mcp-servers/" + req.Id + "/edit"
		}
		h.showAfterPost(w, r, at, mcpFormScreen(h.loadSnav(r.Context(), r, "servers"), vm))
		return
	}
	// The detail page tests on load, which is the "and test" in the button.
	http.Redirect(w, r, "/settings/mcp-servers/"+resp.Msg.GetServer().GetId(), http.StatusSeeOther)
}

// handleMCPServerTest sends the browser to the detail page, which tests the
// server as it loads; answering the POST itself would re-test on refresh.
func (h *Handler) handleMCPServerTest(w http.ResponseWriter, r *http.Request) {
	http.Redirect(w, r, "/settings/mcp-servers/"+r.PathValue("id"), http.StatusSeeOther)
}

func (h *Handler) handleMCPServerDelete(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, err := h.profiles.DeleteMCPServer(r.Context(), connect.NewRequest(&psmithv1.DeleteMCPServerRequest{Id: id})); err != nil {
		http.Redirect(w, r, "/settings/mcp-servers/"+id+"?error="+url.QueryEscape(errMessage(err)), http.StatusSeeOther)
		return
	}
	http.Redirect(w, r, "/settings/mcp-servers", http.StatusSeeOther)
}
