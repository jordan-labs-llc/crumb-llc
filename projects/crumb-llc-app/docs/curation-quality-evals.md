# Curation quality evals

This is the local regression gate for curation-quality changes. It captures the failure families
that previously required a full manual purchase journey to notice: query drift, price-insane decks,
off-topic candidates, generic card rationale, and golden mission regressions.

## Current harness

Run the deterministic eval set:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
cd projects/crumb-llc-app/CrumbKit
swift test --filter CurationQualityEvalTests
```

The suite lives in `CrumbKit/Tests/CrumbKitTests/CurationQualityEvalTests.swift` and is intentionally
CI-safe. It does not call a live model. Instead, it scores the deterministic floor and the post-model
guards that every model tier uses before a deck reaches the UI:

- Query drift: a narrow "premium jasmine tea" mission must keep "jasmine" and "tea" in each query.
- Price sanity: a model-proposed `$1,450` adjacent-tea outlier is demoted out of the top three.
- Relevance: strict core terms keep jasmine products while dropping adjacent tea and desk products.
- Voice quality: raw merchant blurbs become mission-anchored Crumb rationale.
- Golden missions: hike, coffee, and desk seed missions still gather and curate complete decks.

## Baseline

Baseline recorded on 2026-07-02 with:

- Xcode: `Xcode 27.0` / `Build version 27A5209h`
- Command: `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --filter CurationQualityEvalTests`
- Expected result: 6 tests pass, 0 fail.

Run the full package suite before merging curation changes:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
cd projects/crumb-llc-app/CrumbKit
swift test
```

## Apple beta tooling

This machine has the beta hooks needed for a future live-model layer:

- `fm` CLI is available at `/usr/bin/fm`.
- `Evaluations.framework` exists under the Xcode 27 beta platform developer libraries, including
  `iPhoneSimulator.platform/Developer/Library/Frameworks/Evaluations.framework`.

Do not replace the deterministic suite with live model assertions. Add live scoring beside it once
the Evaluations API shape is pinned. The live layer should run multiple seeds per case and compare
old vs new instructions statistically; single model responses are too noisy for a merge gate.

Useful starting commands:

```bash
fm available
fm quota-usage
fm respond --stream 'Rank these products for a premium jasmine tea gift.'
fm token-count 'premium jasmine tea'
```

For live scoring, feed the same five case families into the Evaluations framework or an `fm`-backed
script, then write the aggregate report here with date, device or simulator configuration, prompt
revision, pass rate, and any statistically significant regressions.
