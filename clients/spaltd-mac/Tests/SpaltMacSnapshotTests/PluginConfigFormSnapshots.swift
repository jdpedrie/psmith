import Testing
import SwiftUI
@testable import SpaltMac
import SpaltKit
import SnapshotHarness

/// `PluginConfigForm` is the shared plugin-config editor used wherever a
/// plugin instance is being configured (currently inside `ProfileForm`).
/// The control rendered for each row is dispatched on `field.type`, so
/// every type-branch needs its own snapshot to lock down rendering.
///
/// Snapshotted at `default` and `minColumn` widths. The form is hosted
/// inside narrow detail columns in production, so min-width clipping is
/// the same regression class as `CallSettingsForm`.
@MainActor
struct PluginConfigFormSnapshots {

    // MARK: - Wrapper

    /// Drives `PluginConfigForm` against a `@State` config dict so its
    /// internal bindings can mutate the values without trip-routing
    /// through a stub view-model. The wrapper supplies the same padded
    /// scroll container the production callsite (`ProfileForm`) uses.
    private struct Wrapper: View {
        let fields: [SpaltConfigField]
        @State var config: [String: Any]

        init(fields: [SpaltConfigField], config: [String: Any] = [:]) {
            self.fields = fields
            self._config = State(initialValue: config)
        }

        var body: some View {
            ScrollView {
                PluginConfigForm(fields: fields, config: $config)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - Single-field variants

    /// Number field — TextField with the `keep_last_n` default ("1")
    /// pre-populated by reading `defaultJSON` at render time.
    @Test
    func numberField() {
        let view = Wrapper(fields: [SnapshotFixtures.numberConfigField()])
        assertViewSnapshots(view, sizes: columnSizes)
    }

    /// Text field — TextField with the `open_tag` default (`<choices>`)
    /// pre-populated. Confirms the JSON-string default-decoding path
    /// surfaces the literal value (not the JSON-quoted form).
    @Test
    func textField() {
        let view = Wrapper(fields: [SnapshotFixtures.textConfigField()])
        assertViewSnapshots(view, sizes: columnSizes)
    }

    /// Textarea field — bordered, multi-line `TextEditor` rendering with
    /// the system-instruction-override (no default — the form shows an
    /// empty editor with the field label and description).
    @Test
    func textareaField() {
        let view = Wrapper(fields: [SnapshotFixtures.textareaConfigField()])
        assertViewSnapshots(view, sizes: columnSizes)
    }

    /// Boolean field, default-on state. Toggle shows "On" because the
    /// field's `defaultJSON: "true"` is honoured at render time.
    @Test
    func booleanFieldOn() {
        let view = Wrapper(fields: [SnapshotFixtures.booleanConfigField()])
        assertViewSnapshots(view, sizes: columnSizes)
    }

    /// Boolean field, off state — explicit `config[name] = false` overrides
    /// the field's "true" default.
    @Test
    func booleanFieldOff() {
        let view = Wrapper(
            fields: [SnapshotFixtures.booleanConfigField()],
            config: ["include_freeform": false]
        )
        assertViewSnapshots(view, sizes: columnSizes)
    }

    /// Select with ≤ 4 options — popover-with-buttons trigger button.
    /// SwiftUI popovers don't render through `NSView.cacheDisplay`'s
    /// offscreen path, so this snapshot captures only the closed
    /// trigger button. The opened popover is a Layer 3 (XCUITest) case.
    /// SKIP: popover doesn't render offscreen
    /// TODO: Layer 3 — assert popover content + checkmark on selection.
    @Test
    func selectFieldShortClosed() {
        let view = Wrapper(fields: [SnapshotFixtures.selectShortConfigField()])
        assertViewSnapshots(view, sizes: columnSizes)
    }

    /// Select with > 4 options — collapsed `Picker(.menu)`. The menu
    /// itself is AppKit chrome that won't render offscreen either, so
    /// the snapshot captures the collapsed pop-up button.
    @Test
    func selectFieldLongCollapsed() {
        let view = Wrapper(fields: [SnapshotFixtures.selectLongConfigField()])
        assertViewSnapshots(view, sizes: columnSizes)
    }

    // MARK: - Composite

    /// All four lettered_choices fields together, in the exact shape
    /// `plugins/lettered_choices.go` registers. Mirrors what users see
    /// when they configure the plugin from the profile form. Locks in
    /// inter-row spacing + the way descriptions wrap.
    @Test
    func letteredChoicesAllFields() {
        let view = Wrapper(fields: SnapshotFixtures.letteredChoicesConfigFields())
        assertViewSnapshots(view, sizes: columnSizes)
    }
}
