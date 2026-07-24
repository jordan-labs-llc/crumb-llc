# Conversation-first mission threads

## Decision

Crumb should keep the durable mission-thread domain introduced in the first mission-thread pass,
but replace the hybrid workspace UI with a chronological conversational feed and one stateful
response dock at the bottom of the screen.

Assistant turns may contain rich, read-only artifacts such as a plan, product, comparison, kit
summary, progress receipt, or error. Every mission response — typed text, a suggested reply, plan
approval, Add, Skip, retry, or cart review — originates from the same bottom dock. Historical
artifacts never contain live decision controls.

This adapts the useful property of Claude's `AskUserQuestion` flow: the assistant produces a
structured request for input, the host presents a focused answer surface, and execution resumes
with a structured answer. It does not attempt to copy Claude's visual treatment literally.

## Why the first conversation pass still felt hybrid

The first pass made the transcript and rich artifacts read-only and moved mission answers to a
bottom dock. Two visual seams remained:

- New missions still began in a scrolling form with a recipient picker, large field, separate
  **Plan it** button, example chips, and Siri card.
- Active missions stacked full-width option cards above a second rounded text field. Although both
  lived in the dock, the result still looked like a control panel attached to chat.
- People, History, and Taste occupied three persistent header icons, giving a tab-like impression
  even though the application has no `TabView`.

The second pass makes the composer envelope itself the only mission input grammar. It appears in
the same bottom location before and during a mission, owns its context and suggested replies, and
collapses secondary navigation into one menu.

## Alternatives considered

### Natural-language-only chat

Every response is typed: “yes,” “skip,” “the first one,” or “make it cheaper.” This is visually
pure, but repetitive, ambiguous after asynchronous updates or relaunch, slower for VoiceOver and
Switch Control, and unsafe for product and checkout identity. Reject.

### Inline response cards

Each assistant question carries buttons or fields in the transcript. This keeps controls near their
context, but old actionable controls remain in scrollback, VoiceOver users must hunt for the newest
question, and input is still distributed around the screen. Reject as the primary model.

### Conversational feed with a response dock

The feed contains messages and read-only artifacts. The bottom dock expands to collect the answer
to the one current question while retaining a free-text route. It preserves conversational rhythm,
efficient choices, stable keyboard and accessibility behavior, and deterministic command identity.
Adopt.

## The response dock

The response dock is the sole mission input surface. It stays mounted for the life of the thread and
supports these modes:

1. `freeText`: normal mission request, clarification, or refinement with optional suggestions.
2. `singleChoice`: two to four semantic options plus Other/free text. Low-risk choices may submit
   immediately.
3. `confirmation`: a precise action summary, confirm/cancel/edit choices, and free text when useful.
4. `working`: specific activity feedback with Stop or a safe steering path.
5. `recovery`: retry, change request, use current results, or cancel, depending on what survived.

V1 deliberately omits multi-select. If a later mission genuinely needs it, it must have a concrete
flow plus keyboard, VoiceOver, persistence, and relaunch tests before the generic mode is added.

At normal text sizes, up to four short replies appear as compact, composer-owned suggestions. A
detailed or overflowing choice opens a bounded, scrollable sheet owned by the composer and repeats
the current question and subject. At accessibility Dynamic Type sizes, that expansion uses full-width 44-point
rows instead of creating a nested option scroller or consuming the conversation viewport.
Confirmation-only interactions do not render an inert text field.

Every delayed reply retains the frozen thread ID, interaction ID, interaction generation, and
subject revision captured when it was presented. If any part changes, the composer dismisses the
old expansion and the reducer rejects the stale answer; matching option labels are never enough.

Navigation is not conversational input. Back, Missions, History, Profile, passive product details,
and the focused Cart/checkout surface may remain conventional navigation. Mission decisions do not.

Normatively, every mission-screen control that answers Crumb, changes plan, product decisions, kit
or taste, retries or stops work, or opens Cart as an answer belongs in the dock. Navigation chrome
may only navigate. Read-only artifacts may disclose details, copy content, or expand accessibility
content, but cannot mutate mission state. **Jump to latest** is transcript navigation. Cart and
checkout are a separate transactional context and may use conventional controls.

## Example mission

### Goal and search (direct missions)

The user enters “Set up my pour-over corner” in the dock. Crumb starts shopping it immediately —
there is no plan-approval turn. A goal that keeps a real multi-part plan (the deterministic kit
expansions, e.g. lacrosse gear) posts the plan as a **read-only in-thread notice** carrying its
stated assumption, while the search is already running. Free text typed during the search is
queued and applied as a refinement the moment the picks land; a response such as “make it goalie
gear” after settle folds into the goal or reworks the deck conversationally.

There are no plan text fields, plus/minus controls, approval buttons, or separate commit button
in the feed.

### Products

Crumb posts one product turn with its image, price, merchant, explanation, and variant as a read-only
attachment, then asks a specific question. The dock offers **Add**, **Skip**, **Show another**, and
**Adjust search**. The pending interaction freezes the product and variant IDs; it never means
“whatever card is currently on top.”

If the product has multiple materially distinct variants, Crumb first asks a single-choice variant
question in the dock. The subsequent Add confirmation repeats the exact variant and authoritative
price. If availability or price changes, Crumb invalidates the question and presents the replacement
facts before accepting Add.

After Add or Skip, the answer becomes a user turn, the domain command commits idempotently, and
Crumb acknowledges the exact product before presenting the next question. A reversible Add may
offer **Undo** in the next dock state.

### Refinement and completion

Typed and suggested refinements both submit through the dock and become ordinary user turns.
Contextual **Reset changes** and **Save to taste** suggestions appear in the dock only when relevant.

When the kit is useful, Crumb posts a read-only kit summary and asks whether to review it. The dock
offers **Review cart**, **Keep shopping**, and **Remove an item**. Cart and merchant checkout remain
purpose-built transactional surfaces; the conversation can navigate to them but cannot silently
purchase or claim that checkout completed.

### Errors and latency

Work begins with a specific status turn such as “Searching three shops for premium jasmine tea.”
Crumb does not generate fake progress prose. During cancellable work the dock exposes **Stop** and,
where safe, accepts a steering message that invalidates the previous operation.

Errors are assistant/status turns in plain language. Recovery choices live in the dock. A passive
unsaved indicator may live in navigation chrome, but **Save again** is a dock recovery action.

## Durable interaction contract

Add a frozen, versioned pending-interaction value to `MissionThread`:

```swift
struct MissionPendingInteraction: Codable, Sendable, Hashable {
    let id: String
    let promptEventID: String
    let interactionGeneration: Int
    let subjectRevision: Int
    let kind: MissionInteractionKind
    let question: String
    let options: [MissionInteractionOption]
    let selectionMode: MissionSelectionMode
    let allowsFreeText: Bool
    let resolver: MissionInteractionResolver
    let createdAt: Date
}
```

Options carry stable semantic command IDs and concise display copy. `resolver` contains typed,
persistable command context such as plan revision, product ID, variant ID, retry descriptor, or cart
summary revision. It never stores a closure and never reconstructs a command by parsing labels or
assistant prose.

`interactionGeneration` changes only when the active question is created, answered, superseded, or
invalidated. `subjectRevision` identifies the relevant frozen plan, product/variant, kit, or retry
subject. Global thread revisions still order persistence, but status, timeline, and persistence
metadata changes do not spuriously invalidate an answer. A subject mutation always does.

Exactly zero or one unresolved interaction may exist in a thread. Submitting an option sends its
stable semantic option ID. Submitting text produces a distinct `.freeText(String)` answer; text is
never mapped back to an option label and never directly executes a write. Typed plan changes and
refinements may produce proposals. Typed “yes,” “add it,” “save this,” or similar write intent must
lead to a new explicit confirmation interaction with frozen entity and action identity.

Submitting an answer is one
reducer transaction:

1. Validate thread ID, interaction generation, subject revision, allowed option ID, and referenced
   entities.
2. Resolve or supersede the pending interaction.
3. Append the visible user answer.
4. Apply the deterministic command with an idempotency ID.
5. Persist the committed thread.
6. Begin the next bounded model or search operation.

If an answer races a subject-changing background completion, one reducer wins. The losing answer
creates no command and receives a visible “That choice is no longer current” turn plus a replacement
question.

`pendingInteraction` and dock-level `blockingRecovery` are distinct. If the question itself was not
durably saved, its actions are disabled and the dock shows **Save again** and **Discard** while
preserving the question behind that recovery. A product answer cannot commit until its resolver is
durable. A save failure after a reversible local mutation preserves the in-memory result, blocks
further conflicting input, and retries the same idempotent revision.

**Discard** is not a warning dismissal. It rolls the thread back to its last durable snapshot and
removes the unsaved question and resolver before normal input becomes available again.

## Turn representation

The current timeline stores one string per event. Conversation-first rendering needs durable content
blocks while keeping authoritative commerce state outside the transcript:

```swift
enum MissionMessageBlock {
    case text(String)
    case planSnapshot(id: String, revision: Int)
    case productSnapshot(productID: String, variantID: String?)
    case comparisonSnapshot(id: String)
    case kitSnapshot(id: String, revision: Int)
    case activity(MissionActivityReceipt)
}
```

Every persisted artifact contains frozen display facts. Product snapshots include title, merchant,
image reference, presented price, presented availability, variant, and necessary disclosure copy;
plan and kit snapshots likewise freeze what the user saw. Stable catalog IDs remain command
validation references, and price/availability are revalidated before Add or checkout. Historical
rendering never depends on a mutable candidate pool. Snapshots do not act as an event-sourced rebuild
log. Completed product artifacts can collapse into concise summaries;
the latest unanswered artifact never collapses automatically.

## Foundation Models boundary

Do not keep an Apple Foundation Models `Tool.call` suspended while waiting for a person. App
backgrounding, process death, long response time, and session context limits make that an unreliable
durability boundary.

Instead, a bounded model turn returns a guided `TurnDirective` such as `respond`, `clarify`, or
`proposePlan`. The app validates and persists any `MissionPendingInteraction`, ends the model turn,
and waits normally. The user's answer begins a new turn using authoritative thread context.

Model-session continuity is opportunistic. After relaunch or context exhaustion, Crumb creates a
fresh bounded session from a deterministic projection of the authoritative thread. It persists no
`LanguageModelSession`, Foundation Models transcript, tool continuation, or suspended task. Warm-
and fresh-session paths must produce equivalent validated directives for the same thread state.

Domain questions such as product Add/Skip, retry/resume, and cart review are constructed by
the app. The model may request clarification only through a restricted schema with one question,
two to four concise options, and a material-information rule. Search tools remain read-only. Write
commands remain app reducers gated by current interaction identity and explicit user intent.
Every returned directive and entity ID is validated. Clarification directives can only ask; they
cannot carry write semantics. Required tool-calling mode always has an explicit exit condition.

App Intents and Siri may start or resume a mission or submit a user message through the same reducer.
A mutating external intent must carry the current interaction ID/generation, subject revision, and
explicit product/variant confirmation. Stale external intents are rejected. “Sole input surface”
describes the in-app mission UI; authenticated external input still obeys the identical protocol and
appears in the transcript.

## State-to-dock contract

| State | Latest turn / artifact | Dock responses | Resume behavior |
|---|---|---|---|
| Planning | Specific activity receipt | Stop; safe steering text | Recover to retry/change-goal without replay |
| Plan ready | Frozen plan and approval question | Start shopping; Change plan; Start over | Restore exact approval question |
| Planner declined | Plain-language reason | Replacement goal text; Cancel | Restore free-text replacement state |
| Gathering, no results | Search receipt and explanation | Retry; Change request; Cancel | Retry only by explicit answer |
| Gathering, partial | Frozen partial result plus status | Use these; Keep searching; Stop | Preserve results and question |
| Product ready | Frozen product/variant question | Add; Skip; Show another; Adjust search | Restore exact product resolver |
| Direct product | Frozen comparison option | Shortlist; Skip; Adjust search | Preserve shortlist wording and identity |
| Gift/recipient | Recipient-context question or notice | App-approved choices; Other text | Restore recipient snapshot |
| Refinement complete | Acknowledgement and next product | Contextual suggestions; Reset; Save to taste | Preserve active directives |
| Deck exhausted | Frozen kit or no-picks summary | Review cart; Find more; Change request; End | No catalog replay |
| Failed/interrupted | Plain-language stable-state explanation | Retry; Change request; Use current; Cancel | Recover exactly once |
| Unsaved | Existing question behind recovery | Save again; Discard | Never answer an undurable resolver |
| Completed | Frozen multi-merchant kit summary | Review cart; Keep shopping | Remain terminal unless explicitly reopened |
| Abandoned | Ended notice | Start new mission | No stale mutation |
| Corrupt/quarantined | Restoration explanation | Delete; Return to Missions | Never construct a write-capable prompt |

Plan fallback and model unavailability use the same plan-ready contract with an honest deterministic-
fallback notice. Remove/Undo and variant change are explicit typed questions referencing frozen IDs.

## Adversarial constraints

- Never resolve “yes,” “it,” or “the first one” against mutable display order.
- A background completion cannot replace a question while the user is answering it.
- A stale or superseded interaction cannot be submitted after another product appears.
- Relaunch restores both the visible question and its typed resolver without replaying tools.
- Catalog copy cannot cause a write tool or invent an interaction kind.
- Unknown directive kinds and hallucinated plan/product/variant IDs are rejected.
- One-tap reversible actions produce visible acknowledgement and an Undo path.
- Recovery arbitration prioritizes unsafe or unsaved state over ordinary suggestions.
- The model cannot repeatedly ask optional questions instead of making reasonable progress.
- Clarification frequency and consecutive questions are bounded and evaluated.
- No assistant prose can add to kit, remove an item, open checkout, or claim a purchase.
- VoiceOver focus is preserved when turns append; a separate **Jump to latest** action is available.

## Migration plan

### Phase 1 — interaction protocol

Add the pending-interaction domain types, V2 document migration, reducer commands, validation, and
round-trip tests. Keep the existing UI temporarily, but route existing Add/Skip/commit/retry calls
through interaction answers so command semantics are proven first.

### Phase 2 — feed and dock

Replace the bounded timeline plus active workspace with one chronological feed. Introduce read-only
message artifacts and a persistent `MissionResponseDock`. Remove the plan-ready composer replacement,
inline plan fields, deck decision buttons/swipes, transcript retry buttons, and separate refinement
action row.

### Phase 3 — conversational planning and browsing

Add structured plan-change directives, sequential product questions, typed refinement acknowledgements,
kit-summary turns, Undo, and dock-driven Cart navigation. Preserve the deterministic floor when
Foundation Models is unavailable.

### Phase 4 — evaluation and polish

Tune when Crumb asks a clarification versus proceeds, collapse answered artifacts, add slow-network
and interruption behavior, and validate all accessibility and visual configurations.

## Acceptance gates

- The mission screen contains exactly one editable text input.
- No plan, product-decision, retry, or cart-review control exists outside the response dock.
- Every actionable assistant question has exactly one persisted pending interaction.
- Option, Other, general text, cancel, retry, and interruption paths all originate in the dock.
- Typed “yes,” “add it,” and “the first one” never mutate the kit without a uniquely resolved,
  explicit confirmation.
- Answer submission appends a user turn before applying one idempotent command.
- Relaunch restores an unanswered interaction without replaying planning, search, Add, or checkout.
- Stale thread, revision, interaction, product, and variant answers are rejected.
- Persistence failures before question display, after display, and during answer submission preserve
  a deterministic blocking recovery without accepting an undurable answer.
- Answer-versus-background-result races, stale App Intents, price changes, unavailable variants,
  Add/Undo, and checkout idempotency are covered.
- Assistant text alone cannot mutate plan, kit, cart, or checkout state.
- Catalog content containing instruction-like text cannot create a write interaction; unknown
  directives and hallucinated IDs are rejected; consecutive clarification is bounded.
- Checked-in fixtures migrate every V1 phase to V2 without inventing a write-capable interaction;
  V2 corrupt resolvers, option IDs, snapshots, and revisions quarantine safely.
- Warm-session and reconstructed fresh-session trajectories are equivalent after validation.
- The deterministic simulator journey covers plan change, approval, Add, Skip, typed and suggested
  refinement, retry, cancellation, Cart round-trip, and unanswered-question relaunch.
- Visual and interaction checks cover default and accessibility XXXL, VoiceOver, dark mode,
  increased contrast, Reduce Motion, landscape, keyboard shown, and simulated slow networking.
- The activity turn and working dock commit synchronously with submission; bounded timeout, offline,
  ignored-cancellation, partial-result, and Stop paths never leave an indefinitely disabled dock.
- Deterministic mocks remain release-blocking. Targeted live direct-product and multi-part journeys
  may source the non-worktree `.env` read-only; they must never print, copy, persist, or commit it,
  and missing live configuration is reported as skipped rather than passed.
