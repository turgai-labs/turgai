import Testing
import TurgaiDomain
import TurgaiTelegram

@testable import Turgai

@Test
func terminalSuppressesRateLimitedPreviewRetry() {
    let configuration = TelegramDeliveryConfiguration(
        minimumDraftInterval: .zero,
        maximumRateLimitRetries: 3
    )
    let conversationID = TelegramBot.conversationID(for: 42)
    let turnID = TurnID()
    let now = ContinuousClock.now
    let preview = TelegramDelivery.Preview(
        event: .reply(
            .partial(
                conversationID: conversationID,
                turnID: turnID,
                text: "draft"
            )
        ),
        turnID: turnID
    )
    let terminal = OutboundDelivery(
        event: .reply(
            .finished(
                conversationID: conversationID,
                turnID: turnID,
                text: "done"
            )
        )
    )
    var state = TelegramDelivery.State()

    let firstEffect = TelegramDelivery.reduce(
        &state,
        .previewReceived(preview, at: now),
        configuration: configuration
    )
    #expect(firstEffect.isSendPreview)

    let terminalEffect = TelegramDelivery.reduce(
        &state,
        .terminalReceived(terminal, turnID: turnID, at: now),
        configuration: configuration
    )
    #expect(terminalEffect.isNone)

    let retryEffect = TelegramDelivery.reduce(
        &state,
        .previewRateLimited(
            until: now.advanced(by: .seconds(1)),
            at: now
        ),
        configuration: configuration
    )
    #expect(retryEffect.isSendReliable)

    let terminalSentEffect = TelegramDelivery.reduce(
        &state,
        .reliableSent(at: now),
        configuration: configuration
    )
    #expect(terminalSentEffect.isNone)
}

@Test
func terminalDuringPreviewRetryDoesNotPoisonNextTurn() {
    let configuration = TelegramDeliveryConfiguration(
        minimumDraftInterval: .zero,
        maximumRateLimitRetries: 1
    )
    let conversationID = TelegramBot.conversationID(for: 42)
    let firstTurnID = TurnID()
    let secondTurnID = TurnID()
    let now = ContinuousClock.now
    let firstUntil = now.advanced(by: .seconds(1))
    let secondUntil = now.advanced(by: .seconds(2))
    let firstPreview = TelegramDelivery.Preview(
        event: .reply(
            .partial(
                conversationID: conversationID,
                turnID: firstTurnID,
                text: "first draft"
            )
        ),
        turnID: firstTurnID
    )
    let secondPreview = TelegramDelivery.Preview(
        event: .reply(
            .partial(
                conversationID: conversationID,
                turnID: secondTurnID,
                text: "second draft"
            )
        ),
        turnID: secondTurnID
    )
    let terminal = OutboundDelivery(
        event: .reply(
            .finished(
                conversationID: conversationID,
                turnID: firstTurnID,
                text: "first answer"
            )
        )
    )
    var state = TelegramDelivery.State()

    let firstEffect = TelegramDelivery.reduce(
        &state,
        .previewReceived(firstPreview, at: now),
        configuration: configuration
    )
    #expect(firstEffect.isSendPreview)

    let retryEffect = TelegramDelivery.reduce(
        &state,
        .previewRateLimited(until: firstUntil, at: now),
        configuration: configuration
    )
    #expect(retryEffect.isWait)

    let terminalEffect = TelegramDelivery.reduce(
        &state,
        .terminalReceived(terminal, turnID: firstTurnID, at: now),
        configuration: configuration
    )
    #expect(terminalEffect.isSendReliable)

    _ = TelegramDelivery.reduce(
        &state,
        .reliableSent(at: now),
        configuration: configuration
    )

    let waitFinishedEffect = TelegramDelivery.reduce(
        &state,
        .waitFinished(at: firstUntil),
        configuration: configuration
    )
    #expect(waitFinishedEffect.isNone)

    let nextTurnSendEffect = TelegramDelivery.reduce(
        &state,
        .previewReceived(secondPreview, at: firstUntil),
        configuration: configuration
    )
    #expect(nextTurnSendEffect.isSendPreview)

    let nextTurnRetryEffect = TelegramDelivery.reduce(
        &state,
        .previewRateLimited(until: secondUntil, at: firstUntil),
        configuration: configuration
    )
    #expect(nextTurnRetryEffect.isWait)
}

@Test
func previewRateLimitRetriesAreBounded() {
    let configuration = TelegramDeliveryConfiguration(
        minimumDraftInterval: .zero,
        maximumRateLimitRetries: 1
    )
    let conversationID = TelegramBot.conversationID(for: 42)
    let turnID = TurnID()
    let now = ContinuousClock.now
    let firstUntil = now.advanced(by: .seconds(1))
    let secondUntil = now.advanced(by: .seconds(2))
    let preview = TelegramDelivery.Preview(
        event: .reply(
            .partial(
                conversationID: conversationID,
                turnID: turnID,
                text: "draft"
            )
        ),
        turnID: turnID
    )
    var state = TelegramDelivery.State()

    let firstEffect = TelegramDelivery.reduce(
        &state,
        .previewReceived(preview, at: now),
        configuration: configuration
    )
    #expect(firstEffect.isSendPreview)

    let firstRateLimitEffect = TelegramDelivery.reduce(
        &state,
        .previewRateLimited(until: firstUntil, at: now),
        configuration: configuration
    )
    #expect(firstRateLimitEffect.isWait)

    let retryEffect = TelegramDelivery.reduce(
        &state,
        .waitFinished(at: firstUntil),
        configuration: configuration
    )
    #expect(retryEffect.isSendPreview)

    let exhaustedEffect = TelegramDelivery.reduce(
        &state,
        .previewRateLimited(until: secondUntil, at: firstUntil),
        configuration: configuration
    )
    #expect(exhaustedEffect.isNone)

    let cooldownEffect = TelegramDelivery.reduce(
        &state,
        .previewReceived(preview, at: firstUntil),
        configuration: configuration
    )
    #expect(cooldownEffect.isWait)

    let resumedEffect = TelegramDelivery.reduce(
        &state,
        .waitFinished(at: secondUntil),
        configuration: configuration
    )
    #expect(resumedEffect.isSendPreview)
}

@Test
func previewCooldownDoesNotBlockReliableDelivery() {
    let configuration = TelegramDeliveryConfiguration(
        minimumDraftInterval: .seconds(10),
        maximumRateLimitRetries: 0
    )
    let conversationID = TelegramBot.conversationID(for: 42)
    let turnID = TurnID()
    let now = ContinuousClock.now
    let preview = TelegramDelivery.Preview(
        event: .reply(
            .partial(
                conversationID: conversationID,
                turnID: turnID,
                text: "draft"
            )
        ),
        turnID: turnID
    )
    let notice = OutboundDelivery(
        event: .notice(
            conversationID: conversationID,
            turnID: turnID,
            text: "notice"
        )
    )
    var state = TelegramDelivery.State()

    _ = TelegramDelivery.reduce(
        &state,
        .previewReceived(preview, at: now),
        configuration: configuration
    )
    _ = TelegramDelivery.reduce(
        &state,
        .previewSent(at: now),
        configuration: configuration
    )

    let cooldownEffect = TelegramDelivery.reduce(
        &state,
        .previewReceived(preview, at: now),
        configuration: configuration
    )
    #expect(cooldownEffect.isWait)

    let reliableEffect = TelegramDelivery.reduce(
        &state,
        .requiredReceived(notice, at: now),
        configuration: configuration
    )
    #expect(reliableEffect.isSendReliable)
}

@Test
func exhaustedRateLimitKeepsCooldownForTheLatestPreview() {
    let configuration = TelegramDeliveryConfiguration(
        minimumDraftInterval: .zero,
        maximumRateLimitRetries: 0
    )
    let conversationID = TelegramBot.conversationID(for: 42)
    let turnID = TurnID()
    let now = ContinuousClock.now
    let until = now.advanced(by: .seconds(5))
    let preview = TelegramDelivery.Preview(
        event: .reply(
            .partial(
                conversationID: conversationID,
                turnID: turnID,
                text: "draft"
            )
        ),
        turnID: turnID
    )
    var state = TelegramDelivery.State()

    _ = TelegramDelivery.reduce(
        &state,
        .previewReceived(preview, at: now),
        configuration: configuration
    )
    let cooldownEffect = TelegramDelivery.reduce(
        &state,
        .previewRateLimited(until: until, at: now),
        configuration: configuration
    )
    #expect(cooldownEffect.isNone)

    let newPreviewEffect = TelegramDelivery.reduce(
        &state,
        .previewReceived(preview, at: now),
        configuration: configuration
    )
    #expect(newPreviewEffect.isWait)

    let immediateEffect = TelegramDelivery.reduce(
        &state,
        .waitFinished(at: now),
        configuration: configuration
    )
    #expect(immediateEffect.isWait)

    let resumedEffect = TelegramDelivery.reduce(
        &state,
        .waitFinished(at: until),
        configuration: configuration
    )
    #expect(resumedEffect.isSendPreview)
}

extension TelegramDelivery.Effect {
    fileprivate var isNone: Bool {
        if case .none = self { return true }
        return false
    }

    fileprivate var isSendPreview: Bool {
        if case .sendPreview = self { return true }
        return false
    }

    fileprivate var isSendReliable: Bool {
        if case .sendReliable = self { return true }
        return false
    }

    fileprivate var isWait: Bool {
        if case .wait = self { return true }
        return false
    }
}
