# Vapour

Playtime and use, in the Omarchy bar, for Steam, Battle.net and anything else
that opens a window. One bar icon and one panel. The panel is strictly a
display: it watches the record that `bin/collect` writes to
`~/.local/state/omarchy/vapour/playtime.json` and draws whatever appears there.
`Panel.qml` owns the bar button and the popup; `Main.qml` runs the collector,
watches the record, and tracks which games currently have a window open — and
for stores that keep no playtime of their own, that tracking is the playtime.

## Install

```bash
omarchy plugin add https://github.com/WeaselBiggs/omarchy-vapour.git --enable
```

Plugins land disabled by default so you can read the code first; `--enable`
skips that. Needs `python3`, which Omarchy ships. Steam needs to have been
signed in at least once on the machine (it reads `localconfig.vdf`); Battle.net
is picked up automatically from the prefix `omarchy-install-gaming-battlenet`
creates. Neither is required: whichever stores are present are the ones shown.

## Panel

- **Hero** — the Steam mark, "Vapour", the total for the week as a pill, and a
  meta line: the stores in play, which window the numbers cover, how many
  games, and when they were updated (or "Playing now" while a game window is
  open).
- **Hours by day** — one row per day for the last week, scaled to the busiest
  day, today bolded at the bottom. Appears once two days of snapshots exist (or
  as soon as a timed session lands).
- **Games** — one row per game played this week, the bar behind each row scaled
  to the game you played most, with a Play button at the trailing edge. Hover
  for the week/total split. Click (or Enter) unfolds the rundown: store (when
  more than one is in play), total time, last two weeks, last played, whether
  it is installed here, and the HowLongToBeat figures with a progress meter
  when they are known.
- **Footer** — only speaks while the week is still being assembled.

With nothing played the module leaves the bar entirely (set `alwaysShow` to
keep it).

## Data

Every game in the record carries a string id: `steam:<appid>`,
`bnet:<product code>`, or whatever `games.json` names. The panel, the
HowLongToBeat cache and the overrides file all key on it.

### Steam

Steam keeps exactly three numbers per game in
`~/.local/share/Steam/userdata/<id>/config/localconfig.vdf`: all-time minutes,
a rolling two-week total, and the last-played timestamp. There is no per-day
or per-week figure, locally or in the Web API.

So "this week" is derived. Every run, the collector snapshots each game's
all-time minutes to `~/.local/state/omarchy/vapour/snapshots/YYYY-MM-DD.json`.
The week is today's total minus the snapshot from seven days ago (or last
Sunday's, in `Since Monday` mode); the day chart is the difference between
consecutive snapshots. Until a baseline exists, Steam's two-week total stands
in and the hero says "Last 2 weeks". Snapshots older than 35 days are pruned.

Game names come from installed `appmanifest_*.acf` files first, then a keyless
lookup on the Steam store, cached forever in `~/.cache/omarchy/vapour/apps/`.
Failed lookups are retried daily. Games without a resolvable name (non-Steam
shortcuts, delisted apps) are skipped.

Steam writes `localconfig.vdf` a little after a game exits, so the collector
also reruns twenty seconds after a `steam_app_*` window disappears.

### Battle.net and everything else

Battle.net keeps no playtime on disk at all — its config carries a last-played
stamp per product and nothing more, and Blizzard has no public API for it. So
Vapour is the stopwatch. `Main.qml` already watches Hyprland's window list for
the "playing now" light; for watched games every change in that list is handed
to `bin/sessions`, which keeps a ledger in
`~/.local/state/omarchy/vapour/sessions.json`:

```json
{
  "open":     { "bnet:fenris": { "start": 1792111500, "seen": 1792114200 } },
  "sessions": [ { "id": "bnet:fenris", "start": 1792025000, "end": 1792027700 } ]
}
```

While a watched game is up its heartbeat is refreshed every minute, so a shell
that dies mid-session still has the time up to the last minute on record; the
next sync closes the orphan at its last heartbeat, never at the moment someone
noticed. Sessions under 30 seconds (a crash on launch, a mis-matched window)
are dropped. Week, day, two-week and total figures for these games come
straight from the ledger — no snapshot baseline needed — and the day chart adds
them to Steam's.

Wine windows carry the executable's name as their class, so Diablo IV is
`diablo iv.exe` and the client itself is `battle.net.exe`. Matching is
case-insensitive. If a game does not register, `hyprctl clients` shows its
class; add it in `games.json` (below).

**Battle.net discovery.** The collector reads `Battle.net.config` out of the
prefix (`~/Games/battlenet` by default, where `omarchy-install-gaming-battlenet`
puts it) for the product codes the client knows, and maps the ones it
recognises — Diablo IV (`fenris`), Diablo II: Resurrected, Diablo III,
Overwatch, World of Warcraft and Classic, StarCraft, StarCraft II, Warcraft
III, Heroes of the Storm, Hearthstone, Warcraft Rumble, the Call of Duty
titles, Crash 4 and the Arcade Collection — to a name, the executable to watch
for, and the code the launcher takes. "Installed" means the product folder
exists under `Program Files (x86)`. The Play button runs

```
uwsm-app -- env WINEPREFIX=<prefix> PROTONPATH=GE-Proton GAMEID=umu-battlenet PROTON_VERB=run \
  umu-run "<prefix>/drive_c/Program Files (x86)/Battle.net/Battle.net Launcher.exe" --exec="launch Fen"
```

which starts the client if it is not up and launches the product once it is
signed in.

**`~/.config/omarchy/vapour/games.json`** adds, adjusts or removes watched
games. Entries are matched to discovered ones by id, so a discovered Blizzard
title can be renamed, given another window class or a different launch line
without being redefined:

```json
{
  "battlenet": {
    "prefix": "~/Games/battlenet",
    "play": "uwsm-app -- gamemoderun env WINEPREFIX={prefix} PROTONPATH=GE-Proton GAMEID=umu-battlenet PROTON_VERB=run umu-run {launcher} --exec=\"launch {code}\""
  },
  "games": [
    { "id": "bnet:fenris", "name": "Diablo 4" },
    { "id": "gog:witcher3", "name": "The Witcher 3", "store": "GOG",
      "classes": ["witcher3.exe"], "play": "uwsm-app -- lutris lutris:rungame/the-witcher-3", "installed": true },
    { "id": "bnet:hsb", "hidden": true }
  ]
}
```

| Key | Meaning |
|---|---|
| `battlenet.prefix` | Where the client lives; `"battlenet": false` turns discovery off |
| `battlenet.play` | Launch template for every Blizzard title: `{prefix}`, `{launcher}` (already shell-quoted) and `{code}` are filled in |
| `games[].id` | Any string; `bnet:<code>` overrides a discovered product |
| `games[].name`, `store` | What the row and the rundown say |
| `games[].classes` | Window classes that mean the game is up (case-insensitive) |
| `games[].play` | Shell line for the Play button; omit it and the row has none |
| `games[].installed` | Shown in the rundown when `false` |
| `games[].hidden` | Drop the game from the panel |

A game with no classes cannot be timed and is left out of the record. Time from
before the ledger existed can be backfilled by hand:

```bash
bin/sessions add bnet:fenris 2026-10-10T20:30 95     # 95 minutes from that moment
bin/sessions list                                    # the ledger, newest first
```

Stores that do keep their own figures (Lutris in its database, Heroic in a
timestamps file) are not read yet; they fit the same `games.json` shape in the
meantime.

### How long to beat

HowLongToBeat has no official API, so `bin/hltb` talks to the endpoint the
site's own search box uses, found the way the community `howlongtobeatpy`
library finds it: read the homepage, scan its JS chunks for the POST `fetch`,
ask that endpoint's `/init` for a token, then search. `collect` starts it in
the background after every record write; it exits immediately when its cache
is fresh, refreshes at most eight stale games per run (1.5 s apart), and
regenerates the record when anything changed.

Results live in `~/.cache/omarchy/vapour/hltb/<id>.json` (`steam-1551980.json`,
`bnet-fenris.json`) with a status:

| Status | Meaning | Kept for |
|---|---|---|
| `ok` | matched, with at least one figure | 30 days |
| `nodata` | matched, nobody has submitted times | 7 days |
| `missing` | no title matched (exact, then ≥ 0.86 similarity, full games only) | 7 days |
| `error` | the site was unreachable or changed shape | 6 hours |

Matching is by title, so the rundown shows the matched title whenever it
differs from the store's. When the scrape breaks, the panel says "unavailable"
and keeps whatever it already knows; nothing else in the widget depends on it.
`bin/hltb --force --verbose` refreshes everything and narrates.

Hand corrections go in `~/.config/omarchy/vapour/hltb-overrides.json`, in
hours, and always win. Keys are game ids; a bare Steam app id still works:

```json
{
  "steam:1161580": { "main": 20, "extra": 30, "completionist": 45 },
  "bnet:fenris": { "main": 30, "extra": 60, "completionist": 150 }
}
```

The meter measures total playtime against the main story — or, past that,
against completionist. Set `hltbEnabled` to `false` to skip the lookups and
hide the block (overrides still show).

### Moving from 0.3

Everything used to live under `omarchy/steam`. The first run of 0.4 moves the
record, snapshots, name cache, HowLongToBeat cache and overrides to
`omarchy/vapour`, renaming HowLongToBeat entries from `<appid>.json` to
`steam-<appid>.json`. Nothing is lost and nothing needs re-fetching.

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
- IPC: `omarchy-shell dan.vapour <open|close|toggle|refresh|play [id]>`.
  `play` takes a game id (`bnet:fenris`) or a bare Steam app id; without one
  it resumes the top game, which makes a keybinding for "resume what I was
  playing" a one-liner.

## Settings

Settings live on the widget's entry in `~/.config/omarchy/shell.json` and can
be set with `omarchy bar set dan.vapour <key> <value>`. Without `--json` the
value is stored as a string; add `--json` to store a real number or boolean.
The plugin accepts either form, so both of these keep the icon in the bar:

```bash
omarchy bar set dan.vapour alwaysShow true          # stores "true"
omarchy bar set dan.vapour alwaysShow true --json   # stores true
```

| Key | Default | What it does |
|---|---|---|
| `refreshIntervalSec` | `900` | How often the collector reruns |
| `weekMode` | `"Rolling 7 days"` | Or `"Since Monday"` |
| `minMinutes` | `5` | Hide games under this many minutes |
| `showWeekInBar` | `false` | Show the week's hours next to the bar icon |
| `alwaysShow` | `false` | Keep the icon with nothing played |
| `lookupNames` | `true` | Keyless store lookup for Steam game names |
| `hltbEnabled` | `true` | Look up lengths on HowLongToBeat in the background |

## Files

```
manifest.json   plugin manifest
Panel.qml       bar button + popup
Main.qml        collector runner, record watcher, running-game tracker, ledger sync
bin/collect     python3, no dependencies beyond the standard library
bin/sessions    the ledger for games Vapour times itself; called by Main.qml
bin/hltb        HowLongToBeat lookups, same constraints; started by collect
```

Saving a file here logs "Local plugin changed, reloading", but QML edits only
take effect after `omarchy restart shell` on Quickshell builds without
`Qt.clearComponentCache`. The Python scripts pick up edits on their next run.
