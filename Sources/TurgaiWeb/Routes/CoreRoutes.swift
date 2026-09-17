import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import NIOCore
import TurgaiApplication
import TurgaiHail
import TurgaiPersistence
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

extension TurgaiMainWebApp {
    func registerCoreRoutes(on router: Router<BasicRequestContext>, dependencies: TurgaiRouteDependencies) {
        let auth = dependencies.auth
        let setup = dependencies.setup
        let agentProfiles = dependencies.agentProfiles
        let runtimeSnapshots = dependencies.runtimeSnapshots
        router.get { request, context in
            guard await auth.hasAdmin() else {
                return TurgaiWebSupport.redirect(to: "/onboarding")
            }
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: "/login")
            }
            let isComplete = await setup.isComplete
            let isReady = await setup.isReady
            let hasDefaultProfile = await agentProfiles.defaultProfile() != nil
            if isComplete && isReady && hasDefaultProfile {
                let profiles = await agentProfiles.profiles()
                let runtime = await runtimeSnapshots()
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
        router.get("/api/agents") { request, _ in
            guard await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) != nil else {
                return Response(status: .unauthorized)
            }
            let profiles = await agentProfiles.profiles()
            let runtime = await runtimeSnapshots()
            return try TurgaiWebSupport.jsonResponse(
                TurgaiDashboardSnapshot(
                    profiles: profiles.map {
                        BotSummary(
                            id: $0.id,
                            name: $0.name,
                            model: $0.model.identifier,
                            enabled: $0.enabled
                        )
                    },
                    runtime: runtime
                )
            )
        }
    }
}
