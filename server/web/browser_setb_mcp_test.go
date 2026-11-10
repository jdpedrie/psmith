package web

import (
	"testing"
	"time"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// A save the server refuses comes back with everything typed, the
// environment included: it is as write-only as the headers, which already
// survive, and retyping a key because a name was wrong is the bug.
func TestBrowser_SetbMCPFailedSaveKeepsWhatWasTyped(t *testing.T) {
	e := newSetbBrowser(t)
	e.open(t, "/settings/mcp-servers/new")
	e.setbTypeInto(t, "#asname", "   ")
	e.setbClick(t, `label:has(input[name=transport][value=stdio])`)
	e.setbTypeInto(t, "#ascommand", "npx")
	e.setbTypeInto(t, "#asargs", "-y\nserver")
	e.setbTypeInto(t, "#asenv", "API_KEY=abc")
	e.setbClick(t, `[data-setb-submitbar] button[type=submit]`)
	waitUntil(t, e.browserEnv, "error", `!!document.querySelector('[role=alert].result')`, 5*time.Second)
	got := eval[string](t, e.browserEnv, `[document.querySelector('[name=transport]:checked').value, document.querySelector('#ascommand').value, document.querySelector('#asargs').value, document.querySelector('#asenv').value].join('|')`)
	if got != "stdio|npx|-y\nserver|API_KEY=abc" {
		t.Fatalf("after a refused save: transport|command|args|env = %q", got)
	}
}

// Editing a server with a stored environment and failing the save still
// says the environment is stored, so nobody retypes it thinking it's gone.
func TestBrowser_SetbMCPFailedEditStillSaysStored(t *testing.T) {
	e := newSetbBrowser(t)
	env := "API_KEY=abc"
	resp, err := e.prof.UpsertMCPServer(e.uctx, connect.NewRequest(&psmithv1.UpsertMCPServerRequest{Name: "Local", Transport: "stdio", Command: "npx", Env: &env}))
	if err != nil {
		t.Fatal(err)
	}
	e.open(t, "/settings/mcp-servers/"+resp.Msg.GetServer().GetId()+"/edit")
	if p := eval[string](t, e.browserEnv, `document.querySelector('#asenv').placeholder`); p == "" {
		t.Fatal("the edit form doesn't say the environment is stored")
	}
	e.setbClearAndType(t, "#asname", " ")
	e.setbClick(t, `[data-setb-submitbar] button[type=submit]`)
	waitUntil(t, e.browserEnv, "error", `!!document.querySelector('[role=alert].result')`, 5*time.Second)
	if p := eval[string](t, e.browserEnv, `document.querySelector('#asenv').placeholder`); p != "Type a new environment to replace the stored one." {
		t.Fatalf("after a refused edit the environment's placeholder is %q", p)
	}
}
