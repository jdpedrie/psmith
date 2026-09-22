package profiles

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/jdpedrie/psmith/db"
	"github.com/jdpedrie/psmith/server/store"
	"github.com/jdpedrie/psmith/server/testutil"
)

// thinkingEffortUpSQL returns the Up half of the 00053 migration with the
// goose directives stripped, so the test can replay it against rows that
// carry the pre-migration shape. pgtestdb hands out fully migrated
// databases, which is exactly why the conversion has to be re-run here:
// the migration itself already ran against an empty table.
func thinkingEffortUpSQL(t *testing.T) string {
	t.Helper()
	raw, err := db.Migrations.ReadFile("migrations/00053_thinking_effort.sql")
	if err != nil {
		t.Fatalf("read migration: %v", err)
	}
	text := string(raw)
	up := text[strings.Index(text, "-- +goose Up"):strings.Index(text, "-- +goose Down")]
	var lines []string
	for _, l := range strings.Split(up, "\n") {
		if strings.HasPrefix(l, "-- +goose") {
			continue
		}
		lines = append(lines, l)
	}
	return strings.Join(lines, "\n")
}

// TestMigration_ThinkingEffort_RewritesStoredBudgets: the four stored
// shapes a profile could carry before the change each land on the level
// the drivers would have derived for them, and a blob that already has an
// effort is left untouched, so the Up is safe to run twice.
func TestMigration_ThinkingEffort_RewritesStoredBudgets(t *testing.T) {
	t.Parallel()
	pool := testutil.Pool(t)
	q := store.New(pool)
	ctx := context.Background()
	user := mustCreateUser(t, q, "migrator")

	cases := []struct {
		name   string
		before string
		want   string
	}{
		{"enabled false", `{"enabled": false, "budget_tokens": 4096}`, "THINKING_EFFORT_OFF"},
		{"enabled no budget", `{"enabled": true}`, "THINKING_EFFORT_MEDIUM"},
		{"small budget", `{"enabled": true, "budget_tokens": 1024}`, "THINKING_EFFORT_LOW"},
		{"large budget", `{"enabled": true, "budget_tokens": 32000}`, "THINKING_EFFORT_XHIGH"},
		{"budget without enabled", `{"budget_tokens": 16000}`, "THINKING_EFFORT_HIGH"},
		{"already migrated", `{"effort": "THINKING_EFFORT_LOW", "enabled": true}`, "THINKING_EFFORT_LOW"},
	}
	ids := make([]uuid.UUID, len(cases))
	for i, c := range cases {
		id, err := uuid.NewV7()
		if err != nil {
			t.Fatal(err)
		}
		ids[i] = id
		blob := `{"call_settings": {"temperature": 0.5, "thinking": ` + c.before + `}, "default_model_id": "m"}`
		if _, err := q.CreateProfile(ctx, store.CreateProfileParams{
			ID: id, UserID: user.ID, Name: c.name, DefaultSettings: []byte(blob),
		}); err != nil {
			t.Fatalf("CreateProfile %s: %v", c.name, err)
		}
	}

	if _, err := pool.Exec(ctx, thinkingEffortUpSQL(t)); err != nil {
		t.Fatalf("replay migration: %v", err)
	}

	for i, c := range cases {
		row, err := q.GetProfileByID(ctx, ids[i])
		if err != nil {
			t.Fatalf("GetProfileByID %s: %v", c.name, err)
		}
		var got struct {
			CallSettings struct {
				Temperature float64                `json:"temperature"`
				Thinking    map[string]json.RawMessage `json:"thinking"`
			} `json:"call_settings"`
			DefaultModelID string `json:"default_model_id"`
		}
		if err := json.Unmarshal(row.DefaultSettings, &got); err != nil {
			t.Fatalf("%s: decode: %v", c.name, err)
		}
		if string(got.CallSettings.Thinking["effort"]) != `"`+c.want+`"` {
			t.Errorf("%s: effort = %s want %q (thinking=%v)", c.name, got.CallSettings.Thinking["effort"], c.want, got.CallSettings.Thinking)
		}
		for _, stale := range []string{"enabled", "budget_tokens"} {
			if _, ok := got.CallSettings.Thinking[stale]; ok {
				t.Errorf("%s: %s should not survive the migration", c.name, stale)
			}
		}
		if got.CallSettings.Temperature != 0.5 || got.DefaultModelID != "m" {
			t.Errorf("%s: sibling fields disturbed: %s", c.name, row.DefaultSettings)
		}
	}
}
