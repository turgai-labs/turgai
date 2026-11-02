import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import HummingbirdWebSocket
import NIOCore
import TurgaiApplication
import TurgaiHail
import TurgaiModels
import TurgaiPersistence
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

extension TurgaiMainWebApp {
    func registerCoreRoutes(on router: Router<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies) {
        let auth = dependencies.auth
        let setup = dependencies.setup
        let agentProfiles = dependencies.agentProfiles
        let runtimeSnapshots = dependencies.runtimeSnapshots
        router.get { request, context in
            guard try await auth.hasAdmin() else {
                return TurgaiWebSupport.redirect(to: "/onboarding")
            }
            guard let user = await TurgaiWebSupport.authenticatedDashboardUser(from: request, auth: auth) else {
                if let account = await TurgaiWebSupport.authenticatedAccount(from: request, auth: auth),
                    account.role == .user
                {
                    return TurgaiWebSupport.redirect(to: "/chat")
                }
                return TurgaiWebSupport.redirect(to: "/login")
            }
            let isComplete = await setup.isComplete
            let isReady = await setup.isReady
            let hasDefaultProfile = try await agentProfiles.defaultProfile() != nil
            if isComplete && isReady && hasDefaultProfile {
                let profiles = try await agentProfiles.profiles()
                let runtime = await runtimeSnapshots(.account(user.id))
                return HTMLResponse {
                    TurgaiPage(
                        title: "Turgai",
                        user: user,
                        profiles: profiles.map(TurgaiWebSupport.botCard),
                        runtime: runtime
                    )
                }.response(from: request, context: context)
            }
            return TurgaiWebSupport.redirect(to: "/onboarding/model")
        }
        // Public: lets a client such as the Mac app wait for setup before opening chat.
        router.get("/api/v1/status") { _, _ in
            let hasAdmin = try await auth.hasAdmin()
            let isComplete = await setup.isComplete
            let isReady = await setup.isReady
            let hasDefaultProfile = try await agentProfiles.defaultProfile() != nil
            let complete = hasAdmin && isComplete && isReady && hasDefaultProfile
            return try TurgaiWebSupport.jsonResponse(TurgaiServerStatus(setup: complete ? .complete : .pending))
        }
        router.get("/api/agents") { request, _ in
            guard let user = await TurgaiWebSupport.authenticatedDashboardUser(from: request, auth: auth) else {
                return Response(status: .unauthorized)
            }
            let profiles = try await agentProfiles.profiles()
            let runtime = await runtimeSnapshots(.account(user.id))
            return try TurgaiWebSupport.jsonResponse(
                TurgaiDashboardSnapshot(
                    profiles: profiles.map {
                        BotSummary(
                            id: $0.id,
                            name: $0.name,
                            model: $0.model.identifier,
                            availability: $0.availability
                        )
                    },
                    runtime: runtime
                )
            )
        }
    }
}
