import Testing
import TurgaiDomain

@testable import TurgaiObjects

@Suite("Who may read and write an object")
struct AccessTests {
    private let family = GroupID(rawValue: "family")
    private var dad: CallScope { .person(UserID("dad"), in: family, as: .admin) }
    private var mom: CallScope { .person(UserID("mom"), in: family, as: .admin) }
    private var kid: CallScope { .person(UserID("kid"), in: family, as: .member) }

    @Test
    func aNewObjectIsItsMakersAlone() {
        let access = ObjectAccess(madeBy: dad)

        #expect(access.allows(dad, .write))
        #expect(!access.allows(mom, .read))
        #expect(!access.allows(kid, .read))
        // In another chat, still his.
        #expect(access.allows(.person(UserID("dad"), in: GroupID(rawValue: "work"), as: .member), .write))
    }

    @Test
    func sharedWithTheFamilyItsMembersReadAndItsAdminsWrite() {
        let access = ObjectAccess(madeBy: dad)
            .sharing(with: .group(family), .read)
            .sharing(with: .admins(of: family), .write)

        #expect(access.allows(kid, .read))
        #expect(!access.allows(kid, .write))
        #expect(access.allows(mom, .write))
        // Someone not in the family's chat, for that call, isn't in it.
        #expect(!access.allows(.person(UserID("kid"), in: GroupID(rawValue: "school"), as: .member), .read))
    }

    @Test
    func whatTurgaiMakesIsEveryonesToRead() {
        let access = ObjectAccess(madeBy: .runtime)

        #expect(access.allows(kid, .read))
        #expect(!access.allows(kid, .write))
        #expect(access.allows(.runtime, .write))
    }

    @Test
    func onlyWhoMayWriteItShares() throws {
        var object = LiveObject()
        object = object.applying(
            .adopted(
                BehaviorID(rawValue: "List"), try Script(code: "actor List {}", type: "List"), starts: [:], by: dad))

        #expect(throws: DynamicObjectError.notAllowed(.write)) {
            try object.sharing(with: .group(family), .read, by: kid)
        }
        object = object.applying(try object.sharing(with: .group(family), .read, by: dad))
        #expect(object.access?.allows(kid, .read) == true)
    }
}
