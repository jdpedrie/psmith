package web

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"strconv"
	"strings"

	"connectrpc.com/connect"
	"github.com/google/uuid"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// The inspector's editor for a plugin's list settings (Context Packs'
// packs, a council's members): each record is a row that opens to its
// fields, with Add, Delete and Paste JSON. It reads the element schema off
// the field, so no plugin needs its own form. Every action is a form post,
// so it works without script.

// cfgItemVM is one entry of the config view, in the plugin's declared
// order: a flat field or a list.
type cfgItemVM struct {
	Field *configFieldVM
	List  *listFieldVM
}

type listFieldVM struct {
	Name        string
	Display     string
	Description string
	Rows        []listRowVM
	Paste       string // what was pasted, kept when it didn't parse
	PasteError  string
}

type listRowVM struct {
	N       int
	IDField string // the auto id's field name, or ""
	ID      string
	Title   string
	Open    bool
	Fields  []configFieldVM
}

// listInputName is a row field's form name.
func listInputName(field string, row int, item string) string {
	return "lst_" + field + "_" + strconv.Itoa(row) + "_" + item
}

// inspConfigItems lays out a plugin's per-conversation settings. open names
// the row to show open ("packs.2"); add appends a blank row, open, to that
// list.
func (h *Handler) inspConfigItems(ctx context.Context, t *psmithv1.PluginType, current []byte, models []modelVM, open, add string) []cfgItemVM {
	flat := map[string]configFieldVM{}
	for _, f := range configFieldVMs(t, current, models, false) {
		flat[f.Name] = f
	}
	var cur map[string]json.RawMessage
	_ = json.Unmarshal(current, &cur)
	var profiles []configOptVM
	var out []cfgItemVM
	for _, f := range t.GetConfigFields() {
		if f.GetGlobal() {
			continue
		}
		if f.GetType() != psmithv1.ConfigField_LIST {
			v := flat[f.GetName()]
			out = append(out, cfgItemVM{Field: &v})
			continue
		}
		if profiles == nil {
			profiles = h.profileOptions(ctx)
		}
		lst := &listFieldVM{Name: f.GetName(), Display: orName(f.GetDisplay(), f.GetName()), Description: f.GetDescription()}
		var rows []json.RawMessage
		_ = json.Unmarshal(cur[f.GetName()], &rows)
		if add == f.GetName() {
			rows = append(rows, json.RawMessage(`{}`))
		}
		for i, raw := range rows {
			lst.Rows = append(lst.Rows, listRow(f, i, raw, models, profiles, open == f.GetName()+"."+strconv.Itoa(i) || (add == f.GetName() && i == len(rows)-1)))
		}
		out = append(out, cfgItemVM{List: lst})
	}
	return out
}

func listRow(f *psmithv1.ConfigField, i int, raw json.RawMessage, models []modelVM, profiles []configOptVM, open bool) listRowVM {
	row := listRowVM{N: i, Open: open, Title: "Untitled"}
	var obj map[string]json.RawMessage
	_ = json.Unmarshal(raw, &obj)
	var shown []*psmithv1.ConfigField
	for _, it := range f.GetItemFields() {
		if it.GetType() == psmithv1.ConfigField_AUTO_ID {
			row.IDField = it.GetName()
			row.ID = jsonScalarString(obj[it.GetName()])
			if row.ID == "" {
				row.ID = uuid.NewString()
			}
			continue
		}
		shown = append(shown, it)
	}
	fields := configFieldVMs(&psmithv1.PluginType{ConfigFields: shown}, raw, models, false)
	for k, it := range shown {
		if it.GetType() == psmithv1.ConfigField_PROFILE_PICKER && len(profiles) > 0 {
			fields[k].Type = "select"
			fields[k].Options = profiles
		}
		if row.Title == "Untitled" && (fields[k].Type == "text" || fields[k].Type == "textarea") && strings.TrimSpace(fields[k].Value) != "" {
			row.Title = firstLine(fields[k].Value)
		}
		fields[k].Name = listInputName(f.GetName(), i, it.GetName())
	}
	row.Fields = fields
	return row
}

// profileOptions lists the account's profiles for a profile choice.
func (h *Handler) profileOptions(ctx context.Context) []configOptVM {
	out := []configOptVM{}
	if h.profiles == nil {
		return out
	}
	resp, err := h.profiles.ListProfiles(ctx, connect.NewRequest(&psmithv1.ListProfilesRequest{}))
	if err != nil {
		return out
	}
	for _, p := range resp.Msg.GetProfiles() {
		out = append(out, configOptVM{Value: p.GetId(), Label: p.GetName()})
	}
	return out
}

// applyListFields writes every list field's rows from the posted form over
// cfg. del ("packs.2") drops one row. A row whose visible fields are all
// empty is dropped, which is how an added row nobody filled in goes away.
// Keys a row has that the schema doesn't name survive.
func applyListFields(t *psmithv1.PluginType, cfg, current []byte, form url.Values, del string) ([]byte, error) {
	out := map[string]json.RawMessage{}
	_ = json.Unmarshal(cfg, &out)
	var cur map[string]json.RawMessage
	_ = json.Unmarshal(current, &cur)
	for _, f := range t.GetConfigFields() {
		if f.GetGlobal() || f.GetType() != psmithv1.ConfigField_LIST {
			continue
		}
		name := f.GetName()
		n, err := strconv.Atoi(form.Get("lst_" + name + "_n"))
		if err != nil {
			// The form didn't draw this list; leave what's stored.
			if old, ok := cur[name]; ok {
				out[name] = old
			}
			continue
		}
		byID := map[string]map[string]json.RawMessage{}
		var old []map[string]json.RawMessage
		_ = json.Unmarshal(cur[name], &old)
		var idField string
		for _, it := range f.GetItemFields() {
			if it.GetType() == psmithv1.ConfigField_AUTO_ID {
				idField = it.GetName()
			}
		}
		for _, o := range old {
			if idField != "" {
				byID[jsonScalarString(o[idField])] = o
			}
		}
		rows := []map[string]json.RawMessage{}
		for i := 0; i < n; i++ {
			if del == name+"."+strconv.Itoa(i) {
				continue
			}
			row := map[string]json.RawMessage{}
			if idField != "" {
				id := strings.TrimSpace(form.Get(listInputName(name, i, idField)))
				if id == "" {
					id = uuid.NewString()
				}
				for k, v := range byID[id] {
					row[k] = v
				}
				row[idField], _ = json.Marshal(id)
			}
			filled := false
			for _, it := range f.GetItemFields() {
				if it.GetType() == psmithv1.ConfigField_AUTO_ID {
					continue
				}
				v := strings.TrimSpace(form.Get(listInputName(name, i, it.GetName())))
				switch it.GetType() {
				case psmithv1.ConfigField_BOOLEAN:
					row[it.GetName()] = json.RawMessage(strconv.FormatBool(v == "true"))
					filled = filled || v == "true"
					continue
				case psmithv1.ConfigField_NUMBER:
					if _, err := strconv.ParseFloat(v, 64); err != nil {
						delete(row, it.GetName())
						continue
					}
					row[it.GetName()] = json.RawMessage(v)
				case psmithv1.ConfigField_MODEL_PICKER:
					pid, mid, ok := splitModelValue(v)
					if !ok {
						delete(row, it.GetName())
						continue
					}
					row[it.GetName()], _ = json.Marshal(map[string]string{"provider_id": pid, "model_id": mid})
				default:
					if v == "" {
						delete(row, it.GetName())
						continue
					}
					row[it.GetName()], _ = json.Marshal(v)
				}
				filled = true
			}
			if filled {
				rows = append(rows, row)
			}
		}
		b, err := json.Marshal(rows)
		if err != nil {
			return nil, err
		}
		out[name] = b
	}
	return json.Marshal(out)
}

// pasteListRows replaces a list's rows with pasted JSON: an array of
// objects, or an object holding one under the field's name. Rows without
// an id get one, so pasted rows are no different from added ones.
func pasteListRows(t *psmithv1.PluginType, cfg []byte, field, text string) ([]byte, error) {
	var f *psmithv1.ConfigField
	for _, x := range t.GetConfigFields() {
		if x.GetName() == field && x.GetType() == psmithv1.ConfigField_LIST {
			f = x
		}
	}
	if f == nil {
		return nil, errors.New("That setting isn't a list.")
	}
	var rows []map[string]any
	if err := json.Unmarshal([]byte(text), &rows); err != nil {
		var wrap map[string]json.RawMessage
		if json.Unmarshal([]byte(text), &wrap) != nil || json.Unmarshal(wrap[field], &rows) != nil || wrap[field] == nil {
			return nil, errors.New("Expected a JSON array of rows.")
		}
	}
	for _, it := range f.GetItemFields() {
		if it.GetType() != psmithv1.ConfigField_AUTO_ID {
			continue
		}
		for _, r := range rows {
			if s, _ := r[it.GetName()].(string); s == "" {
				r[it.GetName()] = uuid.NewString()
			}
		}
	}
	out := map[string]any{}
	_ = json.Unmarshal(cfg, &out)
	out[field] = rows
	return json.Marshal(out)
}
