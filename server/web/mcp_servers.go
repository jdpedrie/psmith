package web

import (
	"context"
	"net/http"
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

func secretPlaceholder(set bool) string {
	if set {
		return "Stored. Leave empty to keep it."
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

func failing(tests map[string]mcpTest) int {
	n := 0
	for _, t := range tests {
		if !t.OK {
			n++
		}
	}
	return n
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
	n.ServersBad = failing(tests)
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
	if t.OK {
		vm.Status = &testVM{OK: true, Message: "Connected and listed " + sbPlural(len(t.Tools), "tool") + ", just now"}
	} else {
		vm.Status = &testVM{Message: t.Err}
	}
	n := h.loadSnav(r.Context(), r, "servers")
	if !t.OK {
		n.ServersBad = 1
	}
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
	Error   string
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
	// The form never shows stored secrets, so blank leaves them alone.
	if v := r.PostFormValue("env"); strings.TrimSpace(v) != "" {
		req.Env = &v
	}
	if v := r.PostFormValue("headers"); strings.TrimSpace(v) != "" {
		req.Headers = &v
	}
	resp, err := h.profiles.UpsertMCPServer(r.Context(), connect.NewRequest(req))
	if err != nil {
		vm := mcpFormVM{Error: errMessage(err), Headers: r.PostFormValue("headers"), Server: mcpServerVM{
			ID: req.Id, Name: req.Name, Transport: req.Transport,
			Command: req.Command, Args: req.Args, URL: req.Url, ToolPrefix: req.ToolPrefix,
		}}
		h.render(w, r, http.StatusBadRequest, mcpFormScreen(h.loadSnav(r.Context(), r, "servers"), vm))
		return
	}
	// The detail page tests on load, which is the "and test" in the button.
	http.Redirect(w, r, "/settings/mcp-servers/"+resp.Msg.GetServer().GetId(), http.StatusSeeOther)
}

func (h *Handler) handleMCPServerTest(w http.ResponseWriter, r *http.Request) {
	h.handleMCPServerDetail(w, r)
}

func (h *Handler) handleMCPServerDelete(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, err := h.profiles.DeleteMCPServer(r.Context(), connect.NewRequest(&psmithv1.DeleteMCPServerRequest{Id: id})); err != nil {
		http.Error(w, errMessage(err), http.StatusBadRequest)
		return
	}
	http.Redirect(w, r, "/settings/mcp-servers", http.StatusSeeOther)
}
