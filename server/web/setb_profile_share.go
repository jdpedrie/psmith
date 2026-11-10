package web

import (
	"bytes"
	"encoding/base64"
	"errors"
	"io"
	"net/http"
	"regexp"
	"strconv"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

type importWarnVM struct {
	Text     string
	Renamed  string // set for a rename: the new name, shown bold
	Original string // the name it collided with
	Neutral  bool
}

// importReviewVM is a dry-run import waiting for the user to commit.
type importReviewVM struct {
	FileName string
	Summary  string // "1 profile · exported by Ana"
	Payload  string // base64 of the file, posted back on Import
	Warnings []importWarnVM
	Error    string
}

type profileShareVM struct {
	Head     profileHeadVM
	Chain    bool
	ChainLen int
	Notices  []string
	Filename string
	Import   *importReviewVM
	Delete   sbConfirmVM
	Error    string
}

type shareState struct {
	Import *importReviewVM
	Error  string
}

func (h *Handler) handleProfileShare(w http.ResponseWriter, r *http.Request) {
	h.renderShare(w, r, shareState{})
}

func sbDeleteConfirm(p *psmithv1.Profile, open bool) sbConfirmVM {
	base := "/settings/profiles/" + p.GetId() + "/share"
	return sbConfirmVM{
		ID: "sb-delete", Open: open,
		Label: "Delete " + p.GetName(), LabelDetail: "Its prompt, models and plugins go with it.",
		Question: "Delete " + p.GetName() + "?", Detail: "This can't be undone. Its prompt, models and plugins go with it.",
		Verb: "Delete", OpenHref: base + "?delete=1", CancelHref: base,
		Action: "/settings/profiles/" + p.GetId() + "/delete",
	}
}

func (h *Handler) renderShare(w http.ResponseWriter, r *http.Request, st shareState) {
	ix, p, ok := h.loadProfilePage(w, r)
	if !ok {
		return
	}
	del := sbDeleteConfirm(p, r.URL.Query().Get("delete") == "1")
	if fragmentFor(r, del.ID) {
		h.render(w, r, http.StatusOK, sbConfirm(del))
		return
	}
	vm := profileShareVM{Head: ix.head(p, "share"), Chain: r.URL.Query().Get("chain") == "1", ChainLen: len(ix.chain(p)), Import: st.Import, Delete: del, Error: st.Error}
	exp, err := h.profiles.ExportProfile(r.Context(), connect.NewRequest(&psmithv1.ExportProfileRequest{ProfileId: p.GetId(), PreserveChain: vm.Chain}))
	if err == nil {
		vm.Notices, vm.Filename = exp.Msg.GetNotices(), exp.Msg.GetSuggestedFilename()
	}
	h.answer(w, r, "/settings/profiles/"+p.GetId()+"/share", http.StatusOK, profileShareScreen(h.loadSnav(r.Context(), r, "profiles"), vm))
}

func (h *Handler) handleProfileExport(w http.ResponseWriter, r *http.Request) {
	resp, err := h.profiles.ExportProfile(r.Context(), connect.NewRequest(&psmithv1.ExportProfileRequest{
		ProfileId:     r.PathValue("id"),
		PreserveChain: r.URL.Query().Get("chain") == "1",
	}))
	if err != nil {
		http.Error(w, errMessage(err), http.StatusBadRequest)
		return
	}
	name := resp.Msg.GetSuggestedFilename()
	if name == "" {
		name = "profile.psmithprofile"
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", "attachment; filename="+strconv.Quote(name))
	_, _ = w.Write(resp.Msg.GetPayload())
}

// --- import ---

func (h *Handler) handleProfileImportPage(w http.ResponseWriter, r *http.Request) {
	h.render(w, r, http.StatusOK, profileImportScreen(h.loadSnav(r.Context(), r, "profiles"), nil))
}

// handleProfileImport reviews an uploaded bundle (a dry run) or, when the
// review posts its payload back, creates the profiles. With from=<id> the
// review renders on that profile's Share tab; otherwise on the import page.
func (h *Handler) handleProfileImport(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseMultipartForm(8 << 20); err != nil && !errors.Is(err, http.ErrNotMultipart) {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	from := r.FormValue("from")
	show := func(rv *importReviewVM) {
		if from != "" {
			r.SetPathValue("id", from)
			h.renderShare(w, r, shareState{Import: rv})
			return
		}
		h.showAfterPost(w, r, "/settings/profiles/import", profileImportScreen(h.loadSnav(r.Context(), r, "profiles"), rv))
	}

	if enc := r.PostFormValue("payload"); enc != "" {
		payload, err := base64.StdEncoding.DecodeString(enc)
		if err != nil {
			show(&importReviewVM{Error: "The file didn't survive the round trip. Choose it again."})
			return
		}
		resp, err := h.profiles.ImportProfile(r.Context(), connect.NewRequest(&psmithv1.ImportProfileRequest{Payload: payload}))
		if err != nil {
			show(&importReviewVM{Error: errMessage(err)})
			return
		}
		created := resp.Msg.GetProfiles()
		if len(created) == 0 {
			http.Redirect(w, r, "/settings/profiles", http.StatusSeeOther)
			return
		}
		http.Redirect(w, r, "/settings/profiles/"+created[len(created)-1].GetId(), http.StatusSeeOther)
		return
	}

	file, hdr, err := r.FormFile("file")
	if err != nil {
		show(&importReviewVM{Error: "Choose a .psmithprofile file to import."})
		return
	}
	defer func() { _ = file.Close() }()
	payload, err := io.ReadAll(io.LimitReader(file, 8<<20))
	if err != nil {
		show(&importReviewVM{Error: err.Error()})
		return
	}
	show(h.reviewImport(r, hdr.Filename, payload))
}

func (h *Handler) reviewImport(r *http.Request, name string, payload []byte) *importReviewVM {
	rv := &importReviewVM{FileName: name, Payload: base64.StdEncoding.EncodeToString(payload)}
	resp, err := h.profiles.ImportProfile(r.Context(), connect.NewRequest(&psmithv1.ImportProfileRequest{Payload: payload, DryRun: true}))
	if err != nil {
		rv.Error, rv.Payload = errMessage(err), ""
		return rv
	}
	rv.Summary = bundleSummary(payload)
	for _, n := range resp.Msg.GetRenamed() {
		rv.Warnings = append(rv.Warnings, importWarnVM{Renamed: n, Original: renameSuffix.ReplaceAllString(n, ""), Neutral: true})
	}
	for _, wn := range resp.Msg.GetWarnings() {
		rv.Warnings = append(rv.Warnings, importWarnVM{Text: wn.GetMessage(), Neutral: wn.GetKind() == psmithv1.ImportWarningKind_IMPORT_WARNING_KIND_RENAMED})
	}
	return rv
}

// renameSuffix is what the importer appends on a name collision, " (2)".
var renameSuffix = regexp.MustCompile(` \(\d+\)$`)

// bundleMagic must match server/profiles' header. The import review only
// reads the count and provenance from it; ImportProfile validates the file.
var bundleMagic = []byte("PSMITHPROFILE\x00")

// bundleSummary is "2 profiles · exported by Ana", or "" if the header
// doesn't parse.
func bundleSummary(payload []byte) string {
	if !bytes.HasPrefix(payload, bundleMagic) {
		return ""
	}
	var b psmithv1.ProfileBundle
	if proto.Unmarshal(payload[len(bundleMagic):], &b) != nil {
		return ""
	}
	n := len(b.GetProfiles())
	s := strconv.Itoa(n) + " profile"
	if n != 1 {
		s += "s"
	}
	if by := b.GetExportedBy(); by != "" {
		s += " · exported by " + by
	}
	return s
}
