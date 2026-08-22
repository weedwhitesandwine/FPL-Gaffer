#!/usr/bin/env python3
"""Gaffer's data engine.

Talks to the Fantasy Premier League API, works out everything the overlay
needs (live points, provisional bonus, auto-subs, league tables, fixture
difficulty, price moves), and writes it to a small state file the QML side
watches. Also raises desktop notifications while the overlay is closed.

  gafferd.py daemon    poll forever, adapting the cadence to whether
                       matches are actually being played
  gafferd.py once      one refresh pass, then exit
  gafferd.py status    print a one-line summary (handy for debugging)

Standard library only, on purpose: this ships inside a desktop plugin and
should never need a virtualenv.
"""

import fcntl
import gzip
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

API = "https://fantasy.premierleague.com/api"
UA = "Mozilla/5.0 (X11; Linux x86_64) Gaffer/1.0 (Omarchy plugin)"

# Settings, cache and logs. This is deliberately NOT inside the plugin
# folder: Omarchy watches that folder recursively with inotify and reloads
# the plugin on every write, so a state file living there would reload the
# shell once a minute all through a match. The XDG state directory is the
# right home for it, and the installer says so out loud.
def _state_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(base, "gaffer")


STATE_DIR = _state_dir()
CACHE_DIR = os.path.join(STATE_DIR, "cache")
STATE_FILE = os.path.join(STATE_DIR, "state.json")
BAR_FILE = os.path.join(STATE_DIR, "bar.json")
SETTINGS_FILE = os.path.join(STATE_DIR, "settings.json")
SEEN_FILE = os.path.join(STATE_DIR, "seen.json")
LOCK_FILE = os.path.join(STATE_DIR, "gafferd.lock")
LOG_FILE = os.path.join(STATE_DIR, "gafferd.log")

DEFAULT_SETTINGS = {
    "greeted": False,
    # "gaffer" plays the fantasy game and needs a team number; "statto" just
    # follows the football — scores, tables and fixtures, no FPL squad.
    "appMode": "gaffer",
    "entryId": 0,
    "mode": "center",
    "barIcon": True,
    "barSection": "right",
    "shortcut": "",
    "watchlist": [],
    "fixtureWeeks": 6,
    "leagueMemberCap": 120,
    "notify": {
        # Every goal in every match, whether or not you own anyone in it.
        "matchGoals": False,
        "kickoff": False,
        "goals": True,
        "bonus": True,
        "prices": True,
        "news": True,
        "deadline": True,
        "summary": True,
    },
}

# How stale a cached response may be before we go back to the network,
# in seconds. Two figures each: when matches are live, and when they're not.
TTL = {
    "bootstrap": (600, 1800),
    "fixtures": (50, 900),
    "live": (50, 3600),
    "entry": (240, 1800),
    "picks": (240, 1800),
    "history": (600, 3600),
    "status": (120, 900),
    "league": (300, 1800),
}


# --------------------------------------------------------------------- utils

def log(msg):
    line = "%s  %s\n" % (datetime.now().strftime("%H:%M:%S"), msg)
    try:
        with open(LOG_FILE, "a") as fh:
            fh.write(line)
            if fh.tell() > 512_000:
                fh.truncate(0)
    except OSError:
        pass


def now():
    return datetime.now(timezone.utc)


def parse_ts(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def write_atomic(path, payload):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(payload, fh, separators=(",", ":"))
    os.replace(tmp, path)


def read_json(path, fallback=None):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return fallback


def load_settings():
    settings = dict(DEFAULT_SETTINGS)
    stored = read_json(SETTINGS_FILE, {}) or {}
    settings.update({k: v for k, v in stored.items() if k in DEFAULT_SETTINGS})
    notify = dict(DEFAULT_SETTINGS["notify"])
    notify.update(stored.get("notify") or {})
    settings["notify"] = notify
    return settings


def notify(title, body, urgency="normal", icon="applications-games"):
    try:
        subprocess.Popen(
            ["notify-send", "-a", "Gaffer", "-u", urgency, "-i", icon, title, body],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        pass


# ----------------------------------------------------------------- transport

def fetch(path, kind, live, force=False):
    """GET an API path, going through a small on-disk cache."""
    slug = path.strip("/").replace("/", "_").replace("?", "_").replace("=", "-")
    cache_path = os.path.join(CACHE_DIR, slug + ".json")
    ttl = TTL.get(kind, (300, 900))[0 if live else 1]

    if not force and os.path.exists(cache_path):
        age = time.time() - os.path.getmtime(cache_path)
        if age < ttl:
            cached = read_json(cache_path)
            if cached is not None:
                return cached

    req = urllib.request.Request(
        API + path,
        headers={"User-Agent": UA, "Accept": "application/json", "Accept-Encoding": "gzip"},
    )
    try:
        with urllib.request.urlopen(req, timeout=25) as resp:
            raw = resp.read()
            if resp.headers.get("Content-Encoding") == "gzip":
                raw = gzip.decompress(raw)
            data = json.loads(raw.decode("utf-8"))
    except (urllib.error.URLError, ValueError, OSError, TimeoutError) as exc:
        log("fetch failed %s: %s" % (path, exc))
        return read_json(cache_path)  # stale beats nothing

    try:
        write_atomic(cache_path, data)
    except OSError:
        pass
    return data


# ------------------------------------------------------------ fpl arithmetic

def award_bonus(bps_rows):
    """Turn a fixture's raw bonus-system scores into 3/2/1 bonus points.

    Ties share the higher award and swallow the one below, which is how the
    real game does it: two players tied at the top both get 3 and the next
    man gets 1, three tied at the top get 3 each and nobody gets 2 or 1.
    """
    if not bps_rows:
        return {}
    ranked = sorted(bps_rows, key=lambda r: -r["value"])
    tiers, seen_values = [], []
    for row in ranked:
        if row["value"] not in seen_values:
            seen_values.append(row["value"])
            tiers.append([])
        if len(tiers) > 3:
            break
        tiers[-1].append(row)

    awards, points_left = {}, [3, 2, 1]
    for tier in tiers:
        if not points_left:
            break
        award = points_left[0]
        for row in tier:
            awards[row["element"]] = award
        points_left = points_left[len(tier):]
    return awards


def provisional_bonus(fixtures):
    """Likely bonus per player, for matches where it hasn't been confirmed."""
    out = {}
    for fx in fixtures:
        if not fx.get("started"):
            continue
        stats = {s["identifier"]: s for s in fx.get("stats", [])}
        confirmed = stats.get("bonus")
        if confirmed and (confirmed.get("h") or confirmed.get("a")):
            continue  # real bonus is in the live feed already
        bps = stats.get("bps")
        if not bps:
            continue
        rows = list(bps.get("h", [])) + list(bps.get("a", []))
        for element, award in award_bonus(rows).items():
            out[element] = award
    return out


def bonus_races(fixtures, players):
    """The live bonus-point race, per match still in the balance."""
    races = []
    for fx in fixtures:
        if not fx.get("started"):
            continue
        stats = {s["identifier"]: s for s in fx.get("stats", [])}
        settled = stats.get("bonus")
        if settled and (settled.get("h") or settled.get("a")):
            continue  # bonus is in the bag; there's no race left to watch
        bps = stats.get("bps")
        if not bps:
            continue
        rows = sorted(
            list(bps.get("h", [])) + list(bps.get("a", [])),
            key=lambda r: -r["value"],
        )[:6]
        awards = award_bonus(list(bps.get("h", [])) + list(bps.get("a", [])))
        races.append({
            "fixture": fx["id"],
            "label": fx["_label"],
            "minutes": fx.get("minutes", 0),
            "rows": [{
                "name": players.get(r["element"], {}).get("web_name", "?"),
                "team": players.get(r["element"], {}).get("team_short", ""),
                "bps": r["value"],
                "bonus": awards.get(r["element"], 0),
            } for r in rows],
        })
    return races


VALID_MIN = {1: 1, 2: 3, 3: 2, 4: 1}
VALID_MAX = {1: 1, 2: 5, 3: 5, 4: 3}


def project_autosubs(picks, live, fixtures_by_team):
    """Which bench players will come on for team-mates who never played.

    Only counts a starter as a blank once their match is actually over —
    before that they might still be an unused substitute who comes on.
    """
    starters = [p for p in picks if p["position"] <= 11]
    bench = [p for p in picks if p["position"] > 11]

    def finished(pick):
        fx = fixtures_by_team.get(pick["_team"])
        return bool(fx and fx.get("finished_provisional"))

    def minutes(pick):
        return live.get(pick["element"], {}).get("minutes", 0)

    blanks = [p for p in starters if finished(p) and minutes(p) == 0]
    if not blanks:
        return []

    shape = {}
    for p in starters:
        shape[p["element_type"]] = shape.get(p["element_type"], 0) + 1

    subs, used = [], set()
    for blank in blanks:
        shape[blank["element_type"]] -= 1
        for cand in bench:
            if cand["element"] in used:
                continue
            if minutes(cand) == 0 and finished(cand):
                continue
            # Goalkeepers only ever swap with the other goalkeeper.
            if (cand["element_type"] == 1) != (blank["element_type"] == 1):
                continue
            trial = dict(shape)
            trial[cand["element_type"]] = trial.get(cand["element_type"], 0) + 1
            if any(trial.get(t, 0) < VALID_MIN[t] for t in VALID_MIN):
                continue
            if any(trial.get(t, 0) > VALID_MAX[t] for t in VALID_MAX):
                continue
            shape = trial
            used.add(cand["element"])
            subs.append({"off": blank["element"], "on": cand["element"]})
            break
        else:
            shape[blank["element_type"]] += 1
    return subs


# ---------------------------------------------------------------- assembling

def index_players(boot):
    teams = {t["id"]: t for t in boot["teams"]}
    types = {t["id"]: t["singular_name_short"] for t in boot["element_types"]}
    players = {}
    for e in boot["elements"]:
        rise = fall = 0
        for proj in e.get("price_change_projections") or []:
            if proj.get("offset") != 0:
                continue
            try:
                pct = float(proj.get("projected_percent") or 0)
            except (TypeError, ValueError):
                pct = 0.0
            if pct > 0:
                rise = pct
            elif pct < 0:
                fall = pct
        players[e["id"]] = {
            "id": e["id"],
            "code": e["code"],
            "web_name": e.get("known_name") or e["web_name"],
            "team": e["team"],
            "team_short": teams[e["team"]]["short_name"],
            "team_code": e["team_code"],
            "pos": types[e["element_type"]],
            "element_type": e["element_type"],
            "cost": e["now_cost"] / 10.0,
            "cost_change": e["cost_change_start"] / 10.0,
            "total_points": e["total_points"],
            "event_points": e["event_points"],
            "form": e["form"],
            "ppg": e["points_per_game"],
            "selected": e["selected_by_percent"],
            "status": e["status"],
            "news": e.get("news") or "",
            "chance": e.get("chance_of_playing_next_round"),
            "minutes": e["minutes"],
            "goals": e["goals_scored"],
            "assists": e["assists"],
            "xg": e.get("expected_goals"),
            "xa": e.get("expected_assists"),
            "xgi": e.get("expected_goal_involvements"),
            "defcon": e.get("defensive_contribution"),
            "ict": e["ict_index"],
            "bonus": e["bonus"],
            "transfers_in": e.get("transfers_in_event", 0),
            "transfers_out": e.get("transfers_out_event", 0),
            "price_pct": e.get("price_change_percent") or 0,
            "rise_pct": rise,
            "fall_pct": fall,
            "pens": e.get("penalties_text") or "",
            "pens_order": e.get("penalties_order"),
            "corners_order": e.get("corners_and_indirect_freekicks_order"),
            "fk_order": e.get("direct_freekicks_order"),
            "clean_sheets": e.get("clean_sheets", 0),
            "yellow": e.get("yellow_cards", 0),
            "red": e.get("red_cards", 0),
            "saves": e.get("saves", 0),
            "ep_next": e.get("ep_next"),
        }
    return players, teams


def label_fixtures(fixtures, teams):
    for fx in fixtures:
        home = teams.get(fx["team_h"], {}).get("short_name", "?")
        away = teams.get(fx["team_a"], {}).get("short_name", "?")
        hs, as_ = fx.get("team_h_score"), fx.get("team_a_score")
        if fx.get("started") and hs is not None:
            fx["_label"] = "%s %d-%d %s" % (home, hs, as_, away)
        else:
            fx["_label"] = "%s v %s" % (home, away)
        fx["_home"] = home
        fx["_away"] = away
        fx["_home_name"] = teams.get(fx["team_h"], {}).get("name", home)
        fx["_away_name"] = teams.get(fx["team_a"], {}).get("name", away)
    return fixtures


def build_fixture_grid(all_fixtures, teams, first_gw, weeks):
    """Difficulty per club for the coming weeks, plus blanks and doubles."""
    gws = list(range(first_gw, first_gw + weeks))
    grid = []
    for team_id, team in sorted(teams.items(), key=lambda kv: kv[1]["short_name"]):
        cells = []
        for gw in gws:
            games = [f for f in all_fixtures
                     if f.get("event") == gw and team_id in (f["team_h"], f["team_a"])]
            entries = []
            for f in games:
                home = f["team_h"] == team_id
                opp = f["team_a"] if home else f["team_h"]
                entries.append({
                    "opp": teams.get(opp, {}).get("short_name", "?"),
                    "home": home,
                    "fdr": f["team_h_difficulty"] if home else f["team_a_difficulty"],
                })
            cells.append(entries)
        total = sum(e["fdr"] for c in cells for e in c)
        played = sum(len(c) for c in cells)
        grid.append({
            "team": team["short_name"],
            "name": team["name"],
            "cells": cells,
            "avg": round(total / played, 2) if played else 0,
            "games": played,
        })
    return {"gameweeks": gws, "rows": grid}


def match_detail(fx, players):
    """Who did what in one match — scorers, assists, cards, own goals.

    The same shape the fixture feed uses: every event is a list of players
    per side, so a hat-trick is one entry with a count of three.
    """
    stats = {s["identifier"]: s for s in fx.get("stats", [])}

    def side(identifier, key):
        rows = []
        for entry in (stats.get(identifier) or {}).get(key, []) or []:
            meta = players.get(entry["element"])
            if not meta:
                continue
            rows.append({"name": meta["web_name"], "count": entry["value"]})
        return rows

    detail = {}
    for identifier in ("goals_scored", "assists", "own_goals",
                       "yellow_cards", "red_cards", "bonus", "penalties_missed"):
        detail[identifier] = {"home": side(identifier, "h"), "away": side(identifier, "a")}
    return detail


# The monsters board: a podium of three for each of nine ways to be
# remarkable. Ported from the categories Neil's earlier FPL Gaffer used,
# with one substitution — fouls committed are not in the public API, so the
# foul-happy category runs on bookings instead, which amounts to the same
# accusation.
MONSTER_MINUTES = 90


def build_monsters(players):
    eligible = [p for p in players.values() if (p.get("minutes") or 0) >= MONSTER_MINUTES]

    def card(p, value, suffix=""):
        return {
            "id": p["id"], "name": p["web_name"], "team": p["team_short"],
            "pos": p["pos"], "cost": p["cost"], "points": p["total_points"],
            "value": value, "suffix": suffix,
        }

    def top(pool, key, count=3):
        ranked = sorted(pool, key=lambda p: -float(key(p) or 0))
        return [p for p in ranked if float(key(p) or 0) > 0][:count]

    def num(field):
        return lambda p: p.get(field) or 0

    cats = []

    def add(cid, title, glyph, blurb, stat, pool, key, suffix=""):
        winners = top(pool, key)
        cats.append({
            "id": cid, "title": title, "glyph": glyph, "blurb": blurb, "stat": stat,
            "players": [card(p, key(p), suffix) for p in winners],
        })

    attackers = [p for p in eligible if p["pos"] in ("MID", "FWD")]
    def_mids   = [p for p in eligible if p["pos"] in ("DEF", "MID")]
    defenders  = [p for p in eligible if p["pos"] == "DEF"]
    back_line  = [p for p in eligible if p["pos"] in ("DEF", "GKP")]
    keepers    = [p for p in eligible if p["pos"] == "GKP"]

    add("goal", "Goal Monsters", "⚽", "Top scorers this season",
        "GOALS", attackers, num("goals"))
    add("defcon", "DefCon Monsters", "⛨", "Defensive contribution machines",
        "DEFCON", def_mids, num("defcon"))
    add("closet", "Closet Strikers", "⚑", "Defenders who think they are forwards",
        "GOALS", defenders, num("goals"))
    add("assists", "Assist Kings", "♚", "The creators and providers",
        "ASSISTS", eligible, num("assists"))

    # Set-piece duty is a standing, not a tally: first-choice penalties count
    # for most, corners and free kicks for less.
    def sp_score(p):
        score = 0
        if (p.get("pens_order") or 99) <= 1:
            score += 3
        if (p.get("corners_order") or 99) <= 2:
            score += 2
        if (p.get("fk_order") or 99) <= 2:
            score += 2
        return score

    sp_pool = sorted([p for p in eligible if sp_score(p) > 0],
                     key=lambda p: (-sp_score(p), -p["total_points"]))[:3]
    cats.append({
        "id": "setpiece", "title": "Set Piece Merchants", "glyph": "⌖",
        "blurb": "First choice on penalties, corners and free kicks",
        "stat": "DUTIES",
        "players": [dict(card(p, sp_score(p)), duties=" ".join(
            ([" PEN"] if (p.get("pens_order") or 99) <= 1 else [])
            + (["CRN"] if (p.get("corners_order") or 99) <= 2 else [])
            + (["FK"] if (p.get("fk_order") or 99) <= 2 else [])).strip())
                    for p in sp_pool],
    })

    add("value", "Value Monsters", "◈", "Best return per million spent",
        "PTS/£m", [p for p in eligible if p["cost"] > 0],
        lambda p: round(p["total_points"] / p["cost"], 2))
    add("cleansheet", "Clean Sheet Machines", "▤", "The brick walls",
        "CLEAN SHEETS", back_line, num("clean_sheets"))
    add("shotstopper", "Shot Stoppers", "✤", "Keepers earning their money",
        "SAVES", keepers, num("saves"))
    add("dirty", "Dirty Dogs", "▬", "The foul-happy merchants",
        "YELLOWS", eligible, num("yellow"))
    add("seeya", "See Ya", "▮", "Early bath specialists",
        "REDS", eligible, num("red"))

    return {"minutes": MONSTER_MINUTES, "categories": cats}


def build_league_table(all_fixtures, teams):
    """The actual Premier League table, worked out from results.

    The API carries won/drawn/lost fields on each club but never fills them
    in, so the only trustworthy source is the scoreline of every match that
    has been played.
    """
    table = {tid: {
        "team": t["short_name"], "name": t["name"], "code": t["code"],
        "played": 0, "won": 0, "drawn": 0, "lost": 0,
        "gf": 0, "ga": 0, "gd": 0, "points": 0, "form": [],
    } for tid, t in teams.items()}

    played = [f for f in all_fixtures
              if f.get("finished_provisional") and f.get("team_h_score") is not None]
    played.sort(key=lambda f: f.get("kickoff_time") or "")

    for f in played:
        home, away = table.get(f["team_h"]), table.get(f["team_a"])
        if not home or not away:
            continue
        hs, as_ = f["team_h_score"], f["team_a_score"]
        for side, scored, conceded in ((home, hs, as_), (away, as_, hs)):
            side["played"] += 1
            side["gf"] += scored
            side["ga"] += conceded
            side["gd"] = side["gf"] - side["ga"]
            if scored > conceded:
                side["won"] += 1
                side["points"] += 3
                side["form"].append("W")
            elif scored == conceded:
                side["drawn"] += 1
                side["points"] += 1
                side["form"].append("D")
            else:
                side["lost"] += 1
                side["form"].append("L")

    rows = sorted(table.values(),
                  key=lambda r: (-r["points"], -r["gd"], -r["gf"], r["name"]))
    for i, row in enumerate(rows, 1):
        row["position"] = i
        row["form"] = row["form"][-5:]
    return rows


def fetch_league(league_id, live, cap, players, live_stats, prov, entry_id, summary=None):
    """A mini-league table, recalculated live where the league is small."""
    data = fetch("/leagues-classic/%d/standings/?page_standings=1" % league_id, "league", live)
    if not data:
        return None
    results = (data.get("standings") or {}).get("results") or []
    league = data.get("league") or {}
    rows = [{
        "entry": r.get("entry"),
        "name": r.get("entry_name"),
        "player": r.get("player_name"),
        "rank": r.get("rank"),
        "last_rank": r.get("last_rank"),
        "total": r.get("total"),
        "event_total": r.get("event_total"),
        "live_total": None,
        "live_gw": None,
        "chip": None,
    } for r in results]

    # For a small league we can pull everyone's team and score it ourselves,
    # which gives a genuinely live table rather than one frozen at kickoff.
    if live and rows and len(rows) <= cap:
        gw = live_stats.get("_gw")
        for row in rows:
            picks = fetch("/entry/%d/event/%d/picks/" % (row["entry"], gw), "picks", live)
            if not picks:
                continue
            score, chip = score_picks(picks, live_stats, prov, players)
            row["live_gw"] = score
            row["chip"] = chip
            base = (row["total"] or 0) - (row["event_total"] or 0)
            row["live_total"] = base + score
        if any(r["live_total"] is not None for r in rows):
            rows.sort(key=lambda r: -(r["live_total"] if r["live_total"] is not None else -1))
            for i, row in enumerate(rows, 1):
                row["live_rank"] = i

    summary = summary or {}
    total = summary.get("size") or league.get("rank_count") or len(rows)
    # In a league of millions you will not appear in the first fifty, so
    # carry your own standing separately and let the tab show it regardless.
    mine = next((r for r in rows if r["entry"] == entry_id), None)
    return {
        "id": league_id,
        "name": league.get("name") or summary.get("name"),
        "size": total,
        "shown": len(rows[:60]),
        "computed": bool(rows and rows[0].get("live_rank")),
        "your_rank": summary.get("rank"),
        "your_last_rank": summary.get("last_rank"),
        "in_view": mine is not None,
        "rows": rows[:60],
        "me": entry_id,
    }


def score_picks(picks_payload, live_stats, prov, players):
    """Points a squad is on right now, including likely bonus and subs."""
    picks = []
    for p in picks_payload.get("picks", []):
        meta = players.get(p["element"], {})
        picks.append({**p, "_team": meta.get("team")})
    chip = picks_payload.get("active_chip")
    hits = (picks_payload.get("entry_history") or {}).get("event_transfers_cost", 0)

    fixtures_by_team = live_stats.get("_by_team", {})
    subs = project_autosubs(picks, live_stats, fixtures_by_team) if chip != "bboost" else []
    swap_in = {s["on"] for s in subs}
    swap_out = {s["off"] for s in subs}

    total = 0
    for p in picks:
        counts = p["position"] <= 11 or chip == "bboost" or p["element"] in swap_in
        if p["element"] in swap_out:
            counts = False
        if not counts:
            continue
        stats = live_stats.get(p["element"], {})
        pts = stats.get("total_points", 0) + prov.get(p["element"], 0)
        total += pts * (p["multiplier"] if p["multiplier"] else 1)
    return total - hits, chip


def squad_view(picks_payload, live_stats, prov, players, fixtures_by_team, teams):
    picks = []
    for p in picks_payload.get("picks", []):
        meta = players.get(p["element"], {})
        picks.append({**p, "_team": meta.get("team")})
    chip = picks_payload.get("active_chip")
    subs = project_autosubs(picks, live_stats, fixtures_by_team) if chip != "bboost" else []
    swap_in = {s["on"] for s in subs}
    swap_out = {s["off"] for s in subs}

    rows = []
    for p in picks:
        meta = players.get(p["element"], {})
        stats = live_stats.get(p["element"], {})
        fx = fixtures_by_team.get(meta.get("team"))
        prov_pts = prov.get(p["element"], 0)
        base = stats.get("total_points", 0)
        mult = p["multiplier"] if p["multiplier"] else 1
        benched = p["position"] > 11 and chip != "bboost"
        counting = (not benched or p["element"] in swap_in) and p["element"] not in swap_out

        if fx is None:
            when, live_now = "no fixture", False
        elif fx.get("finished_provisional"):
            when, live_now = "FT", False
        elif fx.get("started"):
            when, live_now = "%d'" % (fx.get("minutes") or 0), True
        else:
            ko = parse_ts(fx.get("kickoff_time"))
            when = ko.astimezone().strftime("%a %H:%M") if ko else "TBC"
            live_now = False

        rows.append({
            "id": p["element"],
            "name": meta.get("web_name", "?"),
            "team": meta.get("team_short", ""),
            "team_code": meta.get("team_code"),
            "code": meta.get("code"),
            "pos": meta.get("pos", ""),
            "position": p["position"],
            "captain": p.get("is_captain", False),
            "vice": p.get("is_vice_captain", False),
            "multiplier": mult,
            "benched": benched,
            "counting": counting,
            "subbed_in": p["element"] in swap_in,
            "subbed_out": p["element"] in swap_out,
            "points": base,
            "provisional": prov_pts,
            "applied": (base + prov_pts) * (mult if counting else 1),
            "minutes": stats.get("minutes", 0),
            "goals": stats.get("goals_scored", 0),
            "assists": stats.get("assists", 0),
            "bonus": stats.get("bonus", 0),
            "bps": stats.get("bps", 0),
            "defcon": stats.get("defensive_contribution", 0),
            "saves": stats.get("saves", 0),
            "cs": stats.get("clean_sheets", 0),
            "yellow": stats.get("yellow_cards", 0),
            "red": stats.get("red_cards", 0),
            "status": meta.get("status", "a"),
            "news": meta.get("news", ""),
            "chance": meta.get("chance"),
            "cost": meta.get("cost", 0),
            "fixture": fx.get("_label") if fx else "",
            "when": when,
            "live": live_now,
            "played": stats.get("minutes", 0) > 0,
            "to_play": fx is not None and not fx.get("started"),
        })
    rows.sort(key=lambda r: r["position"])
    return rows, subs, chip


# ------------------------------------------------------------------- notices

def raise_notices(state, previous, settings):
    seen = read_json(SEEN_FILE, {}) or {}
    wants = settings["notify"]
    squad = {r["id"]: r for r in state.get("squad", [])}
    before = {r["id"]: r for r in (previous or {}).get("squad", [])}

    if wants.get("goals"):
        for pid, row in squad.items():
            old = before.get(pid)
            if not old:
                continue
            if row["goals"] > old["goals"]:
                notify("⚽ %s scores" % row["name"],
                       "%s — %s. Now on %d points." % (row["fixture"], row["when"], row["applied"]))
            if row["assists"] > old["assists"]:
                notify("🅰 %s assists" % row["name"],
                       "%s — %s. Now on %d points." % (row["fixture"], row["when"], row["applied"]))
            if row["red"] > old["red"]:
                notify("🟥 %s sent off" % row["name"], row["fixture"], urgency="critical")

    # Live scores from every match, for people following the football rather
    # than a fantasy team. Compares this pass's scoreline against the last.
    if wants.get("matchGoals"):
        before_fx = {f["id"]: f for f in (previous or {}).get("fixtures", [])}
        for fx in state.get("fixtures", []):
            old = before_fx.get(fx["id"])
            if not old or fx.get("hs") is None or old.get("hs") is None:
                continue
            if fx["hs"] != old["hs"] or fx["as"] != old["as"]:
                scorer = ""
                detail = fx.get("detail") or {}
                goals = (detail.get("goals_scored") or {})
                side = goals.get("home" if fx["hs"] != old["hs"] else "away") or []
                if side:
                    scorer = side[-1]["name"]
                notify("⚽ %s" % fx["label"],
                       (scorer + " · " if scorer else "") + "%d'" % (fx.get("minutes") or 0))
            elif old.get("finished") is False and fx.get("finished"):
                notify("Full time — %s" % fx["label"], "")

    if wants.get("kickoff"):
        for fx in state.get("fixtures", []):
            key = "ko-%d" % fx["id"]
            if fx.get("started") and not seen.get(key):
                seen[key] = True
                notify("Kick off — %s" % fx["label"], "")

    if wants.get("news"):
        for pid, row in squad.items():
            old = before.get(pid)
            if old and row["news"] and row["news"] != old["news"]:
                notify("📋 %s — team news" % row["name"], row["news"], urgency="critical")

    if wants.get("bonus"):
        key = "bonus-%s" % state.get("gw")
        if state.get("bonus_added") and not seen.get(key):
            seen[key] = True
            notify("Bonus confirmed — GW%s" % state.get("gw"),
                   "Final score %d points." % state.get("live_points", 0))

    if wants.get("prices"):
        for row in state.get("price_watch", []):
            key = "price-%d-%s" % (row["id"], row["direction"])
            if row["likely"] and not seen.get(key):
                seen[key] = True
                arrow = "rising" if row["direction"] == "up" else "falling"
                notify("💷 %s is %s tonight" % (row["name"], arrow),
                       "%s · £%.1fm · %s%% of the way there"
                       % (row["team"], row["cost"], row["progress"]))

    if wants.get("deadline") and state.get("deadline_in"):
        hours = state["deadline_in"] / 3600.0
        for mark in (24, 3, 1):
            key = "dl-%s-%d" % (state.get("next_gw"), mark)
            if hours <= mark and not seen.get(key):
                seen[key] = True
                trouble = [r["name"] for r in state.get("squad", [])
                           if r["status"] in ("i", "s", "u", "n") and not r["benched"]]
                body = "GW%s deadline." % state.get("next_gw")
                if trouble:
                    body += " Doubts in your XI: " + ", ".join(trouble[:4])
                notify("⏰ %d hour%s to the deadline" % (mark, "" if mark == 1 else "s"),
                       body, urgency="critical" if mark <= 3 else "normal")

    write_atomic(SEEN_FILE, seen)


# -------------------------------------------------------------------- refresh

def refresh(settings, previous):
    boot = fetch("/bootstrap-static/", "bootstrap", False)
    if not boot:
        return None
    players, teams = index_players(boot)

    events = boot["events"]
    current = next((e for e in events if e["is_current"]), None)
    nxt = next((e for e in events if e["is_next"]), None)
    gw = (current or nxt or events[0])["id"]

    all_fixtures = label_fixtures(fetch("/fixtures/", "fixtures", False) or [], teams)
    live_now = any(f.get("started") and not f.get("finished_provisional")
                   for f in all_fixtures if f.get("event") == gw)

    if live_now:  # go back for genuinely fresh copies
        all_fixtures = label_fixtures(fetch("/fixtures/", "fixtures", True, force=True) or [], teams)

    gw_fixtures = [f for f in all_fixtures if f.get("event") == gw]
    live_raw = fetch("/event/%d/live/" % gw, "live", live_now) or {}
    live_stats = {e["id"]: e["stats"] for e in live_raw.get("elements", [])}

    by_team = {}
    for f in gw_fixtures:
        by_team[f["team_h"]] = f
        by_team[f["team_a"]] = f
    live_stats["_by_team"] = by_team
    live_stats["_gw"] = gw

    prov = provisional_bonus(gw_fixtures)
    status = fetch("/event-status/", "status", live_now) or {}
    bonus_added = all(s.get("bonus_added") for s in status.get("status", [])) if status.get("status") else False

    mode = settings.get("appMode") or "gaffer"
    entry_id = int(settings.get("entryId") or 0) if mode == "gaffer" else 0
    state = {
        "mode": mode,
        "updated": now().isoformat(),
        "gw": gw,
        "next_gw": nxt["id"] if nxt else None,
        "live_now": live_now,
        "bonus_added": bonus_added,
        "season_finished": bool(current and current.get("finished") and not nxt),
        "entry_id": entry_id,
    }

    if nxt:
        deadline = parse_ts(nxt["deadline_time"])
        state["deadline"] = nxt["deadline_time"]
        state["deadline_in"] = max(0, (deadline - now()).total_seconds()) if deadline else None

    # ---- the manager's own team (skipped entirely in statto mode)
    if entry_id:
        entry = fetch("/entry/%d/" % entry_id, "entry", live_now)
        if entry:
            state["manager"] = "%s %s" % (entry.get("player_first_name", ""), entry.get("player_last_name", ""))
            state["team_name"] = entry.get("name")
            state["overall_rank"] = entry.get("summary_overall_rank")
            state["overall_points"] = entry.get("summary_overall_points")
            state["total_players"] = boot.get("total_players")
            state["leagues"] = [{
                "id": l["id"],
                "name": l["name"],
                "rank": l.get("entry_rank"),
                "last_rank": l.get("entry_last_rank"),
                "size": l.get("rank_count"),
                "type": l.get("league_type"),
            } for l in ((entry.get("leagues") or {}).get("classic") or [])]

        picks = fetch("/entry/%d/event/%d/picks/" % (entry_id, gw), "picks", live_now)
        if picks:
            rows, subs, chip = squad_view(picks, live_stats, prov, players, by_team, teams)
            points, _ = score_picks(picks, live_stats, prov, players)
            hist = picks.get("entry_history") or {}
            state["squad"] = rows
            state["autosubs"] = [{
                "off": players.get(s["off"], {}).get("web_name", "?"),
                "on": players.get(s["on"], {}).get("web_name", "?"),
            } for s in subs]
            state["chip"] = chip
            state["live_points"] = points
            state["hits"] = hist.get("event_transfers_cost", 0)
            state["transfers"] = hist.get("event_transfers", 0)
            state["bank"] = (hist.get("bank") or 0) / 10.0
            state["value"] = (hist.get("value") or 0) / 10.0
            state["players_played"] = sum(1 for r in rows if r["counting"] and r["played"])
            state["players_to_play"] = sum(1 for r in rows if r["counting"] and r["to_play"])
            state["captain"] = next((r["name"] for r in rows if r["captain"]), None)
            state["captain_points"] = next((r["applied"] for r in rows if r["captain"]), 0)
            state["bench_points"] = sum(r["points"] + r["provisional"] for r in rows if r["benched"])

        history = fetch("/entry/%d/history/" % entry_id, "history", False)
        if history:
            state["season"] = [{
                "gw": h["event"], "points": h["points"], "rank": h["overall_rank"],
                "gw_rank": h["rank"], "bench": h["points_on_bench"],
                "value": (h.get("value") or 0) / 10.0, "hits": h.get("event_transfers_cost", 0),
            } for h in history.get("current", [])]
            state["chips_used"] = [{"name": c["name"], "gw": c["event"]}
                                   for c in history.get("chips", [])]

    # ---- everything not tied to one manager
    state["fixtures"] = [{
        "id": f["id"], "label": f["_label"], "home": f["_home"], "away": f["_away"],
        "home_name": f["_home_name"], "away_name": f["_away_name"],
        "started": f.get("started", False), "finished": f.get("finished_provisional", False),
        "minutes": f.get("minutes", 0), "kickoff": f.get("kickoff_time"),
        "hs": f.get("team_h_score"), "as": f.get("team_a_score"),
        "hd": f.get("team_h_difficulty"), "ad": f.get("team_a_difficulty"),
        "detail": match_detail(f, players) if f.get("started") else None,
    } for f in sorted(gw_fixtures, key=lambda f: f.get("kickoff_time") or "")]

    # Handy for the bar readout in either mode: what's on now, what's next.
    state["live_matches"] = sum(1 for f in gw_fixtures
                                if f.get("started") and not f.get("finished_provisional"))
    upcoming = sorted([f for f in all_fixtures
                       if not f.get("started") and f.get("kickoff_time")],
                      key=lambda f: f["kickoff_time"])
    state["next_kickoff"] = upcoming[0]["kickoff_time"] if upcoming else None
    state["next_match"] = upcoming[0]["_label"] if upcoming else None

    # The grid starts at the gameweek being played, not the one after it. A
    # week with matches still to come is the week you are planning around.
    gw_done = all(f.get("finished_provisional") for f in gw_fixtures) if gw_fixtures else True
    grid_start = (nxt["id"] if (gw_done and nxt) else gw)

    state["bonus_races"] = bonus_races(gw_fixtures, players)
    state["league_table"] = build_league_table(all_fixtures, teams)
    if mode == "gaffer":
        state["monsters"] = build_monsters(players)
    state["grid"] = build_fixture_grid(
        all_fixtures, teams, grid_start, int(settings.get("fixtureWeeks") or 6))

    owned = {r["id"] for r in state.get("squad", [])}
    watch = (set(settings.get("watchlist") or []) | owned) if mode == "gaffer" else set()
    price_watch = []
    for pid in watch:
        meta = players.get(pid)
        if not meta:
            continue
        pct = float(meta["price_pct"] or 0)
        direction = "up" if pct >= 0 else "down"
        magnitude = abs(pct)
        if magnitude < 20:
            continue
        price_watch.append({
            "id": pid, "name": meta["web_name"], "team": meta["team_short"],
            "cost": meta["cost"], "direction": direction,
            "progress": round(magnitude, 1), "likely": magnitude >= 95,
            "owned": pid in owned,
        })
    price_watch.sort(key=lambda r: -r["progress"])
    state["price_watch"] = price_watch

    state["news"] = sorted(
        [{
            "id": p["id"], "name": p["web_name"], "team": p["team_short"], "pos": p["pos"],
            "status": p["status"], "news": p["news"], "chance": p["chance"],
            "owned": p["id"] in owned, "selected": p["selected"],
        } for p in players.values() if p["news"] and p["status"] != "a"],
        key=lambda r: (not r["owned"], -float(r["selected"] or 0)))[:60]

    def top(key, count=25, reverse=True):
        pool = [p for p in players.values() if p["minutes"] > 0 or key == "form"]
        return sorted(pool, key=lambda p: float(p.get(key) or 0), reverse=reverse)[:count]

    state["form_table"] = [{
        "id": p["id"], "name": p["web_name"], "team": p["team_short"], "pos": p["pos"],
        "cost": p["cost"], "form": p["form"], "points": p["total_points"],
        "selected": p["selected"], "xgi": p["xgi"], "defcon": p["defcon"],
        "status": p["status"], "owned": p["id"] in owned,
    } for p in top("form", 40)]

    # A differential is in form, cheap to own and barely owned by anyone else.
    diffs = [p for p in players.values()
             if float(p["selected"] or 0) < 8 and float(p["form"] or 0) >= 4 and p["status"] == "a"]
    diffs.sort(key=lambda p: -float(p["form"] or 0))
    state["differentials"] = [{
        "id": p["id"], "name": p["web_name"], "team": p["team_short"], "pos": p["pos"],
        "cost": p["cost"], "form": p["form"], "selected": p["selected"],
        "points": p["total_points"], "xgi": p["xgi"], "owned": p["id"] in owned,
    } for p in diffs[:30]]

    state["all_players"] = [{
        "id": p["id"], "name": p["web_name"], "team": p["team_short"], "pos": p["pos"],
        "cost": p["cost"], "form": p["form"], "points": p["total_points"],
        "selected": p["selected"], "xg": p["xg"], "xa": p["xa"], "xgi": p["xgi"],
        "defcon": p["defcon"], "ict": p["ict"], "minutes": p["minutes"],
        "goals": p["goals"], "assists": p["assists"], "bonus": p["bonus"],
        "status": p["status"], "news": p["news"], "ep": p["ep_next"],
        "pens": p["pens_order"], "owned": p["id"] in owned,
        "tin": p["transfers_in"], "tout": p["transfers_out"],
        "price_pct": p["price_pct"],
    } for p in sorted(players.values(), key=lambda p: -p["total_points"])]

    # ---- mini-leagues, small ones scored live
    cap = int(settings.get("leagueMemberCap") or 120)
    tables = []
    # Small leagues first — those are the ones with someone in them you know.
    ordered = sorted(state.get("leagues", []), key=lambda l: l.get("size") or 0)
    for league in (ordered[:20] if mode == "gaffer" else []):
        table = fetch_league(league["id"], live_now, cap, players, live_stats, prov,
                             entry_id, league)
        if table:
            tables.append(table)
    state["tables"] = tables

    return state


def write_bar(state):
    """The tiny slice the bar icon reads — kept separate so it stays cheap."""
    if not state:
        return
    bar = {
        "mode": state.get("mode", "gaffer"),
        "next_kickoff": state.get("next_kickoff"),
        "live_matches": state.get("live_matches"),
        "gw": state.get("gw"),
        "points": state.get("live_points"),
        "live": state.get("live_now"),
        "played": state.get("players_played"),
        "to_play": state.get("players_to_play"),
        "rank": state.get("overall_rank"),
        "captain": state.get("captain"),
        "captain_points": state.get("captain_points"),
        "deadline_in": state.get("deadline_in"),
        "chip": state.get("chip"),
        "provisional": not state.get("bonus_added") and state.get("live_now"),
    }
    write_atomic(BAR_FILE, bar)


def cadence(state):
    """How long to wait before looking again."""
    if not state:
        return 120
    if state.get("live_now"):
        return 55
    left = state.get("deadline_in")
    if left is not None:
        if left < 3600:
            return 120       # deadline imminent — watch prices and news closely
        if left < 6 * 3600:
            return 300
    # Nothing on: check in occasionally, mostly for injury news and prices.
    return 900


# ----------------------------------------------------------------------- main

def single_instance():
    fh = open(LOCK_FILE, "w")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return None
    fh.write(str(os.getpid()))
    fh.flush()
    return fh


def cycle(previous):
    settings = load_settings()
    mode = settings.get("appMode") or "gaffer"
    if mode == "gaffer" and not settings.get("entryId"):
        write_atomic(STATE_FILE, {"needs_setup": True, "mode": mode,
                                  "updated": now().isoformat()})
        return None
    state = refresh(settings, previous)
    if not state:
        return previous
    write_atomic(STATE_FILE, state)
    write_bar(state)
    try:
        raise_notices(state, previous, settings)
    except Exception as exc:                                    # never die on a toast
        log("notify pass failed: %s" % exc)
    return state


def main():
    # First run creates the data directory the installer told the user about.
    os.makedirs(CACHE_DIR, exist_ok=True)
    mode = sys.argv[1] if len(sys.argv) > 1 else "once"

    if mode == "status":
        state = read_json(STATE_FILE, {}) or {}
        print("GW%s  %s pts  rank %s  live=%s  updated %s" % (
            state.get("gw"), state.get("live_points"), state.get("overall_rank"),
            state.get("live_now"), state.get("updated")))
        return

    if mode == "once":
        cycle(read_json(STATE_FILE))
        return

    lock = single_instance()
    if lock is None:
        log("another gafferd already holds the lock — exiting")
        return

    log("gafferd started")
    state = read_json(STATE_FILE)
    while True:
        try:
            state = cycle(state)
        except Exception as exc:
            log("cycle failed: %s" % exc)
        time.sleep(cadence(state))


if __name__ == "__main__":
    main()
