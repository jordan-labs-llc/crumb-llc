# Direct missions: should the plan be removed?

> **Status (2026-07-23): shipped as the default.** The `CRUMB_DIRECT_MISSIONS` flag is gone —
> direct missions are the only flow. The pre-default-on checklist below was completed:
> the mid-gather free-text wedge now buffers as a post-settle refinement
> (`MissionThread.queuedRefinements`); `isShoppable`/`isSingleItem` are one guided FM call again
> (`GoalTriage` seam behind `DirectMissionPlanner`, heuristic floor); stop/failure recovery
> offers a "Resume shopping" confirmation instead of resurrecting plan approval; the relevance
> gate derives breadth from `isSingleItem` (not part count) and the gather tools pass their own
> query through for kit-breadth missions; kit-cue goals keep the deterministic plan as an
> editable-in-thread notice. The evaluation below is kept as the decision record.

**Question.** The on-device Foundation Model is not sophisticated enough to decompose even a
simple goal ("Premium jasmine tea") into a reasonable plan. Should the upfront plan be removed
entirely, letting the Foundation Model instead figure out what to call on the catalog API?

**Answer.** Remove the *upfront FM-generated plan and the approval turn* for single-intent
missions — the prototype validates this cleanly. Do **not** delete the plan data structure or the
deterministic planner: the one-part mission shell (title, query, single-item framing, declines)
is what the orchestrator, relevance gate, history, and cart framing all read. Kit-class goals
still need a parts list; keep them on a (deterministic or model-checked) plan until the
orchestrator + gate can carry breadth on their own.

## The prototype

`CRUMB_DIRECT_MISSIONS=1` (DEBUG launch environment, wired in `CrumbApp`):

- `RuleBasedMissionPlanner` builds the mission shell in ~1ms — no model call before shopping.
- `AppModel.retryPlanningInActiveThread` skips the plan-approval interaction and runs
  `beginCuration()` immediately; the planning receipt survives until the gathering receipt
  replaces it, so every persisted intermediate state stays crash-recoverable.
- The intelligence moves entirely into `AppleFoundationMissionOrchestrator`: the on-device model
  drives `search_catalog` / `find_similar` tool calls against the live broker, guarded per-result
  by the relevance gate, floored by the deterministic fan-out.

Flag off, nothing changes (verified: default `false`, Release forces `false`, full app suite green).

## Simulator evidence (iPhone 17 Pro, iOS 27, live Azure broker, on-device model up)

Same goal both runs: **"Find premium jasmine tea"**.

| Stage | Baseline (FM plan + approval) | Direct |
|---|---|---|
| plan | 4,400ms on-device → one generic part **"Tea"** (dropped *premium jasmine*) | 1ms rule shell, query = the goal verbatim |
| approval turn | required ("Should I shop it?") | none |
| gather (agentic) | 8,331ms, 15 candidates, `agent=true` | 7,849ms, 14 candidates, `agent=true` |
| curate settle | 31,045ms on-device | 26,530ms on-device |
| deck | top: Premium Jasmine Green Tea $7.99 | top: Natural Jasmine Green Tea $6.00; correct "Shortlist" framing |

The FM **planner** added 4.4s + an interaction turn and *degraded* the goal ("Tea") — the drift
class the hill-climb harness (#93) measures. The FM **orchestrator** performed well in both runs.
The model is good at choosing API calls inside a tool loop and bad at emitting an upfront
decomposition artifact; deck quality was rescued by the orchestrator + gate + TeaCuration, not by
the plan.

## Adversarial review findings (two independent reviewers)

Fixed in this prototype:

1. **Crash-recovery hole** — the direct branch persisted a `phase .planning` /
   `pendingOperation == nil` busy state that restore could not recover. Fixed by keeping the
   planning receipt alive across the handoff.
2. **Wrong cancellation slot** — the direct gather chain ran under the planning task slot, so a
   retry's `startCurating()` couldn't supersede it. Fixed by moving the handle to the gathering slot.
3. **Plan-change text searched verbatim** — `applyPlanChange`'s wrapper prompt ("…Update the
   shopping plan with this request…") is a model instruction; the rule-based planner would use it
   as the literal query. In direct mode the change is now folded into the goal and re-run.

Known limitations, deliberately accepted for the prototype (they define the removal boundary):

- **Kit-class goals degrade.** One-part missions make the relevance gate derive narrow core terms
  and drop the orchestrator's beyond-plan searches at the tool boundary (`GatherToolSupport.onTopic`);
  kit-completeness (#67) never engages; sports-kit assumptions have no surface to edit. Single-item
  goals (jasmine tea) are unaffected — gate, TeaCuration, history, re-shop behave identically.
- **Heuristic judgments replace model judgments**: `isShoppable` (declines) and `isSingleItem`
  (shortlist-vs-kit framing) are now word-cue heuristics for every goal. Mis-frames exist in both
  directions ("dorm room refresh" → shortlist; "sourdough starter kit" → kit).
- **Free text typed mid-gather** cancels the search and, on an empty deck, wedges into a stuck
  "Reworking" state (pre-existing bug, but direct mode makes the gather question the front door —
  fix before default-on).
- Stop-mid-gather and gather-failure retries can still resurface a plan-approval turn
  (`returnPhase: .planReady`); cosmetic in direct mode but inconsistent with its premise.

## Recommendation

1. **Ship direct missions for single-intent goals** (the overwhelmingly common case and the one
   the user experience complaint is about): goal → deterministic shell → agentic gather. No FM
   planner call, no approval turn.
2. **Keep one cheap guided FM call** for the two judgments the heuristics fumble — `isShoppable`
   + `isSingleItem` (sub-second, one `@Generable` bool pair) — with the heuristics as the floor.
3. **Route kit-cue goals through a plan** (deterministic expansions like `sportsKit`, or the FM
   planner while it lasts), surfaced as an *editable-in-thread notice* rather than a blocking
   approval turn. Revisit full removal once the relevance gate derives breadth from `isSingleItem`
   instead of part count and kit-completeness can be derived post-hoc from the gathered deck.
4. Before default-on: fix the mid-gather free-text wedge, make stop/failure recovery
   direct-mode-aware, and update the Siri handoff copy ("breaks it down into an editable plan").
