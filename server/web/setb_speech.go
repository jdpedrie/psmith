package web

import (
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"connectrpc.com/connect"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

type sbSpeechVM struct {
	KindOpts     []sbOpt
	Voice        string
	Model        string
	Speed        string // "1.0"
	BaseURL      string
	KeySet       bool
	Replace      bool
	ProviderOpts []sbOpt
	Note         string
	Status       *testVM
	Dirty        int
	Reset        sbConfirmVM
}

var speechKindLabels = map[string]string{
	"apple_local":       "On-device",
	"grok":              "Grok (xAI)",
	"openai-compatible": "OpenAI-compatible",
}

var speechKindNotes = map[string]string{
	"apple_local":       "Each app reads replies with the device's own voice. Nothing goes through this server.",
	"grok":              "xAI's text-to-speech. Reuse your xAI provider's key or save one here.",
	"openai-compatible": "OpenAI's TTS or any self-hosted server speaking the same API, like Kokoro or Piper behind an OpenAI-compatible bridge. OpenAI voices include alloy.",
}

func speechReset(open bool) sbConfirmVM {
	return sbConfirmVM{
		ID: "sb-reset", Open: open,
		Label: "Reset to on-device", LabelDetail: "Removes the configuration and key. Read-aloud falls back to the on-device voice in each app.",
		Question: "Reset speech to on-device?", Detail: "The configuration and key go. Read-aloud falls back to the on-device voice in each app.",
		Verb: "Reset", OpenHref: "/settings/speech?reset=1", CancelHref: "/settings/speech", Action: "/settings/speech/delete", InForm: true,
	}
}

func (h *Handler) handleSpeech(w http.ResponseWriter, r *http.Request) {
	h.renderSpeech(w, r, nil, nil)
}

func (h *Handler) renderSpeech(w http.ResponseWriter, r *http.Request, result *testVM, posted url.Values) {
	reset := speechReset(r.URL.Query().Get("reset") == "1")
	if fragmentFor(r, reset.ID) {
		h.render(w, r, http.StatusOK, sbConfirm(reset))
		return
	}
	cfgResp, err := h.speech.GetSpeechConfig(r.Context(), connect.NewRequest(&psmithv1.GetSpeechConfigRequest{}))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	c := cfgResp.Msg.GetConfig()
	kind := orName(c.GetKind(), "apple_local")
	vm := sbSpeechVM{
		Voice: c.GetVoice(), Model: c.GetModel(), BaseURL: c.GetBaseUrl(), KeySet: c.GetApiKeySet(),
		Replace: r.URL.Query().Get("replace") == "1" || !c.GetApiKeySet(),
		Speed:   "1.0", Note: speechKindNotes[kind], Status: result, Reset: reset,
	}
	if c.GetSpeed() > 0 {
		vm.Speed = strconv.FormatFloat(c.GetSpeed(), 'f', 1, 64)
	}
	kinds := []string{kind}
	if kr, err := h.speech.ListSpeechKinds(r.Context(), connect.NewRequest(&psmithv1.ListSpeechKindsRequest{})); err == nil {
		kinds = kr.Msg.GetKinds()
	}
	// On-device leads: it's the default every account starts on.
	for _, k := range append([]string{"apple_local"}, kinds...) {
		if k == "apple_local" && len(vm.KindOpts) > 0 {
			continue
		}
		vm.KindOpts = append(vm.KindOpts, sbOpt{Value: k, Label: orName(speechKindLabels[k], k), Selected: k == kind})
	}
	vm.ProviderOpts = []sbOpt{{Value: "", Label: "None", Selected: c.GetProviderRef() == ""}}
	if h.models != nil {
		if pr, err := h.models.ListUserModelProviders(r.Context(), connect.NewRequest(&psmithv1.ListUserModelProvidersRequest{})); err == nil {
			for _, p := range pr.Msg.GetProviders() {
				vm.ProviderOpts = append(vm.ProviderOpts, sbOpt{Value: p.GetId(), Label: orName(p.GetLabel(), p.GetType()), Selected: p.GetId() == c.GetProviderRef()})
			}
		}
	}
	if posted != nil {
		kind, ref := posted.Get("kind"), posted.Get("provider_ref")
		vm.Dirty = countChanged(
			[2]string{selectedValue(vm.KindOpts), kind}, [2]string{vm.Voice, posted.Get("voice")}, [2]string{vm.Model, posted.Get("model")},
			[2]string{vm.Speed, posted.Get("speed")}, [2]string{vm.BaseURL, posted.Get("base_url")},
			[2]string{selectedValue(vm.ProviderOpts), ref}, [2]string{"", posted.Get("api_key")})
		for i := range vm.KindOpts {
			vm.KindOpts[i].Selected = vm.KindOpts[i].Value == kind
		}
		for i := range vm.ProviderOpts {
			vm.ProviderOpts[i].Selected = vm.ProviderOpts[i].Value == ref
		}
		vm.Voice, vm.Model, vm.BaseURL = posted.Get("voice"), posted.Get("model"), posted.Get("base_url")
		if sp := posted.Get("speed"); sp != "" {
			vm.Speed = sp
		}
		vm.Note = speechKindNotes[kind]
	}
	h.answer(w, r, "/settings/speech", http.StatusOK, speechScreen(h.loadSnav(r.Context(), r, "speech"), vm))
}

func (h *Handler) handleSpeechSave(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	kind := strings.TrimSpace(r.PostFormValue("kind"))
	voice := strings.TrimSpace(r.PostFormValue("voice"))
	model := strings.TrimSpace(r.PostFormValue("model"))
	baseURL := strings.TrimSpace(r.PostFormValue("base_url"))
	ref := r.PostFormValue("provider_ref")
	req := &psmithv1.UpdateSpeechConfigRequest{Kind: &kind, Voice: &voice, Model: &model, BaseUrl: &baseURL, ProviderRef: &ref}
	if s, err := strconv.ParseFloat(strings.TrimSpace(r.PostFormValue("speed")), 64); err == nil {
		req.Speed = &s
	}
	if k := r.PostFormValue("api_key"); k != "" {
		req.ApiKey = &k
	}
	enabled := true
	req.Enabled = &enabled
	if _, err := h.speech.UpdateSpeechConfig(r.Context(), connect.NewRequest(req)); err != nil {
		h.renderSpeech(w, r, &testVM{Message: errMessage(err)}, r.PostForm)
		return
	}
	http.Redirect(w, r, "/settings/speech", http.StatusSeeOther)
}

// handleSpeechKeyDelete clears the saved key so synthesis falls to the
// reused provider key.
func (h *Handler) handleSpeechKeyDelete(w http.ResponseWriter, r *http.Request) {
	empty := ""
	if _, err := h.speech.UpdateSpeechConfig(r.Context(), connect.NewRequest(&psmithv1.UpdateSpeechConfigRequest{ApiKey: &empty})); err != nil {
		h.renderSpeech(w, r, &testVM{Message: errMessage(err)}, nil)
		return
	}
	http.Redirect(w, r, "/settings/speech", http.StatusSeeOther)
}

func (h *Handler) handleSpeechTest(w http.ResponseWriter, r *http.Request) {
	resp, err := h.speech.TestSpeechConfig(r.Context(), connect.NewRequest(&psmithv1.TestSpeechConfigRequest{}))
	result := &testVM{}
	switch {
	case err != nil:
		result = testFailed(0, errMessage(err), "The speech provider")
	case resp.Msg.GetOk() && resp.Msg.GetAudioBytes() == 0:
		result.OK = true
		result.Message = "On-device speech needs nothing from this server."
	case resp.Msg.GetOk():
		result.OK = true
		result.Message = "Synthesized " + thousands(resp.Msg.GetAudioBytes()) + " bytes of audio in " + strconv.FormatInt(resp.Msg.GetLatencyMs(), 10) + " ms, just now"
	default:
		result = testFailed(resp.Msg.GetLatencyMs(), resp.Msg.GetErrorMessage(), "The speech provider")
	}
	h.renderSpeech(w, r, result, nil)
}

func (h *Handler) handleSpeechDelete(w http.ResponseWriter, r *http.Request) {
	if _, err := h.speech.DeleteSpeechConfig(r.Context(), connect.NewRequest(&psmithv1.DeleteSpeechConfigRequest{})); err != nil {
		h.renderSpeech(w, r, &testVM{Message: errMessage(err)}, nil)
		return
	}
	http.Redirect(w, r, "/settings/speech", http.StatusSeeOther)
}
