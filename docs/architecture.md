# Crumb — Architecture (1-page overview)

This document is a short orientation. The authoritative spec for the current scaffold is
the initial setup brief that seeded this work (kept with the implementer); this page
summarizes the shape that brief asked for and links the pieces together.

## What Crumb is

A task-driven personal-curator shopping agent. The user hands over a **mission**
("pack me for a rainy weekend hike"). Crumb proposes products as a **swipeable deck**;
accepted items build into a **kit** — a cross-merchant cart. Checkout **hands off per
shop** to each merchant's own secure checkout (honest to what's GA today on Shopify's
Universal Commerce Protocol). The signature UI element is the **kit tray** that fills as
the user swipes.

## Module boundaries

```
┌───────────────────────────────────────────────────────────┐
│ Crumb (app target — UI only, @MainActor, SwiftUI)          │
│   App/           CrumbApp, AppModel (@Observable), RootView │
│   DesignSystem/  CrumbColor / CrumbType / CrumbMetrics      │
│                  Components/ (KitTray, ProductCard, …)      │
│   Features/      Missions → Plan → Curate → Cart, Taste…    │
│   Intents/       CurateKitIntent, ShoppingTaskEntity, …     │
│   Resources/     Assets.xcassets, LaunchScreen              │
└───────────────────────────┬───────────────────────────────┘
                            │ depends on (local SPM package)
┌───────────────────────────▼───────────────────────────────┐
│ CrumbKit (Swift package — core logic, NO UI, Sendable)     │
│   Models/    ShoppingTask, Product, Variant, Shop,         │
│              KitItem, Cart, TasteProfile                     │
│   Services/  UCPClient (protocol), MockUCPClient,           │
│              UCPConfig, Placement                            │
│   Curator/   CuratorEngine (protocol), RuleBasedCurator     │
│   SeedData/  three sample missions (hike / coffee / desk)   │
└───────────────────────────────────────────────────────────┘
```

Keeping models/services/curation in `CrumbKit` makes them testable (`swift test`) and
reusable by future projects (`crumb-llc-api`, etc.). All UI stays in the app target.

## Flow

```
Missions ──tap task──▶ Plan ──"Curate my kit"──▶ Curate ──kit tray──▶ Cart ──▶ per-shop handoff
   ▲                                                                                  
   └──── "Hey Siri, ask Crumb…" ──▶ CurateKitIntent ──▶ Plan (preselected mission)
```

`AppModel` is `@Observable` and owns `route`, `selectedTask`, `kit`, `tasteProfile`, and
the injected `UCPClient` + `CuratorEngine`. `RootView` switches on `AppModel.route`.
`AppModel` is registered as an **App Intents dependency** at launch so Siri/Shortcuts can
drive navigation into the Plan screen.

## Seams left open (intentionally not built yet)

- **Networking:** `UCPClient` is a protocol; only `MockUCPClient` exists. A
  `LiveUCPClient` mapping to UCP `search_catalog` / `get_product` / Universal Cart /
  `continue_url` is a drop-in later. Global Catalog search is GA (API key only); native
  in-agent checkout requires Shopify opt-in; Universal Cart is early access — so
  **per-shop handoff** is the default checkout path.
- **Curation:** `RuleBasedCurator` is deterministic. A future `FoundationModelsCurator`
  (on-device `LanguageModelSession`) sits behind the same `CuratorEngine` protocol, gated
  by `if #available(iOS 27, *)` + `SystemLanguageModel.default.isAvailable`.
- **Platforms:** iOS/iPadOS/macOS/visionOS are wired; watchOS/tvOS are noted seams only.
- **Secrets:** `UCPConfig` reads a gitignored `Secrets.plist`; `Secrets.example.plist`
  is committed as a template. Setup runs with the mock and no real key.

## Toolchain

Built with the Xcode 26 / Swift 6 line (strict concurrency, Swift 6 language mode),
deployment minimum **26.0** across platforms. 27-only features (App Intents 2.0
affordances, Foundation Models) are gated behind `#available(iOS 27, …)`.
