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