package web

import (
	"encoding/json"
	"net/url"
	"strings"

	psmithv1 "github.com/jdpedrie/psmith/gen/psmith/v1"
)

// fragVM is one part of a reply drawn from Message.ui_fragments: prose, or a
// component from pluginapi/CONTENT_RENDERERS.md. Components the web client
// has no renderer for show their props as JSON, as the catalog asks.
type fragVM struct {
	Kind    string // "text", "card_list", "key_value", "choice_list", "image", "error", "json"
	HTML    string // text: rendered markdown; json: pretty props
	Cards   []cardVM
	Pairs   []pairVM
	Choices []choiceVM
	Images  []imageFragVM
	Message string // error
	Code    string
	Retry   string // error: an action, like a choice's
}

type cardVM struct {
	Title, Description, URL, Host, Image string
	Badges                               []string
}

type pairVM struct{ Key, Value string }

type choiceVM struct {
	Letter  string
	Label   string
	Action  string // "send:B", "compose:text"; empty is a static row
	Payload string // the text the action sends or composes
	Chosen  bool   // the user then sent this choice
}

type imageFragVM struct{ URL, Alt, Caption string }

func fragmentsOf(frags []*psmithv1.UIFragment) []fragVM {
	out := make([]fragVM, 0, len(frags))
	for _, f := range frags {
		out = append(out, fragmentOf(f.GetComponent(), f.GetProps()))
	}
	return out
}

func fragmentOf(component string, props []byte) fragVM {
	raw := fragVM{Kind: "json", HTML: prettyJSON(props)}
	switch component {
	case "text":
		var p struct {
			Text string `json:"text"`
		}
		if json.Unmarshal(props, &p) != nil {
			return raw
		}
		return fragVM{Kind: "text", HTML: renderMarkdown(p.Text)}
	case "card_list":
		var p struct {
			Items []struct {
				Title       string   `json:"title"`
				Description string   `json:"description"`
				URL         string   `json:"url"`
				Image       string   `json:"image"`
				Badges      []string `json:"badges"`
			} `json:"items"`
		}
		if json.Unmarshal(props, &p) != nil {
			return raw
		}
		v := fragVM{Kind: "card_list"}
		for _, it := range p.Items {
			c := cardVM{Title: it.Title, Description: it.Description, Badges: it.Badges, Image: safeURL(it.Image)}
			if u := safeURL(it.URL); u != "" {
				c.URL = u
				if pu, err := url.Parse(u); err == nil {
					c.Host = pu.Host
				}
			}
			v.Cards = append(v.Cards, c)
		}
		return v
	case "key_value":
		var p struct {
			Pairs []pairVM `json:"pairs"`
		}
		if json.Unmarshal(props, &p) != nil {
			return raw
		}
		return fragVM{Kind: "key_value", Pairs: p.Pairs}
	case "choice_list":
		var p struct {
			Items []struct {
				Label  string `json:"label"`
				Value  string `json:"value"`
				Action string `json:"action"`
			} `json:"items"`
		}
		if json.Unmarshal(props, &p) != nil {
			return raw
		}
		v := fragVM{Kind: "choice_list"}
		for i, it := range p.Items {
			letter := strings.TrimSpace(it.Value)
			if len([]rune(letter)) > 2 || letter == "" {
				letter = string(rune('A' + min(i, 25)))
			}
			label := strings.TrimPrefix(it.Label, letter+". ")
			c := choiceVM{Letter: letter, Label: label}
			if scheme, payload, ok := strings.Cut(it.Action, ":"); ok && (scheme == "send" || scheme == "compose") {
				c.Action, c.Payload = it.Action, payload
			}
			v.Choices = append(v.Choices, c)
		}
		return v
	case "image", "image_grid":
		var p struct {
			URL     string        `json:"url"`
			Alt     string        `json:"alt"`
			Caption string        `json:"caption"`
			Items   []imageFragVM `json:"items"`
		}
		if json.Unmarshal(props, &p) != nil {
			return raw
		}
		v := fragVM{Kind: "image"}
		if p.URL != "" {
			p.Items = append([]imageFragVM{{URL: p.URL, Alt: p.Alt, Caption: p.Caption}}, p.Items...)
		}
		for _, im := range p.Items {
			if u := safeURL(im.URL); u != "" {
				im.URL = u
				v.Images = append(v.Images, im)
			}
		}
		return v
	case "error":
		var p struct {
			Message string `json:"message"`
			Code    string `json:"code"`
			Retry   string `json:"retry"`
		}
		if json.Unmarshal(props, &p) != nil {
			return raw
		}
		return fragVM{Kind: "error", Message: p.Message, Code: p.Code, Retry: p.Retry}
	}
	return raw
}

// safeURL keeps only http(s) links: fragment props are plugin and model
// authored, and a javascript: URL in an href is script.
func safeURL(s string) string {
	u, err := url.Parse(strings.TrimSpace(s))
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return ""
	}
	return u.String()
}
