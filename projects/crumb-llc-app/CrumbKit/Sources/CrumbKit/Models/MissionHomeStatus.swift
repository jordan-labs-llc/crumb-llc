import Foundation

/// Which of the three things a mission on Home can be: something is waiting for *you*, Crumb needs a
/// *decision* from you, or it is Crumb's move.
///
/// Home used to render `MissionContinuationSummary.text(for:)` alone, which mapped eight phases onto
/// eight different phrasings ("Ready to shop", "Searching shops", "Needs attention", "Planning",
/// "Ready for another goal", plus three contents-derived strings). Five of those could appear on one
/// screen, in five registers, so there was no pattern for a person to learn — and a `.failed` mission
/// read as the same kind of thing as a settled one. This type makes the single distinction that
/// actually changes what someone does next, and lets the view encode it in form as well as words.
public enum MissionHomeState: String, Hashable, Sendable, CaseIterable {
    /// There is something here to look at — kept items, or a deck nobody has reviewed yet.
    case ready
    /// Crumb has stopped and needs a decision. Includes the settled-but-empty gather, which is a
    /// dead end presented as a finished one unless it is called out.
    case stalled
    /// Crumb is mid-flight. Nothing for the person to do but wait (or watch the elapsed time).
    case working
}

/// The Home-facing reading of a mission: its state, a short reason, and when it last moved.
public enum MissionHomeStatus {

    /// Which bucket a thread belongs in.
    ///
    /// `deckReady` is deliberately not treated as "ready" on its own: it is a state-machine fact (the
    /// gather finished), not a claim that anything was found. A settled deck holding nothing is a
    /// stall, because the next move belongs to the person.
    public static func state(for thread: MissionThread) -> MissionHomeState {
        switch thread.phase {
        case .planning, .gathering:
            return .working
        case .planReady:
            return .ready
        case .deckReady:
            if !thread.kit.isEmpty || !thread.remainingDeckIDs.isEmpty { return .ready }
            return .stalled
        case .failed, .declined:
            return .stalled
        // Neither reaches Home — `upsertThreadInMemory` drops both from `incompleteThreads` — but the
        // switch stays total so adding a phase is a compile error rather than a silent default.
        case .completed, .abandoned:
            return .ready
        }
    }

    /// What a mission that is *currently searching* can truthfully say about its own progress, or
    /// `nil` when it has nothing to add.
    ///
    /// The gather is the longest wait in the app — up to 45 seconds — and for all of it every surface
    /// said the same static sentence ("Searching the shops…" in the feed pill and the dock, "Crumb is
    /// working…" in the pinned header), so a run that was going well looked exactly like a run that
    /// had hung. The streamed gather writes each batch into `candidates` as it lands, so the count is
    /// already on the thread; nothing here computes or stores anything new.
    ///
    /// Deliberately narrow. `.planning` is also `.working` state, and a planning mission has issued no
    /// catalog call at all — claiming a find count there would be fabrication, so it keeps its own
    /// "Planning". An empty pool likewise stays quiet: before the first batch there is genuinely
    /// nothing to report, and the pill beside the spinner is already saying so.
    ///
    /// It also says nothing about *shops*. The pinned header already owns that word for the distinct
    /// merchants in the kit, and two different numbers both labelled "shops" in one line is worse than
    /// one number.
    public static func workingDetail(for thread: MissionThread) -> String? {
        guard thread.phase == .gathering, !thread.candidates.isEmpty else { return nil }
        return "Found \(thread.candidates.count) so far"
    }

    /// The short second line on a Home row: what is waiting, or why Crumb stopped.
    ///
    /// For a stall this prefers the mission's own last failure sentence over a generic label, because
    /// "I couldn't reach the shops" tells a person whether to retry, and "Needs attention" does not.
    public static func detail(for thread: MissionThread, currencyCode: String = "USD") -> String {
        switch state(for: thread) {
        case .ready, .working:
            // A live search reports its own progress; everything else keeps the phase wording, which
            // for those states is the whole truth.
            if let working = workingDetail(for: thread) { return working }
            return MissionContinuationSummary.text(for: thread, currencyCode: currencyCode)
        case .stalled:
            if let failure = thread.timeline.last(where: { $0.kind == .failure })?.text,
               !failure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return failure
            }
            if thread.phase == .deckReady { return "Nothing found yet" }
            if thread.phase == .declined { return "Waiting on a new goal" }
            return "Stopped before it finished"
        }
    }

    /// A coarse, human stamp for when the mission last moved. Recency is the only thing Home's sort
    /// encodes, and it used to be invisible on every row — so "Searching shops" could equally mean
    /// four seconds or four weeks, and only one of those means the mission is stuck.
    ///
    /// Buckets stay deliberately coarse, and hand off to an absolute date past a fortnight rather
    /// than counting up to "37d".
    public static func relativeTime(
        _ date: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let seconds = now.timeIntervalSince(date)
        // A clock skew or a thread stamped in the future reads as "just now" rather than as a
        // negative age.
        guard seconds >= 60 else { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }

        // Every bucket past an hour is derived from the day difference against the *passed* `now`.
        // `Calendar.isDateInYesterday` would read the system clock instead, which happens to be right
        // in production and is always wrong under a fixed test fixture.
        let startOfDate = calendar.startOfDay(for: date)
        let startOfNow = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day ?? 0
        if days == 0 { return "\(Int(seconds / 3600))h ago" }
        if days == 1 { return "Yesterday" }
        if days < 7 { return "\(days)d ago" }
        if days < 14 { return "Last week" }

        var format = Date.FormatStyle.dateTime.month(.abbreviated).day()
        format.locale = locale
        return date.formatted(format)
    }
}
