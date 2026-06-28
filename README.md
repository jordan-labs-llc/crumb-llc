# crumb-llc

The Crumb mono-repo. **Crumb** is a task-driven personal-curator shopping agent: you
hand over a *mission* ("pack me for a rainy weekend hike"), Crumb proposes products as
a swipeable deck, accepted items build into a **kit** (a cross-merchant cart), and
checkout **hands off per shop** to each merchant's own secure checkout. Discovery and
checkout ride on Shopify's Universal Commerce Protocol (UCP) Catalog APIs.

## Repository layout

Every project lives at `projects/{project-name}` and is **self-contained** — it owns its
own README, build, and tooling. The root only carries shared conventions and docs.

```
crumb-llc/
├── README.md            # you are here
├── .gitignore           # Swift/Xcode + macOS + node (for future projects)
├── .editorconfig
├── .gitattributes
├── docs/
│   └── architecture.md  # 1-page overview
└── projects/
    └── crumb-llc-app/   # the multiplatform SwiftUI app (Crumb)
```

### The `projects/{project-name}` convention

Future siblings follow the same pattern and are added under `projects/` as they appear:

| Project              | Status   | What it is                                            |
| -------------------- | -------- | ----------------------------------------------------- |
| `crumb-llc-app`      | present  | Multiplatform SwiftUI app (iOS/iPadOS/macOS/visionOS) |
| `crumb-llc-api`      | planned  | Backend / UCP integration service                     |
| `crumb-llc-infra`    | planned  | Infrastructure-as-code                                |

> Only `crumb-llc-app` exists today. The other rows describe the convention so the root
> is ready for them — do not assume they are present.

## Getting started

See [`projects/crumb-llc-app/README.md`](projects/crumb-llc-app/README.md) for build and
run instructions. The app runs entirely on mock data (`MockUCPClient`) — no API keys or
network access are required for the current scaffold.

## Status

Scaffolding only: structure, navigation, design tokens, mock data, and protocol seams.
Real networking, payments, and the curation algorithm are intentionally **not** wired up
yet. See `docs/architecture.md` and the per-project README for what is and isn't built.
