# Changelog

## [0.9.5] — Unreleased

### Added

- **AI song identification** helps find lyrics when a video's title, artist,
  or chapter labels are incomplete or misleading.
- **YouTube album support.** Lyrics follow the current track in chaptered
  videos. For albums without chapters, the plugin can find a tracklist and
  estimate track boundaries from the song durations.
- **YouTube captions** provide timed lines when lyric sources miss, before AI
  lookup is needed.
- **Web lyrics as a last resort.** When the lyric databases have no match,
  AI can find plain lyrics on the web. The source hostname links to the
  original page.
- **Your choice of AI provider:** OpenAI, Anthropic, Gemini, xAI, Groq,
  Mistral, or OpenRouter. Choose a model or disable AI entirely.
- **Clear AI status messages** show when a lookup is running, when a video
  is classified as not a song, or why a request failed. Reload lyrics to retry.
- **Remembered results** let previously identified tracks and album
  tracklists load without repeating the AI lookup.
- **A settings shortcut** opens the plugin's settings from the lyrics panel.

### Fixed

- Lyrics lookups no longer remain stuck on “Waiting for AI...” after a
  result-processing failure.
- Longer AI responses are less likely to be interrupted before they finish.

## [0.9.4] — 2026-09-09

### Added

- **Lyrics variants picker.** Use the list button to browse alternative
  lyrics, switch versions, or restore the default without interrupting the
  lyrics already on screen.

### Fixed

- The mini panel's cover stays in place when a lyric line wraps.
- Selecting an alternative lyric version no longer fails.
- Lyrics and the current-line bar display remain visible while choosing
  another version.

## [0.9.3] — 2026-09-06

### Changed

- Requires Noctalia 5.0.1 or later.
- Lyrics panels stay visible above fullscreen video. Change a panel's Layer
  setting to restore its previous behavior.

## [0.9.2] — 2026-09-06

### Added

- **Current lyrics in the bar.** An optional widget setting shows the current
  synced lyric line beside the song title.
- **Lyrics supplied by the player** can now be displayed without an online
  lookup.

## [0.9.1] — 2026-09-05

### Added

- **NetEase Cloud Music fallback** finds additional lyrics when LRCLIB has
  no match or is unavailable. Synced lyrics are preferred when available.

### Fixed

- Instrumental and missing-lyrics notices no longer appear as song lyrics.
- Connection errors now refer to the lyric services rather than only LRCLIB.

## [0.9.0] — 2026-09-03

### Added

- **Album artwork in the bar widget**, with a dimmed appearance while paused.
- **Widget appearance settings** for artwork, artist names, text length,
  scrolling titles, and hiding the widget when nothing is playing.
- **Playback shortcuts:** right-click to play or pause; use the mouse wheel
  or back/forward buttons to skip tracks. Middle-click opens widget settings.
- Vertical bars show the album artwork without text.

### Fixed

- The widget returns to normal brightness when playback resumes.
- The artist appears beside the song title by default.

## [0.8.13] — 2026-09-02

### Fixed

- Connection failures are shown as errors instead of “No lyrics found”.
- Long Cyrillic and other non-ASCII text is no longer cut through a character.
- Improved plain-lyrics rendering and consistency of karaoke text sizing.
- More interface text can be translated through Noctalia.
- Corrected the documented number of visible lines for each panel size.

## [0.8.12] — 2026-09-02

### Fixed

- Installation documentation now lists all three panel sizes.

## [0.8.11] — 2026-09-02

### Fixed

- Long lyric lines wrap within the panel instead of being cut off.
- The karaoke view adjusts to wrapped lines so the current lyric stays visible.

## [0.8.10] — 2026-09-02

### Changed

- Documented the required `busctl` and `curl` dependencies.
- Panel text can be translated through Noctalia Translate.
- Updated the plugin thumbnail.

## [0.8.9] — 2026-09-01

### Fixed

- The compact panel now applies the layout adjustments introduced in 0.8.8,
  keeping its playback controls visible.

## [0.8.8] — 2026-09-01

### Fixed

- Adjusted artwork, title space, and playback controls to fit each panel size.
- Removed duplicate placement settings for compact and large panels.

## [0.8.7] — 2026-09-01

### Added

- **Compact, medium, and large panels**, showing up to 10, 14, and 16 lyric
  lines respectively. Choose the size opened by the bar widget and
  control-center tile in plugin settings.

## [0.8.5] — 2026-09-01

### Added

- **Click a synced lyric line to seek** to that point in the song.
- **Keyboard lyric navigation:** Up/Down selects a line; Return or Space
  seeks to it when timing is available. Plain lyrics can also be browsed.

### Fixed

- Seeking lands at the selected timestamp instead of jumping by that amount.
- Seeking, shuffle, and repeat controls work correctly.
- Lyrics remain browsable before the first timed line.
- The bar widget displays its empty state correctly.

## [0.8.3] — 2026-09-01

### Changed

- Declared the `busctl` dependency and corrected the plugin description.
- Translations are managed through Noctalia Translate.
- Removed an unavailable roadmap link from the documentation.

## [0.8.1] — 2026-09-01

### Fixed

- The bar widget respects its configured text and icon colors.
- Middle-click play/pause works without an additional settings change.

## [0.8.0] — 2026-09-01

### Added

- Scrolling titles for long song and artist names.
- A playback progress bar between the track information and lyrics.
- English and Russian interface text.
- Screenshots and installation documentation.

### Changed

- The karaoke view shows 14 lyric lines instead of 11.
- Smoother lyric and title animations.
- Added more fallback options when the first lyric lookup finds nothing.
- The progress bar replaces the cover's progress ring.

### Fixed

- Overlapping letters and incorrectly wrapped lyric lines.
- Scrolling titles failing to start.
- Long titles and artist names becoming clipped or incorrectly centered.
