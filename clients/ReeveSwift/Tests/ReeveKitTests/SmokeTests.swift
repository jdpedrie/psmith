import Testing
@testable import ReeveKit

@Test
func inMemoryTokenStoreRoundTrip() throws {
    let store = InMemoryTokenStore()
    #expect(try store.load() == nil)
    try store.save("abc123")
    #expect(try store.load() == "abc123")
    try store.clear()
    #expect(try store.load() == nil)
}
