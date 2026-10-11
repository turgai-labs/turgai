import Hail
import TurgaiApplication

/// Changes only the introduction of the objects page; its links and every other page remain identical.
struct EvalPages: Pages {
    let base: ObjectSession
    let introduction: String?

    func open(_ address: PageAddress) async throws(PageUnavailable) -> Page {
        var page = try await base.open(address)
        if address == ObjectTools.link.address, let introduction,
            case .text(let text) = page.output, text.hasPrefix(ObjectTools.description)
        {
            page.output = .text(introduction + text.dropFirst(ObjectTools.description.count))
        }
        return page
    }
}
