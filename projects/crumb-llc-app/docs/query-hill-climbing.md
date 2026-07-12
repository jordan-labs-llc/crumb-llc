# Query hill-climbing runbook (for coding agents)

This is the repeatable process for improving how Crumb turns a shopping goal into catalog
queries with Apple Foundation Models. It measures the production planner—not an approximation
written for `fm`—and prevents a prompt change from looking better merely because it was tested on
easy examples.

The motivating failure is `find premium jasmine tea`. Shopify returns strong results for
`premium jasmine tea`, but the planner can lose `premium`, classify the goal as a multi-part kit,
add accessories, or leak unrelated taste vocabulary such as `merino` into retrieval queries.

---

## 1. What is being optimized

The inner-loop target is the output that actually reaches catalog gathering:

```text
user goal + taste profile
  → AppleFoundationMissionPlanner
  → PlannedMission
  → ShoppingTask.searchQueries
  → Shopify catalog
```

Score `ShoppingTask.searchQueries`, not the human-facing `plan` labels. The agentic orchestrator
and Shopify retrieval can be evaluated separately after the planner clears this suite.

The test corpus lives at:

```text
CrumbKit/Tests/Fixtures/shopping_query_cases.json
```

It contains single-item, kit, gift, ambiguous, noisy-input, negative-constraint, non-shopping,
and taste-conflict cases. Each case specifies its expected altitude plus required, allowed, and
forbidden retrieval terms or required kit concepts.

---

## 2. The evaluation tools

| Tool | Purpose |
|---|---|
| `crumb-query-collect` | Calls the real `AppleFoundationMissionPlanner` sequentially and checkpoints every run. |
| `crumb-query-harness` | Deterministically scores recorded observations. It never calls a model. |
| `Scripts/evaluate_queries.sh` | Runs collection, text scoring, and JSON scoring end to end. |

The collector uses the production planner's actual `PlannerInstructions`, `@Generable`
`MissionDraft`, profile tuning, retry behavior, and deterministic reconciliation. Do not replace it
with plain `fm respond` for a benchmark: that does not reproduce the app's guided generation.

Evaluation output is written beneath `.evaluation/`, which is intentionally gitignored. Each run
contains:

```text
.evaluation/<prompt-id>/
├── observations.json     # scorer input
├── report.json           # machine-readable score
├── report.txt            # human-readable score
└── raw/                  # one diagnostic JSON document per case/run
```

Raw records include planner tier, fallback note, latency, resolved taste profile, plan labels, and
catalog queries.

---

## 3. Prerequisites

CrumbKit currently requires Swift 6.4 and the macOS 27 Foundation Models runtime. Use Xcode beta:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
cd projects/crumb-llc-app/CrumbKit
```

The wrapper selects this Xcode automatically when it exists.

By default, collection requires every requested run to report `onDevice` or `privateCloud`.
Rule-based degradation is persisted for diagnosis and then causes the command to fail. This keeps a
fallback result from masquerading as a model evaluation. Use `--allow-fallback` only when testing the
fallback pipeline deliberately.

---

## 4. Establish a baseline

Use a unique prompt ID for every candidate. The ID labels results; it does not change the prompt.

One complete pass:

```bash
Scripts/evaluate_queries.sh \
  --prompt-id planner-baseline-YYYYMMDD \
  --runs 1
```

A stochastic comparison should normally use five runs per case:

```bash
Scripts/evaluate_queries.sh \
  --prompt-id planner-v2 \
  --runs 5
```

Collection is sequential to avoid model contention. It checkpoints after every generation. Rerun
the same command to resume missing runs; completed `(caseID, runID)` pairs are skipped. If the
selection or run count becomes narrower, the observation file is rewritten to contain only the
current selection, so stale runs cannot enter the score.

For a quick diagnostic:

```bash
Scripts/evaluate_queries.sh \
  --prompt-id jasmine-smoke \
  --runs 1 \
  --case tea-premium-jasmine \
  --case tea-jasmine-merino-leak
```

Partial runs opt into partial scoring automatically and report their corpus coverage prominently.
Never compare a partial headline with a full-corpus headline.

---

## 5. Understand the score

Each case receives 0–100 points. The scorer rewards:

- correct shoppability and single-item versus multi-part altitude;
- retention of required product terms and explicit constraints;
- complete coverage of required kit concepts across distinct queries;
- absence of forbidden taste or category vocabulary;
- usable, distinct, concise queries; and
- limited lexical similarity to reviewed canonical queries.

Hard failures cap a superficially plausible result. Examples include an unshoppable response, no
usable query, wrong altitude, or forbidden leakage. A multi-part critical pass requires concepts to
be distributed across at least two distinct concept-bearing queries; one giant query or duplicated
queries cannot pass.

The report includes:

| Metric | Interpretation |
|---|---|
| `Headline` | Weighted summary of mean, P10, critical-pass rate, and leakage. Never inspect alone. |
| `Mean` / `Median` | Typical case quality. |
| `P10` | Lower-tail reliability; important for stochastic model behavior. |
| `Critical pass` | Runs satisfying every semantic invariant. |
| `Altitude accuracy` | Correct single item, kit, or non-shopping classification. |
| `Required recall` | Required query terms or kit concepts retained. |
| `Forbidden leakage` | Runs containing prohibited vocabulary. |
| `Model runs` / `Tiers` | Proof that scoring reflects Foundation Models rather than fallback. |
| `Coverage` | Evaluated cases divided by the entire corpus. |

Strict scoring requires all corpus cases and equal run counts per case. The scorer rejects missing,
unknown, duplicated, or uneven observations instead of silently changing the denominator.

---

## 6. The hill-climbing loop

Change one behavioral variable at a time:

1. Record a baseline with the current code and a new prompt ID.
2. Inspect the worst runs and raw artifacts; group failures by cause.
3. Make one narrow change to instructions, schema, context, or deterministic reconciliation.
4. Run focused smoke cases while iterating.
5. Run the complete corpus with the same number of runs as the baseline.
6. Compare headline components, category summaries, and individual regressions.
7. Keep the change only if it passes the acceptance gates below.
8. Commit the code change and update the baseline section of this document when the new behavior is
   intentionally adopted.

Good hill-climb changes reduce the model's work or make invariants deterministic. For example:

- keep taste out of retrieval planning and apply it during ranking;
- deterministically preserve explicit product terms from the original goal;
- deterministically enforce obvious single-item altitude;
- split intent extraction from title/note generation; and
- always run exact planner queries before allowing an agent to broaden retrieval.

Avoid fixing one golden string with a special-case prompt while making other categories worse.

---

## 7. Acceptance gates

Compare candidates using the same corpus, model tier, OS/toolchain, and run count. A candidate should
not be retained unless:

- corpus coverage is 100% and per-case run counts are equal;
- every requested run used an actual model tier;
- the headline and P10 improve or remain within an explicitly justified tolerance;
- critical-pass rate does not decrease;
- forbidden leakage does not increase;
- no category mean falls by more than five points without a reviewed reason;
- `tea-premium-jasmine` and all taste-conflict cases pass every run; and
- focused and full CrumbKit tests pass.

Run tests with:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --filter QueryHillClimbScorerTests

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test
```

Do not promote a candidate solely because its headline increased. Inspect P10, leakage, altitude,
category regressions, and the actual worst-run queries.

---

## 8. Current baseline

Baseline recorded on 2026-07-11 from commit `1eb3f32`, prompt ID `planner-main-1pass`, one run per
case, using the on-device tier for all 76 cases:

| Metric | Result |
|---|---:|
| Headline | 27.0 |
| Mean | 60.4 |
| Median | 68.9 |
| P10 | 20.0 |
| Critical pass | 9.2% |
| Perfect | 7.9% |
| Altitude accuracy | 28.9% |
| Required recall | 61.0% |
| Forbidden leakage | 5.3% |
| Model provenance | 76/76 on-device |

Important observations:

- `find premium jasmine tea` produced `jasmine tea` plus `ceramic cup`, lost `premium`, and was
  incorrectly classified as multi-part.
- 54 of 76 cases had incorrect altitude.
- 15 cases emitted default taste vocabulary such as `merino`, `muted`, or `earthy` in catalog
  queries.
- The rainy-hike mission searched for `merino hiking boots`, `merino rain jacket`, and
  `merino daypack`.
- Only seven cases achieved a critical pass, including all four non-shopping controls.

This baseline strongly suggests that retrieval planning should not receive the general taste block,
and that obvious single-item altitude should be reconciled deterministically from the original goal.

---

## 9. Corpus maintenance

When a production failure is discovered:

1. Add a minimal case that reproduces it.
2. Encode semantic invariants, not one model sentence.
3. Put explicit user constraints in `requiredQueryTerms`.
4. Put known taste/category contaminants in `forbiddenQueryTerms`.
5. For kits, list independently searchable concepts in `requiredPartConcepts`.
6. Add one or more reviewed `canonicalQueries`.
7. Run the canonical corpus test; canonical observations must remain critical passes.

Do not weaken an expectation merely to make the current model pass. Change the corpus only when the
product requirement itself changes.
