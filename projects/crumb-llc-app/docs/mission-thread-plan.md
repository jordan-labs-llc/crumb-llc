# Mission threads — implementation plan

> Historical implementation plan: the durable thread/domain design remains current, but the
> hybrid “active artifact + composer” UI described below was superseded by
> [conversation-first-mission-design.md](conversation-first-mission-design.md). The shipping
> interface uses one chronological, read-only conversation feed and one bottom response dock.

## Outcome

Crumb treats each shopping mission as one durable conversation-backed workspace. Planning,
catalog gathering, product decisions, and refinements change the active artifact inside that
workspace instead of navigating through separate Plan and Curate screens. The product deck,
editable plan, refinement chips, kit tray, and checkout remain purpose-built controls.

The application owns the thread record. Apple Foundation Models transcripts are model context,
not commerce state, and are never the source of truth for plans, candidates, or the kit.

## Scope

This change will:

1. Add a versioned `MissionThread` aggregate to CrumbKit with a unique thread ID, original and
   current goal, phase, task,
   editable plan, candidates, base candidates, remaining deck order, kit, refinement context,
   recipient snapshot, timestamps, and an ordered typed timeline.
2. Add `MissionThreadStore` in-memory and SwiftData implementations. The SwiftData record stores
   the versioned aggregate atomically as JSON and is included in `CrumbPersistence.models`.
3. Create a thread before planning starts, immediately route into it, and record planning,
   search, refinement, product-decision, and failure events in user-facing language.
4. Guard every asynchronous planner, gather, curation, chip, and refinement completion with both
   the unique thread ID and a unique per-operation ID. Superseding work is cancelled and its
   operation ID invalidated; commit never relies on cooperative cancellation alone.
5. Replace `.plan` and `.curate` routes with one `.missionThread` route. Phase changes update the
   active artifact without remounting the workspace.
6. Add a compact semantic timeline above the active artifact. It shows user messages, Crumb
   responses, and application activity without exposing prompts, raw tools, JSON, or reasoning.
7. Preserve the editable plan, streaming deck, Add/Skip controls, refinement chips, pinned kit
   tray, accessibility actions, deterministic fallbacks, Cart, checkout, History, Siri, and App
   Intents.
8. Persist a bounded, most-recent-first set of incomplete threads and offer a Continue section from
   Missions. Resuming restores
   the plan, products, deck order, kit, recipient, refinements, and timeline without replaying tool
   side effects.
9. Link History receipt snapshots to their originating thread with one optional scalar `threadID`.
   Deleting either side never cascades to or invalidates the other.
10. Fix `ShoppingTask.rebuilt` so `isSingleItem` survives plan edits.

## Domain and mutation rules

- `AppModel.activeThread` is the only writable mission state. Task, draft plan, candidates, base
  candidates, deck order, kit, recipient, and refinement context are computed projections into it.
  Every mutation runs through one `mutateActiveThread` transaction that validates the command,
  updates the snapshot, increments its revision, optionally appends timeline entries, and
  synchronously persists. There is no later bidirectional snapshot/synchronization path.
- The timeline is an append-only explanation of committed domain operations and terminal failures,
  not an event-sourced replay log. Retry descriptors are structured data, never parsed from prose.
- Thread timeline entries have stable IDs, a monotonic sequence, a semantic kind, text, timestamp,
  and optional product/operation identity.
- Product and kit mutations remain deterministic application commands. Assistant prose alone can
  never add an item or begin checkout.
- Add/remove operations are idempotent by product ID. Search tools remain read-only. Checkout stays
  behind the existing explicit user interface and confirmation flow.
- A new prompt while a turn is active is disabled rather than queued. A failed or cancelled turn
  leaves a visible retryable event and no permanent pending state.
- Only final semantic messages are persisted; transient streaming text and spinner state are not.
- Durable JSON uses frozen `MissionThreadDocumentV1` DTOs. The codec reads the version header first,
  decodes the matching frozen shape, validates invariants, and migrates it into the current domain.
  Corrupt payloads are quarantined as `MissionThreadLoadFailure` values so Missions can show a
  non-crashing “Mission couldn’t be restored” row with Delete; they are never silently emptied.
- `MissionThreadStore.save` is synchronous, throwing, and revision-ordered: an older revision may
  not overwrite a newer row. Memory stays usable after a disk error, while the thread exposes a
  visible “Not saved on this device” notice and a retry path.
- The store keeps at most 12 incomplete threads. Completed/abandoned threads are removed from the
  continuation list; History remains their independent receipt. Declined threads remain retryable
  until explicitly deleted or superseded by a successful goal in that same thread.

## State machine and interruption recovery

- `planning`: the goal and recipient snapshot exist; `task` may be absent; one planning operation
  may be pending.
- `planReady`: `task` and a nonempty stable-ID draft plan exist.
- `gathering`: a committed task and searchable queries exist; partial product batches may exist.
- `deckReady`: candidates/base candidates are unique and every remaining deck ID resolves to a
  candidate; accepted/skipped products are absent from the deck; kit products and variants are
  unique and valid.
- `failed`: a structured retry descriptor records planning input, gather task revision, or
  refinement text and the stable phase to return to.
- `declined`: no task is required and the composer can submit a replacement goal in the same thread.

The durable snapshot stores a semantic `pendingOperation` containing operation ID, kind, input, and
pre-operation stable phase. On load, `recoverAfterInterruption` clears it and appends one idempotent
interruption event: planning becomes retryable; gathering with partial candidates becomes actionable
with optional Retry, gathering without candidates returns to the plan; refinement restores the last
committed deck and offers Retry. Task handles and spinner flags remain transient.

Decoded snapshots run `validateAndNormalize`: product, kit, timeline, plan, and operation IDs must be
unique; deck IDs must resolve; kit variants must belong to their product; timeline sequence must be
strictly increasing; and phase prerequisites must hold. Harmless duplicates normalize
deterministically; irreparable documents are quarantined.

## Foundation Models boundary

- Keep the existing planner, mission orchestrator, curator, refinement interpreter, relevance
  gate, and recap writer seams. Their model-backed and rule-based implementations feed the same
  thread mutations.
- Do not persist Apple `Transcript` in v1 and do not replace the existing seams with one unrestricted
  agent loop.
- Dynamic profiles continue to expose only the read tools needed by the current task. Any future
  write tool must validate the current thread, known product and variant IDs, an idempotent operation
  ID, and explicit user intent.
- Context compaction is a separate model concern. Durable goal, recipient, constraints, plan, and
  kit state come from `MissionThread`, never from whether an old transcript entry survived trimming.

## Original UI structure (superseded)

`MissionThreadView` has three layers and is keyed by thread ID, never phase:

1. A user-controlled collapsible, chronological timeline. It never automatically removes the
   VoiceOver-focused entry. A current status live region announces only new work.
2. One active artifact: planning/decline state, an extracted inset-free `EditablePlanArtifact`,
   search state, or an extracted inset-free `ProductDeckArtifact`. Existing routed `PlanView` and
   `CurateView` are not nested because they own scrolling, full-height frames, safe-area insets, and
   root accessibility identities.
3. One bottom safe-area inset, ordered as optional KitTray then `MissionThreadComposer`. At
   accessibility Dynamic Type sizes the deck becomes a vertically scrolling single-card layout
   with explicit Add/Skip buttons rather than a fixed-height stack.

Cart remains a focused route. Back from Cart returns to the same thread, preserving the exact deck,
kit, and timeline. Back from the thread returns to Missions without deleting it.

Composer dispatch is explicit: planning/gathering/reworking is disabled with specific status copy;
declined retries planning with a replacement goal in the same thread; plan-ready v1 uses the
editable plan artifact and disables free-text with “Edit the plan above”; deck-ready uses the
existing refinement pipeline. Reset appends `refinementsReset`, clears active refinement context,
and leaves earlier turns visibly marked as superseded.

## Implementation sequence

1. Add and test the thread domain types, frozen V1 DTO/codec, invariant validator, throwing
   revision-safe store protocol, SwiftData record, corrupt-row quarantine, shared-schema
   registration, current-schema round trips, and a legacy-four-model to five-model disk migration.
2. Inject the store into `AppModel`; make `activeThread` the only writable mission state; expose
   existing view-facing values as projections; create, mutate, save, recover, resume, and delete
   through one transaction path.
3. Add thread plus operation guards, structured pending operations, cancellation/invalidation, and
   interruption recovery to every asynchronous pipeline.
4. Consolidate routing and navigation around `.missionThread`.
5. Extract inset-free editable-plan and product-deck artifacts; add `MissionThreadView`, timeline
   rendering, waiting/decline states, phase-aware composer, one ordered bottom inset, and the
   bounded Missions continuation section.
6. Record plan/search/refinement/decision/cart events only after their corresponding state changes.
7. Update App Intents, screenshot hooks, live-journey expectations, architecture documentation, and
   accessibility identifiers.
8. Add a DEBUG persistent UI-test mode that selects `MockUCPClient` independently of screenshot
   fixtures and uses an isolated on-disk SwiftData store with explicit one-time reset/seed controls.
   Run deterministic unit, app, UI, persistence-relaunch, and simulator visual checks. Run live
   broker journeys only when a local `Secrets.plist` is available.

## Required adversarial tests

- Two same-goal threads have different IDs; late planning, gathering, curation, and refinement work
  from the first cannot mutate the second. Retried operations inside one thread also reject the
  superseded operation’s late completion.
- Direct-product missions remain `isSingleItem` after editing and committing the plan.
- Thread store round-trips planning-without-task, declined, plan, recipient snapshot, candidates,
  deck order, kit, refinements, pending operation, timeline order, and schema version. Checked-in V1
  JSON fixtures decode, corrupt rows quarantine, stale revisions are rejected, and a real legacy
  four-model on-disk store migrates without losing existing data.
- Relaunch/resume restores actionable state without reissuing search or checkout side effects, and
  crash fixtures recover planning, gather, and refinement pending operations exactly once.
- Repeated Add is idempotent; assistant text alone cannot mutate the kit.
- Reset marks earlier refinements superseded and excludes them from future active context.
- A total catalog outage, unavailable model, timeout, and interrupted pending turn produce an inline
  retry state and never leave the composer permanently disabled.
- The single route remains mounted while the active artifact changes from plan to deck.
- Add/Skip, typed refinement, chip refinement, Reset, Cart round-trip, gift context, and
  direct-product wording remain correct.
- VoiceOver order and identifiers remain stable; controls remain reachable with Reduce Motion,
  dark mode, increased contrast, and accessibility-extra-extra-extra-large content size.

## Validation gates

- Xcode 27 / Swift 6.4 CrumbKit suite passes.
- Generated Xcode project builds for the iOS 27 simulator.
- `CrumbTests` and `CrumbKitSimTests` pass.
- A deterministic `MissionThreadUITests` journey passes on the iOS 27 simulator and captures the
  timeline, plan, deck, refinement, Cart return, and relaunch/resume states.
- The deterministic resume journey uses persistent mock UI-test mode, not the in-memory screenshot
  fixture and not a live broker.
- Simulator screenshots are inspected in default and accessibility visual configurations.
- `git diff --check`, repository status, and a final targeted/full test pass are clean.

## Explicit non-goals

- Persisting Apple Foundation Models transcripts.
- A single unrestricted model agent controlling every mission stage.
- Autonomous checkout or purchase tools.
- Branching conversations, multiple simultaneous active model sessions, or replay-based event
  sourcing.
- Replacing History receipts or rendering every historical deck inline.
