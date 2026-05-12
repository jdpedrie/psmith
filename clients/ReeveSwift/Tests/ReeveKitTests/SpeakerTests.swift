import Foundation
import Testing
@testable import ReeveKit

/// Pure-function tests for the speech sanitiser. Audio playback itself
/// is system-driven (`AVSpeechSynthesizer`) and not unit-testable from
/// here — the sanitiser is the only Reeve-owned logic in `Speaker`.
@Suite("Speaker.sanitiseForSpeech")
struct SpeakerSanitiserTests {

    @Test
    func dropsCodeFences() {
        let input = "Here is some code:\n```swift\nlet x = 1\n```\nDone."
        let out = Speaker.sanitiseForSpeech(input)
        #expect(out.contains("(code block)"))
        #expect(!out.contains("```"))
        #expect(!out.contains("let x = 1"))
    }

    @Test
    func stripsInlineBackticks() {
        let out = Speaker.sanitiseForSpeech("Use the `foo` function.")
        #expect(out == "Use the foo function.")
    }

    @Test
    func reducesMarkdownLinkToLabel() {
        let out = Speaker.sanitiseForSpeech("See [the docs](https://example.com) for more.")
        #expect(out == "See the docs for more.")
    }

    @Test
    func replacesBareURLsWithLink() {
        let out = Speaker.sanitiseForSpeech("Visit https://example.com/page now.")
        #expect(out.contains("(link)"))
        #expect(!out.contains("example.com"))
    }

    @Test
    func stripsHeadingAndBulletLeaders() {
        let input = """
        # Big heading
        ## Smaller
        - first
        * second
        > quoted
        """
        let out = Speaker.sanitiseForSpeech(input)
        #expect(!out.contains("# "))
        #expect(!out.contains("## "))
        #expect(!out.contains("- "))
        #expect(!out.contains("* "))
        #expect(!out.contains("> "))
        #expect(out.contains("Big heading"))
        #expect(out.contains("first"))
    }

    @Test
    func plainTextIsUnchanged() {
        let input = "Just a normal sentence with no markdown."
        #expect(Speaker.sanitiseForSpeech(input) == input)
    }
}
