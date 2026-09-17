import AnyLanguageModel
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

struct SetupFooter: HTML, Sendable {
    let step: Int?
    let backHref: String?
    let forwardHref: String?
    let forwardLabel: String?
    let submitFormID: String?
    let submitLabel: String?

    init(
        step: Int?,
        backHref: String? = nil,
        forwardHref: String? = nil,
        forwardLabel: String? = nil,
        submitFormID: String? = nil,
        submitLabel: String? = nil
    ) {
        self.step = step
        self.backHref = backHref
        self.forwardHref = forwardHref
        self.forwardLabel = forwardLabel
        self.submitFormID = submitFormID
        self.submitLabel = submitLabel
    }

    var body: some HTML {
        nav(.class("setup-footer")) {
            div(.class("setup-footer-actions")) {
                if let backHref {
                    SetupArrow(href: backHref, label: "Back", isBack: true)
                } else {
                    span(.class("setup-footer-spacer")) {}
                }
                if let forwardHref, let forwardLabel {
                    SetupArrow(href: forwardHref, label: forwardLabel, isBack: false)
                } else if let submitFormID, let submitLabel {
                    SetupSubmit(formID: submitFormID, label: submitLabel)
                }
            }
            if let step { SetupProgress(step: step) }
        }
    }
}
