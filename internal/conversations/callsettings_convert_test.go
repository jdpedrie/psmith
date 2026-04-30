package conversations

import (
	"testing"

	clarkv1 "github.com/jdpedrie/clark/gen/clark/v1"
	"github.com/jdpedrie/clark/internal/providers"
)

func TestProtoCallSettingsToProvider_AnthropicNil(t *testing.T) {
	out := protoCallSettingsToProvider(&clarkv1.CallSettings{})
	if out.Anthropic != nil {
		t.Errorf("expected Anthropic nil when proto unset, got %+v", out.Anthropic)
	}
}

func TestProtoCallSettingsToProvider_AnthropicCacheEnabledRoundTrip(t *testing.T) {
	on := true
	off := false
	cases := []struct {
		name string
		in   *bool
		want *bool
	}{
		{"on", &on, &on},
		{"off", &off, &off},
		{"unset", nil, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := protoCallSettingsToProvider(&clarkv1.CallSettings{
				Anthropic: &clarkv1.AnthropicExtras{CacheEnabled: tc.in},
			})
			if out.Anthropic == nil {
				t.Fatalf("expected Anthropic non-nil")
			}
			got := out.Anthropic.CacheEnabled
			switch {
			case tc.want == nil && got != nil:
				t.Errorf("expected nil, got %v", *got)
			case tc.want != nil && got == nil:
				t.Errorf("expected %v, got nil", *tc.want)
			case tc.want != nil && got != nil && *tc.want != *got:
				t.Errorf("expected %v, got %v", *tc.want, *got)
			}
		})
	}
}

func TestProtoCallSettingsToProvider_AnthropicCacheTTL(t *testing.T) {
	ttl5m := clarkv1.CacheTTL_CACHE_TTL_5M
	ttl1h := clarkv1.CacheTTL_CACHE_TTL_1H
	ttlUnspec := clarkv1.CacheTTL_CACHE_TTL_UNSPECIFIED
	cases := []struct {
		name string
		in   *clarkv1.CacheTTL
		want providers.CacheTTL
	}{
		{"unset", nil, providers.CacheTTLUnspecified},
		{"unspecified", &ttlUnspec, providers.CacheTTLUnspecified},
		{"5m", &ttl5m, providers.CacheTTL5m},
		{"1h", &ttl1h, providers.CacheTTL1h},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := protoCallSettingsToProvider(&clarkv1.CallSettings{
				Anthropic: &clarkv1.AnthropicExtras{CacheTtl: tc.in},
			})
			if out.Anthropic == nil {
				t.Fatalf("expected Anthropic non-nil")
			}
			if out.Anthropic.CacheTTL != tc.want {
				t.Errorf("CacheTTL = %d, want %d", out.Anthropic.CacheTTL, tc.want)
			}
		})
	}
}

func TestConvertProtoCacheTTL_Direct(t *testing.T) {
	ttl5m := clarkv1.CacheTTL_CACHE_TTL_5M
	ttl1h := clarkv1.CacheTTL_CACHE_TTL_1H
	cases := []struct {
		name string
		in   *clarkv1.CacheTTL
		want providers.CacheTTL
	}{
		{"nil", nil, providers.CacheTTLUnspecified},
		{"5m", &ttl5m, providers.CacheTTL5m},
		{"1h", &ttl1h, providers.CacheTTL1h},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := convertProtoCacheTTL(tc.in)
			if got != tc.want {
				t.Errorf("got %d, want %d", got, tc.want)
			}
		})
	}
}
