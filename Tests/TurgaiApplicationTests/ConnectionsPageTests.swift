import Elementary
import Foundation
import Testing
import TurgaiDomain
import TurgaiSpaces

@testable import TurgaiWeb

/// A space's connection pages: under the space, each with the space's tabs.
@Suite("Connections pages")
struct ConnectionsPageTests {
    private let user = AuthenticatedUser.administrator(AccountInfo(id: UUID(), username: "admin"))
    private let family = SpaceListing(
        id: SpaceID(), name: SpaceName("Family")!, status: .active, permissions: .all)
    private var path: String { "/spaces/\(family.id.rawValue.uuidString)/connections" }

    @Test("the list page renders each connection under its space")
    func connectionsListRenders() {
        let connection = ConnectionID()
        let html = ConnectionsPage(
            user: user, space: family,
            connections: [
                ConnectionListItem(
                    id: connection, label: "Team Telegram", enabled: true, hasToken: true, stopped: nil)
            ]
        ).render()

        #expect(html.contains("Connections"))
        #expect(html.contains("Family"))
        #expect(html.contains("Team Telegram"))
        #expect(html.contains("Active"))
        #expect(html.contains("Token set"))
        #expect(html.contains(path + "/new"))
        #expect(html.contains(path + "/\(connection)/delete"))
        #expect(!html.contains("/channels"))
    }

    @Test("the edit page never renders the token value")
    func editPageHidesToken() {
        let token = "123456:super-secret-token"
        let html = ConnectionEditPage(
            user: user, space: family,
            connection: ConnectionDraft(
                id: ConnectionID(), label: "Team Telegram", enabled: true, chatIDs: "42,-100", hasToken: true,
                token: "")
        ).render()

        #expect(!html.contains(token))
        #expect(html.contains("A token is currently set."))
        #expect(html.contains("42,-100"))
        #expect(html.contains("checked"))
        #expect(html.contains("Family"))
        #expect(html.contains("/update"))
        #expect(html.contains("starts receiving Telegram updates"))
    }

    @Test("the new page renders the supported connection form, for its space")
    func newPageRendersSupportedConnection() {
        let html = NewConnectionPage(user: user, space: family).render()

        #expect(html.contains("Family"))
        #expect(html.contains("Telegram"))
        #expect(html.contains("name=\"kind\""))
        #expect(html.contains("value=\"telegram\""))
        #expect(!html.contains("name=\"space\""))
        #expect(html.contains("Label"))
        #expect(html.contains(path + "/create"))
    }
}
