package modelproviders

import (
	"encoding/json"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
	"google.golang.org/protobuf/types/known/timestamppb"

	reevev1 "github.com/jdpedrie/reeve/gen/reeve/v1"
	"github.com/jdpedrie/reeve/internal/modelmeta"
	"github.com/jdpedrie/reeve/internal/profiles"
	"github.com/jdpedrie/reeve/internal/providers"
	"github.com/jdpedrie/reeve/internal/store"
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

// storeProviderToProto maps a store row to its proto shape. Method
// form so it can resolve the dual-column config (encrypted preferred,
// plaintext fallback for unmigrated rows) through the service's
// cipher.
//
// Decryption failures fall through to nil Config rather than erroring
// the whole proto — the proto field is informational at the wire
// layer and a missing config doesn't prevent the row from rendering.
// The error gets logged so a misconfigured cipher (wrong key) is
// surfaced.
func (s *Service) storeProviderToProto(p store.UserModelProvider) *reevev1.UserModelProvider {
	cfg, err := s.resolveProviderConfig(p)
	if err != nil {
		s.logger.Warn("decrypt provider config for proto response failed",
			"provider_id", p.ID,
			"error", err,
		)
		cfg = nil
	}
	out := &reevev1.UserModelProvider{
		Id:          p.ID.String(),
		Type:        p.Type,
		Label:       p.Label,
		Config:      cfg,
		OwnerUserId: p.UserID.String(),
		CreatedAt:   timestamppb.New(p.CreatedAt),
		UpdatedAt:   timestamppb.New(p.UpdatedAt),
	}
	if len(p.DefaultSettings) > 0 {
		out.DefaultSettings = callSettingsFromJSON(p.DefaultSettings)
	}
	return out
}

// storeUserModelToProto maps a store user_models row to its proto shape.
func storeUserModelToProto(m store.UserModel) *reevev1.UserModel {
	out := &reevev1.UserModel{
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

func pricingFromCols(in, out, cr, cw *float64) *reevev1.ModelPricing {
	if in == nil && out == nil && cr == nil && cw == nil {
		return nil
	}
	return &reevev1.ModelPricing{
		InputPerMillionTokens:      in,
		OutputPerMillionTokens:     out,
		CacheReadPerMillionTokens:  cr,
		CacheWritePerMillionTokens: cw,
	}
}

func capabilitiesFromJSON(b []byte) *reevev1.ModelCapabilities {
	var c modelmeta.Capabilities
	if err := json.Unmarshal(b, &c); err != nil {
		return nil
	}
	return capabilitiesToProto(c)
}

func capabilitiesToProto(c modelmeta.Capabilities) *reevev1.ModelCapabilities {
	return &reevev1.ModelCapabilities{
		Streaming:       c.Streaming,
		Thinking:        c.Thinking,
		ToolUse:         c.ToolUse,
		Vision:          c.Vision,
		PromptCaching:   c.PromptCaching,
		GeneratesImages: c.GeneratesImages,
	}
}

func providerCapsToProto(c providers.ModelCapabilities) *reevev1.ModelCapabilities {
	return &reevev1.ModelCapabilities{
		Streaming:       c.Streaming,
		Thinking:        c.Thinking,
		ToolUse:         c.ToolUse,
		Vision:          c.Vision,
		PromptCaching:   c.PromptCaching,
		GeneratesImages: c.GeneratesImages,
	}
}

// callSettingsFromJSON decodes the JSONB blob persisted in
// `user_models.default_settings` (or `user_model_providers.default_settings`)
// back into a proto CallSettings. The blob is protojson — see
// profiles.MarshalCallSettings — so we delegate to that codec.
func callSettingsFromJSON(b []byte) *reevev1.CallSettings {
	if len(b) == 0 {
		return nil
	}
	cs, err := profiles.UnmarshalCallSettings(b)
	if err != nil {
		return nil
	}
	return cs
}

// encodeCallSettings serializes a driver-side CallSettings struct to the
// JSONB shape used in `user_models.default_settings`. Returns (nil, nil) for
// an all-empty settings struct so the column stays NULL.
func encodeCallSettings(s providers.CallSettings) ([]byte, error) {
	proto := callSettingsToProto(s)
	if proto == nil {
		return nil, nil
	}
	return profiles.MarshalCallSettings(proto)
}

// callSettingsToProto converts a driver-side CallSettings to the proto type.
// Returns nil when every field is unset — so callers can skip persisting an
// empty blob entirely.
func callSettingsToProto(s providers.CallSettings) *reevev1.CallSettings {
	out := &reevev1.CallSettings{
		Temperature: s.Temperature,
		TopP:        s.TopP,
	}
	if s.MaxOutputTokens != nil {
		v := int32(*s.MaxOutputTokens)
		out.MaxOutputTokens = &v
	}
	if s.TopK != nil {
		v := int32(*s.TopK)
		out.TopK = &v
	}
	if len(s.StopSequences) > 0 {
		out.StopSequences = append([]string(nil), s.StopSequences...)
	}
	if t := s.Thinking; t != nil {
		ts := &reevev1.ThinkingSettings{Enabled: t.Enabled}
		if t.BudgetTokens != nil {
			v := int32(*t.BudgetTokens)
			ts.BudgetTokens = &v
		}
		if ts.Enabled != nil || ts.BudgetTokens != nil {
			out.Thinking = ts
		}
	}
	if isCallSettingsEmpty(out) {
		return nil
	}
	return out
}

// isCallSettingsEmpty returns true when every field on the proto is unset.
// Helps the encode path skip writing a useless `{}` blob.
func isCallSettingsEmpty(cs *reevev1.CallSettings) bool {
	if cs == nil {
		return true
	}
	return cs.Temperature == nil && cs.TopP == nil && cs.MaxOutputTokens == nil &&
		len(cs.StopSequences) == 0 && cs.TopK == nil &&
		cs.Thinking == nil && cs.Anthropic == nil && cs.Openai == nil && cs.Google == nil
}

func stringToMetadataSourceEnum(s string) reevev1.MetadataSource {
	switch modelmeta.Source(s) {
	case modelmeta.SourceCatalog:
		return reevev1.MetadataSource_METADATA_SOURCE_CATALOG
	case modelmeta.SourceDriver:
		return reevev1.MetadataSource_METADATA_SOURCE_DRIVER
	case modelmeta.SourceManual:
		return reevev1.MetadataSource_METADATA_SOURCE_MANUAL
	}
	return reevev1.MetadataSource_METADATA_SOURCE_UNSPECIFIED
}

// catalogModelToDiscovered builds a DiscoveredModel from a catalog Model.
// Used by the catalog-driven discovery path (every provider with a
// `catalog_provider_id`); pricing/context/etc come straight from the
// curated catalog so the user picks from a metadata-rich list.
func catalogModelToDiscovered(m *modelmeta.Model, alreadyEnabled bool) *reevev1.DiscoveredModel {
	out := &reevev1.DiscoveredModel{
		ModelId:        m.ID,
		DisplayName:    m.DisplayName,
		Modalities:     m.Modalities,
		Capabilities: &reevev1.ModelCapabilities{
			Streaming:       m.Capabilities.Streaming,
			Thinking:        m.Capabilities.Thinking,
			ToolUse:         m.Capabilities.ToolUse,
			Vision:          m.Capabilities.Vision,
			PromptCaching:   m.Capabilities.PromptCaching,
			GeneratesImages: m.Capabilities.GeneratesImages,
		},
		MetadataSource: reevev1.MetadataSource_METADATA_SOURCE_CATALOG,
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
func providerModelToDiscovered(m providers.Model, alreadyEnabled bool) *reevev1.DiscoveredModel {
	out := &reevev1.DiscoveredModel{
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

func sourceToEnum(s modelmeta.Source) reevev1.MetadataSource {
	switch s {
	case modelmeta.SourceCatalog:
		return reevev1.MetadataSource_METADATA_SOURCE_CATALOG
	case modelmeta.SourceDriver:
		return reevev1.MetadataSource_METADATA_SOURCE_DRIVER
	case modelmeta.SourceManual:
		return reevev1.MetadataSource_METADATA_SOURCE_MANUAL
	}
	return reevev1.MetadataSource_METADATA_SOURCE_DRIVER
}

func pricingToProto(in, out, cr, cw float64) *reevev1.ModelPricing {
	if in == 0 && out == 0 && cr == 0 && cw == 0 {
		return nil
	}
	p := &reevev1.ModelPricing{}
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
