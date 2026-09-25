# Media Lyrics

## Track identification fallback

Ordinary MPRIS metadata remains the first lyric lookup source. When a player
exposes a YouTube URL, the service can also ask `yt-dlp` for chapter metadata
without downloading the video. For a chaptered album upload, the active
chapter's title and duration become the lookup target. Lyric timestamps and
panel seeking are relative to that chapter.

An optional LLM fallback can identify a track from incomplete MPRIS
fields, a source URL, video title/uploader, chapter, playback position, and
duration. It runs only after the literal lyric lookup fails, including for
chapters. Titles and artist fields are not split or cleaned with heuristics.
The first LLM attempt reconciles the original player fields with the video
title, description, music credits, upload channel, full chapter list, active
chapter and playback position, then calls `search_lyrics` against the same LRCLIB
database used by the plugin, inspects the returned catalog matches, and may
revise its query. It selects an actual returned result ID; the plugin uses
that result's metadata and lyrics. There are no self-assessed confidence
scores. OpenRouter web search is available from the start, but the prompt
prioritizes parsing the title and querying the lyric database without asking
for web research. Chapter labels are treated as hints. Uncached `yt-dlp`
metadata loads in the background without blocking the first AI attempt;
successful metadata is cached per video in memory and on disk.
Uploader/player artist fields and chapter labels are unverified clues: they
may name a channel, omit the performer, or use translated track names. If new
context arrives during an unsuccessful or pending identification, the model
is retried with that context.
For clearly non-song videos or segments, the model can immediately return
`{"not_a_song": true}` without lyric or web searches. Both panels show
“Waiting for AI...” while identification runs and “Classified as not a song
by AI” for that outcome. Classification is not a backend error and is not
retried until reload or a track change.
Successful identifications are reused;
otherwise each chapter gets one identification sequence until
reload. It can work without a YouTube URL
or `yt-dlp`. For long unchaptered videos, it rechecks at most once per
three-minute position bucket, or at a verified track boundary if the model
finds a timestamped tracklist. If evidence is insufficient, it leaves the
identity unchanged rather than guessing. No audio is uploaded or transcribed;
some videos therefore cannot be identified. Metadata and successful
identifications are cached in the plugin data directory.

This fallback is controlled in the plugin settings:

- **YouTube fallback** enables chapter lookup (on by default).
- **yt-dlp binary path** can be an absolute path; empty uses `yt-dlp` from `PATH`.
- **LLM backend** is a dropdown selecting exactly one provider: Ollama,
  OpenAI, Anthropic, Gemini, xAI, Groq, DeepSeek, Mistral, or OpenRouter.
  OpenRouter is the default. Select **Disabled** to turn identification off.
  Only the selected provider's key, model, and endpoint settings are shown.
  Saved keys for other providers are inactive; missing keys and failed calls
  report an error without switching providers.
- **Ollama endpoint** defaults to `http://localhost:11434/v1`. A local server
  without authentication needs no API key; select an installed model.
- **OpenAI endpoint** defaults to `https://api.openai.com/v1`; override it for
  Ollama or another compatible server. Both a base URL including `/v1` and a
  full `/chat/completions` URL are accepted.
- Each provider has a configurable model. OpenRouter defaults to
  `~google/gemini-flash-latest` with optional web search. All providers get
  the lyric database search tool; the selected model must support tool calling.
  Each identification allows up to four lyric queries, with up to 20 results
  per query, to prevent repeated searches from running indefinitely.
- **LLM output token limit** is a text field accepting positive whole numbers
  directly below the selected model and defaults to **32768**, including reasoning for
  providers that count it in the output budget. This is configurable for
  models with different limits. Identification returns track metadata only;
  lyrics still come from the lyrics providers.

If identification fails and there are no lyrics, both panels show
`No lyrics found (LLM backend for <provider> returned error: <error>)`.
Authentication, network, malformed/empty response, and token-limit failures
are included. Reload lyrics or change the provider settings to retry.
Responses use streaming transport so longer requests are not cut off by the
ordinary HTTP client's 30-second timeout.

The model is asked for track identity only, not lyrics. Noctalia currently
stores plugin settings, including the optional API key, as plain text in its
user settings file. Keep that file private. Provider requests send the key
through Noctalia's native HTTPS client, never as a subprocess argument.

`yt-dlp` and `python3` are needed only for YouTube metadata extraction. The
LLM fallback can run without either one. Each identification and web
search may incur API charges; select Disabled to turn identification off.

A full-featured media player panel with **time-synced lyrics** for the Noctalia desktop shell. Karaoke-style lyric carousel (10/14/16 visible lines per size preset), album cover, transport controls, and a progress bar — all in one floating panel. The main panel and lyric pipeline are Luau; the optional YouTube metadata helper is a short-lived Python process. No playerctl, Python daemon, or GTK overlay is needed.

## Replay a lookup

Run the production service and provider adapters with explicit metadata:

```sh
python3 replay_lyrics.py \
  --title 'Frost Children, Ninajirachi - Sisters' \
  --artist 'Frost Children' \
  --url 'https://www.youtube.com/watch?v=Oyct_cZvYiY' \
  --duration 223
```

The command reads the selected provider settings locally and makes real
database/API calls. It prints the final state and request timings, without
printing credentials or lyric text. It neither controls the player nor reads
or writes the live lyric caches. API calls may incur the provider's charges.
Use `--provider none` to test literal lookup, `--model` to override the model,
`--metadata path.json` for chapter metadata, or `--yt-dlp` to fetch it anew.
Without those metadata options, the supplied title/artist/duration are used
directly, with no chapters and no yt-dlp invocation.

Requires Python 3.11+, `curl`, and `liblua5.4`. This replay uses Lua 5.4 to run
the same source files; it does not emulate Noctalia's Luau callback CPU budget
or render its UI. Tests use deterministic transports and real JSON:

```sh
python3 -m unittest test_llm_backend.py test_youtube_info.py test_replay_lyrics.py
```

| Light theme | Dark theme |
| --- | --- |
| ![Media Lyrics panel (light)](screenshots/panel-light.png) | ![Media Lyrics panel (dark)](screenshots/panel-dark.png) |

## Plugin

| Field | Value |
| --- | --- |
| ID | `tranzem/media-lyrics` |
| Entries | Bar widget: `now-playing`; panels: `panel` (medium 520×520), `panel-compact` (440×440), `panel-large` (640×640), `panel-mini` (360×120); service: `service`; shortcut: `toggle` |

## Requirements

- Noctalia v5 (plugin API 24+)
- `busctl` (systemd, present on every Arch install)
- `curl` — used for the HTTPS lyric fetches: LRCLIB primary + NetEase Cloud
  Music fallback (spawned as `curl -sSf -m 8 -4 <url>`, argv-only, no shell;
  LRCLIB resolves IPv4 faster than the built-in HTTP client on some setups)
- Outbound HTTPS access to `https://lrclib.net` (primary) and
  `https://music.163.com` (NetEase fallback) for lyrics

No player-specific software. Any MPRIS-capable player works: Spotify, MPD, Cider, web players, VLC, and anything else that exposes MPRIS over D-Bus. `sleep` (coreutils) is used for a short refresh delay after transport commands.

## Usage

Enable the plugin, then open the panel:

```sh
noctalia msg plugins enable tranzem/media-lyrics
noctalia msg panel-toggle tranzem/media-lyrics:panel
```

The panel opens at the size preset selected by the `panel_size` setting
(compact 440 / medium 520 / large 640). The `now-playing` bar widget and the
`toggle` control-center tile both open the selected preset; you can also open
a specific preset directly:

```sh
noctalia msg panel-toggle tranzem/media-lyrics:panel-compact
noctalia msg panel-toggle tranzem/media-lyrics:panel-large
noctalia msg panel-toggle tranzem/media-lyrics:panel-mini
```

`panel-mini` is a compact always-on surface (cover + the current lyric line)
intended for pinning to the desktop; it does not close on outside clicks.

Add the `now-playing` widget to your bar: a compact chip with the album
cover and **Title - Artist** of the active MPRIS player. Its gestures mirror
the shell's built-in media widget:

- **Left click** — open the lyrics panel.
- **Right click** — play/pause.
- **Middle click** — this widget's display settings.
- **Wheel / mouse back / forward** — previous / next track.
- On a **vertical bar** the chip collapses to the artwork only.

Display options are edited in the widget's own settings popup (middle click):

| Setting | Default | Effect |
| --- | --- | --- |
| `album_art_only` | off | Show only the artwork, no text |
| `hide_album_art` | off | Hide the artwork and its fallback icon |
| `hide_artist` | off | Show only the track title |
| `artist_first` | off | Show `Artist - Title` instead of `Title - Artist` |
| `min_length` | 80 | Minimum widget length (px) — accepted for parity; plugin chips are sized by the host to their content |
| `max_length` | 220 | Text area width (px); long titles truncate or scroll to fit |
| `art_size` | 16 | Artwork size (px) |
| `title_scroll` | none | Scroll long titles: `none`, `always`, or `on hover` |
| `hide_when_no_media` | off | Hide the chip when no MPRIS player is active |
| `show_lyric_line` | off | Show `Title · current line` in the chip instead of `Title - Artist` while synced lyrics are ready (long lines scroll with the marquee; falls back to the artist line otherwise) |

A `toggle` shortcut (control-center tile) is also available. Bind it to a hotkey in Noctalia's shortcut settings, or from your compositor:

```toml
"Ctrl+Alt+M" = "spawn:noctalia msg panel-toggle tranzem/media-lyrics:panel"
```

The panel shows the active MPRIS player automatically; when nothing is playing it renders an empty state.

## Features

- **Karaoke lyric carousel** — 10/14/16 lines visible at once (compact/medium/large presets); the active line is bright, neighbours fade by distance (Clavis-style). Works with synced (LRC) and plain lyrics.
- **Clickable lyric lines** — click a synced line to seek the player to that timestamp.
- **Manual lyric scroll** — Up/Down step a line (the host's chord validator accepts only basic key names; PageUp/PageDown/Home/End are rejected).
- **LRCLIB integration** — exact `/api/get` lookup first, `/api/search` fallback, LRC parsed in pure Luau.
- **Lyrics variants picker** — the header "list" button (always visible while a track plays) fetches the full LRCLIB search result on demand and lists alternative lyric versions: pick one to switch instantly (the playing lyrics are never interrupted while the list loads), pick **Default** to restore the automatic chain, or switch again at any time — the candidate list stays in memory per track.
- **NetEase Cloud Music fallback** — no-auth second source for LRCLIB misses (public endpoints, browser headers only): synced LRC wins, candidates ranked by title/artist + duration, metadata lines stripped; instrumental placeholders are filtered.
- **Local `.lrc` files** — drop `Artist - Title.lrc` into the local lyrics folder; they take priority over the network.
- **Marquee titles** — long track/artist names hold for 2 s, then scroll slowly instead of wrapping or clipping. Overlap-free (per-slice node recreation).
- **Album cover + progress bar** — interpolated progress between polls, transport controls (prev / play-pause / next), shuffle and repeat state.
- **Live lyric line in the chip** — optional `show_lyric_line` widget setting: while synced lyrics are ready the chip shows `Title · current line` instead of the artist (steps with playback, marquee for long lines).
- **Settings** — lyric timing offset in ms, on-disk cache, local lyrics folder. Translatable UI: strings go through Noctalia's i18n (`noctalia.tr`, English ships in the plugin; other locales via Noctalia Translate).

## Advantages over alternative lyric plugins

- **Lean runtime.** No playerctl, python daemons, pip packages, or GTK overlays to install and maintain — just `busctl` and `curl`, present on virtually every Linux system. Enable → works.
- **Player-agnostic.** Reads MPRIS directly via Noctalia's D-Bus aggregator — works with any player, not tied to a specific app.
- **A real panel, not a 1–3 line bar widget.** Full-screen-height carousel with 10–16 visible lines (per size preset) keeps whole verses in view.
- **Overflow handled properly.** Long titles get a marquee, single-line sanitizer strips embedded newlines, integer button heights prevent glyph overlap.
- **Offline-friendly.** LRCLIB responses are cached; local `.lrc` files work without network at all.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `panel_size` | `select` | `medium` | Panel size preset: `mini` (360×120 chip panel), `compact` (440×440, 10 lyric lines), `medium` (520×520, 14 lines), `large` (640×640, 16 lines). The bar widget and the control-center tile open this preset. |
| `offset_ms` | `int` | `0` | Shift lyric timing: positive shows lines earlier, negative later. |
| `use_cache` | `bool` | `true` | Cache fetched lyrics in the plugin data directory for offline reuse. |
| `local_lyrics_dir` | `folder` | `~/.local/share/media-lyrics` | Folder with local `.lrc` files named `Artist - Title.lrc`; searched before LRCLIB. |
| `player_allowlist` | `string` | *(empty)* | Comma-separated identity/bus-name substrings; when set, only matching players are shown (e.g. `spotify, mpd`). |
| `player_blocklist` | `string` | *(empty)* | Comma-separated substrings of players to exclude (e.g. `firefox` to ignore a browser's MPRIS). |

## IPC

```sh
noctalia msg panel-toggle tranzem/media-lyrics:panel
```

## Local development

Add the parent directory as a local Noctalia source:

```sh
noctalia msg plugins source add media-lyrics-dev path /path/to/media-lyrics-parent
noctalia msg plugins enable tranzem/media-lyrics
noctalia msg config-reload
```

## To Do

Upcoming work, roughly in priority order:

- [ ] Album cover inside a capsule shape (panel info row — the bar-widget
      chip already shows the artwork since 0.9.0)
- [x] Additional lyric sources — **NetEase fallback DONE in 0.9.1** (no-auth,
      last in the chain); **embedded MPRIS `xesam:asText` DONE in 0.9.2**
      (zero-network, position 2 in the chain). Remaining: Musixmatch,
      Spotify — most need API keys/tokens (see Notes)
- [x] Lyrics variants picker — switch between alternative LRCLIB versions on
      the fly (DONE in 0.9.4: header button, on-demand search, Default row)
- [x] Clickable lyric lines — click a line to seek the track to that moment (DONE in 0.8.5: click + Return/Space)
- [ ] Seek on progress-bar click — **BLOCKED by host**: click handlers do not
      report coordinates, so a click position cannot be mapped to a timestamp
      (only lyric-line clicks and the keyboard cursor can seek)
- [ ] Compact mode with a pinnable widget — the bar chip + panel presets
      cover the compact surface; a desktop-pinned view would need a new
      `[[desktop_widget]]` entry (open question)
- [x] Preconfigured widget actions — default gestures declared in the manifest (DONE in 0.8.1 and reworked in 0.9.0: now mirrors the built-in media widget — right click = play/pause, back/forward + wheel = prev/next; middle click = widget settings)
- [x] Widget size setting — panel size presets (DONE in 0.8.7: `panel_size` select — compact 440 / medium 520 / large 640)
- [x] Bar widget album cover + display settings (DONE in 0.9.0: artwork chip, `album_art_only` / `hide_album_art` / `hide_artist` / `artist_first` / `min_length` / `max_length` / `art_size` / `title_scroll` / `hide_when_no_media`; vertical bars show the artwork only)

## Notes

- The service polls MPRIS via `busctl` (150 ms cadence) and publishes a snapshot to `noctalia.state`; the panel animates from those publishes.
- Lyrics are fetched from public services with `curl` — LRCLIB API primary,
  NetEase Cloud Music fallback on misses; nothing is uploaded. Cache and
  local lyrics live under the plugin data directory and `local_lyrics_dir`.
- Spawned processes (all argv-form, no shell): `busctl` (MPRIS poll), `curl` (LRCLIB + NetEase lyric fetches, IPv4, 8 s timeout), `sleep` (coreutils, 0.35 s refresh delay after transport commands).
- Adapted from the Clavis shell media player text layer (karaoke render + LRCLIB provider), ported to pure Luau for Noctalia v5.
