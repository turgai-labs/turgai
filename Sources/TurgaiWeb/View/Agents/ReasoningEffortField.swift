import Elementary
import Hail

/// Picks how hard the model reasons: the provider's default, or one level.
struct ReasoningEffortField: HTML, Sendable {
    /// The chosen level's name: empty is the provider's default.
    let selected: String

    private static let efforts: [ReasoningEffort] = [.none, .minimal, .low, .medium, .high, .xhigh, .max]

    var body: some HTML {
        label(.class("form-field")) {
            span(.class("field-label")) { "Reasoning effort" }
            select(.name("reasoningEffort")) {
                Choice(value: "", label: "Provider default", isSelected: selected.isEmpty)
                for effort in Self.efforts {
                    Choice(value: effort.rawValue, label: effort.rawValue, isSelected: selected == effort.rawValue)
                }
            }
            p(.class("hint")) { "Leave it at provider default unless this model supports a specific level." }
        }
    }

    /// One option, selected when it's the profile's.
    private struct Choice: HTML, Sendable {
        let value: String
        let label: String
        let isSelected: Bool

        var body: some HTML {
            if isSelected {
                option(.value(value), .selected) { label }
            } else {
                option(.value(value)) { label }
            }
        }
    }
}
