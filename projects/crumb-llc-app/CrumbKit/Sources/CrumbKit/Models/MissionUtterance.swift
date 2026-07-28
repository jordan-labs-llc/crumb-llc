import Foundation

/// What a person asked Crumb to do with the product it is currently showing.
public enum MissionDecision: String, Hashable, Sendable, Codable {
    /// Keep this one — put it in the kit.
    case add
    /// Not this one, and don't offer it again.
    case skip
    /// Not this one, but keep looking in the same direction.
    case showAnother
}

/// Where a person asked to go once the decision in the same breath has been applied.
///
/// The two are deliberately distinct. "Let's create a cart" is a request to *see the cart*, and
/// leaves the person inside the mission with the kit and a subtotal in front of them. "Check out"
/// is a request to *start paying*, and opens the checkout sheet. Collapsing them would either
/// strand someone who is ready to buy, or shove someone who only wanted to look into a payment
/// flow they did not ask for.
public enum MissionNextStep: String, Hashable, Sendable, Codable {
    case reviewCart
    case checkout
}

/// One typed message, parsed against the closed vocabulary of the question that is on screen.
///
/// ## Why this type exists
///
/// The mission loop used to map a whole typed message onto a single product option with one
/// exact dictionary lookup. That worked for `"add it"` and failed for every sentence a person
/// actually types. The reported failure was verbatim:
///
/// ```
/// "I like it. Let's create a cart."
/// ```
///
/// `"i like it"` was in the vocabulary and `"let's create a cart"` was not in it *at all* — there
/// was no cart intent anywhere in the map. The whole-string lookup missed, the message fell through
/// to the refinement branch, and Crumb answered a decision and a request to buy by re-curating the
/// deck: *"I updated the picks to match."* The person said yes and got handed more homework.
///
/// ## What changed
///
/// A message is now split into **clauses** and each clause is matched independently, so a decision
/// and a next step can arrive in one breath. Two properties from the old design are kept
/// deliberately, because they are what make a *write* safe to derive from prose:
///
/// - **Exact clause matching, never substring.** `"I don't like it"` must never match on the
///   `"like it"` inside it. Substring matching would invert the meaning of a negation and add the
///   thing the person just rejected.
/// - **Ordinals never resolve.** `"add the second one"` names a product this question does not
///   carry an identity for, so it stays a refinement rather than becoming a guess about which
///   product to write.
///
/// Parsing is pure and deterministic. Intent sits on the write path — misreading `"skip"` as
/// `"add"` puts a thing in someone's cart — so it is decided by code with a closed vocabulary, not
/// by a model. Ranking, where being interesting matters more than being predictable, is where the
/// model earns its place.
public struct MissionUtterance: Hashable, Sendable {
    /// What to do with the product on screen, when the message said so unambiguously.
    public let decision: MissionDecision?
    /// Where to go afterwards, when the message asked.
    public let nextStep: MissionNextStep?
    /// Everything the vocabulary did not account for, to be treated as a change request.
    ///
    /// When `decision` and `nextStep` are both `nil` this is the entire trimmed message: a
    /// sentence Crumb does not recognise is a refinement, exactly as before. When it accompanies a
    /// decision it is the leftover clause — `"I like it, but cheaper"` keeps the yes *and* the
    /// note.
    public let refinement: String?

    public init(
        decision: MissionDecision? = nil,
        nextStep: MissionNextStep? = nil,
        refinement: String? = nil
    ) {
        self.decision = decision
        self.nextStep = nextStep
        self.refinement = refinement
    }

    /// True when nothing in the message was recognised, so the whole of it is a change request.
    public var isPureRefinement: Bool { decision == nil && nextStep == nil }

    // MARK: - Parsing

    /// Parses a typed message. Total: every input yields a value, worst case a pure refinement.
    public static func parse(_ raw: String) -> MissionUtterance {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return MissionUtterance() }

        var decision: MissionDecision?
        var nextStep: MissionNextStep?
        var leftovers: [String] = []
        var contradicted = false

        for (original, match) in resolvedClauses(in: trimmed) {
            guard let match else {
                leftovers.append(original)
                continue
            }
            if let found = match.decision {
                switch decision {
                case nil:
                    decision = found
                case let existing? where existing == found:
                    break
                case let existing?:
                    // "no thanks, show me another" says one thing twice; "add it, actually skip it"
                    // says two opposite things. Reconcile the first, refuse to guess at the second —
                    // an unwanted write is far worse than an unnecessary question.
                    if let reconciled = reconcile(existing, found) { decision = reconciled }
                    else { contradicted = true }
                }
            }
            if let found = match.nextStep {
                // Paying is further along than looking, and a message carrying both means the
                // person is ready to pay.
                if nextStep == nil || found == .checkout { nextStep = found }
            }
        }

        guard !contradicted else { return MissionUtterance(refinement: trimmed) }
        guard decision != nil || nextStep != nil else { return MissionUtterance(refinement: trimmed) }

        let leftover = leftovers.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return MissionUtterance(
            decision: decision,
            nextStep: nextStep,
            refinement: leftover.isEmpty ? nil : leftover
        )
    }

    /// `skip` and `showAnother` are the same rejection at different volumes, so the more specific
    /// request wins. Anything paired with `add` is a genuine contradiction.
    private static func reconcile(_ lhs: MissionDecision, _ rhs: MissionDecision) -> MissionDecision? {
        let pair: Set<MissionDecision> = [lhs, rhs]
        return pair == [.skip, .showAnother] ? .showAnother : nil
    }

    // MARK: - Clauses

    /// Sentence boundaries. A person writes one intent per sentence: "I like it. Let's create a
    /// cart." is two.
    private static let sentenceSeparators: [String] = [".", "!", "?", ";", "\n"]

    /// Weaker boundaries, used only when they fully resolve — see ``resolvedClauses(in:)``.
    private static let conjunctionSeparators: [String] = [
        ",", " and then ", " and ", " then ", " — ", " – ", " - ",
    ]

    /// Splits a message into clauses paired with what each one means, `nil` where nothing matched.
    ///
    /// Sentences are split unconditionally. Conjunctions are not: splitting on `" and "` would
    /// turn `"make it black and green"` into two fragments and rejoin them as mangled nonsense in
    /// the refinement text. So a sentence is only broken at a conjunction when **every** resulting
    /// piece is in the vocabulary — which is true of `"no thanks, show me another"` and false of
    /// `"make it black and green"`. A sentence that does not fully resolve is carried through whole
    /// and unedited, so a person's own words survive to be echoed back to them.
    private static func resolvedClauses(in text: String) -> [(original: String, match: Match?)] {
        var results: [(String, Match?)] = []
        var sentences = [text]
        for separator in sentenceSeparators {
            sentences = sentences.flatMap { $0.components(separatedBy: separator) }
        }

        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let direct = match(clause: normalize(trimmed)) {
                results.append((trimmed, direct))
                continue
            }
            if let split = fullyResolvedSplit(of: trimmed) {
                results.append(contentsOf: split.map { ($0.0, Optional($0.1)) })
                continue
            }
            results.append((trimmed, nil))
        }
        return results
    }

    /// The conjunction split of a sentence, but only when every piece carries a known meaning.
    private static func fullyResolvedSplit(of sentence: String) -> [(String, Match)]? {
        for separator in conjunctionSeparators {
            let pieces = sentence.components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard pieces.count > 1 else { continue }
            let matches = pieces.map { match(clause: normalize($0)) }
            if matches.allSatisfy({ $0 != nil }) {
                return zip(pieces, matches.map { $0! }).map { ($0, $1) }
            }
        }
        return nil
    }

    /// Lowercases and folds the punctuation that makes an otherwise-exact match miss.
    ///
    /// The curly apostrophe matters more than it looks: iOS smart quotes turn every typed
    /// `"let's"` into `"let\u{2019}s"`, so a vocabulary written with straight quotes never matches
    /// anything a person actually types on a phone. The reported failure carried exactly this
    /// character.
    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")   // ’ right single quote
            .replacingOccurrences(of: "\u{02BC}", with: "'")   // ʼ modifier apostrophe
            .replacingOccurrences(of: "\u{2018}", with: "'")   // ‘ left single quote
            .replacingOccurrences(of: "\u{2026}", with: ".")   // … ellipsis
    }

    private struct Match {
        var decision: MissionDecision?
        var nextStep: MissionNextStep?
    }

    /// Exact lookup, retried once after shedding conversational padding, so "ok add it please"
    /// resolves without the vocabulary having to enumerate every politeness.
    private static func match(clause: String) -> Match? {
        if let direct = vocabulary[clause] { return direct }
        let stripped = shedPadding(clause)
        guard stripped != clause, !stripped.isEmpty else { return nil }
        return vocabulary[stripped]
    }

    /// Words that carry no intent on their own. None of them is a vocabulary entry, so shedding
    /// them can never turn one recognised phrase into a different one.
    private static let leadingPadding = [
        "ok", "okay", "oh", "alright", "all right", "well", "so", "hmm", "um", "uh",
        "actually", "i think", "i guess", "lets", "let's", "please",
    ]
    private static let trailingPadding = ["please", "thanks", "thank you", "for me", "though"]

    private static func shedPadding(_ clause: String) -> String {
        var value = clause
        var changed = true
        while changed {
            changed = false
            for word in leadingPadding where value.hasPrefix(word + " ") {
                value = String(value.dropFirst(word.count + 1))
                changed = true
                break
            }
            for word in trailingPadding where value.hasSuffix(" " + word) {
                value = String(value.dropLast(word.count + 1))
                changed = true
                break
            }
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - The closed vocabulary

    private static let vocabulary: [String: Match] = {
        var map: [String: Match] = [:]

        func add(_ phrases: [String], _ match: Match) {
            for phrase in phrases { map[phrase] = match }
        }

        // Keep this one.
        add([
            "add", "add it", "add this", "add that", "add it to the cart", "add to cart",
            "keep", "keep it", "keep this", "keep that", "shortlist", "shortlist it",
            "take it", "i'll take it", "ill take it", "i want it", "i want this",
            "yes", "yes please", "yep", "yup", "yeah", "sure", "perfect", "love it",
            "looks good", "looks great", "sounds good", "that works", "works for me",
            "i like it", "i like this", "like it", "like this", "good", "great", "nice",
            "that one", "this one", "go with it", "go with this",
        ], Match(decision: .add))

        // Not this one.
        add([
            "skip", "skip it", "skip this", "pass", "pass on it", "no", "nope", "no thanks",
            "no thank you", "not this one", "not this", "not for me", "don't like it",
            "dont like it", "i don't like it", "i dont like it", "i don't like this",
            "i dont like this", "drop it", "remove it", "lose it", "not interested",
        ], Match(decision: .skip))

        // Keep looking.
        add([
            "show another", "show me another", "another", "another one", "next", "next one",
            "what else", "something else", "show me something else", "more options",
            "keep looking", "keep going", "anything else",
        ], Match(decision: .showAnother))

        // Show me the cart. The reported failure lives here — none of this existed.
        add([
            "create a cart", "let's create a cart", "lets create a cart", "make a cart",
            "make me a cart", "build a cart", "build the cart", "build me a cart",
            "cart", "the cart", "show me the cart", "show the cart", "see the cart",
            "open the cart", "view the cart", "review the cart", "review cart",
            "what's in the cart", "whats in the cart",
        ], Match(nextStep: .reviewCart))

        // Start paying.
        add([
            "checkout", "check out", "let's check out", "lets check out", "go to checkout",
            "place the order", "place my order", "order it", "order this", "pay", "pay now",
            "ready to buy", "i'm ready to buy", "im ready to buy", "ready to check out",
            "complete the order", "finish the order",
        ], Match(nextStep: .checkout))

        // Both at once. "Buy it" is a yes and an instruction to pay, and reading it as only a
        // shortlist — which is what it used to do — is why saying it twice got you nowhere.
        add([
            "buy it", "buy this", "buy that", "let's buy it", "lets buy it", "purchase it",
            "purchase this", "i'll buy it", "ill buy it", "take my money",
        ], Match(decision: .add, nextStep: .checkout))

        return map
    }()
}
