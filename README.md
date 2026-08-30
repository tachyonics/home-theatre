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
  - `Scan` — filename and folder parsing, the library scanner, and the sidecar
    asset scanner that maps files to the capabilities they provide
  - `Resolve` — derives the sequence a client actually renders, and the
    capability inventory behind the details pane
  - `Report` — plain-text rendering of a resolved library
- `Sources/AdminUI` — a deliberately minimal macOS harness for exercising the core
- `Tests/HomeTheatreCoreTests` — includes a Doctor Who fixture covering specials
  interleaved between seasons, a merged two-parter, and extras at every level

## Running

```sh
swift test          # 59 tests
swift run AdminUI   # pick a TV library folder, read the resolved structure
```

`AdminUI` is currently read-only: a three-column browser over Series → Seasons →
Episodes. Episodes are listed in resolved display order, badged `inherited` or
`pinned NxM`, with extras nested under whatever they belong to. Series-level
extras and unplaced files sit in the seasons column, since they belong to no
season.

A right-hand drawer describes whatever is selected — series, season or episode —
showing the resolved state (identity vs display numbering, where it renders, lock
state) above a **Provides** section: a drop-down over every capability that item
*could* supply, present or not, counted as "6 of 11".

Capability, not file, is the unit. A poster is one entry whether it is
`folder.jpg`, `poster.jpg` or a `season01-poster.jpg` sitting up in the series
folder, and the NFO is simply the "Series/Season/Episode Details" capability
rather than a special case. Picking one explains what it buys you and lists the
files behind it — thumbnail, pixel size, byte count, and which naming rule
claimed it.

Two things the file system will not tell you are made explicit. **Shadowed
files**: Emby checks the documented filenames in order and stops at the first, so
a `poster.jpg` sitting behind a `folder.jpg` is on disk and never read — it is
greyed out and labelled *Ignored — folder.jpg is checked first*, the same
treatment the NFO view gives a superseded tag. **Missing capabilities** stay in
the list rather than vanishing, showing the filenames that would satisfy them, so
absence is actionable instead of invisible — the same reasoning as the extras
drawer's fixed folder list.

Extras are deliberately *not* one of the capabilities. They are the bottom
drawer's subject and are scoped differently there — the selected item and
everything beneath it — so listing them here as well would only disagree with it.

The Details capability renders the NFO behind the item: every tag in document
order, colour-coded by role, with the file's raw source underneath. Tags Emby
would silently ignore are struck through and labelled, so an `<airsbefore_season>`
overwritten by a later `<displayseason>`, or a `<displayepisode>0</displayepisode>`
rejected for being non-positive, are visible rather than mysterious.

A bottom drawer lists the extras for the same selection. The left pane is a
fixed list of the nine extras folders Emby recognises — shown whether or not they
currently hold anything, because it is also the set of places an extra can be
filed — plus a bucket for extras bound by filename suffix, which sit in no folder
at all. Scope is the selected item **and everything beneath it**,
each row labelled with its real owner, so a series whose extras all hang off
episodes does not present as empty. The details drawer keeps full window height
beside both.

Either a library root (one directory per series) or a single series folder works;
the scanner detects which it was given, and the Auto/Library/Series control
overrides it when detection cannot tell. The toolbar's Report button opens the
full text rendering, which is the copyable, diffable view of the same data.

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

From Emby's naming documentation, which does cover these:

- **Images are named by role, and most roles accept several names in a fixed
  order.** Primary is `folder`, `poster`, `cover`, `default`, then `show` — the
  last valid only in a series folder. Backdrop, uniquely, is *multi-valued*:
  `backdrop`/`backdropX`, `fanart`/`fanart-X`, `background-X`, `art-X` and an
  `extrafanart/` sub-folder all accumulate rather than compete. Banner, Thumb,
  Logo, Disc and Clear Art each take their own aliases. Extensions are `jpg`,
  `jpeg`, `png`, `tbn`.
- **A series folder can hold season artwork.** `seasonXX-poster`,
  `seasonXX-fanart`, `seasonXX-banner`, `seasonXX-landscape` and the
  `season-specials-` forms belong to a season while living a level up — so they
  are attached to that season, and marked shadowed when the season folder has its
  own copy, which wins.
- **Episode images** are `{name}-thumb.ext` beside the video, or `{name}.ext`
  inside a `metadata/` sub-folder.
- **External subtitles** are `{name}[.lang][.default|.forced|.foreign|.sdh].ext`
  in `ass`, `srt`, `ssa`, `sub`/`idx` or `vtt`. `.foreign` is a synonym for
  `.forced`; a `.sub` and its `.idx` are one track, not two. The prefix must be
  the full stem, so `Show S01E03-behindthescenes.srt` belongs to the extra, not
  to the episode.
- **Theme media** is `theme.ext` or a `theme-music/` folder for songs, and a
  `backdrops/` folder for videos. Those folders — with `extrafanart/` and
  `metadata/` — are asset stores, not content, so their contents are never
  reported as unplaced files.

## Next

1. Verify the resolver against a real Emby library — load, re-serialise, and
   confirm an empty diff. Spurious diffs are rules this scanner has wrong.
2. NFO write path: merge managed fields into the existing document, preserving
   unrecognised elements.
3. Plan / apply: file moves and NFO writes as a reviewable, journalled,
   idempotent operation list.
4. Editing UI on top of a model that already round-trips.
