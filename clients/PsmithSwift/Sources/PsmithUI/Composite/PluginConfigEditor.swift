import SwiftUI
import PsmithKit

/// Dispatcher that routes a plugin's config form to either the
/// generic `PluginConfigForm` or a per-plugin custom view. Use
/// this in place of `PluginConfigForm` everywhere a plugin's
/// config is edited (profile form, plugin settings page, model
/// gear popover that hosts plugin config).
///
/// Most plugins are happy with the field-by-field generic form.
/// Plugins whose config shape is "list of structured objects"
/// (or otherwise doesn't lend itself to a flat ConfigField list)
/// register a custom view here so the user gets a real editor
/// rather than a JSON textarea.
///
/// To register a custom form: add a `case` in `customForm`
/// matching the plugin's machine name. The custom view receives
/// the same `[String: Any]` config binding the generic form
/// uses, so the on-disk JSON shape stays the source of truth.
public struct PluginConfigEditor: View {
    let pluginName: String
    let fields: [PsmithConfigField]
    @Binding var config: [String: Any]
    let availableModels: [PsmithUserModel]
    let providerLabels: [String: String]
    let providerTypes: [String: String]
    let providerPresetIDs: [String: String]
    let availableProfiles: [(id: String, name: String)]

    public init(
        pluginName: String,
        fields: [PsmithConfigField],
        config: Binding<[String: Any]>,
        availableModels: [PsmithUserModel] = [],
        providerLabels: [String: String] = [:],
        providerTypes: [String: String] = [:],
        providerPresetIDs: [String: String] = [:],
        availableProfiles: [(id: String, name: String)] = []
    ) {
        self.pluginName = pluginName
        self.fields = fields
        self._config = config
        self.availableModels = availableModels
        self.providerLabels = providerLabels
        self.providerTypes = providerTypes
        self.providerPresetIDs = providerPresetIDs
        self.availableProfiles = availableProfiles
    }

    public var body: some View {
        // No switch on plugin name any more.
        //
        // There used to be one, with a hand-written form for
        // component_builder, because the field vocabulary could not express
        // "a list of records" and that plugin needed one. `ConfigFieldList`
        // closed that gap, so the bespoke form was deleted and every plugin
        // — including any added later — renders from its own declared schema.
        //
        // If a plugin ever needs something this form cannot draw, grow the
        // field vocabulary rather than reintroducing a case here: a new type
        // serves every plugin, a case serves one and has to be maintained in
        // every client.
        PluginConfigForm(
            fields: fields,
            config: $config,
            availableModels: availableModels,
            providerLabels: providerLabels,
            providerTypes: providerTypes,
            providerPresetIDs: providerPresetIDs,
            availableProfiles: availableProfiles
        )
    }
}
