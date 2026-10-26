import Elementary
import Foundation
import Testing

@testable import TurgaiWeb

@Suite("Channels pages")
struct ChannelsPageTests {
    @Test("the list page renders channel metadata")
    func channelsListRenders() {
        let page = ChannelsPage(
            user: .administrator(AccountInfo(id: UUID(), username: "admin")),
            channels: [
                ChannelListItem(
                    id: UUID(),
                    label: "Team Telegram",
                    enabled: true,
                    hasToken: true,
                    botName: "Helper"
                )
            ]
        )

        let html = page.render()

        #expect(html.contains("Channels"))
        #expect(html.contains("Team Telegram"))
        #expect(html.contains("Active"))
        #expect(html.contains("Token set"))
        #expect(html.contains("Helper"))
        #expect(html.contains("/channels/new"))
        #expect(!html.contains("restart"))
        #expect(html.contains("/channels/delete"))
    }

    @Test("the edit page never renders the token value")
    func editPageHidesToken() {
        let token = "123456:super-secret-token"
        let page = ChannelEditPage(
            user: .administrator(AccountInfo(id: UUID(), username: "admin")),
            channel: ChannelDraft(
                id: UUID(),
                label: "Team Telegram",
                enabled: true,
                routing: .profile("helper"),
                chatIDs: "42,-100",
                hasToken: true,
                token: ""
            ),
            bots: [ChannelBotOption(id: "helper", name: "Helper")]
        )

        let html = page.render()

        #expect(!html.contains(token))
        #expect(html.contains("A token is currently set."))
        #expect(html.contains("42,-100"))
        #expect(html.contains("checked"))
        #expect(html.contains("Helper"))
        #expect(html.contains("Default routing"))
        #expect(html.contains("/channels/update"))
        #expect(html.contains("Channel status"))
        #expect(html.contains("Active"))
        #expect(html.contains("starts receiving Telegram updates"))
        #expect(!html.contains("Listen on this channel"))
    }

    @Test("the new page renders the supported channel form")
    func newPageRendersSupportedChannel() {
        let page = NewChannelPage(
            user: .administrator(AccountInfo(id: UUID(), username: "admin"))
        )

        let html = page.render()

        #expect(html.contains("Telegram"))
        #expect(html.contains("name=\"kind\""))
        #expect(html.contains("value=\"telegram\""))
        #expect(html.contains("checked"))
        #expect(!html.contains("WhatsApp"))
        #expect(!html.contains("Discord"))
        #expect(html.contains("Label"))
        #expect(html.contains("/channels/create"))
    }
}
