# v1.7.0+18

## Material 3 Refresh + Artist Profiles + Search Reliability

### NEW FEATURES

- **Material 3 UI Refresh:** Migrated major screens/components to Material 3 with responsive spacing and layout behavior.
- **Dynamic Theme Colors:** Removed legacy glass mode and added seed-color based app theming.
- **Artist Profile Screen:** Added artist profile page with artist art, bio (more/less), monthly audience, Top Songs, Albums, and Singles & EPs.
- **Multi-Artist Picker:** Tapping artist name in full player now supports multi-artist tracks using a tap-only picker sheet.
- **Search Albums Section:** Search now shows a dedicated Albums section under song results with open-to-playlist flow.

### BUG FIXES / IMPROVEMENTS

- **Navigation + Mini-player:** Stabilized right-side quick switcher layout and floating mini-player spacing across screen sizes.
- **Album Filtering:** Limited search album results to album-only intent and reduced EP/Episode/podcast noise.
- **YouTube Search Resilience:** Added strategy fallback and persisted cache refresh behavior for more stable results under API/network variance.

### UPCOMING (work in progress)

- Better artist identity matching for edge-case names/collaborations
- Further recommendation relevance tuning and queue quality improvements

# v1.6.0+17

## Lyrics + Distribution Flavors + Android Widgets

### BUG FIXES / IMPROVEMENTS

- **Lyrics:** Added lyrics support (Synced & Unsynced).
- **Flavors Added:** Introduced `github` and `izzy` product flavors for distribution-specific behavior.
- **Manual Updates Kept:** "Check for updates" in Settings remains available for all flavors.
- **Android Widgets:** Added 2x2 and 4x2 home-screen music widgets with playback controls.
- **Widget Playback UX:** Added progress support and improved artwork handling for widgets.
- **Navigation Layout Fix:** Fixed bottom navigation size inconsistency in 3-button mode that caused mini-player overlap/mixing.
- **Release Pipeline:** Updated CI workflow to publish a separate Izzy arm64-only APK artifact alongside normal flavor outputs.

### UPCOMING (work in progress)

- Better relevance tuning for search and recommendations

# v1.5.1+16

## Queue Stability + Smooth Mode Performance Tuning

### BUG FIXES / IMPROVEMENTS

- **Dynamic Queue:** Reworked queue auto-extend behavior to keep "Up Next" filled more consistently during continuous playback
- **Duplicate Control:** Tightened duplicate/noisy title filtering for auto-fetched songs (better handling of low-signal uploads and title variants)
- **Memory Safety:** Added/strengthened stream subscription cleanup in player/background flow to avoid listener buildup
- **Playlist Dialog Stability:** Fixed controller/dispose race issues that could throw errors when creating playlists
- **Smooth Mode Perf:** Added smooth-mode-only optimizations for full player and search input path (reduced heavy rendering work and lighter image decode pressure)

### UPCOMING (work in progress)

- Better relevance tuning for search and recommendations
- Lyrics support(targeted for v1.6+)

# v1.5.0+15

## Sleep Timer + Search/Home Feed Upgrade

### BUG FIXES / IMPROVEMENTS

- **Sleep Timer:** Added sleep timer controls (15m, 30m, 60m, end of current song) with live status and timer state handling
- **Sleep Overlay:** Added full-screen sleep timer completion screen after timer stop
- **Home:** Added new feed shelves - Charts, Trending Albums, and Trending Songs
- **Charts/Albums:** Added dedicated open flow to list songs from a selected chart/album
- **Artwork Quality:** Improved thumbnail fallback logic for chart/album songs to prefer cleaner, higher-quality art
- **Performance:** Improved progressive song/art loading behavior and in-session caching for feed sections
- **Scroll Stability:** Fixed major vertical scroll jump issues in Search feed sections
- **UI Polish:** Improved mini-player/bottom-nav positioning across devices (including Samsung-safe layout cases)

### UPCOMING (work in progress)

- Expose sleep timer actions for local/downloaded tracks in full player controls
- More queue prefetch/retry hardening for weak network conditions
- Further low-end device transition/performance tuning

# v1.4.0+14

## Offline-First Local Audio Player + Streaming Overhaul

### BUG FIXES / IMPROVEMENTS

- **Streaming Toggles:** Removed XOR behaviour — both services can now be turned off or on independently. App defaults to a fully offline local audio player when both are off
- **Network Guard:** Every network call (trending, metadata, artwork, suggestions, update checks) is now wrapped in a streaming-enabled check — zero internet usage when both services are off
- **Update Checks:** Removed automatic update check on first launch. Updates are now checked only when you tap "Check for Updates" in Settings
- **Search:** Search bar now searches your local audio files when both streaming services are off
- **Local Audios:** Home screen now lists and plays local audio files from your device
- **Library Tab:** Disabled in local-only mode with a clear placeholder — available only when a streaming service is on

### UPCOMING (work in progress)

- More queue prefetch/retry hardening for weak network conditions
- Further low-end device transition/performance tuning
- Better relevance tuning for search and recommendations
- YTM Charts etc

# v1.3.3+13

## Backend Updates + UI Improvements

### BUG FIXES / IMPROVEMENTS

- **Downloads:** Backend now waits for the full file before returning, so "Download complete" and the saved file are in sync (no more incomplete files or late toasts)
- **Downloads:** Larger transfer buffer (256 KB) and throttled progress updates for faster, smoother downloads
- **Downloads:** Clearer toasts: "Downloading: …" on tap "Download complete" only when the file is fully written; "Download failed" when the backend returns an error
- **Updated UI:** Added Quick Access Section in Library

### UPCOMING (work in progress)

- More queue prefetch/retry hardening for weak network conditions
- Further low-end device transition/performance tuning
- Better relevance tuning for search and recommendations
- YTM Charts etc
