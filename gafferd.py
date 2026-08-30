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

import errno
import fcntl
import http.client
import ipaddress
import json
import os
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib
from datetime import datetime, timezone

API = "https://fantasy.premierleague.com/api"
# The Premier League's own feed. It is the source of everything the fantasy
# game either does not publish or publishes late: the match clock, the live
# score, goals, bookings and the referee. It answers a plain client as long
# as the request looks like it came from premierleague.com.
PULSE = "https://footballapi.pulselive.com/football"
# Club badges, and nothing else. The number in the path is the club's Opta
# id, which the fantasy feed publishes as each team's `code` — so the whole
# address is built from a number this process already holds, and never from
# anything a reply said. Fetched once per club and kept on disk afterwards.
BADGE = "https://resources.premierleague.com/premierleague/badges/70/t%d.png"
UA = "Mozilla/5.0 (X11; Linux x86_64) Gaffer/1.0 (Omarchy plugin)"

# The only three hosts Gaffer ever talks to. Everything it fetches is a path
# under one of these, and all three are named in the README, so the list is
# the promise rather than a guess at one.
ALLOWED_HOSTS = ("fantasy.premierleague.com", "footballapi.pulselive.com",
                 "resources.premierleague.com")

# A reply that keeps arriving is not the same problem as a reply that is too
# large, and a socket timeout does not catch it: dribbling one byte at a time
# keeps the connection busy for as long as the other end likes. This is the
# wall clock a whole body has to arrive within.
BODY_DEADLINE = 30

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
# Badges are PNGs rather than API replies, and the cache prune sweeps by age:
# a club crest does not go stale, so it gets its own directory the sweep
# leaves alone.
BADGE_DIR = os.path.join(STATE_DIR, "badges")
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
    # A squad is locked the moment the deadline passes, so every other
    # manager's team is identical for the rest of the gameweek. Their live
    # scores come from the gameweek feed, which is fetched once a cycle
    # regardless — so re-reading their picks every minute was fetching
    # something that cannot change. Held for the length of a gameweek.
    "picks_locked": (21600, 21600),
    "history": (600, 3600),
    "status": (120, 900),
    "league": (300, 1800),
}


# --------------------------------------------------------------------- utils

def log(msg):
    line = "%s  %s\n" % (datetime.now().strftime("%H:%M:%S"), msg)
    try:
        # O_NOFOLLOW: this file gets truncated when it grows, and truncating
        # through a symlink planted at its well-known name would truncate
        # whatever the link points at instead of a log.
        # O_NONBLOCK as well, and then a look at what was actually opened:
        # O_NOFOLLOW refuses a symlink but says nothing about a FIFO, and
        # opening one of those for writing waits for a reader that never
        # comes. Without the flag the daemon stops here; with it the open
        # fails, and the check below refuses anything that is not a file.
        fd = os.open(LOG_FILE, os.O_WRONLY | os.O_APPEND | os.O_CREAT
                     | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            os.close(fd)
            return
        with os.fdopen(fd, "a") as fh:
            fh.write(line)
            if fh.tell() > 512_000:
                fh.truncate(0)
    except OSError:
        pass


_cache_pruned_at = 0.0


def prune_cache(force=False):
    """Drop cache entries that have outlived their usefulness: anything past
    the age limit, and — if the directory is still too big — the oldest first
    until it is under the ceiling. A missing entry costs one re-fetch."""
    global _cache_pruned_at
    when = time.time()
    if not force and (when - _cache_pruned_at) < CACHE_PRUNE_EVERY:
        return 0
    _cache_pruned_at = when
    removed = 0
    entries = []
    try:
        names = os.listdir(CACHE_DIR)
    except OSError:
        return 0
    for name in names:
        path = os.path.join(CACHE_DIR, name)
        try:
            st = os.lstat(path)
        except OSError:
            continue
        if not stat.S_ISREG(st.st_mode):
            continue
        if when - st.st_mtime > MAX_CACHE_AGE:
            try:
                os.unlink(path)
                removed += 1
            except OSError:
                pass
            continue
        entries.append((st.st_mtime, st.st_size, path))

    total = sum(e[1] for e in entries)
    if total > MAX_CACHE_TOTAL:
        entries.sort()                      # oldest first
        for _, size, path in entries:
            if total <= MAX_CACHE_TOTAL:
                break
            try:
                os.unlink(path)
                total -= size
                removed += 1
            except OSError:
                pass
    if removed:
        log("pruned %d cache entries" % removed)
    return removed


def now():
    return datetime.now(timezone.utc)


def parse_ts(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def ensure_dirs():
    """Create the state and cache directories and confirm they are fit to
    write into: owned by us, writable by nobody else. Every file this process
    writes is staged in one of them before being renamed into place, and a
    directory someone else can write is one where names can be swapped out
    from under a rename."""
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    os.makedirs(CACHE_DIR, mode=0o700, exist_ok=True)
    os.makedirs(BADGE_DIR, mode=0o700, exist_ok=True)
    for d in (STATE_DIR, CACHE_DIR, BADGE_DIR):
        st = os.stat(d)
        if st.st_uid != os.getuid() or (st.st_mode & 0o022):
            raise RuntimeError(
                "%s is not an owner-only directory; refusing to write there" % d)


def write_atomic(path, payload):
    """Replace a file without ever writing through a name an attacker could
    have planted first. The stage file comes from mkstemp — an unpredictable
    name, created with O_CREAT|O_EXCL, which never follows a symlink — in the
    same directory as the destination, then renamed over it in one step. A
    predictable `path + ".tmp"` would let a pre-planted symlink turn this
    write into the truncation of whatever the link pointed at."""
    fd, tmp = tempfile.mkstemp(prefix=".gaffer.", suffix=".tmp",
                               dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(payload, fh, separators=(",", ":"))
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def write_bytes_atomic(path, blob):
    """The same staged rename for something that is not JSON. A badge is a
    file the shell then loads by name, so a half-written one is worse than no
    badge at all: the image either arrives complete or it never appears."""
    fd, tmp = tempfile.mkstemp(prefix=".gaffer.", suffix=".tmp",
                               dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(blob)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# Ceilings on everything that arrives from outside this process. Nothing either
# feed publishes comes close to the wire limit: the whole fantasy player
# database is under two megabytes. Reading without one would let a single
# oversized reply — or a small, heavily compressed one that unpacks into
# gigabytes — exhaust the memory of a process that runs all day, and then write
# the result into the cache folder.
#
# The files in the state directory get the same treatment. This process writes
# them, but it does not own the disk: a restored backup, or anything else able
# to write a home directory, can leave something quite different behind. Each
# file is read up to its ceiling and one byte further — that byte is what says
# it is too big — and refused there, before it is parsed. The cache holds whole
# API responses, so it gets the same ceiling the network does.
MAX_WIRE = 8 * 1024 * 1024        # bytes accepted over the wire
MAX_UNPACKED = 32 * 1024 * 1024   # bytes accepted after decompression
MAX_SETTINGS_BYTES = 64 * 1024
# A club badge is around eight kilobytes of PNG. A quarter of a megabyte is
# already far more than one can honestly be, and it is what the read stops at.
MAX_BADGE_BYTES = 256 * 1024
MAX_STATE_BYTES = 8 * 1024 * 1024
MAX_CACHE_BYTES = MAX_WIRE
# The cache is one file per API path, and mini-league standings mean one file
# per rival manager per gameweek — 1,713 of them in two days on a real
# account, and nothing ever removed one. Left alone that is tens of thousands
# of files and a gigabyte or more across a season, for data that is re-fetched
# the moment it is wanted. Anything older than this has served its purpose.
MAX_CACHE_AGE = 3 * 24 * 3600
MAX_CACHE_TOTAL = 64 * 1024 * 1024
CACHE_PRUNE_EVERY = 3600


def read_json(path, fallback=None, ceiling=MAX_STATE_BYTES):
    """Opened without following symlinks and checked to be a regular file
    first: the state directory is where a restored backup lands, and a
    symlink or FIFO left at one of these names must not redirect the read or
    block it forever — open() on a FIFO with no writer simply never returns."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                return fallback
            with os.fdopen(fd, "rb") as fh:
                fd = None
                raw = fh.read(ceiling + 1)
        finally:
            if fd is not None:
                os.close(fd)
        if len(raw) > ceiling:
            log("%s is larger than %d bytes, ignoring it" % (path, ceiling))
            return fallback
        return json.loads(raw.decode("utf-8"))
    except (OSError, ValueError):
        return fallback


def as_int(value, fallback):
    """Settings values come off disk, and valid JSON of the wrong type must
    not be able to crash a cycle."""
    try:
        return int(value)
    except (TypeError, ValueError):
        return fallback


def load_settings():
    settings = dict(DEFAULT_SETTINGS)
    stored = read_json(SETTINGS_FILE, {}, MAX_SETTINGS_BYTES)
    if not isinstance(stored, dict):
        stored = {}
    settings.update({k: v for k, v in stored.items() if k in DEFAULT_SETTINGS})
    # Each value that gets arithmetic or attribute access done to it is
    # checked for shape here, once, rather than trusted at every use site.
    notify = dict(DEFAULT_SETTINGS["notify"])
    if isinstance(stored.get("notify"), dict):
        notify.update(stored["notify"])
    settings["notify"] = notify
    if not isinstance(settings.get("watchlist"), list):
        settings["watchlist"] = []
    for key in ("entryId", "fixtureWeeks", "leagueMemberCap"):
        settings[key] = as_int(settings.get(key), DEFAULT_SETTINGS[key])
    # A number is not yet a sensible number. The fixture grid is built column
    # by column from this, and settings.json can be hand-edited or restored
    # from a backup: at twenty thousand weeks the engine spends three seconds
    # a cycle building a state file too large for the overlay's own read
    # ceiling, so the panel sits frozen on stale data. There are 38 gameweeks
    # in a season and the grid is a planning aid, not an archive.
    settings["fixtureWeeks"] = max(1, min(20, settings["fixtureWeeks"]))
    settings["leagueMemberCap"] = max(1, min(2000, settings["leagueMemberCap"]))
    return settings


def plain(s):
    """Player names, fixture labels and team news all arrive from the APIs and
    all end up in a notification. The notification is drawn by the shell, not
    by us, and it interprets markup in both the summary and the body — the
    summary through a Text left on AutoText, the body deliberately as
    StyledText. Neither is ours to pin, so the two characters that turn a
    string into markup come out before it is handed over. Every Text inside
    the plugin is pinned to plain text; these are the sinks that cannot be."""
    return str("" if s is None else s).replace("<", "").replace(">", "")


# How many things have happened on a pitch since this machine started
# counting. The bar icon watches the number rather than the notifications: a
# toast can be missed, dismissed, or turned off at the desktop, and the point
# of the flash is that something happened in a match you are following. Only
# football moves it — a price change at two in the morning is news, but it is
# not something to flash an icon about.
MATCH_PULSES = 0


def notify(title, body, urgency="normal", icon="applications-games",
           pulse=False):
    if pulse:
        global MATCH_PULSES
        MATCH_PULSES += 1
    try:
        subprocess.Popen(
            # `--` matters: a title is a positional argument, and a feed string
            # that happens to begin with a dash would otherwise be read as an
            # option by notify-send rather than as the text to show.
            ["notify-send", "-a", "Gaffer", "-u", urgency, "-i", icon, "--",
             plain(title), plain(body)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        pass


# ----------------------------------------------------------------- transport

# A hand-driven refresh means somebody is looking at the screen wanting newer
# numbers than the ones on it. Honouring the background timers there makes the
# button a lie: press it ten seconds after a cycle and it re-reads the cache and
# changes nothing. So a manual pass ignores the timers on the handful of feeds
# that carry the match clock and your own score — but only those, and only down
# to a few seconds, so leaning on the key cannot turn into a flood.
MANUAL = False
MANUAL_KINDS = ("fixtures", "live", "status", "entry", "picks")
MANUAL_TTL = 5


class TooBig(Exception):
    """The other end sent more than we are willing to hold in memory."""


class UnsafeTarget(urllib.error.URLError):
    """An address Gaffer will not fetch: not https, not one of the two feeds,
    or resolving somewhere that is not on the internet. It subclasses the
    error the callers already expect from a failed fetch, so refusing one
    falls back to cache exactly as being offline does."""


def _refuse_private(host):
    """A name that answers with a loopback, private or otherwise non-public
    address is not the Premier League: it is this machine, or something else
    on this network. Every address the name resolves to has to be public,
    because the connection may use any of them."""
    try:
        infos = socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
    except socket.gaierror as exc:
        raise UnsafeTarget("could not resolve %s (%s)" % (host, exc))
    for info in infos:
        addr = ipaddress.ip_address(info[4][0])
        if addr.is_loopback or addr.is_private or addr.is_link_local \
                or addr.is_reserved or addr.is_multicast or not addr.is_global:
            raise UnsafeTarget("%s resolves to %s, which is not on the "
                               "internet" % (host, addr))


def check_target(url):
    """Every address fetched, whether asked for or arrived at by redirect."""
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https":
        raise UnsafeTarget("refusing a %s address"
                           % (parts.scheme or "scheme-less"))
    host = (parts.hostname or "").lower()
    if host not in ALLOWED_HOSTS:
        raise UnsafeTarget("refusing %s: not one of the two declared feeds"
                           % (host or "an address with no host"))
    _refuse_private(host)


class _DeclaredFeedsOnly(urllib.request.HTTPRedirectHandler):
    """Left to itself urllib follows a redirect wherever it is pointed — off
    https, onto another host, or at a service on this machine — on the say-so
    of whoever controls the reply. A redirect may move within the two feeds
    Gaffer declares, and nowhere else."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_target(newurl)
        return urllib.request.HTTPRedirectHandler.redirect_request(
            self, req, fp, code, msg, headers, newurl)


OPENER = urllib.request.build_opener(_DeclaredFeedsOnly())


def _resp_socket(resp):
    """The socket underneath a response, reached through the buffered layers
    (BufferedReader over SocketIO), so its timeout can be tightened to however
    long the body has left. None if the layers are not the expected shape."""
    fp = getattr(resp, "fp", None)
    raw = getattr(fp, "raw", fp)
    return getattr(raw, "_sock", None)


def read_capped(resp, deadline=None, ceiling=None):
    """Read a response body, refusing anything oversized, and unpack gzip a
    slice at a time so a small reply cannot inflate without limit.

    `ceiling` tightens the wire limit for a caller that knows its reply is
    small — a club badge is eight kilobytes, and there is no reason to accept
    eight megabytes of one."""
    ceiling = MAX_WIRE if ceiling is None else min(ceiling, MAX_WIRE)
    # A checked-between-reads deadline is not enough on its own: a buffered
    # read(n) waits to fill all n bytes, so a peer dripping small chunks
    # inside the idle timeout could hold one read for hours before the check
    # ran. read1() hands back whatever has arrived and the socket timeout is
    # clamped to the time remaining before every read, but one read1() can
    # still sit inside chunk-header parsing across repeated receives if the
    # peer drips framing bytes within the idle timeout. The watchdog makes
    # the ceiling hard regardless: at the deadline it severs the socket, so
    # whatever call is in flight comes back with EOF or an error and is
    # reported as the timeout it really is.
    raw = bytearray()
    sock = _resp_socket(resp) if deadline is not None else None
    idle = sock.gettimeout() if sock is not None else None
    expired = threading.Event()
    watchdog = None
    if sock is not None:
        def _sever():
            expired.set()
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        watchdog = threading.Timer(max(0.0, deadline - time.monotonic()),
                                   _sever)
        watchdog.daemon = True
        watchdog.start()
    try:
        while len(raw) <= ceiling:
            if deadline is not None:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or expired.is_set():
                    # Caught alongside the socket timeout by every caller, so
                    # a feed that trickles falls back to cache like one that
                    # never answered.
                    raise TimeoutError("reply still arriving after %d seconds"
                                       % BODY_DEADLINE)
                # fileno goes to -1 once the body is complete and http.client
                # has closed the connection; nothing can block on the network
                # then, the remaining reads only drain the buffer.
                if sock is not None and sock.fileno() >= 0:
                    sock.settimeout(remaining if idle is None
                                    else min(idle, remaining))
            try:
                chunk = resp.read1(min(65536, ceiling + 1 - len(raw)))
            except (OSError, http.client.HTTPException):
                # The severed socket surfaces as ECONNRESET, a TLS error, or
                # http.client tripping over truncated chunk framing.
                if expired.is_set():
                    raise TimeoutError("reply still arriving after %d seconds"
                                       % BODY_DEADLINE) from None
                raise
            if expired.is_set():
                raise TimeoutError("reply still arriving after %d seconds"
                                   % BODY_DEADLINE)
            if not chunk:
                break
            raw += chunk
    finally:
        if watchdog is not None:
            watchdog.cancel()
    raw = bytes(raw)
    if len(raw) > ceiling:
        raise TooBig("reply exceeded %d bytes" % ceiling)
    if resp.headers.get("Content-Encoding") != "gzip":
        return raw

    unzip = zlib.decompressobj(16 + zlib.MAX_WBITS)
    out = bytearray()
    pending = raw
    while pending:
        out += unzip.decompress(pending, MAX_UNPACKED + 1 - len(out))
        if len(out) > MAX_UNPACKED:
            raise TooBig("reply unpacked past %d bytes" % MAX_UNPACKED)
        pending = unzip.unconsumed_tail
    out += unzip.flush()
    if len(out) > MAX_UNPACKED:
        raise TooBig("reply unpacked past %d bytes" % MAX_UNPACKED)
    return bytes(out)


def fetch(path, kind, live, force=False):
    """GET an API path, going through a small on-disk cache."""
    slug = path.strip("/").replace("/", "_").replace("?", "_").replace("=", "-")
    cache_path = os.path.join(CACHE_DIR, slug + ".json")
    ttl = TTL.get(kind, (300, 900))[0 if live else 1]
    if MANUAL and kind in MANUAL_KINDS:
        ttl = min(ttl, MANUAL_TTL)

    if not force and os.path.exists(cache_path):
        age = time.time() - os.path.getmtime(cache_path)
        if age < ttl:
            cached = read_json(cache_path, ceiling=MAX_CACHE_BYTES)
            if cached is not None:
                return cached

    url = API + path
    req = urllib.request.Request(
        url,
        headers={"User-Agent": UA, "Accept": "application/json", "Accept-Encoding": "gzip"},
    )
    try:
        # The address asked for is checked as well as any it redirects to:
        # the constant is right, but the name behind it still has to answer
        # with a public address rather than something on this machine.
        check_target(url)
        deadline = time.monotonic() + BODY_DEADLINE
        with OPENER.open(req, timeout=25) as resp:
            data = json.loads(read_capped(resp, deadline).decode("utf-8"))
    except (urllib.error.URLError, ValueError, OSError, TimeoutError,
            zlib.error, TooBig) as exc:
        log("fetch failed %s: %s" % (path, exc))
        return read_json(cache_path, ceiling=MAX_CACHE_BYTES)  # stale beats nothing

    try:
        write_atomic(cache_path, data)
    except OSError:
        pass
    return data


def pulse_fetch(path, ttl):
    """GET from the Premier League feed, cached on disk like the FPL one."""
    slug = "pulse_" + path.strip("/").replace("/", "_").replace("?", "_") \
                           .replace("=", "-").replace("&", "_")
    cache_path = os.path.join(CACHE_DIR, slug + ".json")
    if os.path.exists(cache_path):
        if time.time() - os.path.getmtime(cache_path) < ttl:
            cached = read_json(cache_path, ceiling=MAX_CACHE_BYTES)
            if cached is not None:
                return cached

    url = PULSE + path
    req = urllib.request.Request(
        url,
        headers={"User-Agent": UA, "Accept": "application/json",
                 "Accept-Encoding": "gzip",
                 "Origin": "https://www.premierleague.com",
                 "Referer": "https://www.premierleague.com/"},
    )
    try:
        check_target(url)
        deadline = time.monotonic() + BODY_DEADLINE
        with OPENER.open(req, timeout=20) as resp:
            data = json.loads(read_capped(resp, deadline).decode("utf-8"))
    except (urllib.error.URLError, ValueError, OSError, TimeoutError,
            zlib.error, TooBig) as exc:
        log("pulse fetch failed %s: %s" % (path, exc))
        return read_json(cache_path, ceiling=MAX_CACHE_BYTES)

    try:
        write_atomic(cache_path, data)
    except OSError:
        pass
    return data


# What a PNG starts with. A reply from the badge host that is not one is not
# written: the shell would be handed a file it cannot draw, and an image is
# the one thing here that is never inspected before it is used.
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def looks_like_png(path):
    """Whether the file already at a badge's name is a PNG at all.

    A crest is written once and then read on every launch by the shell's image
    loader, which is the one reader here that does no checking of its own. What
    is on disk months later is not necessarily what was written: a restored
    backup can leave anything at that name, including a symlink pointing
    somewhere else, or a FIFO that would park the loader forever. So the file
    is opened on the same terms as every other read in this plugin — no
    symlink, regular file, non-blocking — and the eight bytes that identify a
    PNG are checked before its path is handed on.
    """
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return False
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return False
        with os.fdopen(fd, "rb") as fh:
            fd = None
            return fh.read(len(PNG_MAGIC)) == PNG_MAGIC
    except OSError:
        return False
    finally:
        if fd is not None:
            os.close(fd)


def fetch_badge(code):
    """One club crest, downloaded once and kept. Returns its path, or None.

    The address is built from an integer — the club's Opta id, which arrives
    as a number in the fantasy feed and is used as a number here — so there is
    no path for a value from a reply to steer where this fetches from or what
    it writes over."""
    try:
        code = int(code)
    except (TypeError, ValueError):
        return None
    if code <= 0:
        return None
    path = os.path.join(BADGE_DIR, "t%d.png" % code)
    if os.path.exists(path):
        if looks_like_png(path):
            return path
        # Something is at that name that is not a crest. Take it out of the
        # way and fetch the real one rather than handing the shell a file to
        # open.
        log("%s is not a PNG, replacing it" % path)
        try:
            os.unlink(path)
        except OSError:
            return None

    url = BADGE % code
    req = urllib.request.Request(url, headers={"User-Agent": UA,
                                               "Accept": "image/png"})
    try:
        check_target(url)
        deadline = time.monotonic() + BODY_DEADLINE
        with OPENER.open(req, timeout=20) as resp:
            blob = read_capped(resp, deadline, ceiling=MAX_BADGE_BYTES)
    except (urllib.error.URLError, ValueError, OSError, TimeoutError,
            zlib.error, TooBig) as exc:
        log("badge fetch failed t%d: %s" % (code, exc))
        return None

    if not blob.startswith(PNG_MAGIC):
        log("badge t%d did not arrive as a PNG, discarding it" % code)
        return None
    try:
        write_bytes_atomic(path, blob)
    except OSError as exc:
        log("could not store badge t%d: %s" % (code, exc))
        return None
    return path


def badge_paths(teams):
    """Every club's crest on disk, keyed by the three letters the screens
    already draw. Missing ones are fetched, at most twenty times ever: after
    the first pass through a season this reads the directory and stops."""
    out = {}
    for team in teams.values():
        short = team.get("short_name")
        path = fetch_badge(team.get("code"))
        if short and path:
            out[short] = path
    return out


def pulse_index():
    """(home club, away club) -> Premier League fixture id.

    Both feeds carry the league's own club numbering — the fantasy one calls
    it `pulse_id` — so the two can be joined exactly. Joining on club names
    cannot work: one feed says Man Utd where the other says Manchester
    United, and seven of the twenty clubs disagree in that way.
    """
    seasons = pulse_fetch("/competitions/1/compseasons", 86400)
    if not seasons or not seasons.get("content"):
        return {}
    # The rows below are read defensively one at a time; this was the one
    # value taken on trust, and a season with a missing or non-numeric id
    # would raise out of here rather than leave the live feed unavailable.
    first = seasons["content"][0] if isinstance(seasons["content"], list) else {}
    season_id = as_int(first.get("id") if isinstance(first, dict) else 0, 0)
    if not season_id:
        return {}

    listing = pulse_fetch(
        "/fixtures?comps=1&compSeasons=%d&pageSize=100&sort=asc" % season_id, 21600)
    if not listing:
        return {}

    index = {}
    for f in listing.get("content") or []:
        sides = f.get("teams") or []
        if len(sides) != 2:
            continue
        try:
            index[(int(sides[0]["team"]["id"]), int(sides[1]["team"]["id"]))] = int(f["id"])
        except (KeyError, TypeError, ValueError):
            continue
    return index


# A booking is one event type carrying its colour in the description: a
# second yellow arrives as YR, which is a sending off however it was earned.
PL_CARDS = {"Y": "yellow_cards", "YR": "red_cards", "R": "red_cards"}
PL_GOALS = {"G": "goals_scored", "P": "goals_scored", "O": "own_goals"}


def pulse_match(fx, index):
    """One live match as the league itself sees it: clock, score, events.

    The fantasy feed runs two to four minutes behind the match and publishes
    bookings late or not at all, so anything that is simply a fact about the
    football is taken from the Premier League instead. Points, bonus, prices
    and ownership stay with the fantasy game, which is the only feed that
    has them.
    """
    pl_id = index.get((fx.get("_home_pulse"), fx.get("_away_pulse")))
    if not pl_id:
        return None
    detail = pulse_fetch("/fixtures/%d" % pl_id, 20)
    if not detail:
        return None
    sides = detail.get("teams") or []
    if len(sides) != 2:
        return None
    home_id = int(sides[0]["team"]["id"])

    # Events name a person, not a fantasy player, so the two team sheets in
    # the same document are what turns an id back into a surname.
    names = {}
    for sheet in detail.get("teamLists") or []:
        for person in (sheet.get("lineup") or []) + (sheet.get("substitutes") or []):
            name = person.get("name") or {}
            names[person.get("id")] = name.get("last") or name.get("display") or ""

    buckets = {}
    for ev in detail.get("events") or []:
        kind = ev.get("type")
        if kind == "B":
            identifier = PL_CARDS.get(ev.get("description") or "", "yellow_cards")
        else:
            identifier = PL_GOALS.get(kind)
        if not identifier:
            continue
        who = names.get(ev.get("personId"))
        if not who:
            continue
        side = "home" if int(ev.get("teamId") or 0) == home_id else "away"
        tally = buckets.setdefault(identifier, {"home": {}, "away": {}})
        tally[side][who] = tally[side].get(who, 0) + 1

    def score(entry):
        value = entry.get("score")
        return int(value) if value is not None else None

    officials = detail.get("matchOfficials") or []
    main = next((o for o in officials if o.get("role") == "MAIN"), None)

    return {
        "referee": ((main or {}).get("name") or {}).get("display") or None,
        "minutes": int((detail.get("clock") or {}).get("secs") or 0) // 60,
        # The league writes the clock the way a broadcaster does — "45+3'00"
        # through first-half stoppage — which seconds-divided-by-sixty turns
        # into a meaningless 48th minute. Keep the label it actually used.
        "clock": ((detail.get("clock") or {}).get("label") or "").split("'")[0],
        "phase": detail.get("phase"),
        "hs": score(sides[0]),
        "as": score(sides[1]),
        "events": {
            identifier: {side: [{"name": n, "count": c} for n, c in rows.items()]
                         for side, rows in tally.items()}
            for identifier, tally in buckets.items()
        },
    }


def apply_live_feed(fixtures, teams):
    """Let the league's own feed correct the fantasy one, in place.

    Only matches actually in play are looked up: a finished match is settled
    and a match not yet kicked off has nothing to say. Everything downstream
    — the scoreline in the label, the bar readout, the goal notifications —
    then reads the corrected numbers without knowing where they came from.
    """
    playing = [f for f in fixtures
               if f.get("started") and not f.get("finished_provisional")]
    if not playing:
        return
    index = pulse_index()
    if not index:
        return
    for fx in playing:
        fx["_home_pulse"] = teams.get(fx["team_h"], {}).get("pulse_id")
        fx["_away_pulse"] = teams.get(fx["team_a"], {}).get("pulse_id")
        pl = pulse_match(fx, index)
        if not pl:
            continue
        if pl["minutes"]:
            fx["minutes"] = pl["minutes"]
        if pl["hs"] is not None:
            fx["team_h_score"] = pl["hs"]
        if pl["as"] is not None:
            fx["team_a_score"] = pl["as"]
        fx["_pl_events"] = pl["events"]
        # Half time is not a minute of football, it is a fifteen-minute break
        # with the clock stopped on however much stoppage the first half ran
        # to. Showing a number there invents play that is not happening.
        fx["_referee"] = pl.get("referee")
        fx["_pl_clock"] = "HT" if pl.get("phase") == "H" else (
            pl["clock"] + "'" if pl.get("clock") else None)


# ------------------------------------------------------- sheets and numbers

# How many people one side of a football match can be. Eleven start and nine
# sit down, so this is generous by half — but it is a list from somewhere else
# being written into a file this process reads back every cycle, and a length
# nobody bounded is how a feed having a bad day becomes a state file too large
# to read at all. Everything above the cap is dropped, and a sheet that has
# been cut short simply draws short.
SHEET_CAP = 30


def team_sheet(sheet):
    """One side's eleven, in the shape it stands in on the grass.

    The league publishes the shape twice over: a `formation` label everyone
    recognises, and the same thing as lines of player ids running from the
    goalkeeper forward. The second is what makes a pitch drawable rather than
    a list — so the ids are turned back into people here, and anything the
    formation does not account for is added as a last line rather than
    dropped, because a player left off the pitch is a worse answer than a
    shape that looks slightly wrong.
    """
    people = {}
    for person in (sheet.get("lineup") or [])[:SHEET_CAP]:
        if not isinstance(person, dict):
            continue
        name = person.get("name") or {}
        info = person.get("info") or {}
        people[person.get("id")] = {
            "n": as_int(person.get("matchShirtNumber")
                        or info.get("shirtNum") or 0, 0),
            "name": name.get("last") or name.get("display") or "",
            "full": name.get("display") or "",
            "pos": person.get("matchPosition") or info.get("position") or "",
            "c": person.get("captain") is True,
        }

    lines, placed = [], set()
    formation = sheet.get("formation") or {}
    for line in (formation.get("players") or [])[:SHEET_CAP]:
        if not isinstance(line, list):
            continue
        row = [people[pid] for pid in line[:SHEET_CAP] if pid in people]
        if row:
            lines.append(row)
            placed.update(pid for pid in line if pid in people)
    spare = [p for pid, p in people.items() if pid not in placed]
    if spare:
        lines.append(spare)

    subs = []
    for person in (sheet.get("substitutes") or [])[:SHEET_CAP]:
        if not isinstance(person, dict):
            continue
        name = person.get("name") or {}
        info = person.get("info") or {}
        subs.append({
            "n": as_int(person.get("matchShirtNumber")
                        or info.get("shirtNum") or 0, 0),
            "name": name.get("last") or name.get("display") or "",
            "pos": person.get("matchPosition") or info.get("position") or "",
        })

    return {"formation": (formation.get("label") or ""),
            "lines": lines, "subs": subs}


def pulse_sheets(detail):
    """Both team sheets from a fixture document, home first.

    Returns None until the sides are named, which the league does about an
    hour before kick-off — an empty pitch drawn for a match nobody has picked
    a team for yet says less than not drawing one.
    """
    sides = detail.get("teams") or []
    sheets = detail.get("teamLists") or []
    if len(sides) != 2 or len(sheets) != 2:
        return None
    try:
        home_id = int(sides[0]["team"]["id"])
    except (KeyError, TypeError, ValueError):
        return None
    by_team = {}
    for sheet in sheets:
        if not isinstance(sheet, dict):
            continue
        by_team[as_int(sheet.get("teamId"), -1)] = team_sheet(sheet)
    home = by_team.get(home_id)
    away = next((s for tid, s in by_team.items() if tid != home_id), None)
    if not home or not away or not home["lines"] or not away["lines"]:
        return None
    return {"home": home, "away": away}


# The numbers worth putting on a screen, out of the hundred and sixty-six the
# league keeps. Each is the feed's own name for it, the label to draw, and
# whether it is a percentage — which decides both the suffix and whether the
# two sides are expected to add up to a hundred.
MATCH_STATS = [
    ("possession_percentage", "Possession", True),
    ("total_scoring_att", "Shots", False),
    ("ontarget_scoring_att", "On target", False),
    ("won_corners", "Corners", False),
    ("fk_foul_lost", "Fouls", False),
    ("total_offside", "Offsides", False),
    ("saves", "Saves", False),
]


def pulse_stats(pl_id, live):
    """The match's own numbers: possession, shots, corners, fouls.

    A separate document from the fixture, and the one place these live — the
    fantasy feed has nothing like them. Cached hard once the match is over,
    because a finished match's numbers are final.
    """
    stats = pulse_fetch("/stats/match/%d" % pl_id, 45 if live else 86400)
    if not isinstance(stats, dict):
        return None
    sides = ((stats.get("entity") or {}).get("teams") or [])
    data = stats.get("data")
    if len(sides) != 2 or not isinstance(data, dict):
        return None
    try:
        ids = [str(int(s["team"]["id"])) for s in sides]
    except (KeyError, TypeError, ValueError):
        return None

    def values(team_key):
        entry = data.get(team_key)
        rows = (entry or {}).get("M") if isinstance(entry, dict) else None
        out = {}
        for row in rows or []:
            if isinstance(row, dict) and isinstance(row.get("name"), str):
                out[row["name"]] = as_float(row.get("value"))
        return out

    home, away = values(ids[0]), values(ids[1])
    if not home and not away:
        return None

    rows = []
    for name, label, pct in MATCH_STATS:
        h, a = home.get(name), away.get(name)
        if h is None and a is None:
            continue
        rows.append({"label": label, "h": h or 0.0, "a": a or 0.0, "pct": pct})

    # Passing is two numbers everywhere else and one number here: what people
    # mean by pass accuracy is the share that found a team-mate.
    def accuracy(side):
        total = side.get("total_pass") or 0
        return round(100.0 * (side.get("accurate_pass") or 0) / total, 1) \
            if total else None
    ha, aa = accuracy(home), accuracy(away)
    if ha is not None or aa is not None:
        rows.append({"label": "Pass accuracy", "h": ha or 0.0, "a": aa or 0.0,
                     "pct": True})
    return rows or None


def apply_match_sheets(fixtures, teams):
    """Team sheets and match statistics for the gameweek's matches.

    Held to the gameweek on purpose: these are two more documents per match,
    and nobody is looking at the line-ups from a Tuesday in November. A match
    is worth asking about once the sides are likely to be named — an hour
    before kick-off — and stops being worth asking about after it is over,
    which the cache handles by holding a finished match's answer for a day.
    """
    index = None
    for fx in fixtures:
        kick = parse_ts(fx.get("kickoff_time"))
        soon = kick is not None and (kick - now()).total_seconds() < 5400
        if not (fx.get("started") or soon):
            continue
        if index is None:
            index = pulse_index()
            if not index:
                return
        fx["_home_pulse"] = teams.get(fx["team_h"], {}).get("pulse_id")
        fx["_away_pulse"] = teams.get(fx["team_a"], {}).get("pulse_id")
        pl_id = index.get((fx.get("_home_pulse"), fx.get("_away_pulse")))
        if not pl_id:
            continue
        live = fx.get("started") and not fx.get("finished_provisional")
        # A match still to kick off is the one case a long hold gets wrong:
        # the sides are named while it sits in the cache, and the answer held
        # is the one from before they were.
        ttl = 45 if live else (86400 if fx.get("started") else 300)
        detail = pulse_fetch("/fixtures/%d" % pl_id, ttl)
        if isinstance(detail, dict):
            fx["_sheets"] = pulse_sheets(detail)
        if fx.get("started"):
            fx["_mstats"] = pulse_stats(pl_id, live)


def referee_records(all_fixtures):
    """Cards shown by each referee, for the matches that have been played.

    The referee comes from the Premier League feed; the cards come from the
    fantasy feed we already have. A finished match never changes, so each
    referee is looked up once and remembered.
    """
    by_teams = pulse_index()
    if not by_teams:
        return []

    known = read_json(os.path.join(CACHE_DIR, "referees.json"), {},
                      MAX_CACHE_BYTES) or {}
    records = {}

    for fx in all_fixtures:
        if not fx.get("finished_provisional"):
            continue
        pulse_id = by_teams.get((fx.get("_home_pulse"), fx.get("_away_pulse")))
        if not pulse_id:
            continue

        name = known.get(str(pulse_id))
        if name is None:
            detail = pulse_fetch("/fixtures/%d" % pulse_id, 31536000)
            officials = (detail or {}).get("matchOfficials") or []
            main = next((o for o in officials if o.get("role") == "MAIN"), None)
            name = ((main or {}).get("name") or {}).get("display") or ""
            known[str(pulse_id)] = name
        if not name:
            continue

        stats = {s["identifier"]: s for s in fx.get("stats", [])}

        def count(identifier):
            entry = stats.get(identifier) or {}
            return sum(r["value"] for side in ("h", "a") for r in entry.get(side, []) or [])

        rec = records.setdefault(name, {"name": name, "matches": 0, "yellow": 0, "red": 0})
        rec["matches"] += 1
        rec["yellow"] += count("yellow_cards")
        rec["red"] += count("red_cards")

    try:
        write_atomic(os.path.join(CACHE_DIR, "referees.json"), known)
    except OSError:
        pass

    for rec in records.values():
        rec["cards"] = rec["yellow"] + rec["red"]
    return sorted(records.values(), key=lambda r: -r["cards"])


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


def team_fixtures(by_team, team_id):
    return by_team.get(team_id) or []


def shown_fixture(fixtures):
    """The fixture worth putting on a player's card.

    A match in play beats one still to come, which beats one already over —
    because the first is what you are watching and the last is settled.
    """
    if not fixtures:
        return None
    live = [f for f in fixtures if f.get("started") and not f.get("finished_provisional")]
    if live:
        return live[0]
    upcoming = [f for f in fixtures if not f.get("started")]
    if upcoming:
        return sorted(upcoming, key=lambda f: f.get("kickoff_time") or "")[0]
    return sorted(fixtures, key=lambda f: f.get("kickoff_time") or "")[-1]


VALID_MIN = {1: 1, 2: 3, 3: 2, 4: 1}
VALID_MAX = {1: 1, 2: 5, 3: 5, 4: 3}


def effective_multipliers(picks, live, fixtures_by_team, chip):
    """Who actually carries the armband, by element id.

    The API keeps the captain's multiplier until the gameweek is finalised,
    so a captain who was never on the pitch still counted double — and the
    vice still counted single — for the rest of the week. FPL moves the
    armband as soon as the captain's match is over with no minutes; this
    works out the same answer live, so the score, the bar and every
    mini-league row agree with the game rather than with the API's lag.
    """
    mults = {p["element"]: (p["multiplier"] if p["multiplier"] else 1)
             for p in picks}
    if chip == "bboost":
        pass  # bench boost changes who counts, not who is captain

    cap = next((p for p in picks if p.get("is_captain")), None)
    vice = next((p for p in picks if p.get("is_vice_captain")), None)
    if not cap or not vice:
        return mults

    def played(pick):
        return live.get(pick["element"], {}).get("minutes", 0) > 0

    def done(pick):
        games = team_fixtures(fixtures_by_team, pick["_team"])
        if not games:
            return True
        return all(f.get("finished_provisional") for f in games)

    # The armband only moves once the captain's own match is over and he was
    # not on the pitch. Before that he may still come on.
    if played(cap) or not done(cap):
        return mults

    armband = mults.get(cap["element"], 2) or 2
    mults[cap["element"]] = 1
    mults[vice["element"]] = armband
    return mults


def project_autosubs(picks, live, fixtures_by_team):
    """Which bench players will come on for team-mates who never played.

    Only counts a starter as a blank once their match is actually over —
    before that they might still be an unused substitute who comes on.
    """
    starters = [p for p in picks if p["position"] <= 11]
    bench = [p for p in picks if p["position"] > 11]

    def finished(pick):
        # Only a blank once every one of his club's matches this week is over —
        # or once it is clear there was never a match to play. Requiring a
        # fixture to exist meant a starter in a blank gameweek was treated as
        # still to come for the whole week, so no substitute was ever
        # projected for him and the score stayed short.
        games = team_fixtures(fixtures_by_team, pick["_team"])
        if not games:
            return True
        return all(f.get("finished_provisional") for f in games)

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

def as_float(value):
    """FPL sends some numbers as strings; take them at face value once."""
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


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
            "price_pct": as_float(e.get("price_change_percent")),
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
            "tackles": e.get("tackles", 0),
            "cbit": e.get("clearances_blocks_interceptions", 0),
            "recoveries": e.get("recoveries", 0),
            "ep_next": e.get("ep_next"),
        }
    return players, teams


def label_fixtures(fixtures, teams):
    for fx in fixtures:
        home = teams.get(fx["team_h"], {}).get("short_name", "?")
        away = teams.get(fx["team_a"], {}).get("short_name", "?")
        hs, as_ = fx.get("team_h_score"), fx.get("team_a_score")
        # Both, not just the home one: a started fixture with one score
        # reported and the other still null raised on the %d and took the
        # whole refresh down with it.
        if fx.get("started") and hs is not None and as_ is not None:
            fx["_label"] = "%s %d-%d %s" % (home, hs, as_, away)
        else:
            fx["_label"] = "%s v %s" % (home, away)
        fx["_home"] = home
        fx["_away"] = away
        fx["_home_name"] = teams.get(fx["team_h"], {}).get("name", home)
        fx["_away_name"] = teams.get(fx["team_a"], {}).get("name", away)
        fx["_home_pulse"] = teams.get(fx["team_h"], {}).get("pulse_id")
        fx["_away_pulse"] = teams.get(fx["team_a"], {}).get("pulse_id")
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
    # Where the league has reported an event itself, its version replaces the
    # fantasy one wholesale rather than being added to it — the two describe
    # the same events, and the league gets there first.
    detail.update(fx.get("_pl_events") or {})
    return detail


def fixture_row(fx, players):
    """One match in the shape the screens read it in."""
    return {
        "id": fx["id"], "label": fx["_label"], "home": fx["_home"], "away": fx["_away"],
        "home_name": fx["_home_name"], "away_name": fx["_away_name"],
        "started": fx.get("started", False), "finished": fx.get("finished_provisional", False),
        "minutes": fx.get("minutes", 0), "clock": fx.get("_pl_clock"),
        "referee": fx.get("_referee"),
        "kickoff": fx.get("kickoff_time"),
        "hs": fx.get("team_h_score"), "as": fx.get("team_a_score"),
        "hd": fx.get("team_h_difficulty"), "ad": fx.get("team_a_difficulty"),
        "detail": match_detail(fx, players) if fx.get("started") else None,
        # Both absent until the league names the sides and the match is under
        # way; the screen draws neither section rather than an empty one.
        "lineups": fx.get("_sheets"),
        "mstats": fx.get("_mstats"),
    }


# The monsters board: a podium of three for each of nine ways to be
# remarkable. Ported from the categories an earlier FPL Gaffer app used,
# with one substitution — fouls committed are not in the public API, so the
# foul-happy category runs on bookings instead, which amounts to the same
# accusation.
# No minutes qualifier. Every category counts something a player either did
# or did not do, and a goal is a goal whether it came in the ninetieth minute
# or the sixth. The old ninety-minute gate hid two of Arsenal's three
# scorers on the opening weekend, which is exactly the wrong answer.
def build_monsters(players, referees=None, mode="gaffer"):
    eligible = list(players.values())

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

    def add(cid, title, glyph, blurb, stat, pool, key, suffix="", swatch=""):
        winners = top(pool, key)
        cats.append({
            "id": cid, "title": title, "glyph": glyph, "blurb": blurb, "stat": stat,
            # A swatch draws a real card in the fixed booking colours instead
            # of a text glyph — a yellow card should look like a yellow card.
            "swatch": swatch,
            "players": [card(p, key(p), suffix) for p in winners],
        })

    defenders  = [p for p in eligible if p["pos"] == "DEF"]
    back_line  = [p for p in eligible if p["pos"] in ("DEF", "GKP")]
    keepers    = [p for p in eligible if p["pos"] == "GKP"]

    # Goals count from anyone. A scoring goalkeeper belongs on this list more
    # than anybody.
    add("goal", "Goal Monsters", "⚽", "Top scorers this season, any position",
        "GOALS", eligible, num("goals"))
    # Defensive contribution is scored by defenders, midfielders and forwards
    # alike under the current rules, so the category is open to all of them.
    if mode == "gaffer":
        add("defcon", "DefCon Monsters", "⛨", "Defensive contribution machines",
            "DEFCON", eligible, num("defcon"))
    else:
        add("tackles", "Ball Winners", "⛨", "Most tackles made",
            "TACKLES", eligible, num("tackles"))
        add("cbit", "Human Walls", "▧", "Clearances, blocks and interceptions",
            "CBI", eligible, num("cbit"))
        add("recoveries", "Scavengers", "◇", "Loose balls hoovered up",
            "RECOVERIES", eligible, num("recoveries"))
    add("closet", "Closet Strikers", "⚑", "Defenders who think they are forwards",
        "GOALS", defenders, num("goals"))
    add("assists", "Assist Kings", "♚", "The creators and providers",
        "ASSISTS", eligible, num("assists"))

    if mode == "gaffer":
        add("value", "Value Monsters", "$", "Best return per million spent",
            "PTS/£m", [p for p in eligible if p["cost"] > 0],
            lambda p: round(p["total_points"] / p["cost"], 2))
    add("cleansheet", "Clean Sheet Machines", "▤", "The brick walls",
        "CLEAN SHEETS", back_line, num("clean_sheets"))
    add("shotstopper", "Shot Stoppers", "✤", "Keepers earning their money",
        "SAVES", keepers, num("saves"))
    add("dirty", "Dirty Dogs", "", "The foul-happy merchants",
        "YELLOWS", eligible, num("yellow"), swatch="yellow")
    add("seeya", "See Ya", "", "Early bath specialists",
        "REDS", eligible, num("red"), swatch="red")

    # The one category that is not about players at all.
    whistle = []
    for rec in (referees or [])[:3]:
        breakdown = []
        if rec["yellow"]:
            breakdown.append("%dY" % rec["yellow"])
        if rec["red"]:
            breakdown.append("%dR" % rec["red"])
        whistle.append({
            "id": 0, "name": rec["name"],
            "team": "%d match%s" % (rec["matches"], "" if rec["matches"] == 1 else "es"),
            "pos": "", "cost": 0, "points": 0,
            "value": rec["cards"], "suffix": "",
            "duties": " ".join(breakdown),
        })
    cats.append({
        "id": "refs", "title": "See You Next Tuesday", "glyph": "",
        "blurb": "Referees, by cards shown", "stat": "CARDS",
        "swatch": "both", "players": whistle,
    })

    return {"categories": cats}


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
            # Your own team stays on the short cache; everyone else's is
            # locked and read once.
            # The id comes off the wire, and %d on a string raises rather
            # than returning a wrong answer — one malformed row would cost the
            # whole league table until the cache expired.
            rival = as_int(row.get("entry"), 0)
            if not rival:
                continue
            picks = fetch("/entry/%d/event/%d/picks/" % (rival, gw),
                          "picks" if rival == entry_id else "picks_locked", live)
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

    mults = effective_multipliers(picks, live_stats, fixtures_by_team, chip)

    total = 0
    for p in picks:
        counts = p["position"] <= 11 or chip == "bboost" or p["element"] in swap_in
        if p["element"] in swap_out:
            counts = False
        if not counts:
            continue
        stats = live_stats.get(p["element"], {})
        pts = stats.get("total_points", 0) + prov.get(p["element"], 0)
        total += pts * mults.get(p["element"], 1)
    return total - hits, chip


def past_squad(entry_id, gw, fixtures, players, teams):
    """Your own players in a gameweek that is already over.

    The same rows the live squad is built from, so a finished match can still
    say who of yours was in it. Everything here has stopped moving — the picks
    locked when the week began and the points settled when it ended — so both
    feeds are read at the long end of their cache lives rather than fetched
    again every cycle.
    """
    picks = fetch("/entry/%d/event/%d/picks/" % (entry_id, gw), "picks_locked", False)
    if not picks:
        return []
    raw = fetch("/event/%d/live/" % gw, "live", False) or {}
    stats = {e["id"]: e["stats"] for e in raw.get("elements", [])}
    by_team = {}
    for f in fixtures:
        by_team.setdefault(f["team_h"], []).append(f)
        by_team.setdefault(f["team_a"], []).append(f)
    stats["_by_team"] = by_team
    stats["_gw"] = gw
    rows, _, _ = squad_view(picks, stats, provisional_bonus(fixtures), players, by_team, teams)
    return rows


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
        games = team_fixtures(fixtures_by_team, meta.get("team"))
        fx = shown_fixture(games)
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
            "double": len(games) > 1,
            "when": when,
            "live": live_now,
            "played": stats.get("minutes", 0) > 0,
            "to_play": fx is not None and not fx.get("started"),
        })
    rows.sort(key=lambda r: r["position"])
    return rows, subs, chip


# ------------------------------------------------------------------- notices

def raise_notices(state, previous, settings):
    global MATCH_PULSES
    MATCH_PULSES = 0
    seen = read_json(SEEN_FILE, {}, MAX_SETTINGS_BYTES)
    if not isinstance(seen, dict):
        seen = {}
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
                       "%s — %s. Now on %d points." % (row["fixture"], row["when"], row["applied"]),
                       pulse=True)
            if row["assists"] > old["assists"]:
                notify("🅰 %s assists" % row["name"],
                       "%s — %s. Now on %d points." % (row["fixture"], row["when"], row["applied"]),
                       pulse=True)
            if row["red"] > old["red"]:
                notify("🟥 %s sent off" % row["name"], row["fixture"], pulse=True)

    # Live scores from every match, for people following the football rather
    # than a fantasy team. Compares this pass's scoreline against the last.
    if wants.get("matchGoals"):
        before_fx = {f["id"]: f for f in (previous or {}).get("fixtures", [])}
        for fx in state.get("fixtures", []):
            old = before_fx.get(fx["id"])
            if not old or fx.get("hs") is None or old.get("hs") is None:
                continue
            if fx["hs"] != old["hs"] or fx["as"] != old["as"]:
                # Who actually just scored: the player whose tally went up
                # since the last pass. The list is insertion-ordered, not
                # chronological, so taking the last entry named whoever
                # happened to sit at the end of it.
                which = "home" if fx["hs"] != old["hs"] else "away"
                now_side = ((fx.get("detail") or {}).get("goals_scored")
                            or {}).get(which) or []
                was_side = ((old.get("detail") or {}).get("goals_scored")
                            or {}).get(which) or []
                was = {g.get("name"): g.get("value", 0) for g in was_side}
                gained = [g for g in now_side
                          if g.get("value", 0) > was.get(g.get("name"), 0)]
                scorer = ", ".join(g["name"] for g in gained if g.get("name"))
                if not scorer and now_side:
                    # No usable comparison — better an unnamed goal than a
                    # confidently wrong name.
                    scorer = ""
                # The same clock the app shows: 45+3' rather than a 48th
                # minute that nobody watching the match would recognise.
                when = fx.get("clock") or "%d'" % (fx.get("minutes") or 0)
                notify("⚽ %s" % fx["label"],
                       (scorer + " · " if scorer else "") + when, pulse=True)
            elif old.get("finished") is False and fx.get("finished"):
                notify("Full time — %s" % fx["label"], "", pulse=True)

    if wants.get("kickoff"):
        before_kick = {f["id"]: f for f in (previous or {}).get("fixtures", [])}
        for fx in state.get("fixtures", []):
            if not fx.get("started"):
                continue
            key = "ko-%d" % fx["id"]
            if seen.get(key):
                continue
            seen[key] = True
            # A match that kicked off while we were watching is news. One
            # already under way when we started up is not, so it is marked
            # as told without being announced.
            was = before_kick.get(fx["id"])
            if was is not None and not was.get("started"):
                notify("Kick off — %s" % fx["label"], "", pulse=True)

    if wants.get("news"):
        for pid, row in squad.items():
            old = before.get(pid)
            if old and row["news"] and row["news"] != old["news"]:
                notify("📋 %s — team news" % row["name"], row["news"])

    if wants.get("bonus"):
        key = "bonus-%s" % state.get("gw")
        if state.get("bonus_added") and not seen.get(key):
            seen[key] = True
            notify("Bonus confirmed — GW%s" % state.get("gw"),
                   "Final score %d points." % state.get("live_points", 0))

    if wants.get("prices"):
        for row in state.get("price_watch", []):
            # The list covers the whole market now; the notifications must not.
            # Only your own players and the ones you have chosen to watch are
            # worth a desktop alert at midnight.
            if not (row.get("owned") or row.get("watched")):
                continue
            # Dated: without a day in the key a player could raise one rise
            # and one fall alert for the whole season, because seen.json is
            # never pruned. Prices move nightly.
            key = "price-%s-%d-%s" % (now().date().isoformat(),
                                      row["id"], row["direction"])
            if row["likely"] and not seen.get(key):
                seen[key] = True
                arrow = "rising" if row["direction"] == "up" else "falling"
                notify("💷 %s is %s tonight" % (row["name"], arrow),
                       "%s · £%.1fm · %s%% of the way there"
                       % (row["team"], row["cost"], row["progress"]))

    if wants.get("deadline") and state.get("deadline_in"):
        hours = state["deadline_in"] / 3600.0
        reached = [m for m in (24, 3, 1) if hours <= m]
        if reached:
            mark = min(reached)
            key = "dl-%s-%d" % (state.get("next_gw"), mark)
            if not seen.get(key):
                # Anything looser has been overtaken; never say it after the fact.
                for m in reached:
                    seen["dl-%s-%d" % (state.get("next_gw"), m)] = True
                trouble = [r["name"] for r in state.get("squad", [])
                           if r["status"] in ("i", "s", "u", "n") and not r["benched"]]
                body = "GW%s deadline." % state.get("next_gw")
                if trouble:
                    body += " Doubts in your XI: " + ", ".join(trouble[:4])
                notify("⏰ %d hour%s to the deadline" % (mark, "" if mark == 1 else "s"),
                       body, urgency="critical" if mark <= 3 else "normal")

    # seen.json is a ledger of things already said, and nothing ever removed
    # anything from it. Keys carrying a date are dropped once they are old
    # enough that the thing they describe cannot recur.
    today = now().date().isoformat()
    seen = {k: v for k, v in seen.items()
            if not k.startswith("price-") or k[6:16] >= today}

    # The running count of match events, kept beside the ledger of what has
    # already been said so it survives a restart. It only ever goes up: the
    # bar icon flashes on the number changing, and a counter that reset would
    # flash the whole session's football at whoever logged back in.
    seen["event_seq"] = as_int(seen.get("event_seq"), 0) + MATCH_PULSES
    state["event_seq"] = seen["event_seq"]
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

    # The league's own feed is quicker and more complete than the fantasy one
    # on the football itself. It is a second source though, so it corrects
    # what it can and must never be able to take the refresh down with it.
    try:
        apply_live_feed(all_fixtures, teams)
        all_fixtures = label_fixtures(all_fixtures, teams)
    except Exception as exc:
        log("live feed unavailable, using the fantasy clock: %s" % exc)

    gw_fixtures = [f for f in all_fixtures if f.get("event") == gw]

    # Who is on the pitch and what the match is doing — the same second source,
    # and the same rule: it enriches the week's matches and must never be able
    # to take the refresh down with it.
    try:
        apply_match_sheets(gw_fixtures, teams)
    except Exception as exc:
        log("no team sheets this gameweek: %s" % exc)

    live_raw = fetch("/event/%d/live/" % gw, "live", live_now) or {}
    live_stats = {e["id"]: e["stats"] for e in live_raw.get("elements", [])}

    # A club can play twice in a gameweek. Keeping only one of its fixtures
    # meant a player who blanked in the early game could be written off as a
    # definite blank while his second match was still to come.
    by_team = {}
    for f in gw_fixtures:
        by_team.setdefault(f["team_h"], []).append(f)
        by_team.setdefault(f["team_a"], []).append(f)
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
            # Skip a malformed row rather than raise through the whole
            # refresh: the id becomes a URL further on and the name is drawn,
            # so both have to be the shape they claim. This matches how the
            # standings rows are read — one bad row costs that row.
            leagues = []
            for l in ((entry.get("leagues") or {}).get("classic") or []):
                if not isinstance(l, dict):
                    continue
                league_id = as_int(l.get("id"), 0)
                if not league_id:
                    continue
                leagues.append({
                    "id": league_id,
                    "name": str(l.get("name") or "League %d" % league_id),
                    "rank": l.get("entry_rank"),
                    "last_rank": l.get("entry_last_rank"),
                    "size": l.get("rank_count"),
                    "type": l.get("league_type"),
                })
            state["leagues"] = leagues

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
    state["fixtures"] = [fixture_row(f, players)
                         for f in sorted(gw_fixtures, key=lambda f: f.get("kickoff_time") or "")]

    # Handy for the bar readout in either mode: what's on now, what's next.
    state["live_matches"] = sum(1 for f in gw_fixtures
                                if f.get("started") and not f.get("finished_provisional"))
    upcoming = sorted([f for f in all_fixtures
                       if not f.get("started") and f.get("kickoff_time")],
                      key=lambda f: f["kickoff_time"])
    state["next_kickoff"] = upcoming[0]["kickoff_time"] if upcoming else None
    state["next_match"] = upcoming[0]["_label"] if upcoming else None

    # Club crests, as paths to files already on this machine. The screens
    # never fetch an image themselves: whatever a badge turns out to be, it
    # arrives here, capped, checked for being a PNG at all, and written whole.
    try:
        state["badges"] = badge_paths(teams)
    except Exception as exc:
        log("badges unavailable, using club initials: %s" % exc)
        state["badges"] = {}

    # A gameweek does not stop mattering the moment its last whistle goes. The
    # fantasy clock holds it as current right through the gap, and when it
    # finally turns over, the week just watched would otherwise disappear from
    # the one screen that showed it. It travels alongside the current week
    # instead, settled, for the live tab to fold away rather than lose.
    prev_gw, prev_fixtures = None, []
    for e in sorted(events, key=lambda e: e["id"], reverse=True):
        if e["id"] >= gw:
            continue
        played = [f for f in all_fixtures if f.get("event") == e["id"] and f.get("started")]
        if played:
            prev_gw, prev_fixtures = e["id"], played
            break
    state["prev_gw"] = prev_gw
    # Last week's sheets and numbers too, so the drawer is the same screen as
    # the week above it rather than a poorer version of it. A finished match
    # is asked about once and held for a day.
    try:
        apply_match_sheets(prev_fixtures, teams)
    except Exception as exc:
        log("no team sheets for gameweek %s: %s" % (prev_gw, exc))
    state["prev_fixtures"] = [fixture_row(f, players)
                              for f in sorted(prev_fixtures, key=lambda f: f.get("kickoff_time") or "")]
    # Who of yours played in them is worth having too, but it is a second
    # helping of a screen that reads perfectly well without it — so it must
    # never be able to take the refresh down with it.
    state["prev_squad"] = []
    if entry_id and prev_gw:
        try:
            state["prev_squad"] = past_squad(entry_id, prev_gw, prev_fixtures, players, teams)
        except Exception as exc:
            log("last week's squad unavailable, showing the results alone: %s" % exc)

    # The grid starts at the gameweek being played, not the one after it. A
    # week with matches still to come is the week you are planning around.
    gw_done = all(f.get("finished_provisional") for f in gw_fixtures) if gw_fixtures else True
    grid_start = (nxt["id"] if (gw_done and nxt) else gw)

    state["bonus_races"] = bonus_races(gw_fixtures, players)
    state["league_table"] = build_league_table(all_fixtures, teams)
    # The referee names are the one thing that comes from outside the FPL
    # API. If that feed changes shape or disappears, that category should go
    # quiet — it must not be able to take the whole refresh down with it.
    try:
        refs = referee_records(all_fixtures)
    except Exception as exc:
        log("referee lookup failed, carrying on without it: %s" % exc)
        refs = []
    state["monsters"] = build_monsters(players, refs, mode)
    state["grid"] = build_fixture_grid(
        all_fixtures, teams, grid_start, int(settings.get("fixtureWeeks") or 6))

    owned = {r["id"] for r in state.get("squad", [])}
    watched = set(settings.get("watchlist") or [])
    # The whole market, not just the fifteen: a price move you care about is
    # as often on a player you are about to buy as on one you already have.
    # Your own are carried whatever their progress, because a screen headed
    # "my team" that says "nothing here" tells you less than the numbers do.
    price_watch = []
    for pid, meta in (players.items() if mode == "gaffer" else []):
        pct = meta["price_pct"]
        direction = "up" if pct >= 0 else "down"
        magnitude = abs(pct)
        if magnitude < 20 and pid not in owned:
            continue
        price_watch.append({
            "id": pid, "name": meta["web_name"], "team": meta["team_short"],
            "cost": meta["cost"], "direction": direction,
            "progress": round(magnitude, 1), "likely": magnitude >= 95,
            "owned": pid in owned, "watched": pid in watched,
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
        # When this was worked out, so a countdown drawn from it can subtract
        # the time since rather than showing the same number until the next
        # write.
        "deadline_at": (now().timestamp() + state["deadline_in"]
                        if state.get("deadline_in") else None),
        "chip": state.get("chip"),
        "provisional": not state.get("bonus_added") and state.get("live_now"),
        # Goals, cards, kick-offs and full time, counted. The icon flashes when
        # it moves; it never goes backwards, so a missed write is a missed
        # flash rather than a permanently confused one.
        "event_seq": state.get("event_seq"),
    }
    write_atomic(BAR_FILE, bar)


def cadence(state, ok=True):
    """How long to wait before looking again."""
    # A cycle that fetched nothing tells us nothing, so the state we are
    # holding is however stale it was before. Deciding the next sleep from it
    # is how a blink of bad network turns into a quarter of an hour asleep:
    # come back soon instead and ask again.
    if not ok:
        return 60
    if not state:
        return 120
    wait = 900       # nothing on: check in occasionally, for news and prices
    if state.get("live_now"):
        wait = 55
    else:
        left = state.get("deadline_in")
        if left is not None:
            if left < 3600:
                wait = 120   # deadline imminent — watch prices and news closely
            elif left < 6 * 3600:
                wait = 300
    # Never sleep through a kick-off. Left alone, the sleep is chosen from a
    # world where no match is on, so a game starting mid-nap goes unseen until
    # the nap ends — the first goal of the evening landing in silence. Wake as
    # the whistle goes instead, and let the next pass pick up the live cadence.
    kick = parse_ts(state.get("next_kickoff"))
    if kick:
        until = (kick - now()).total_seconds() + 5
        if 0 < until < wait:
            wait = until
    return max(20, wait)


# ----------------------------------------------------------------------- main

def single_instance():
    # O_NOFOLLOW, and no truncation until the lock is actually held: a bare
    # open(path, "w") both follows a symlink planted at this well-known name
    # and truncates its target before the lock is even attempted.
    try:
        fd = os.open(LOCK_FILE, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW
                     | os.O_NONBLOCK, 0o600)
    except OSError as e:
        if e.errno == errno.ELOOP:
            log("refusing lock file that is a symlink: %s" % LOCK_FILE)
            return None
        if e.errno == errno.ENXIO:
            log("refusing lock file that is a pipe: %s" % LOCK_FILE)
            return None
        raise
    # A restored backup or a planted name can leave something here that is
    # not a file. Locking it would succeed and mean nothing.
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        log("refusing lock file that is not a regular file: %s" % LOCK_FILE)
        os.close(fd)
        return None
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return None
    os.ftruncate(fd, 0)
    os.write(fd, str(os.getpid()).encode())
    return fd


def cycle(previous):
    settings = load_settings()
    mode = settings.get("appMode") or "gaffer"
    if mode == "gaffer" and not settings.get("entryId"):
        write_atomic(STATE_FILE, {"needs_setup": True, "mode": mode,
                                  "updated": now().isoformat()})
        return None, True
    state = refresh(settings, previous)
    if not state:
        return previous, False
    # The notify pass runs first because it is what counts the match events,
    # and the bar file carries that count: written the other way round, the
    # icon would learn about a goal one cycle after the desktop did.
    try:
        raise_notices(state, previous, settings)
    except Exception as exc:                                    # never die on a toast
        log("notify pass failed: %s" % exc)
    write_atomic(STATE_FILE, state)
    write_bar(state)
    return state, True


def read_state_file():
    """The previous state, or None. Shape-checked here because valid JSON of
    the wrong type would otherwise reach cadence() and the notify pass, both
    of which assume a dictionary."""
    state = read_json(STATE_FILE)
    return state if isinstance(state, dict) else None


def main():
    # First run creates the data directory the installer told the user about.
    ensure_dirs()
    mode = sys.argv[1] if len(sys.argv) > 1 else "once"

    if mode == "status":
        state = read_state_file() or {}
        print("GW%s  %s pts  rank %s  live=%s  updated %s" % (
            state.get("gw"), state.get("live_points"), state.get("overall_rank"),
            state.get("live_now"), state.get("updated")))
        return

    if mode == "once":
        global MANUAL
        MANUAL = True
        cycle(read_state_file())
        return

    lock = single_instance()
    if lock is None:
        log("another gafferd already holds the lock — exiting")
        return

    log("gafferd started")
    state = read_state_file()
    while True:
        ok = False
        try:
            # Compare against what was last WRITTEN, not against what this
            # process happens to remember. A manual refresh (`gafferd.py
            # once`, which the panel's refresh button runs) writes a newer
            # state and raises its own notices; the daemon then still held the
            # older one, so the next cycle announced the same goal, assist,
            # red card and news item all over again.
            prune_cache()
            on_disk = read_state_file()
            if on_disk is not None:
                state = on_disk
            state, ok = cycle(state)
        except Exception as exc:
            log("cycle failed: %s" % exc)
        time.sleep(cadence(state, ok))


if __name__ == "__main__":
    main()
