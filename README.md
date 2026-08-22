# FPL Gaffer

**The ultimate dashboard for Premier League fans — FPL mode for players and
Fan mode for everyone else.**

A Premier League and Fantasy Premier League dashboard for the
[Omarchy](https://omarchy.org) shell. Live scores, the real league table, a
fixture difficulty grid, player stats and a podium board — and, if you play
the game, your squad scored live with provisional bonus, projected auto-subs
and your mini-leagues. All of it wearing your current Omarchy theme.

![FPL Gaffer mode — your squad on the pitch](preview.png)

![Premier League Fan mode — the live match ticker](fan-mode.png)

Two ways to use it, chosen on first run and changeable in settings:

- **FPL Gaffer mode** — you play the game. Eight tabs: your squad as a pitch or
  a list scored live, the match ticker, the league table, your mini-leagues
  re-scored live, a fixture difficulty grid, every player in the game, the
  Monsters board, and news with price and injury watch.
- **Premier League Fan mode** — you just follow the football. Five tabs: Live,
  Table, Fixtures, Leaders and News. No fantasy team needed, and nothing that
  only means something inside the game.

| | FPL Gaffer | Premier League Fan |
| --- | --- | --- |
| Squad, Leagues, Players | ✓ | — |
| Live, Table, Fixtures, News | ✓ | ✓ |
| Podium board | Monsters — goals, defcon, value, cards, referees | Leaders — goals, tackles, blocks, recoveries, cards, referees |
| API calls per refresh | 22 | 4 |

## Install

```bash
./install.sh
```

It lists exactly what it will write and where, and writes nothing until you
say yes. `--dry-run` shows the list and stops; `--yes` skips the prompt;
`--uninstall` removes the code and asks separately before touching your data.

It writes to exactly two places:

| What | Where | Why there |
| --- | --- | --- |
| Plugin code | `~/.config/omarchy/plugins/io.github.weedwhitesandwine.gaffer` | the only place the shell loads plugins from (`--plugin-dir` to override) |
| Settings, cache, logs | `~/.local/state/gaffer` (or `$XDG_STATE_HOME`) | **must** stay out of the plugin folder — see below |

The state file cannot live in the plugin folder. Omarchy watches that folder
recursively with `inotifywait -m -r` and reloads the plugin on every write
inside it, so a file that changes each minute during a match would reload
your shell each minute too. Measured: five writes into a subfolder of a
plugin directory produced seven plugin reloads.

The files are staged and moved into place in one step, so installing costs
one shell reload rather than one per file. Then run `omarchy restart shell`
and enable it in the plugin manager.

## Removing it

```bash
./install.sh --uninstall
```

It asks before removing the plugin, and asks separately before touching your
settings and cache — the default is to leave them. To take it out of the bar
and drop its hotkey without uninstalling:

```bash
./gaffer-ctl.sh bar off
./gaffer-ctl.sh unbind
```

Or remove it through the Omarchy plugin manager, which handles the plugin
folder; your settings under `~/.local/state/gaffer` stay until you delete
them.

## What it needs, and what it touches

**Dependencies.** `python3` only, and only its standard library — no
virtualenv, no pip, no build step. `notify-send` for desktop notifications,
which Omarchy already provides. Nothing else.

**Privileges.** None. It never asks for a password, never uses `sudo` or
`pkexec`, and runs entirely as you. It does not start a second Quickshell
process; the one background process it does start is the Python engine,
supervised with `setpriv --pdeathsig TERM` so it cannot outlive the shell,
and stoppable with `./gaffer-ctl.sh stop`.

**Files.** It writes to exactly two places: its own plugin folder at install
time, and `~/.local/state/gaffer` for settings, cache and logs. It deletes
nothing on its own — clearing the cache is a command you run.

**Network.** Two hosts, both read-only and unauthenticated:
`fantasy.premierleague.com` for everything, and `footballapi.pulselive.com`
for one field the fantasy API does not publish, the name of a match referee.
No account, no key, no login, and nothing is ever sent anywhere — your team
number is used only to build a URL for your own public team page.

## How it works

`gafferd.py` does all the thinking — it talks to the Fantasy Premier League
API, works out live points, provisional bonus, auto-subs, league tables and
fixture difficulty, and writes the result to a small state file. The overlay
watches that file, so opening it is instant and nothing ever blocks on the
network. The daemon also raises desktop notifications while the overlay is
closed.

It polls about once a minute while matches are actually being played, every
couple of minutes in the hour before a deadline, and every fifteen minutes
otherwise. Everything is cached on disk, and a stale copy is used if the API
is unreachable.

Standard library Python only — no virtualenv, no build step.

## Keys

| Key | Does |
| --- | --- |
| `Tab` / `←` `→` | move between tabs |
| `↑` `↓` / `PgUp` `PgDn` | move the selection |
| type | filter the current tab |
| `Enter` | act on the selection (stars a player on the watchlist) |
| double-click a player | show him on the Players tab, selected and scrolled to |
| click a column heading | rank by it; click again to reverse |
| `Ctrl+,` | settings |
| `Ctrl+R` | refresh now |
| `Esc` | clear the filter, then close |

## Your team ID

Your FPL team ID is the number in your own team's web address. This works
right now, before the season starts, with no leagues and no history:

1. Sign in at fantasy.premierleague.com in a browser.
2. Open **Pick Team** from the menu.
3. In the "Points & Rankings" box, click **Gameweek History**.
4. Look at the address bar. It reads
   `fantasy.premierleague.com/en/entry/1234567/history` — the number in the
   middle is your team ID.

The same number appears if you open Transfers and click **Transfer History**.

To check you have the right one, open `fantasy.premierleague.com/api/entry/YOUR-ID/`
in a browser. It should show your team name and your own name. If it shows
somebody else, you have copied the wrong number.

## Where things live

| Path | What |
| --- | --- |
| `~/.local/state/gaffer/state.json` | everything the overlay draws |
| `~/.local/state/gaffer/bar.json` | the small slice the bar icon reads |
| `~/.local/state/gaffer/settings.json` | your choices |
| `~/.local/state/gaffer/cache/` | raw API responses |
| `~/.local/state/gaffer/backups/` | previous versions, kept on upgrade |
| `~/.local/state/gaffer/gafferd.log` | engine log |

`gaffer-ctl.sh stop` stops the background engine, and
`gaffer-ctl.sh clear-cache` forgets every cached response — the plugin never
deletes anything on its own.

## The Monsters board

A podium of three for each of ten ways to be remarkable. Most are self
explanatory; three are worth a note:

- **Dirty Dogs** counts bookings, not fouls. Fouls committed are not in the
  public API — they live in a per-match feed the game does not publish.
- **See You Next Tuesday** ranks referees by cards shown. The official comes
  from the Premier League's own feed, the cards from the fantasy feed; a
  finished match is looked up once and remembered.
- There is no set-piece category, because the API records that a player takes
  penalties but never which goals came from them.

## Data

Everything comes from the Fantasy Premier League's own public API at
`fantasy.premierleague.com/api`. It needs no key and no login. One extra
field — the name of a match referee — comes from the Premier League's own
feed at `footballapi.pulselive.com`, which the fantasy API does not publish;
if that feed is unavailable the referee category goes quiet and nothing else
notices.

Price-change predictions are not calculated here. The game publishes its own
projection per player, new for 2026/27, and the plugin reads it: below 20% is
ignored, 20% and up is listed with a progress bar, and 95% and up raises a
notification. It is not a
documented or supported product, so it is treated gently: responses are
cached, polling backs off when nothing is happening, and the plugin never
hammers it.

## Licence

MIT.
