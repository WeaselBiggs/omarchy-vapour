# Steam

One bar icon and one panel for Steam playtime. The panel is strictly a
display: it watches the record that `bin/collect` writes to
`~/.local/state/omarchy/steam/playtime.json` and draws whatever appears there.
`Panel.qml` owns the bar button and the popup; `Main.qml` runs the collector,
watches the record, and tracks which Steam games currently have a window open.

## Install

```bash
omarchy plugin add https://github.com/WeaselBiggs/omarchy-steam-playtime.git --enable
```

Plugins land disabled by default so you can read the code first; `--enable`
skips that. Needs Steam signed in at least once on the machine (it reads
`localconfig.vdf`) and `python3`, which Omarchy ships.

## Panel

- **Hero** — the Steam mark, the total for the week as a pill, and a meta line:
  which window the numbers cover, how many games, and when they were updated
  (or "Playing now" while a game window is open).
- **Hours by day** — one row per day for the last week, scaled to the busiest
  day, today bolded at the bottom. Appears once two days of snapshots exist.
- **Games** — one row per game played this week, the bar behind each row scaled
  to the game you played most, with a Play button at the trailing edge. Hover
  for the week/total split. Click (or Enter) unfolds the rundown: total time,
  last two weeks, last played, whether it is installed here, and the
  HowLongToBeat figures with a progress meter when they are known.
- **Footer** — only speaks while the week is still being assembled.

With nothing played the module leaves the bar entirely (set `alwaysShow` to
keep it).

## Data

Steam keeps exactly three numbers per game in
`~/.local/share/Steam/userdata/<id>/config/localconfig.vdf`: all-time minutes,
a rolling two-week total, and the last-played timestamp. There is no per-day
or per-week figure, locally or in the Web API.

So "this week" is derived. Every run, the collector snapshots each game's
all-time minutes to `~/.local/state/omarchy/steam/snapshots/YYYY-MM-DD.json`.
The week is today's total minus the snapshot from seven days ago (or last
Sunday's, in `Since Monday` mode); the day chart is the difference between
consecutive snapshots. Until a baseline exists, Steam's two-week total stands
in and the hero says "Last 2 weeks". Snapshots older than 35 days are pruned.

Game names come from installed `appmanifest_*.acf` files first, then a keyless
lookup on the Steam store, cached forever in `~/.cache/omarchy/steam/apps/`.
Failed lookups are retried daily. Games without a resolvable name (non-Steam
shortcuts, delisted apps) are skipped.

Steam writes `localconfig.vdf` a little after a game exits, so the collector
also reruns twenty seconds after a `steam_app_*` window disappears.

### How long to beat

HowLongToBeat has no official API, so `bin/hltb` talks to the endpoint the
site's own search box uses, found the way the community `howlongtobeatpy`
library finds it: read the homepage, scan its JS chunks for the POST `fetch`,
ask that endpoint's `/init` for a token, then search. `collect` starts it in
the background after every record write; it exits immediately when its cache
is fresh, refreshes at most eight stale games per run (1.5 s apart), and
regenerates the record when anything changed.

Results live in `~/.cache/omarchy/steam/hltb/<appid>.json` with a status:

| Status | Meaning | Kept for |
|---|---|---|
| `ok` | matched, with at least one figure | 30 days |
| `nodata` | matched, nobody has submitted times | 7 days |
| `missing` | no title matched (exact, then ≥ 0.86 similarity, full games only) | 7 days |
| `error` | the site was unreachable or changed shape | 6 hours |

Matching is by title, so the rundown shows the matched title whenever it
differs from Steam's. When the scrape breaks, the panel says "unavailable" and
keeps whatever it already knows; nothing else in the widget depends on it.
`bin/hltb --force --verbose` refreshes everything and narrates.

Hand corrections go in `~/.config/omarchy/steam/hltb-overrides.json`, in
hours, and always win:

```json
{
  "1161580": { "main": 20, "extra": 30, "completionist": 45 }
}
```

The meter measures total playtime against the main story — or, past that,
against completionist. Set `hltbEnabled` to `false` to skip the lookups and
hide the block (overrides still show).

## Interactions

- Bar icon — a steaming cup (Steam → steam), because Steam's own tray icon
  already sits on that line and two Steam badges would blur together. Left =
  panel, right = launch or focus Steam, middle = play the game you spent the
  most time on this week. It lights up while a game runs. The glyph is
  `fa-mug_hot` (U+EF59); swap `barGlyph` in `Panel.qml` for `cod-coffee`
  (U+EC15) if you prefer the hollow steaming cup.
- Panel: `j`/`k` move, Enter or Space unfold, `l`/`h` unfold/fold, `p` play
  the cursor's game, `r` refresh, Tab moves to the neighboring bar panel, Esc
  closes.
- IPC: `omarchy-shell dan.steam <open|close|toggle|refresh|play [appid]>`.
  `play` without an app id resumes the top game, which makes a keybinding for
  "resume what I was playing" a one-liner.

## Settings

Settings live on the widget's entry in `~/.config/omarchy/shell.json` and can
be set with `omarchy bar set dan.steam <key> <value>` (numbers and booleans
need `--json`):

| Key | Default | What it does |
|---|---|---|
| `refreshIntervalSec` | `900` | How often the collector reruns |
| `weekMode` | `"Rolling 7 days"` | Or `"Since Monday"` |
| `minMinutes` | `5` | Hide games under this many minutes |
| `showWeekInBar` | `false` | Show the week's hours next to the bar icon |
| `alwaysShow` | `false` | Keep the icon with nothing played |
| `lookupNames` | `true` | Keyless store lookup for game names |
| `hltbEnabled` | `true` | Look up lengths on HowLongToBeat in the background |

## Files

```
manifest.json   plugin manifest
Panel.qml       bar button + popup
Main.qml        collector runner, record watcher, running-game tracker
bin/collect     python3, no dependencies beyond the standard library
bin/hltb        HowLongToBeat lookups, same constraints; started by collect
```

Saving a file here logs "Local plugin changed, reloading", but QML edits only
take effect after `omarchy restart shell` on Quickshell builds without
`Qt.clearComponentCache`. The Python scripts pick up edits on their next run.
