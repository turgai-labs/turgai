import Foundation

/// A small in-memory BM25F index for object discovery. Fields keep their own length
/// normalization, so a long description does not drown out a short matching action or title.
struct ObjectSearchIndex {
    struct Document {
        let handle: String
        let title: String
        let actions: String
        let description: String
    }

    private struct IndexedDocument {
        let document: Document
        let fields: [[String: Int]]
        let lengths: [Int]
    }

    private let documents: [IndexedDocument]
    private let averages: [Double]
    private let documentFrequency: [String: Int]
    private let vocabulary: Set<String>

    /// Handle/title, actions, description. Identity is strongest; behavior comes next.
    private static let weights = [3.0, 2.0, 1.0]
    private static let k1 = 1.2
    private static let b = 0.75
    private static let shortestPrefix = 3

    init(_ documents: [Document]) {
        var frequency: [String: Int] = [:]
        var totals = Array(repeating: 0, count: Self.weights.count)
        self.documents = documents.map { document in
            let texts = [document.handle + " " + document.title, document.actions, document.description]
            let tokens = texts.map(Self.tokens)
            for term in Set(tokens.flatMap { $0 }) { frequency[term, default: 0] += 1 }
            for index in totals.indices { totals[index] += tokens[index].count }
            return IndexedDocument(
                document: document,
                fields: tokens.map { Dictionary($0.map { ($0, 1) }, uniquingKeysWith: +) },
                lengths: tokens.map(\.count))
        }
        self.averages = totals.map { documents.isEmpty ? 0 : Double($0) / Double(documents.count) }
        self.documentFrequency = frequency
        self.vocabulary = Set(frequency.keys)
    }

    func search(_ query: String, limit: Int) -> [Document] {
        let queryTerms = Set(Self.tokens(query))
        guard !queryTerms.isEmpty, !documents.isEmpty else { return [] }
        let expanded = queryTerms.flatMap { query -> [(term: String, factor: Double)] in
            if vocabulary.contains(query) { return [(query, 1)] }
            // Only words long enough to mean something stand for longer ones: "a" isn't "and",
            // and the "s" of "it's" isn't "set".
            guard query.count >= Self.shortestPrefix else { return [] }
            return vocabulary.compactMap { term in
                guard term.count >= Self.shortestPrefix else { return nil }
                return term.hasPrefix(query) || query.hasPrefix(term) ? (term, 0.7) : nil
            }
        }
        guard !expanded.isEmpty else { return [] }

        let count = Double(documents.count)
        return documents.compactMap { indexed -> (IndexedDocument, Double)? in
            var score = 0.0
            for (term, factor) in expanded {
                var weightedFrequency = 0.0
                for field in indexed.fields.indices {
                    guard let occurrences = indexed.fields[field][term] else { continue }
                    let average = max(averages[field], 1)
                    let normalization = 1 - Self.b + Self.b * Double(indexed.lengths[field]) / average
                    weightedFrequency += Self.weights[field] * Double(occurrences) / normalization
                }
                guard weightedFrequency > 0, let seen = documentFrequency[term] else { continue }
                let idf = log(1 + (count - Double(seen) + 0.5) / (Double(seen) + 0.5))
                score += factor * idf * weightedFrequency * (Self.k1 + 1) / (weightedFrequency + Self.k1)
            }

            let normalizedQuery = queryTerms.sorted().joined(separator: " ")
            let handle = Set(Self.tokens(indexed.document.handle)).sorted().joined(separator: " ")
            let title = Set(Self.tokens(indexed.document.title)).sorted().joined(separator: " ")
            if normalizedQuery == handle || normalizedQuery == title { score += 100 }
            return score > 0 ? (indexed, score) : nil
        }
        .sorted {
            $0.1 == $1.1 ? $0.0.document.handle < $1.0.document.handle : $0.1 > $1.1
        }
        .prefix(limit)
        .map(\.0.document)
    }

    static func tokens(_ text: String) -> [String] {
        var separated = ""
        for character in text {
            if character.isUppercase, separated.last?.isLowercase == true { separated.append(" ") }
            separated.append(character.isLetter || character.isNumber ? character : " ")
        }
        return separated.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
