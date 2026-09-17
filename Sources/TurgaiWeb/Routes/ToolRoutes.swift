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
    func registerToolRoutes(on router: Router<BasicRequestContext>, dependencies: TurgaiRouteDependencies) {
        let auth = dependencies.auth
        let userToolRegistry = dependencies.userToolRegistry
        router.get("/tools") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            return HTMLResponse {
                TurgaiToolsPage(
                    user: user,
                    documents: userToolRegistry.documents()
                )
            }.response(from: request, context: context)
        }
        router.get("/tools/new") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            return HTMLResponse {
                TurgaiToolEditorPage(
                    user: user,
                    draft: TurgaiToolDraft.new(fileName: TurgaiWebSupport.newToolFileName())
                )
            }.response(from: request, context: context)
        }
        router.get("/tools/:file") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
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
        router.post("/tools/save") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
                return TurgaiWebSupport.redirect(to: await auth.hasAdmin() ? "/login" : "/onboarding")
            }
            let form = try await TurgaiWebSupport.decodeForm(from: request, context: context)
            let isNew = form["isNew"]?.first == "true"
            let submittedFileName = form["fileName"]?.first ?? ""
            let fileName =
                isNew
                ? TurgaiWebSupport.newToolFileName()
                : submittedFileName
            let draft = TurgaiToolDraft(form: form, fileName: fileName, isNew: isNew)
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
        router.post("/tools/delete") { request, context in
            guard let user = await TurgaiWebSupport.authenticatedUser(from: request, auth: auth) else {
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
