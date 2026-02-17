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