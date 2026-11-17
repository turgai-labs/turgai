import Testing
import TurgaiCalls
import TurgaiDomain

@testable import TurgaiObjects

@Suite("Who may read and write an object")
struct AccessTests {
    private let family = SpaceID()
    private var dad: CallScope { CallScope.admin(UserID.dad, in: family) }
    private var mom: CallScope { CallScope.admin(UserID.mom, in: family) }
    private var kid: CallScope { CallScope.member(UserID.kid, in: family) }

    @Test
    func aNewObjectIsItsMakersAlone() {
        let access = Access(madeBy: dad)

        #expect(access.allows(dad, .write))
        #expect(!access.allows(mom, .read))
        #expect(!access.allows(kid, .read))
        // In another chat, still his.
        #expect(
            access.allows(CallScope.member(UserID.dad, in: SpaceID()), .write))
    }

    @Test
    func sharedWithTheMembersTheyReadAndItsDecidersWrite() {
        let access = Access(madeBy: dad)
            .sharing(with: .group(family, .members), .read)
            .sharing(with: .deciders(of: family), .write)

        #expect(access.allows(kid, .read))
        #expect(!access.allows(kid, .write))
        #expect(access.allows(mom, .write))
        // Someone not in the family's chat, for that call, isn't in it.
        #expect(
            !access.allows(CallScope.member(UserID.kid, in: SpaceID()), .read))
    }

    @Test
    func onlyWhoMayWriteItShares() throws {
        var object = DynamicObjectState.unmade
        object = object.applying(
            try object.adopting(
                BehaviorID(rawValue: "List"), try Script(code: "actor List {}", type: "List"), starts: [:],
                by: .start(dad, in: nil)))

        #expect(throws: NotAllowed(.write)) {
            try object.live.sharing(with: .group(family, .members), .read, by: .start(kid, in: nil))
        }
        object = object.applying(
            try object.live.sharing(with: .group(family, .members), .read, by: .start(dad, in: nil)))
        #expect(try object.live.access.allows(kid, .read))
    }

    @Test
    func anObjectNotMadeYetIsTheCallersToMake() throws {
        let object = DynamicObjectState.unmade

        #expect(object.access(for: .start(kid, in: nil)).allows(kid, .write))
        #expect(!object.access(for: .start(kid, in: nil)).allows(dad, .read))
        // Whoever gives it code first is its maker.
        let made = object.applying(
            try object.adopting(
                BehaviorID(rawValue: "List"), try Script(code: "actor List {}", type: "List"), starts: [:],
                by: .start(kid, in: nil)))
        #expect(try made.live.maker == kid)
        #expect(!made.access(for: .start(dad, in: nil)).allows(dad, .read))
    }
}
