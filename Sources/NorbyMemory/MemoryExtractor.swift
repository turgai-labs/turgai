import Foundation

/// A small deterministic extractor for the first memory slice.
///
/// Extraction is deliberately a pure value transformation. It proposes
/// candidates; ``MemoryPolicy`` remains responsible for deciding whether a
/// proposal becomes durable. A model-backed extractor can replace or extend
/// this value later without changing the memory journal.
public enum MemoryExtractor {
    public static func extract(from observation: MemoryObservation) -> [FactCandidate] {
        let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        var candidates: [FactCandidate] = []

        if let value = value(after: "my name is", in: text) {
            candidates.append(
                FactCandidate(
                    namespace: .profile,
                    predicate: "name",
                    value: .person(value),
                    evidence: [observation.id],
                    confidence: 0.98,
                    importance: 0.95,
                    stability: .stable,
                    observedAt: observation.observedAt
                )
            )
        }

        if let value = value(after: "i live in", in: text)
            ?? value(after: "i'm living in", in: text)
        {
            candidates.append(
                FactCandidate(
                    namespace: .profile,
                    predicate: "home",
                    value: .place(value),
                    evidence: [observation.id],
                    confidence: 0.94,
                    importance: 0.85,
                    stability: .mutable,
                    observedAt: observation.observedAt
                )
            )
        }

        if let value = value(after: "i like", in: text)
            ?? value(after: "i love", in: text)
            ?? value(after: "i prefer", in: text)
        {
            candidates.append(
                FactCandidate(
                    namespace: .preference,
                    predicate: "likes",
                    value: .text(value),
                    evidence: [observation.id],
                    confidence: 0.86,
                    importance: 0.55,
                    stability: .situational,
                    observedAt: observation.observedAt
                )
            )
        }

        return candidates
    }

    private static func value(after prefix: String, in text: String) -> String? {
        let lowercased = text.lowercased()
        guard lowercased.hasPrefix(prefix) else { return nil }

        let start = text.index(text.startIndex, offsetBy: prefix.count)
        let value = text[start...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.isEmpty, value.count <= 160 else { return nil }
        return value
    }
}
