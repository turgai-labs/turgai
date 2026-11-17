import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import Logging
import NIOCore
import ServiceLifecycle
import TurgaiApplication
import TurgaiDomain
import TurgaiHail
import TurgaiPersistence
import TurgaiSpaces
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

enum TurgaiWebSupport {
    static let sessionCookieName = "turgai_auth"
    static let bootstrapChallengeCookieName = "turgai_bootstrap"
    /// The cookie a guest no one signed in as comes back with.
    static let guestCookieName = "turgai_guest"

    /// An error a form didn't expect: logged, and, unless the page is one anyone may open, said
    /// with what failed.
    private static func unexpected(_ error: Error, _ failed: String, shown: Bool = true) -> String {
        logger.error("\(failed)", metadata: ["error": "\(error)"])
        return shown ? "\(failed): \(error)" : failed
    }

    private static let logger = Logger(label: "turgai.web")

    static func storageErrorMessage(_ error: Error) -> String {
        switch error {
        case FormValidationError.invalidValue(let field):
            "Enter a valid \(field)."
        case TurgaiStorageConfigurationError.invalidPostgresURL:
            "PostgreSQL URL must look like postgres://host:5432/database."
        case TurgaiStorageConfigurationError.invalidPostgresUsername:
            "A PostgreSQL username is required."
        default:
            unexpected(error, "Could not save storage configuration")
        }
    }

    static func connectionErrorMessage(_ error: Error) -> String {
        switch error {
        case FormValidationError.invalidValue(let field):
            "Enter a valid \(field)."
        case ConnectionFormError.invalidLabel:
            "Give the connection a label and keep it under \(ConnectionLabel.maximumLength) characters."
        case ChannelSecretStore.Refusal.invalidToken:
            "Enter a bot token or leave the token field empty."
        case let refusal as SpaceRefusal:
            refusal.description
        case ConnectionFormError.unsupportedChannel:
            "Choose a supported kind of connection."
        case TelegramAPIError.httpStatus(401), TelegramAPIError.api(code: 401, message: _):
            "Telegram rejected this bot token. Check it with BotFather and try again."
        case TelegramAPIError.rateLimited:
            "Telegram is temporarily rate-limiting validation. Wait a moment and try again."
        default:
            unexpected(error, "Could not save the connection")
        }
    }

    static func registrationErrorMessage(_ error: Error) -> String {
        switch error {
        case TurgaiAuthError.invalidUsername:
            "Choose a username using letters, numbers, dashes, or underscores."
        case TurgaiAuthError.weakPassword:
            "Choose a password with at least 12 characters."
        case TurgaiAuthError.usernameTaken:
            "That username is already taken."
        default:
            unexpected(error, "Could not create the account. Try again.", shown: false)
        }
    }

    static func accountErrorMessage(_ error: Error) -> String {
        switch error {
        case TurgaiAuthError.unknownUser:
            "That account no longer exists."
        case TurgaiAuthError.accountNotApproved:
            "Keep at least one approved administrator."
        default:
            unexpected(error, "Could not update the account")
        }
    }

    static func profileErrorMessage(_ error: Error) -> String {
        switch error {
        case FormValidationError.invalidValue(let field):
            "Enter a valid \(field)."
        case let refusal as SpaceRefusal:
            refusal.description
        case ModelRefusal.unavailable(let reason):
            reason.sentence
        case ModelRefusal.configuration(.keyNeeded):
            "This provider asks for an API key."
        case ModelRefusal.configuration(.windowAboveModel(_, let model)):
            "This model takes at most \(model.formatted()) tokens: enter a smaller context window."
        case ModelRefusal.configuration(.windowUnknown):
            "How many tokens this model takes isn't known here: enter its context window."
        case is AgentModelError:
            "Enter a valid model."
        default:
            unexpected(error, "Could not save the bot")
        }
    }

    static func userToolErrorMessage(_ error: Error) -> String {
        if let error = error as? UserToolRegistryError {
            return error.description
        }
        if let error = error as? ToolDraftError {
            return error.description
        }
        return "Could not save the tool."
    }

    static func newToolFileName() -> String {
        "tool-\(UUID().uuidString.lowercased()).json"
    }

    static func jsonResponse<T: Encodable>(_ value: T) throws -> Response {
        Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: try JSONEncoder().encode(value)))
        )
    }

    static func authenticatedAdminUser(from request: Request, auth: TurgaiAuth) async -> AuthenticatedUser? {
        guard let account = await authenticatedAccount(from: request, auth: auth),
            account.role == .administrator
        else { return nil }
        return Self.userInfo(from: account)
    }

    static func authenticatedUser(from request: Request, auth: TurgaiAuth) async -> AuthenticatedUser? {
        guard let account = await authenticatedAccount(from: request, auth: auth) else { return nil }
        return Self.userInfo(from: account)
    }

    static func authenticatedDashboardUser(from request: Request, auth: TurgaiAuth) async -> AuthenticatedUser? {
        guard let user = await authenticatedUser(from: request, auth: auth) else { return nil }
        switch user {
        case .user: return nil
        case .member, .administrator: return user
        }
    }

    static func authenticatedAccount(from request: Request, auth: TurgaiAuth) async -> Account? {
        guard let cookie = request.cookies[sessionCookieName],
            let account = try? await auth.authenticate(cookie.value)
        else { return nil }
        return account
    }

    static func userInfo(from account: Account) -> AuthenticatedUser {
        let info = AccountInfo(id: account.id, username: account.username)
        switch account.role {
        case .user: return .user(info)
        case .member: return .member(info)
        case .administrator: return .administrator(info)
        }
    }

    static func accountSummary(from account: Account) -> AccountSummary {
        let role: AccountRole =
            switch account.role {
            case .user: .user
            case .member: .member
            case .administrator: .administrator
            }
        let status: AccountStatus =
            switch account.status {
            case .pending: .pending
            case .approved: .approved
            case .disabled: .disabled
            }
        return AccountSummary(
            info: AccountInfo(id: account.id, username: account.username),
            role: role,
            status: status
        )
    }

    static func botCard(from bot: Bot) -> BotCard {
        BotCard(
            id: bot.id.description,
            name: bot.name.rawValue,
            model: bot.modelIdentifier
        )
    }

    static func sessionCookie(_ token: String) -> Cookie {
        Cookie(
            name: sessionCookieName,
            value: token,
            maxAge: Int(TurgaiAuth.sessionLifetime),
            path: "/",
            httpOnly: true,
            sameSite: .lax
        )
    }

    static func expiredSessionCookie() -> Cookie {
        Cookie(
            name: sessionCookieName,
            value: "",
            expires: Date(timeIntervalSince1970: 0),
            maxAge: 0,
            path: "/",
            httpOnly: true,
            sameSite: .lax
        )
    }

    static func bootstrapChallengeCookie(_ challenge: String) -> Cookie {
        Cookie(
            name: bootstrapChallengeCookieName,
            value: challenge,
            maxAge: Int(TurgaiAuth.bootstrapChallengeLifetime),
            path: "/onboarding/register",
            httpOnly: true,
            sameSite: .strict
        )
    }

    static func expiredBootstrapChallengeCookie() -> Cookie {
        Cookie(
            name: bootstrapChallengeCookieName,
            value: "",
            expires: Date(timeIntervalSince1970: 0),
            maxAge: 0,
            path: "/onboarding/register",
            httpOnly: true,
            sameSite: .strict
        )
    }

    /// The guest `token` is, for a year from each time they come.
    static func guestCookie(_ token: String) -> Cookie {
        Cookie(
            name: guestCookieName,
            value: token,
            maxAge: 31_536_000,
            path: "/",
            httpOnly: true,
            sameSite: .strict
        )
    }

    static func redirect(to location: String, settingCookie cookie: Cookie? = nil) -> Response {
        var response = Response(status: .seeOther, headers: [.location: location])
        if let cookie { response.setCookie(cookie) }
        return response
    }

    static func decodeForm<Context: RequestContext>(from request: Request, context: Context) async throws -> [String:
        [String]]
    {
        let buffer = try await request.body.collect(upTo: context.maxUploadSize)
        let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) ?? Data()
        let body = String(decoding: data, as: UTF8.self).replacing("+", with: "%20")
        guard let components = URLComponents(string: "?\(body)") else { return [:] }
        return components.queryItems?.reduce(into: [String: [String]]()) { result, item in
            result[item.name, default: []].append(item.value ?? "")
        } ?? [:]
    }
}
