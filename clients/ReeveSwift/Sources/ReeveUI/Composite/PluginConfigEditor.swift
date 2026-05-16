import SwiftUI
import ReeveKit

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
    let fields: [ReeveConfigField]
    @Binding var config: [String: Any]
    let availableModels: [ReeveUserModel]
    let providerLabels: [String: String]
    let providerTypes: [String: String]
    let providerPresetIDs: [String: String]

    public init(
        pluginName: String,
        fields: [ReeveConfigField],
        config: Binding<[String: Any]>,
        availableModels: [ReeveUserModel] = [],
        providerLabels: [String: String] = [:],
        providerTypes: [String: String] = [:],
        providerPresetIDs: [String: String] = [:]
    ) {
        self.pluginName = pluginName
        self.fields = fields
        self._config = config
        self.availableModels = availableModels
        self.providerLabels = providerLabels
        self.providerTypes = providerTypes
        self.providerPresetIDs = providerPresetIDs
    }

    public var body: some View {
        // SwiftUI builds a single AnyView-wrapped subtree from the
        // switch so the dispatcher itself can stay non-generic.
        // Adding a new custom form is a one-line case + a new
        // file under Composite/.
        switch pluginName {
        case "component_builder":
            ComponentBuilderConfigForm(config: $config)
        default:
            PluginConfigForm(
                fields: fields,
                config: $config,
                availableModels: availableModels,
                providerLabels: providerLabels,
                providerTypes: providerTypes,
                providerPresetIDs: providerPresetIDs
            )
        }
    }
}
