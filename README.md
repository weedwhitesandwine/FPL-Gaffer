# FPL Gaffer

A Fantasy Premier League dashboard for the [Omarchy](https://omarchy.org) shell.
Live scores, provisional bonus, the real Premier League table, mini-leagues,
a fixture difficulty grid and a player explorer — all of it wearing your
current Omarchy theme.

Two ways to use it, chosen on first run and changeable in settings:

- **FPL Gaffer** — you play the game. Your squad scored live with the captain
  doubled and auto-subs projected, the bonus race before it's official, your
  mini-leagues re-scored live, price moves and deadline warnings.
- **Premier League statto** — you just follow the football. Scores, the table,
  fixtures and player stats. No fantasy team needed.

## Install

```bash
./install.sh
```

That stages the files and moves them into `~/.config/omarchy/plugins/` in one
step, so the shell reloads once rather than once per file. Then enable it in
the Omarchy plugin manager.

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
| `~/.local/state/gaffer/bar.json` | the small slice the bar readout reads |
| `~/.local/state/gaffer/settings.json` | your choices |
| `~/.local/state/gaffer/cache/` | raw API responses |
| `~/.local/state/gaffer/gafferd.log` | engine log |

`gaffer-ctl.sh stop` stops the background engine.

## Data

Everything comes from the Fantasy Premier League's own public API at
`fantasy.premierleague.com/api`. It needs no key and no login. It is not a
documented or supported product, so it is treated gently: responses are
cached, polling backs off when nothing is happening, and the plugin never
hammers it.

## Licence

MIT.
