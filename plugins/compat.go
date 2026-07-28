// Package plugins holds Psmith's built-in plugins.
//
// The framework they implement moved to pluginapi (and the host-provided
// capabilities to pluginapi/host). This file re-exports that surface under the
// old names so the plugins and their ~26 consumers keep compiling while the
// move lands in reviewable pieces. It is deleted in the next commit, when each
// plugin becomes its own package and references pluginapi directly.
package plugins

import (
	"context"
	"encoding/json"

	"github.com/jdpedrie/psmith/pluginapi"
	"github.com/jdpedrie/psmith/pluginapi/host"
)

type (
	AssistantContentTransformer = pluginapi.AssistantContentTransformer
	Capabilities                = pluginapi.Capabilities
	CapabilityRequirer          = pluginapi.CapabilityRequirer
	ChunkTransformer            = pluginapi.ChunkTransformer
	ConfigField                 = pluginapi.ConfigField
	ConfigFieldMerge            = pluginapi.ConfigFieldMerge
	ConfigFieldType             = pluginapi.ConfigFieldType
	ConfigOption                = pluginapi.ConfigOption
	Configurable                = pluginapi.Configurable
	Constructor                 = pluginapi.Constructor
	ContentPart                 = pluginapi.ContentPart
	ContentRenderer             = pluginapi.ContentRenderer
	DeviceFactRequester         = pluginapi.DeviceFactRequester
	DisplayTransformer          = pluginapi.DisplayTransformer
	HistoryPos                  = pluginapi.HistoryPos
	HistoryTransformer          = pluginapi.HistoryTransformer
	InboundProcessor            = pluginapi.InboundProcessor
	MessageEnvelope             = pluginapi.MessageEnvelope
	MessageLifecycleHook        = pluginapi.MessageLifecycleHook
	ModelCapabilityRequirements = pluginapi.ModelCapabilityRequirements
	ModelPickerFilter           = pluginapi.ModelPickerFilter
	PendingState                = pluginapi.PendingState
	PendingStateProvider        = pluginapi.PendingStateProvider
	PersistedMessage            = pluginapi.PersistedMessage
	Pipeline                    = pluginapi.Pipeline
	Plugin                      = pluginapi.Plugin
	Spec                        = pluginapi.Spec
	StreamingTag                = pluginapi.StreamingTag
	StreamingTagProvider        = pluginapi.StreamingTagProvider
	SystemPrompter              = pluginapi.SystemPrompter
	ToolAttachment              = pluginapi.ToolAttachment
	ToolDef                     = pluginapi.ToolDef
	ToolProvider                = pluginapi.ToolProvider
	ToolResult                  = pluginapi.ToolResult
	TurnContextInjector         = pluginapi.TurnContextInjector
	TurnInfo                    = pluginapi.TurnInfo
	TypeDescriptor              = pluginapi.TypeDescriptor
	UIFragment                  = pluginapi.UIFragment
	CallerInfo                  = host.CallerInfo
	ProviderResolver            = host.ProviderResolver
	ResolvedModel               = host.ResolvedModel
	ResolvedPricing             = host.ResolvedPricing
	Searcher                    = host.Searcher
	SearchOptions               = host.SearchOptions
	Hit                         = host.Hit
	DeviceToolBroker            = host.DeviceToolBroker
	PluginStateStore            = host.PluginStateStore
)

const (
	ConfigFieldBoolean          = pluginapi.ConfigFieldBoolean
	ConfigFieldModelPicker      = pluginapi.ConfigFieldModelPicker
	ConfigFieldNumber           = pluginapi.ConfigFieldNumber
	ConfigFieldSelect           = pluginapi.ConfigFieldSelect
	ConfigFieldText             = pluginapi.ConfigFieldText
	ConfigFieldTextarea         = pluginapi.ConfigFieldTextarea
	DeviceFactKeyLocale         = pluginapi.DeviceFactKeyLocale
	DeviceFactKeyLocationCity   = pluginapi.DeviceFactKeyLocationCity
	DeviceFactKeyLocationCoords = pluginapi.DeviceFactKeyLocationCoords
	DeviceFactKeyPlatform       = pluginapi.DeviceFactKeyPlatform
	DeviceFactKeyTimezone       = pluginapi.DeviceFactKeyTimezone
	MergeAppendString           = pluginapi.MergeAppendString
	MergeReplace                = pluginapi.MergeReplace
)

var (
	ErrUnknownPlugin = pluginapi.ErrUnknownPlugin
	ErrNoPluginState = host.ErrNoPluginState
)

func NewTextPart(s string) ContentPart { return pluginapi.NewTextPart(s) }
func NewFragmentPart(component string, props json.RawMessage, key string) ContentPart {
	return pluginapi.NewFragmentPart(component, props, key)
}
func WalkText(parts []ContentPart, fn func(text string) []ContentPart) []ContentPart {
	return pluginapi.WalkText(parts, fn)
}
func Register(name string, ctor Constructor) { pluginapi.Register(name, ctor) }
func Build(name string, configBytes json.RawMessage) (Plugin, error) {
	return pluginapi.Build(name, configBytes)
}
func IsRegistered(name string) bool                { return pluginapi.IsRegistered(name) }
func ListRegistered() []string                     { return pluginapi.ListRegistered() }
func Resolve(specs []Spec) (Pipeline, error)       { return pluginapi.Resolve(specs) }
func Describe(name string) (TypeDescriptor, error) { return pluginapi.Describe(name) }
func DescribeAll() ([]TypeDescriptor, error)       { return pluginapi.DescribeAll() }
func MergeLayeredConfigs(name string, layers [][]byte) ([]byte, error) {
	return pluginapi.MergeLayeredConfigs(name, layers)
}

func WithCallerInfo(ctx context.Context, info CallerInfo) context.Context {
	return host.WithCallerInfo(ctx, info)
}
func CallerInfoFrom(ctx context.Context) CallerInfo { return host.CallerInfoFrom(ctx) }
func WithDeviceToolBroker(ctx context.Context, b DeviceToolBroker) context.Context {
	return host.WithDeviceToolBroker(ctx, b)
}
func DeviceToolBrokerFrom(ctx context.Context) DeviceToolBroker {
	return host.DeviceToolBrokerFrom(ctx)
}
func WithProviderResolver(ctx context.Context, r ProviderResolver) context.Context {
	return host.WithProviderResolver(ctx, r)
}
func ProviderResolverFrom(ctx context.Context) ProviderResolver {
	return host.ProviderResolverFrom(ctx)
}
func WithSearcher(ctx context.Context, s Searcher) context.Context { return host.WithSearcher(ctx, s) }
func SearcherFrom(ctx context.Context) Searcher                    { return host.SearcherFrom(ctx) }
func WithPluginStateStore(ctx context.Context, s PluginStateStore) context.Context {
	return host.WithPluginStateStore(ctx, s)
}
func PluginStateStoreFrom(ctx context.Context) PluginStateStore {
	return host.PluginStateStoreFrom(ctx)
}
