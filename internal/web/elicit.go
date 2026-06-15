package web

import (
	"encoding/json"
	"net/http"
	"sort"
	"strings"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/internal/elicit"
)

type elicitField struct {
	Name  string
	Label string
	Type  string // text | password | number | checkbox
}

// parseElicitFields turns an MCP elicitation JSON Schema fragment into form
// fields. It handles the subset the UI supports: an object whose properties
// are strings (password format → secure input), integers/numbers, or booleans.
// Properties are sorted by name for stable rendering.
func parseElicitFields(raw json.RawMessage) []elicitField {
	var schema struct {
		Properties map[string]struct {
			Type   string `json:"type"`
			Title  string `json:"title"`
			Format string `json:"format"`
		} `json:"properties"`
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
		fields = append(fields, elicitField{Name: n, Label: label, Type: typ})
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
	if _, err := h.convos.GetConversation(r.Context(), connect.NewRequest(&reevev1.GetConversationRequest{Id: convID})); err != nil {
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
		// Empty body + outerHTML swap on the form removes the prompt; the
		// waiting tool unblocks and the turn resumes on the open SSE stream.
		w.WriteHeader(http.StatusOK)
		return
	}
	http.Redirect(w, r, "/c/"+convID, http.StatusSeeOther)
}
