# CrumbArt

Crumb's **programmatic** vector art, as plain SwiftUI — so the same shapes drive both the
live UI and the rasterized image assets, and nothing is a hand-exported black box.

## Library — `import CrumbArt`

The app links the `CrumbArt` library product (iOS / macOS / visionOS):

| Symbol | Used by | What it is |
| --- | --- | --- |
| `CrumbMark` / `CrumbGlyph` | everything | The brand atom: a torn, faceted "crumb" silhouette filled warm with a toasted crust and a hard break-facet. |
| `CrumbAppIcon` | the icon exporter | The icon composition — a warm crumb on a pine ground with a breadcrumb-fleck trail. `.iOS` is full-bleed; `.macOS` is the inset squircle. |
| `CrumbBadge` | `AppHeader`, `OnboardingView` | The in-app wordmark mark — the icon in miniature (replaces the old `leaf.circle.fill`). |
| `ProductArt` | `ProductCard` | Refined product-card art: a multi-stop ground, seeded topographic contours, a frosted focal glyph, and a quiet crumb watermark. Also the loading/failure fallback behind live product photos. |
| `CrumbHeroArt` | `OnboardingView` | The onboarding hero band — a diminishing breadcrumb trail leading into a kit. |
| `CrumbEmptyArt` | `CurateView` | Curate empty states (`.kitReady` / `.nothingYet`) — a kit holding (or missing) a crumb. |
| `MarketingFrame` | the marketing tool | A store-style caption + device-framed screenshot on the Crumb board. |

`ArtPalette` owns the exact brand hexes (it mirrors the app's `CrumbColor`, plus art-only
depth shades), because the render tools can't link the app target.

## Tools (macOS, run from `projects/crumb-llc-app/`)

**App icon → `Assets.xcassets/AppIcon.appiconset`** (iOS 1024 + macOS 512 @1x/@2x):

```sh
swift run --package-path CrumbArt crumb-art-render
```

It rasterizes `CrumbAppIcon` with `ImageRenderer`, writes the PNGs, and rewrites
`Contents.json`. Re-run `xcodegen generate` only if the catalog *membership* changed.

**Marketing cards** from captured screenshots:

```sh
swift run --package-path CrumbArt crumb-art-market <screenshots-dir> <out-dir>
```

## Headless screenshots (DEBUG only)

`simctl` can't inject taps, so deep screens are reached with launch environment read by
`CrumbApp` / `RootView`. Screenshot mode also forces the **mock catalog** for deterministic
seed products (which is what exercises `ProductArt`):

| Env (`SIMCTL_CHILD_…`) | Lands on |
| --- | --- |
| _unset_ | Onboarding (first run) |
| `CRUMB_SCREENSHOT=missions` | Missions (profile pre-seeded, onboarding skipped) |
| `CRUMB_SCREENSHOT=curate` `CRUMB_MISSION=<id>` | The curate deck |
| `CRUMB_SCREENSHOT=kit` `CRUMB_MISSION=<id>` | The "that's a kit" empty state |
