import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import HummingbirdWebSocket
import NIOCore
import TurgaiApplication
import TurgaiDomain
import TurgaiHail
import TurgaiModels
import TurgaiPersistence
import TurgaiSpaces
import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

extension TurgaiMainWebApp {
    func registerCoreRoutes(on router: Router<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies) {
        let auth = dependencies.auth
        let system = dependencies.system
        // The spaces the person is in, each as they see it.
        router.get { request, context in
            guard let account = await TurgaiWebSupport.authenticatedAccount(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: "/login")
            }
            let user = TurgaiWebSupport.userInfo(from: account)
            let person = TurgaiDomain.UserID.account(account.id)
            var spaces: [SpaceListing] = []
            for id in try await system.singleton.proxy(SpaceDirectory.self, name: SpaceDirectory.singletonName)
                .spaces(of: person)
            {
                if let listing = try await Space.identified(by: id, on: system).listing(for: person) {
                    spaces.append(listing)
                }
            }
            let shown = spaces.sorted { $0.name.rawValue < $1.name.rawValue }
            return HTMLResponse { SpacesPage(user: user, spaces: shown) }.response(from: request, context: context)
        }
        // Public: lets a client such as the Mac app wait for setup before opening chat. Turgai
        // answering at all is it set up and running.
        router.get("/api/v1/status") { _, _ in
            try TurgaiWebSupport.jsonResponse(TurgaiServerStatus(setup: .complete))
        }
    }
}
