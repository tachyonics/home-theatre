# home-theatre

Curation tooling for an Emby library, aimed at the parts Emby's own metadata
editor structurally cannot express: display ordering, extras association, and
specials interleaving.

## Why

Emby's Metadata Manager edits fields well. It has no concept of "this file is an
extra belonging to that episode" (that is filesystem layout, resolved at scan
time) and only offers three canned episode orders (aired / dvd / absolute). This
tool owns those two things and leaves everything else to Emby.

The output is NFO sidecars and file layout, so nothing here is a server — Emby
reads the result, and so would Jellyfin or anything else that speaks Kodi-style
NFO.

## Layout

- `Sources/HomeTheatreCore` — all logic, no UI dependency
  - `Model` — series / season / episode / extra, with **identity numbering kept
    separate from display numbering**
  - `NFO` — lossless XML tree plus typed reads of the structural tags
  - `Scan` — filename and folder parsing, and the library scanner
  - `Resolve` — derives the sequence a client actually renders
  - `Report` — plain-text rendering of a resolved library
- `Sources/AdminUI` — a deliberately minimal macOS harness for exercising the core
- `Tests/HomeTheatreCoreTests` — includes a Doctor Who fixture covering specials
  interleaved between seasons, a merged two-parter, and extras at every level

## Running

```sh
swift test          # 20 tests
swift run AdminUI   # pick a TV library folder, read the resolved structure
```

`AdminUI` is currently read-only: choose a library root and it prints how the
tree resolves — episodes in display order, extras and their parents, and anything
it could not place.

## The rules this encodes

Taken from Emby's `NfoMetadata` plugin rather than documentation, because the
documentation does not cover them:

- **Identity and display are separate.** `<season>`/`<episode>` drive provider
  matching; `<displayseason>`/`<displayepisode>` drive presentation. Emby only
  ever *writes* display numbering for specials, but its parser *honours* it on any
  episode — which is what makes arbitrary custom ordering possible.
- **Five tags, two properties.** `<displayseason>`, `<airsbefore_season>` and
  `<airsafter_season>` all write the same sort-parent; `<displayepisode>` and
  `<airsbefore_episode>` share a sort-index. Document order decides the winner.
- **Ordering values must be > 0.** Nothing can be placed ahead of episode 1 of a
  display season without renumbering that season.
- **`Specials` is ambiguous.** It is both a season-0 folder name and a valid
  extras folder name; content disambiguates — `SxxExx`-named files make it a
  season.
- **`season.nfo` overrides the folder name.** It lives inside the season folder
  with root element `<season>` (not `<seasondetails>`), and its `<seasonnumber>`
  sets the season's index — so a folder named `Season 1` holding
  `<seasonnumber>2</seasonnumber>` is season 2.
- **Extras carry no NFO**, so the filename is the on-screen title.

## Next

1. Verify the resolver against a real Emby library — load, re-serialise, and
   confirm an empty diff. Spurious diffs are rules this scanner has wrong.
2. NFO write path: merge managed fields into the existing document, preserving
   unrecognised elements.
3. Plan / apply: file moves and NFO writes as a reviewable, journalled,
   idempotent operation list.
4. Editing UI on top of a model that already round-trips.
