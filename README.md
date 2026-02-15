![HONGEET](assets/banner/latest_banner.png)

**<h1 align=center> HONGEET - সংগীত 🎧</h1>**

> A lightweight, high-quality music streaming & offline player — built with love for speed, control, and clean design.

<p align="center">
  <img src="https://skillicons.dev/icons?i=flutter,dart,kotlin,git" /><br>
  <img alt="GitHub Release" src="https://img.shields.io/github/v/release/greenbugx/Hongeet?display_name=release&style=for-the-badge&color=000000" />
  <img alt="GitHub License" src="https://img.shields.io/github/license/greenbugx/Hongeet?display_name=release&style=for-the-badge&color=ffffff" /> <br>
  <a href="https://sourceforge.net/projects/hongeet/files/latest/download"><img alt="Download Hongeet" src="https://a.fsdn.com/con/app/sf-download-button" width=276 height=48 srcset="https://a.fsdn.com/con/app/sf-download-button?button_size=2x 2x"></a>
</p>

---

_HONGEET is a **local-first music app** that lets you  
**stream** and **download** music with maximum control — no ads, no trackers, no nonsense._

Built for people who care about **audio quality**, **performance**, and **ownership**.


<h2 align=center> 📖 Whats HONGEET? </h2>

HONGEET was built to solve a simple problem:

> *“Why is it so hard to just listen to music the way **I** want?”*

Most music apps:
- lock downloads behind paywalls
- restrict quality
- track users aggressively
- break when you go offline

HONGEET does the opposite.

It runs a **local backend inside the app**, streams directly from the source, and lets **you** decide what happens to your music.

---

<h3 align=center> 📸 Screenshots </h3>

<p align="center">
  <img src="assets/screenshots/01.jpg" width="240" />
  <img src="assets/screenshots/02.jpg" width="240" />
  <img src="assets/screenshots/03.jpg" width="240" />
</p>
<p align="center">
  <img src="assets/screenshots/04.jpg" width="240" />
  <img src="assets/screenshots/05.jpg" width="240" />
  <img src="assets/screenshots/06.jpg" width="240" />
</p>
<p align="center">
  <img src="assets/screenshots/07.jpg" width="240" />
  <img src="assets/screenshots/08.jpg" width="240" />
</p>
<p align="center">
  <img src="assets/screenshots/09.jpg" width="240" />
  <img src="assets/screenshots/10.jpg" width="240" />
</p>

---

<h2 align="center">✨ Features</h2>

<div align="center">
  <h3>🎶 Streaming</h3>
  High-quality audio streaming<br>
  Smart URL caching (faster repeat plays)<br>
  Gapless playback with queue management
</div>

<br>

<div align="center">
  <h3>📥 Downloads</h3>
  Download songs directly to device storage<br>
  YouTube extraction powered by youtube_explode_dart<br>
  Offline playback from local files
</div>

<br>

<div align="center">
  <h3>🧠 Smart Playback</h3>
  Recently Played history<br>
  Loop modes (off / all / one)
</div>

<br>

<div align="center">
  <h3>🖤 UI / UX</h3>
  Glassmorphism-inspired design<br>
  Smooth animations<br>
  Full-screen player with blur background<br>
  Mini player support
</div>

<br>

<div align="center">
  <h3>🔐 Local-First</h3>
  No external backend servers<br>
  Everything runs on-device<br>
  Your music stays with you
</div>

<hr>

<h2 align="center">🔐 Permissions</h2>

HONGEET only asks for permissions needed for playback, downloads, and local media access:

- `INTERNET`  
  For streaming audio and fetching music metadata.

- `POST_NOTIFICATIONS` (Android 13+)  
  For playback controls in notification/lock screen and download notifications.

- `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, `WAKE_LOCK`  
  To keep background playback stable while the app is minimized or screen is locked.

- `FOREGROUND_SERVICE_DATA_SYNC`  
  To support background data tasks such as download/stream sync operations.

- `READ_MEDIA_AUDIO` (Android 13+)  
  To read audio files from device storage (downloads/local tracks).

- `READ_EXTERNAL_STORAGE` (Android 12 and below)  
  Backward-compatible local audio access on older Android versions.

- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`  
  Optional: used to open battery optimization settings on aggressive OEM devices.
  This is user-controlled and only requested to improve background playback reliability.

HONGEET does not request contacts, location, microphone, or camera permissions.

---

<h2 align=center> 🤝 Contributing </h2>

Contributions are welcome.

You can help by:

- Reporting bugs
- Improving UI/UX
- Optimizing performance
- Reviewing code

### How to contribute?

- Fork the repo
- Create a feature branch
- Commit clean, meaningful changes
- Open a Pull Request

_For detailed info about Contributing to this project, please check [CONTRIBUTING](CONTRIBUTING.md)_

---

<h2 align=center> ⚠️ Disclaimer </h2>

_HONGEET is a personal / educational project._

- It does not host or distribute copyrighted content
- All media is fetched directly from third-party sources
- Users are responsible for how they use the app
- This project is not affiliated with JioSaavn or YouTube

_If you are a rights holder and believe something is wrong, please open an issue._

---

<h2 align=center> 📜 License </h2>

_This project is licensed under the GNU-AGPLv3 or later. Check [LICENSE](LICENSE) for License info._

---

<h2 align=center> ❤️ Credits & Thanks </h2>

Huge respect and thanks to:

- [youtube_explode_dart](https://github.com/Hexer10/youtube_explode_dart) -> for YouTube stream extraction in pure Dart
- [Saavn API (Unofficial)](https://github.com/sumitkolhe/jiosaavn-api) -> for JioSaavn metadata & streaming access

This project wouldn’t exist without them.

---

_<h5 align=center> HONGEET started as an experiment. </h5>_

_<h4 align=center> It became a challenge. </h4>_

_<h2 align=center> Then it became an app. 🚀🎧 </h2>_
