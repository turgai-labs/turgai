import ComposableArchitecture
import Foundation
import TurgaiModels

/// Which object's card a window shows: the space it's in, and the handle it's listed by.
struct ObjectCardAddress: Codable, Hashable, Sendable {
    let space: SpaceID
    let handle: String
}

/// One object's card, in a window of its own: what it is, its YAML and its Swift, once it's had.
@Reducer
struct ObjectCardFeature {
    @ObservableState
    struct State: Equatable {
        enum Content: Equatable {
            case loading
            case shown([CardBlock])
            case missing
        }

        let address: ObjectCardAddress
        var content = Content.loading
    }

    /// A part of a card, in the order it says them: a heading, some text, or a block of code.
    enum CardBlock: Equatable {
        case heading(String)
        case text(String)
        case code(language: String, String)
    }

    enum Action {
        /// The window appeared: its card is asked for.
        case appeared
        case loaded(ObjectCard)
        case missing
    }

    @Dependency(\.objects) var objects

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .appeared:
                let address = state.address
                return .run { send in
                    do {
                        await send(.loaded(try await objects.card(address.space, address.handle)))
                    } catch {
                        await send(.missing)
                    }
                }

            case .loaded(let card):
                state.content = .shown(Self.blocks(of: card.markdown))
                return .none

            case .missing:
                state.content = .missing
                return .none
            }
        }
    }
}

extension ObjectCardFeature {
    /// A card's Markdown as its parts: `#` headings, fenced blocks of code with their language, and
    /// the text between them, a paragraph at a time.
    static func blocks(of markdown: String) -> [CardBlock] {
        var blocks: [CardBlock] = []
        var code: (language: String, lines: [String])?
        var text: [String] = []
        func endText() {
            let paragraph = text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !paragraph.isEmpty { blocks.append(.text(paragraph)) }
            text = []
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let open = code {
                if line.hasPrefix("```") {
                    blocks.append(.code(language: open.language, open.lines.joined(separator: "\n")))
                    code = nil
                } else {
                    code?.lines.append(line)
                }
            } else if line.hasPrefix("```") {
                endText()
                code = (String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])
            } else if line.hasPrefix("# ") {
                endText()
                blocks.append(.heading(String(line.dropFirst(2))))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                endText()
            } else {
                text.append(line)
            }
        }
        endText()
        if let open = code { blocks.append(.code(language: open.language, open.lines.joined(separator: "\n"))) }
        return blocks
    }
}
