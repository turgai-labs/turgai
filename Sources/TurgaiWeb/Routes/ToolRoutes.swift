import Elementary
import Hail
import Hummingbird
import HummingbirdElementary
import HummingbirdWebSocket
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
    func registerToolRoutes(on router: Router<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies) {
        registerTools(on: router.group("tools"), dependencies: dependencies)
    }

    /// The tools: making one, changing it, and removing it.
    private func registerTools(
        on tools: RouterGroup<BasicWebSocketRequestContext>, dependencies: TurgaiRouteDependencies
    ) {
        let auth = dependencies.auth
        let userToolRegistry = dependencies.userToolRegistry
        tools.get { request, context in
            guard let user = await TurgaiWebSupport.authenticatedDashboardUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            return HTMLResponse {
                TurgaiToolsPage(
                    user: user,
                    documents: userToolRegistry.documents()
                )
            }.response(from: request, context: context)
        }

        tools.get("new") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            return HTMLResponse {
                TurgaiToolEditorPage(
                    user: user,
                    draft: TurgaiToolDraft.new(fileName: TurgaiWebSupport.newToolFileName())
                )
            }.response(from: request, context: context)
        }

        tools.get(":file") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedDashboardUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            guard let fileName = context.parameters.get("file"),
                let document = userToolRegistry.document(named: fileName)
            else {
                return TurgaiWebSupport.redirect(to: "/tools")
            }
            return HTMLResponse {
                TurgaiToolEditorPage(
                    user: user,
                    draft: TurgaiToolDraft(document: document),
                    issue: document.issue
                )
            }.response(from: request, context: context)
        }

        tools.post("save") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let draftKind: ToolDraftKind = form["isNew"]?.first == "true" ? .new : .existing
            let submittedFileName = form["fileName"]?.first ?? ""
            let fileName: String
            switch draftKind {
            case .new: fileName = TurgaiWebSupport.newToolFileName()
            case .existing: fileName = submittedFileName
            }
            let draft = TurgaiToolDraft(form: form, fileName: fileName, kind: draftKind)
            do {
                try userToolRegistry.save(
                    named: fileName,
                    contents: try draft.encodedDefinition()
                )
                return TurgaiWebSupport.redirect(to: "/tools")
            } catch {
                return HTMLResponse {
                    TurgaiToolEditorPage(
                        user: user,
                        draft: draft,
                        error: TurgaiWebSupport.userToolErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }

        tools.post("delete") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedAdminUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let fileName = form["fileName"]?.first ?? ""
            do {
                try userToolRegistry.delete(named: fileName)
                return TurgaiWebSupport.redirect(to: "/tools")
            } catch {
                return HTMLResponse {
                    TurgaiToolsPage(
                        user: user,
                        documents: userToolRegistry.documents(),
                        error: TurgaiWebSupport.userToolErrorMessage(error)
                    )
                }.response(from: request, context: context)
            }
        }
    }
}
