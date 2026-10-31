import Foundation
import Testing
import TurgaiApplication
import TurgaiDomain
import TurgaiPeople

@Suite("Linking persons")
struct PersonLinkingTests {
    private let account = UserID.account(UUID())

    /// A code links whoever enters it with whoever asked for it, once.
    @Test func aCodeLinksOnce() async throws {
        let linking = PersonLinking(storage: .test)
        let code = try await linking.code(for: .ann)

        #expect(try await linking.link(account, using: code) == .ann)
        #expect(try await linking.linked(to: account) == [.ann])
        #expect(try await linking.linked(to: .ann) == [account])
        await #expect(throws: PersonLinkingError.codeDoesNotWork) {
            try await linking.link(.bob, using: code)
        }
    }

    /// A code works for a while, and one asked for again replaces the one before.
    @Test func aCodeWorksForAWhile() async throws {
        let linking = PersonLinking(storage: .test)
        let start = Date(timeIntervalSince1970: 1_000)
        let old = try await linking.code(for: .ann, now: start)
        let expired = try await linking.code(for: .bob, now: start)
        let new = try await linking.code(for: .ann, now: start)

        await #expect(throws: PersonLinkingError.codeDoesNotWork) {
            try await linking.link(account, using: old, now: start)
        }
        await #expect(throws: PersonLinkingError.codeDoesNotWork) {
            try await linking.link(account, using: expired, now: start.addingTimeInterval(PersonLinking.codeLifetime + 1))
        }
        #expect(try await linking.link(account, using: new, now: start) == .ann)
    }

    /// A guest stays a guest: they neither ask for a code nor enter one.
    @Test func aGuestLinksToNoOne() async throws {
        let linking = PersonLinking(storage: .test)
        let guest = UserID.guest(UUID())
        await #expect(throws: PersonLinkingError.guestsDontLink) { try await linking.code(for: guest) }
        let code = try await linking.code(for: .ann)
        await #expect(throws: PersonLinkingError.guestsDontLink) { try await linking.link(guest, using: code) }
    }

    /// Links chain, so a human's every way in is linked to the rest; unlinking one leaves the others.
    @Test func linksChain() async throws {
        let linking = PersonLinking(storage: .test)
        _ = try await linking.link(account, using: try await linking.code(for: .ann))
        _ = try await linking.link(.bob, using: try await linking.code(for: .ann))

        #expect(try await linking.linked(to: account) == [.ann, .bob].sorted { $0.key < $1.key })
        #expect(try await linking.pairedWith(account) == [.ann])

        try await linking.unlink(.ann, from: .bob)
        #expect(try await linking.linked(to: account) == [.ann])
        #expect(try await linking.linked(to: .bob) == [])
    }
}
