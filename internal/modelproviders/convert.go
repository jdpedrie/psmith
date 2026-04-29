package modelproviders

import (
	"encoding/json"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
	"google.golang.org/protobuf/types/known/timestamppb"

	clarkv1 "github.com/jdpedrie/clark/gen/clark/v1"
	"github.com/jdpedrie/clark/internal/modelmeta"
	"github.com/jdpedrie/clark/internal/providers"
	"github.com/jdpedrie/clark/internal/store"
)

// humanizeName converts a name like "openai-compatible" to "Openai Compatible".
func humanizeName(name string) string {
	parts := strings.FieldsFunc(name, func(r rune) bool {
		return r == '-' || r == '_'
	})
	for i, p := range parts {
		if p == "" {
			continue
		}
		parts[i] = strings.ToUpper(p[:1]) + p[1:]
	}
	return strings.Join(parts, " ")
}

// knownStatefulTypes lists provider types that satisfy providers.StatefulProvider.
// Hardcoded for now per the brief — drivers aren't registered for these in this build.
var knownStatefulTypes = map[string]bool{
	"claude-code-subprocess": true,
	"codex-subprocess":       true,
}

// storeProviderToProto maps a store row to its proto shape.
func storeProviderToProto(p store.UserModelProvider) *clarkv1.UserModelProvider {
	return &clarkv1.UserModelProvider{
		Id:          p.ID.String(),
		Type:        p.Type,
		Label:       p.Label,
		Config:      p.Config,
		OwnerUserId: p.UserID.String(),
		CreatedAt:   timestamppb.New(p.CreatedAt),
		UpdatedAt:   timestamppb.New(p.UpdatedAt),
	}
}

// storeUserModelToProto maps a store user_models row to its proto shape.
func storeUserModelToProto(m store.UserModel) *clarkv1.UserModel {
	out := &clarkv1.UserModel{
		UserModelProviderId: m.UserModelProviderID.String(),
		ModelId:             m.ModelID,
		DisplayName:         m.DisplayName,
		ContextWindow:       m.ContextWindow,
		MaxOutputTokens:     m.MaxOutputTokens,
		Modalities:          m.Modalities,
		MetadataSource:      stringToMetadataSourceEnum(m.MetadataSource),
		MetadataSnapshotAt:  timestamppb.New(m.MetadataSnapshotAt),
		EnabledAt:           timestamppb.New(m.EnabledAt),
		Favorite:            m.Favorite,
	}
	if pricing := pricingFromCols(m.InputPricePerMillion, m.OutputPricePerMillion, m.CacheReadPerMillion, m.CacheWritePerMillion); pricing != nil {
		out.Pricing = pricing
	}
	if m.KnowledgeCutoff.Valid {
		s := m.KnowledgeCutoff.Time.Format("2006-01-02")
		out.KnowledgeCutoff = &s
	}
	if len(m.Capabilities) > 0 {
		out.Capabilities = capabilitiesFromJSON(m.Capabilities)
	}
	if len(m.DefaultSettings) > 0 {
		out.DefaultSettings = callSettingsFromJSON(m.DefaultSettings)
	}
	return out
}

func pricingFromCols(in, out, cr, cw *float64) *clarkv1.ModelPricing {
	if in == nil && out == nil && cr == nil && cw == nil {
		return nil
	}
	return &clarkv1.ModelPricing{
		InputPerMillionTokens:      in,
		OutputPerMillionTokens:     out,
		CacheReadPerMillionTokens:  cr,
		CacheWritePerMillionTokens: cw,
	}
}

func capabilitiesFromJSON(b []byte) *clarkv1.ModelCapabilities {
	var c modelmeta.Capabilities
	if err := json.Unmarshal(b, &c); err != nil {
		return nil
	}
	return capabilitiesToProto(c)
}

func capabilitiesToProto(c modelmeta.Capabilities) *clarkv1.ModelCapabilities {
	return &clarkv1.ModelCapabilities{
		Streaming:     c.Streaming,
		Thinking:      c.Thinking,
		ToolUse:       c.ToolUse,
		Vision:        c.Vision,
		PromptCaching: c.PromptCaching,
	}
}

func providerCapsToProto(c providers.ModelCapabilities) *clarkv1.ModelCapabilities {
	return &clarkv1.ModelCapabilities{
		Streaming:     c.Streaming,
		Thinking:      c.Thinking,
		ToolUse:       c.ToolUse,
		Vision:        c.Vision,
		PromptCaching: c.PromptCaching,
	}
}

func callSettingsFromJSON(b []byte) *clarkv1.CallSettings {
	var cs providerCallSettings
	if err := json.Unmarshal(b, &cs); err != nil {
		return nil
	}
	out := &clarkv1.CallSettings{
		Temperature:          cs.Temperature,
		ThinkingEnabled:      cs.ThinkingEnabled,
		ThinkingBudgetTokens: cs.ThinkingBudgetTokens,
		Extras:               cs.Extras,
	}
	if cs.MaxOutputTokens != nil {
		v := int32(*cs.MaxOutputTokens)
		out.MaxOutputTokens = &v
	}
	return out
}

// providerCallSettings mirrors providers.CallSettings for JSON encoding so we
// don't depend on field tag stability of the providers package's struct.
type providerCallSettings struct {
	Temperature          *float64        `json:"temperature,omitempty"`
	MaxOutputTokens      *int            `json:"max_output_tokens,omitempty"`
	ThinkingEnabled      *bool           `json:"thinking_enabled,omitempty"`
	ThinkingBudgetTokens *int32          `json:"thinking_budget_tokens,omitempty"`
	Extras               json.RawMessage `json:"extras,omitempty"`
}

func encodeCallSettings(s providers.CallSettings) ([]byte, error) {
	tmp := providerCallSettings{
		Temperature:     s.Temperature,
		MaxOutputTokens: s.MaxOutputTokens,
		ThinkingEnabled: s.ThinkingEnabled,
		Extras:          s.Extras,
	}
	if s.ThinkingBudgetTokens != nil {
		v := int32(*s.ThinkingBudgetTokens)
		tmp.ThinkingBudgetTokens = &v
	}
	if tmp.Temperature == nil && tmp.MaxOutputTokens == nil &&
		tmp.ThinkingEnabled == nil && tmp.ThinkingBudgetTokens == nil &&
		len(tmp.Extras) == 0 {
		return nil, nil
	}
	return json.Marshal(tmp)
}

func stringToMetadataSourceEnum(s string) clarkv1.MetadataSource {
	switch modelmeta.Source(s) {
	case modelmeta.SourceCatalog:
		return clarkv1.MetadataSource_METADATA_SOURCE_CATALOG
	case modelmeta.SourceDriver:
		return clarkv1.MetadataSource_METADATA_SOURCE_DRIVER
	case modelmeta.SourceManual:
		return clarkv1.MetadataSource_METADATA_SOURCE_MANUAL
	}
	return clarkv1.MetadataSource_METADATA_SOURCE_UNSPECIFIED
}

// catalogModelToDiscovered builds a DiscoveredModel from a catalog Model.
// Used by the catalog-driven discovery path (every provider with a
// `catalog_provider_id`); pricing/context/etc come straight from the
// curated catalog so the user picks from a metadata-rich list.
func catalogModelToDiscovered(m *modelmeta.Model, alreadyEnabled bool) *clarkv1.DiscoveredModel {
	out := &clarkv1.DiscoveredModel{
		ModelId:        m.ID,
		DisplayName:    m.DisplayName,
		Modalities:     m.Modalities,
		Capabilities: &clarkv1.ModelCapabilities{
			Streaming:     m.Capabilities.Streaming,
			Thinking:      m.Capabilities.Thinking,
			ToolUse:       m.Capabilities.ToolUse,
			Vision:        m.Capabilities.Vision,
			PromptCaching: m.Capabilities.PromptCaching,
		},
		MetadataSource: clarkv1.MetadataSource_METADATA_SOURCE_CATALOG,
		AlreadyEnabled: alreadyEnabled,
	}
	if m.ContextWindow > 0 {
		v := int32(m.ContextWindow)
		out.ContextWindow = &v
	}
	if m.MaxOutputTokens > 0 {
		v := int32(m.MaxOutputTokens)
		out.MaxOutputTokens = &v
	}
	if m.Pricing != nil {
		out.Pricing = pricingToProto(m.Pricing.InputPerMillion, m.Pricing.OutputPerMillion,
			m.Pricing.CacheReadPerMillion, m.Pricing.CacheWritePerMillion)
	}
	if m.KnowledgeCutoff != nil {
		s := m.KnowledgeCutoff.Format("2006-01-02")
		out.KnowledgeCutoff = &s
	}
	return out
}

// providerModelToDiscovered builds a DiscoveredModel from a providers.Model.
func providerModelToDiscovered(m providers.Model, alreadyEnabled bool) *clarkv1.DiscoveredModel {
	out := &clarkv1.DiscoveredModel{
		ModelId:        m.ID,
		DisplayName:    m.DisplayName,
		Modalities:     m.Modalities,
		Capabilities:   providerCapsToProto(m.Capabilities),
		MetadataSource: sourceToEnum(m.MetadataSource),
		AlreadyEnabled: alreadyEnabled,
	}
	if m.ContextWindow > 0 {
		v := int32(m.ContextWindow)
		out.ContextWindow = &v
	}
	if m.MaxOutputTokens > 0 {
		v := int32(m.MaxOutputTokens)
		out.MaxOutputTokens = &v
	}
	if m.Pricing != nil {
		out.Pricing = pricingToProto(m.Pricing.InputPerMillion, m.Pricing.OutputPerMillion,
			m.Pricing.CacheReadPerMillion, m.Pricing.CacheWritePerMillion)
	}
	if m.KnowledgeCutoff != "" {
		s := m.KnowledgeCutoff
		out.KnowledgeCutoff = &s
	}
	return out
}

func sourceToEnum(s modelmeta.Source) clarkv1.MetadataSource {
	switch s {
	case modelmeta.SourceCatalog:
		return clarkv1.MetadataSource_METADATA_SOURCE_CATALOG
	case modelmeta.SourceDriver:
		return clarkv1.MetadataSource_METADATA_SOURCE_DRIVER
	case modelmeta.SourceManual:
		return clarkv1.MetadataSource_METADATA_SOURCE_MANUAL
	}
	return clarkv1.MetadataSource_METADATA_SOURCE_DRIVER
}

func pricingToProto(in, out, cr, cw float64) *clarkv1.ModelPricing {
	if in == 0 && out == 0 && cr == 0 && cw == 0 {
		return nil
	}
	p := &clarkv1.ModelPricing{}
	if in != 0 {
		v := in
		p.InputPerMillionTokens = &v
	}
	if out != 0 {
		v := out
		p.OutputPerMillionTokens = &v
	}
	if cr != 0 {
		v := cr
		p.CacheReadPerMillionTokens = &v
	}
	if cw != 0 {
		v := cw
		p.CacheWritePerMillionTokens = &v
	}
	return p
}

// dateOrNullPtr converts a *time.Time pointer to a pgtype.Date.
func dateOrNullPtr(t *time.Time) pgtype.Date {
	if t == nil {
		return pgtype.Date{}
	}
	return pgtype.Date{Time: *t, Valid: true}
}

// dateFromString parses an ISO-ish date and returns a pgtype.Date.
func dateFromString(s string) pgtype.Date {
	if s == "" {
		return pgtype.Date{}
	}
	for _, layout := range []string{"2006-01-02", "2006-01", "2006"} {
		if t, err := time.Parse(layout, s); err == nil {
			return pgtype.Date{Time: t, Valid: true}
		}
	}
	return pgtype.Date{}
}

// floatPtrOrNil returns nil for zero-valued floats.
func floatPtrOrNil(v float64) *float64 {
	if v == 0 {
		return nil
	}
	return &v
}

// intPtrOrNil returns nil for zero-valued ints.
func intPtrOrNil(v int) *int32 {
	if v == 0 {
		return nil
	}
	x := int32(v)
	return &x
}

// strPtr returns nil for empty strings.
func strPtr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}
