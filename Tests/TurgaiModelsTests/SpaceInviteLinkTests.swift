import Foundation
import Testing

@testable import TurgaiModels

struct SpaceInviteLinkTests {
    /// A pasted invite link is read once into its space and token; anything else isn't one.
    @Test
    func anInviteLinkIsReadIntoItsSpaceAndToken() {
        let space = "8F3C1E2A-4B5D-4E6F-8A9B-0C1D2E3F4A5B"
        let link = SpaceInviteLink("  turgai://join/\(space)/abc123\n")
        #expect(link == SpaceInviteLink(spaceID: SpaceID(rawValue: space), token: "abc123"))
        #expect(link?.description == "turgai://join/\(space)/abc123")
        #expect(SpaceInviteLink("https://join/\(space)/abc123") == nil)
        #expect(SpaceInviteLink("turgai://join/family/abc123") == nil)
        #expect(SpaceInviteLink("turgai://join/\(space)/") == nil)
        #expect(SpaceInviteLink("turgai://join/\(space)/abc/def") == nil)
    }
}
