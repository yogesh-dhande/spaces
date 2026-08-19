import Foundation

/// Token-based fuzzy matcher shared by every Spaces client surface that searches text: the Mac's
/// command palette, the Mac's Workspaces dialog, the iOS Workspaces sheet, and the iOS Spaces tab's
/// live search. It lives here rather than in a client target so all of them rank and match identically.
///
/// `match` answers whether one candidate's fields match (and how well); `rank` orders a set of
/// candidates by that score. A surface the user reads structurally uses `match` as a predicate and
/// keeps its own order — see `WorkspaceVisibilityTree`.
public enum FuzzyTextSearch {
    public struct Field: Sendable, Equatable {
        public let text: String
        public let weight: Double

        public init(text: String, weight: Double = 1.0) {
            self.text = text
            self.weight = weight
        }
    }

    public struct Candidate<ID: Hashable & Sendable>: Sendable, Equatable {
        public let id: ID
        public let fields: [Field]

        public init(id: ID, fields: [Field]) {
            self.id = id
            self.fields = fields
        }
    }

    public struct Match: Sendable, Equatable {
        public let score: Double
        public let tokenMatches: [TokenMatch]
    }

    public struct TokenMatch: Sendable, Equatable {
        public let token: String
        public let fieldIndex: Int
        public let score: Double
        public let matchedIndices: [Int]
    }

    public struct RankedCandidate<ID: Hashable & Sendable>: Sendable, Equatable {
        public let id: ID
        public let score: Double
        public let match: Match
    }

    public static func match(query: String, fields: [Field]) -> Match? {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return Match(score: 0, tokenMatches: []) }

        var tokenMatches: [TokenMatch] = []
        var totalScore = 0.0

        for token in tokens {
            var bestMatch: TokenMatch?
            for (fieldIndex, field) in fields.enumerated() {
                guard !field.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                guard let fieldMatch = matchToken(token, in: field.text) else { continue }
                let weightedScore = fieldMatch.score * max(field.weight, 0)
                let candidate = TokenMatch(token: token, fieldIndex: fieldIndex, score: weightedScore, matchedIndices: fieldMatch.matchedIndices)

                if let currentBest = bestMatch {
                    if candidate.score > currentBest.score + 0.000_001 {
                        bestMatch = candidate
                    } else if abs(candidate.score - currentBest.score) <= 0.000_001 {
                        if field.text.count < fields[currentBest.fieldIndex].text.count {
                            bestMatch = candidate
                        } else if field.text.count == fields[currentBest.fieldIndex].text.count, fieldIndex < currentBest.fieldIndex {
                            bestMatch = candidate
                        }
                    }
                } else {
                    bestMatch = candidate
                }
            }

            guard let bestMatch else { return nil }
            totalScore += bestMatch.score
            tokenMatches.append(bestMatch)
        }

        let distinctFieldCount = Set(tokenMatches.map(\.fieldIndex)).count
        let coverageBonus = min(Double(distinctFieldCount - 1) * 0.015, 0.03)
        let finalScore = min((totalScore / Double(tokens.count)) + coverageBonus, 1.0)
        return Match(score: finalScore, tokenMatches: tokenMatches)
    }

    public static func rank<ID: Hashable & Sendable>(query: String, candidates: [Candidate<ID>], limit: Int? = nil) -> [RankedCandidate<ID>] {
        let ranked = candidates.enumerated().compactMap { offset, candidate -> (offset: Int, ranked: RankedCandidate<ID>)? in
            guard let match = match(query: query, fields: candidate.fields) else { return nil }
            return (offset, RankedCandidate(id: candidate.id, score: match.score, match: match))
        }

        let sorted = ranked.sorted { lhs, rhs in
            if abs(lhs.ranked.score - rhs.ranked.score) > 0.000_001 { return lhs.ranked.score > rhs.ranked.score }
            return lhs.offset < rhs.offset
        }.map(\.ranked)

        guard let limit else { return sorted }
        return Array(sorted.prefix(max(limit, 0)))
    }

    private struct PreparedText {
        let characters: [Character]
        let originalIndices: [Int]
        let wordStartFlags: [Bool]
    }

    private struct FieldTokenMatch {
        let score: Double
        let matchedIndices: [Int]
    }

    private struct PathState {
        let score: Double
        let startPosition: Int
        let groups: Int
        let previousMatchIndex: Int?
        let previousChoiceIndex: Int?
    }

    private static func tokenize(_ query: String) -> [String] { query.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty } }

    private static func matchToken(_ token: String, in text: String) -> FieldTokenMatch? {
        let preparedQuery = prepare(token)
        let preparedText = prepare(text)
        guard !preparedQuery.characters.isEmpty, !preparedText.characters.isEmpty else { return nil }

        let queryCharacters = preparedQuery.characters
        let textCharacters = preparedText.characters
        let queryCount = queryCharacters.count

        var statesByQueryIndex: [[PathState]] = []
        var positionsByQueryIndex: [[Int]] = []
        statesByQueryIndex.reserveCapacity(queryCount)
        positionsByQueryIndex.reserveCapacity(queryCount)

        for (queryIndex, queryCharacter) in queryCharacters.enumerated() {
            let allPositions = textCharacters.enumerated().compactMap { index, character in character == queryCharacter ? index : nil }
            guard !allPositions.isEmpty else { return nil }

            var validPositions: [Int] = []
            var states: [PathState] = []
            validPositions.reserveCapacity(allPositions.count)
            states.reserveCapacity(allPositions.count)

            for position in allPositions {
                if queryIndex == 0 {
                    let initialScore = baseCharacterScore(position: position, wordStart: preparedText.wordStartFlags[position])
                    validPositions.append(position)
                    states.append(
                        PathState(score: initialScore, startPosition: position, groups: 1, previousMatchIndex: nil, previousChoiceIndex: nil))
                    continue
                }

                let previousPositions = positionsByQueryIndex[queryIndex - 1]
                let previousStates = statesByQueryIndex[queryIndex - 1]
                var bestState: PathState?

                for (previousChoiceIndex, previousPosition) in previousPositions.enumerated() {
                    guard previousPosition < position else { continue }

                    let previousState = previousStates[previousChoiceIndex]
                    let gap = position - previousPosition - 1
                    let isConsecutive = position == previousPosition + 1

                    var score = previousState.score + 1.0
                    score += preparedText.wordStartFlags[position] ? 0.3 : 0
                    if isConsecutive { score += 1.15 } else { score -= Double(gap) * 0.12 }

                    let groups = previousState.groups + (isConsecutive ? 0 : 1)
                    let candidate = PathState(
                        score: score, startPosition: previousState.startPosition, groups: groups, previousMatchIndex: queryIndex - 1,
                        previousChoiceIndex: previousChoiceIndex)

                    if let currentBest = bestState {
                        if candidate.score > currentBest.score + 0.000_001 {
                            bestState = candidate
                        } else if abs(candidate.score - currentBest.score) <= 0.000_001 {
                            let candidateSpan = position - candidate.startPosition
                            let bestSpan = position - currentBest.startPosition
                            if candidateSpan < bestSpan { bestState = candidate }
                        }
                    } else {
                        bestState = candidate
                    }
                }

                guard let bestState else { continue }
                validPositions.append(position)
                states.append(bestState)
            }

            guard !states.isEmpty else { return nil }
            positionsByQueryIndex.append(validPositions)
            statesByQueryIndex.append(states)
        }

        let lastQueryIndex = queryCount - 1
        let finalPositions = positionsByQueryIndex[lastQueryIndex]
        let finalStates = statesByQueryIndex[lastQueryIndex]

        var bestFinalChoiceIndex: Int?
        var bestFinalScore = -Double.infinity

        for (choiceIndex, endPosition) in finalPositions.enumerated() {
            let state = finalStates[choiceIndex]
            let spanLength = endPosition - state.startPosition + 1
            let unmatchedCharacters = spanLength - queryCount
            let isContiguous = spanLength == queryCount
            let isPrefix = state.startPosition == 0
            let endsAtBoundary = endPosition == (preparedText.wordStartFlags.count - 1) || preparedText.wordStartFlags[safe: endPosition + 1] == true

            var finalScore = state.score
            finalScore += isContiguous ? 2.4 : max(1.3 - (Double(unmatchedCharacters) * 0.14), 0)
            finalScore += isPrefix ? 0.55 : max(0.35 - (Double(state.startPosition) * 0.035), 0)
            finalScore += endsAtBoundary ? 0.4 : 0
            finalScore -= Double(max(state.groups - 1, 0)) * 0.22
            finalScore -= Double(max(textCharacters.count - queryCount, 0)) * 0.01

            if finalScore > bestFinalScore + 0.000_001 {
                bestFinalScore = finalScore
                bestFinalChoiceIndex = choiceIndex
            } else if abs(finalScore - bestFinalScore) <= 0.000_001, let currentBestFinalChoiceIndex = bestFinalChoiceIndex {
                let currentSpan = endPosition - state.startPosition
                let bestSpan = finalPositions[currentBestFinalChoiceIndex] - finalStates[currentBestFinalChoiceIndex].startPosition
                if currentSpan < bestSpan { bestFinalChoiceIndex = choiceIndex }
            }
        }

        guard let bestFinalChoiceIndex else { return nil }

        let matchedPositions = reconstructPositions(
            positionsByQueryIndex: positionsByQueryIndex, statesByQueryIndex: statesByQueryIndex, lastChoiceIndex: bestFinalChoiceIndex)
        let matchedIndices = matchedPositions.map { preparedText.originalIndices[$0] }
        let maxPossibleScore = maximumPossibleScore(forQueryLength: queryCount)
        let normalizedScore = min(max(bestFinalScore / maxPossibleScore, 0), 1)
        return FieldTokenMatch(score: normalizedScore, matchedIndices: matchedIndices)
    }

    private static func reconstructPositions(positionsByQueryIndex: [[Int]], statesByQueryIndex: [[PathState]], lastChoiceIndex: Int) -> [Int] {
        var positions: [Int] = []
        positions.reserveCapacity(statesByQueryIndex.count)

        var queryIndex = statesByQueryIndex.count - 1
        var choiceIndex: Int? = lastChoiceIndex

        while let resolvedChoiceIndex = choiceIndex, queryIndex >= 0 {
            positions.append(positionsByQueryIndex[queryIndex][resolvedChoiceIndex])
            let state = statesByQueryIndex[queryIndex][resolvedChoiceIndex]
            choiceIndex = state.previousChoiceIndex
            guard let previousMatchIndex = state.previousMatchIndex else { break }
            queryIndex = previousMatchIndex
        }

        return positions.reversed()
    }

    private static func maximumPossibleScore(forQueryLength queryLength: Int) -> Double {
        let perCharacter = 2.45 * Double(max(queryLength - 1, 0))
        return 5.35 + perCharacter
    }

    private static func baseCharacterScore(position: Int, wordStart: Bool) -> Double {
        let startBonus = max(0.7 - (Double(position) * 0.04), 0)
        return 1.0 + startBonus + (wordStart ? 0.85 : 0)
    }

    private static func prepare(_ text: String) -> PreparedText {
        let originalCharacters = Array(text)
        var characters: [Character] = []
        var originalIndices: [Int] = []
        var wordStartFlags: [Bool] = []

        for (originalIndex, originalCharacter) in originalCharacters.enumerated() {
            let boundary = isWordStart(originalCharacters, at: originalIndex)
            let folded = String(originalCharacter).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            for (foldedIndex, foldedCharacter) in Array(folded).enumerated() {
                characters.append(foldedCharacter)
                originalIndices.append(originalIndex)
                wordStartFlags.append(boundary && foldedIndex == 0)
            }
        }

        return PreparedText(characters: characters, originalIndices: originalIndices, wordStartFlags: wordStartFlags)
    }

    private static func isWordStart(_ characters: [Character], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let current = characters[index]
        let previous = characters[index - 1]

        let currentIsWord = isWordCharacter(current)
        let previousIsWord = isWordCharacter(previous)
        if currentIsWord && !previousIsWord { return true }
        if isLowercase(previous) && isUppercase(current) { return true }
        if isDigit(previous) != isDigit(current), previousIsWord, currentIsWord { return true }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    private static func isDigit(_ character: Character) -> Bool { character.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) } }

    private static func isUppercase(_ character: Character) -> Bool {
        let string = String(character)
        return string == string.uppercased() && string != string.lowercased()
    }

    private static func isLowercase(_ character: Character) -> Bool {
        let string = String(character)
        return string == string.lowercased() && string != string.uppercased()
    }
}

extension Collection { fileprivate subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil } }
