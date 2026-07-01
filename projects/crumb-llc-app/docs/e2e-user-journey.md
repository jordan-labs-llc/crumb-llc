# E2E user-journey runbook (for a coding agent)

This is a repeatable recipe for **driving a full purchase journey in the iOS 27 Simulator,
capturing every screen, assessing the UX, and filing issues**. It was written from a
"buy premium jasmine tea" run, but the goal is a parameter — swap it for any mission.

The journey is driven by a real **XCUITest** (`CrumbUITests/JasmineTeaJourneyTests.swift`),
which taps live accessibility elements. That is the supported way to "simulate clicks"
here — this machine has no `idb`/`fbsimctl`, and `xcrun simctl` cannot inject taps.

---

## 0. Prerequisites (read this first — it will save you an hour)

| Requirement | Why | How |
|---|---|---|
| **Xcode 27** (currently `/Applications/Xcode-beta.app`) | The app deploys to iOS 27 and links the Foundation Models dynamic-session API that ships only in the iOS 27 runtime. The default `xcode-select` may be 26.x. | Prefix every `xcodebuild`/`simctl` with `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`. Verify: `DEVELOPER_DIR=… xcodebuild -version` → `Xcode 27.x`. |
| **iOS 27 simulator** | Must match the deployment target. | `xcrun simctl list devices available` → pick an **iOS 27.0** device (e.g. `iPhone 17 Pro`). Grab its UDID. |
| **XcodeGen** | The `.xcodeproj` is generated from `project.yml`; **it is not committed**. | `brew install xcodegen`; run `xcodegen generate` after adding/renaming any source file (including a new test). |
| **Live broker vs. mock** | The **mock catalog has no tea** (only hike/coffee/desk seed data). A real product journey needs the live UCP broker. | Run with **no** `CRUMB_SCREENSHOT` env var. `Secrets.plist` already points the app at the live broker; a debug build then uses `LiveUCPClient`. Any `CRUMB_SCREENSHOT` value forces `MockUCPClient` — do **not** set it for a real run. |

> Sanity-check the broker before a run so you can tell "app bug" from "backend down":
> ```bash
> BASE=$(plutil -extract CRUMB_API_BASE_URL raw Crumb/Resources/Secrets.plist 2>/dev/null)
> curl -s -m 15 "$BASE/healthz"                       # -> {"status":"ok","configured":true}
> curl -s -m 30 -X POST "$BASE/catalog/search" \
>   -H 'Content-Type: application/json' \
>   -d '{"query":"premium jasmine tea","limit":5}' | python3 -m json.tool | head -40
> ```
> The broker **scales to zero**, so the first search after idle can take ~30s (cold start).
> `priceMin.amount` is in **cents**.

---

## 1. Build, boot, run

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
cd projects/crumb-llc-app
SIM=<iOS-27-device-UDID>

xcodegen generate                       # only if you touched sources/tests
xcrun simctl boot "$SIM" || true
open -a "$DEVELOPER_DIR/Applications/Simulator.app"

# Build the app + test bundle once, then run only the journey test.
xcodebuild build-for-testing -project Crumb.xcodeproj -scheme Crumb \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath build/dd \
  CODE_SIGNING_ALLOWED=NO

# Fresh install so first-run onboarding is part of the journey:
xcrun simctl uninstall "$SIM" com.crumbllc.Crumb 2>/dev/null || true

xcodebuild test-without-building -project Crumb.xcodeproj -scheme Crumb \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath build/dd \
  -only-testing:CrumbUITests/JasmineTeaJourneyTests \
  -resultBundlePath build/journey.xcresult \
  CODE_SIGNING_ALLOWED=NO
```

Notes:
- `xcodebuild` **buffers stdout**; per-step `NSLog` markers (`CRUMB-JOURNEY …`) mostly appear
  only at the end. The screenshots/trees live in the **result bundle**, not stdout.
- A warm-broker run is ~50s; a cold-start run can be 2–3 min. Keep the network-dependent
  waits in the test generous (the plan step allows 60s, curate 90s).
- Watch progress non-intrusively with `xcrun simctl io "$SIM" screenshot /tmp/peek.png`
  (screenshots don't interfere with the running test).

---

## 2. Extract the evidence (screenshots + accessibility trees)

The test attaches a full-screen screenshot **and** a text dump of the accessibility tree at
every step (`snap("03-plan")` → `03-plan.png` + `03-plan.tree.txt`). Export them:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
OUT=build/journey-out; rm -rf "$OUT"
xcrun xcresulttool export attachments --path build/journey.xcresult --output-path "$OUT"
# Files are UUID-named; the manifest maps them to the snap() names:
python3 - "$OUT" <<'PY'
import json,os,shutil,sys
o=sys.argv[1]; m=json.load(open(f"{o}/manifest.json"))
def walk(x):
    r=[]
    if isinstance(x,dict):
        if "exportedFileName" in x and "suggestedHumanReadableName" in x:
            r.append((x["exportedFileName"],x["suggestedHumanReadableName"]))
        for v in x.values(): r+=walk(v)
    elif isinstance(x,list):
        for v in x: r+=walk(v)
    return r
os.makedirs(f"{o}/named",exist_ok=True)
for exp,name in walk(m):
    if os.path.exists(f"{o}/{exp}"): shutil.copy(f"{o}/{exp}", f"{o}/named/{name}")
print("\n".join(sorted(n.split('_0_')[0] for _,n in walk(m) if n.endswith('.png'))))
PY
```

The `*.tree.txt` dumps are the **accessibility audit**: they list every element's
identifier, label, and frame — use them to verify VoiceOver labels and to find what to tap.

---

## 3. The journey (what "done" looks like)

Expected route: **Onboarding → Missions/composer → Plan → Curate deck → Kit tray → Cart
(per-shop) → Checkout handoff sheet.** There is **no in-app payment** — the handoff opens the
merchant's own web checkout (the test stops at the sheet and does **not** tap continue).

Steps captured by the driver:

| snap | screen | key action |
|---|---|---|
| `00-launch` | onboarding (fresh install) | tap **Skip** |
| `01-missions` | composer | type the goal into `composerField` |
| `02-goal-typed` | composer | tap `planButton` ("Plan it") |
| `03-plan` | plan editor | tap **Curate my kit** |
| `04-curate-first`…`06-curate-after-adds` | curate deck | tap **Add to kit** ×N |
| `07-cart` | cart | tap **Continue to {shop}** |
| `08-handoff` / `09-final` | handoff sheet | (stop — do not open external URL) |

### Gotchas that will trip an agent

- **Accessibility-id clobbering.** A screen-level `.accessibilityIdentifier("XScreen")` on a
  **non-scroll container (VStack)** propagates onto its children and overrides their ids.
  So on Curate, `addButton`/`skipButton` actually report `identifier:'CurateScreen'`, and the
  plan CTA reports `PlanScreen` instead of `curateButton`. **Tap those by visible label**
  ("Add to kit", "Skip", "Curate my kit"). Ids on `ScrollView`-rooted screens (Missions, Cart)
  survive, so `composerField`, `planButton`, `continue.<shop>` work by id. (This is filed as an
  issue; until fixed, prefer label taps for deck/plan CTAs.)
- **KitTray has no id** — match its button by label prefix `"Kit,"` (it reads
  "Kit, N items from M shops, subtotal $X"; empty state: "Your kit is empty").
- **Never gate a tap on a bare `.exists`** right after a screen appears — the control may lag
  the container. Use the `waitTap` helper (waits for existence, then hittability, then taps).
- **`continueAfterFailure = true`** so the run walks as far as the app allows and you capture
  *where* it breaks instead of aborting at the first missing element.

### Reusing the driver for a different goal

Edit the goal string in `JasmineTeaJourneyTests.swift` (`field.typeText("…")`), or generalize
it to read `app.launchEnvironment["CRUMB_UITEST_GOAL"]`. Keep the mission narrow enough that
the live catalog can actually fill it.

---

## 4. Assess each step

For every screen, judge: *Is the copy on-goal? Is the pick relevant and sanely priced? Is the
next action obvious? Are the a11y labels correct (from the `.tree.txt`)?* Cross-check the
curated deck against a **plain broker search** for the same query — if the plain search returns
better/cheaper/on-category results than the deck's top items, that's a curation-quality bug
(query drift, missing price-sanity, ranking). Record the concrete evidence (product title,
price, shop) — screenshots + tree dumps are your citations.

---

## 5. Record issues

Repo: `jordan-labs-llc/crumb-llc`. Labels exist for priority (`P0`–`P3`) and area
(`curation`, `accessibility`, `ux`, plus stock `bug`/`enhancement`).

```bash
gh issue create \
  --title "<area>: <one-line defect>" \
  --label "P0,curation,bug" \
  --body-file <(cat <<'EOF'
## Problem
<what happened, with the exact evidence: product title / price / shop / screen>

## Expected
<the correct behavior>

## Proposal
<concrete fix direction>

## Evidence
<snap name(s), tree excerpt, and/or the plain-search comparison>
EOF
)
```

Keep one issue per defect, most-severe first, and put the reproducing evidence in the body so
the fix can be verified against the same run. The prior run's issues are #20–#28.
