package web

import (
	"context"
	"encoding/json"
	"net/http"
	"sort"
	"strings"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
	"github.com/jdpedrie/psmith/server/elicit"
)

type elicitField struct {
	Name     string
	Label    string
	Type     string // text | password | number | checkbox
	Required bool
	Default  string // the schema's default, as the input's value; "true" checks a checkbox
}

// elicitVM is the card that takes the composer's place while a tool waits
// for the user.
type elicitVM struct {
	ID      string
	Message string
	Fields  []elicitField
	// Source and Tool name who asked, when the stream knows; the chunk
	// payload carries neither today, so the card falls back to a generic
	// title.
	Source string
	Tool   string
}

// elicitTitle is the card's heading.
func elicitTitle(e *elicitVM) string {
	if e.Source != "" {
		return e.Source + " needs input"
	}
	return "A tool needs input"
}

// elicitEvent renders a stream's elicit chunk payload as the slot card, ready
// to send as the `elicit` SSE event. The card swaps itself out of band into
// the composer's place; tool names the call that asked, when known.
func elicitEvent(ctx context.Context, convID string, payload []byte, tool string) string {
	var p struct {
		ElicitationID   string          `json:"elicitation_id"`
		Message         string          `json:"message"`
		RequestedSchema json.RawMessage `json:"requested_schema"`
	}
	if json.Unmarshal(payload, &p) != nil {
		return ""
	}
	e := &elicitVM{ID: p.ElicitationID, Message: p.Message, Fields: parseElicitFields(p.RequestedSchema), Tool: tool}
	return renderComp(ctx, elicitSlot(slotVM{Kind: "elicit", ConvID: convID, Elicit: e}))
}

// parseElicitFields turns an MCP elicitation JSON Schema fragment into form
// fields. It handles the subset the UI supports: an object whose properties
// are strings (password format → secure input), integers/numbers, or booleans.
// Properties are sorted by name for stable rendering.
func parseElicitFields(raw json.RawMessage) []elicitField {
	var schema struct {
		Properties map[string]struct {
			Type    string          `json:"type"`
			Title   string          `json:"title"`
			Format  string          `json:"format"`
			Default json.RawMessage `json:"default"`
		} `json:"properties"`
		Required []string `json:"required"`
	}
	if err := json.Unmarshal(raw, &schema); err != nil {
		return nil
	}
	names := make([]string, 0, len(schema.Properties))
	for n := range schema.Properties {
		names = append(names, n)
	}
	sort.Strings(names)

	fields := make([]elicitField, 0, len(names))
	for _, n := range names {
		p := schema.Properties[n]
		typ := "text"
		switch p.Type {
		case "boolean":
			typ = "checkbox"
		case "integer", "number":
			typ = "number"
		case "string":
			if p.Format == "password" {
				typ = "password"
			}
		}
		label := p.Title
		if label == "" {
			label = n
		}
		f := elicitField{Name: n, Label: label, Type: typ}
		for _, req := range schema.Required {
			if req == n {
				f.Required = true
			}
		}
		if len(p.Default) > 0 {
			var str string
			if json.Unmarshal(p.Default, &str) == nil {
				f.Default = str
			} else {
				f.Default = string(p.Default)
			}
		}
		fields = append(fields, f)
	}
	return fields
}

// handleElicitRespond delivers a user's answer to an in-flight elicitation,
// then clears the prompt. The stream stays open, so the waiting tool unblocks
// and the assistant turn continues on the same SSE connection.
func (h *Handler) handleElicitRespond(w http.ResponseWriter, r *http.Request) {
	convID := r.PathValue("id")
	eid := r.PathValue("eid")

	// Ownership check (cross-user conversations return NotFound).
	if _, err := h.convos.GetConversation(r.Context(), connect.NewRequest(&psmithv1.GetConversationRequest{Id: convID})); err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	cu, err := uuid.Parse(convID)
	if err != nil {
		http.Error(w, "bad conversation id", http.StatusBadRequest)
		return
	}
	eu, err := uuid.Parse(eid)
	if err != nil {
		http.Error(w, "bad elicitation id", http.StatusBadRequest)
		return
	}

	enhanced := r.Header.Get("HX-Request") != ""
	_ = r.ParseForm()
	action := r.URL.Query().Get("action")
	if action == "" {
		action = r.PostFormValue("action")
	}

	var contentJSON json.RawMessage
	if action == "accept" {
		// Field inputs are named field_<name> so they can't collide with the
		// action button; strip the prefix to rebuild the response object.
		content := map[string]string{}
		for k, vs := range r.PostForm {
			name, ok := strings.CutPrefix(k, "field_")
			if !ok || len(vs) == 0 {
				continue
			}
			content[name] = vs[0]
		}
		contentJSON, _ = json.Marshal(content)
	}
	if action == "" {
		action = string(elicit.ActionCancel)
	}

	if err := h.convos.ElicitBroker().Respond(cu, eu, elicit.Response{
		Action:  elicit.Action(action),
		Content: contentJSON,
	}); err != nil {
		h.logger.Warn("web: elicit respond failed", "err", err)
	}

	if enhanced {
		// The composer comes back in the card's place; the waiting tool
		// unblocks and the turn resumes on the open SSE stream.
		vm, err := h.loadConversation(r.Context(), r, convID)
		if err != nil {
			w.WriteHeader(http.StatusOK)
			return
		}
		vm.RunID = h.activeRunID(r, convID)
		h.render(w, r, http.StatusOK, composerSlot(vm))
		return
	}
	http.Redirect(w, r, "/c/"+convID, http.StatusSeeOther)
}
