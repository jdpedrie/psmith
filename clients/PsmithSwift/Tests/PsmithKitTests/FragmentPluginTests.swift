import Foundation
import Testing
@testable import PsmithKit

@Suite("Fragment author")
struct FragmentPluginTests {
    @Test
    func carriesThePluginFromTheWire() {
        var p = Psmith_V1_UIFragment()
        p.component = "choice_list"
        p.plugin = "context_packs"
        #expect(PsmithUIFragment(from: p).plugin == "context_packs")
        p.plugin = ""
        #expect(PsmithUIFragment(from: p).plugin == nil)
    }

    @Test
    func decodesACachedFragmentWithoutOne() throws {
        let old = #"{"component":"text","props":"e30=","key":""}"#
        let f = try JSONDecoder().decode(PsmithUIFragment.self, from: Data(old.utf8))
        #expect(f.plugin == nil)
    }
}
