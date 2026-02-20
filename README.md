<div align="center">

  <img src="assets/banner/latest_banner.png" alt="Hongeet Banner" width="100%" />

  # HONGEET - সংগীত 🎧

  **A lightweight music player with offline playback and optional third-party streaming.**<br>
  *Built with love for speed, control, and clean design.*

  <p>
    <a href="https://flutter.dev">
      <img src="https://skillicons.dev/icons?i=flutter,dart,kotlin,git" height="40" />
    </a>
  </p>

  [![GitHub Release](https://img.shields.io/github/v/release/greenbugx/Hongeet?style=for-the-badge&color=white)](https://github.com/greenbugx/Hongeet/releases)
  [![License](https://img.shields.io/github/license/greenbugx/Hongeet?style=for-the-badge&color=black)](LICENSE)<br>
  [![Downloads Sourceforge](https://img.shields.io/sourceforge/dt/hongeet?style=for-the-badge&color=white&label=Sourceforge%20Monthly%20Downloads)](https://sourceforge.net/projects/hongeet/)
  [![IzzyOnDroid Monthly Downloads](https://img.shields.io/badge/dynamic/json?url=https://dlstats.izzyondroid.org/iod-stats-collector/stats/basic/monthly/rolling.json&query=$.['com.dxku.hongit']&label=IzzyOnDroid%20monthly%20downloads&style=for-the-badge&color=black)](https://apt.izzysoft.de/packages/com.dxku.hongit)

  <br>

  <a href="https://sourceforge.net/projects/hongeet/files/latest/download">
      <img alt="Download Hongeet" src="https://a.fsdn.com/con/app/sf-download-button" width="300" srcset="https://a.fsdn.com/con/app/sf-download-button?button_size=2x 2x">
  </a>
  &nbsp;&nbsp;
  <a href="https://apt.izzysoft.de/packages/com.dxku.hongit">
    <img src="https://gitlab.com/IzzyOnDroid/repo/-/raw/master/assets/IzzyOnDroidButtonGreyBorder_nofont.png" height="53" alt="Get it at IzzyOnDroid">
  </a>

</div>

---

> [!IMPORTANT]
> **Active Development:** Hongeet is currently in active development. Expect bugs, crashes, or missing features.  
> If you encounter issues, please report them in the [Issues Tab](https://github.com/greenbugx/Hongeet/issues).

---

<h1 align=center> 📖 What is HONGEET? </h1>

**HONGEET** was built to solve a simple problem:<br> 
> *“Why is it so hard to just listen to music the way **I** want?”*

Most modern music apps lock downloads behind paywalls, track your data aggressively, or break completely when you go offline. **HONGEET does the opposite.**

Hongeet is a music player that supports **offline local audio playback** and **optional streaming from third-party services such as YouTube Music and JioSaavn** — giving you full control over how and where you listen.

### ✨ Key Highlights
| 🎶 Streaming | 📥 Downloads |
| :--- | :--- |
| • High-quality audio streaming from supported services<br>• Smart URL caching (fast repeats)<br>• Gapless playback & Queue management | • Download directly to device storage<br>• YT Extraction (via `youtube_explode_dart`)<br>• Fully offline playback |

| 🧠 Smart Playback | 🖤 UI / UX |
| :--- | :--- |
| • History & Recents<br>• Loop modes (Off / All / One)<br>• Background playback service | • Glassmorphism-inspired design<br>• Smooth animations<br>• Full-screen & Mini player support |

---

<h2 align=center> 📸 Screenshots </h2>

<div align="center">
  <table>
    <tr>
      <td><img src="assets/screenshots/01.jpg" width="220" /></td>
      <td><img src="assets/screenshots/02.jpg" width="220" /></td>
      <td><img src="assets/screenshots/03.jpg" width="220" /></td>
    </tr>
    <tr>
      <td><img src="assets/screenshots/04.jpg" width="220" /></td>
      <td><img src="assets/screenshots/05.jpg" width="220" /></td>
      <td><img src="assets/screenshots/06.jpg" width="220" /></td>
    </tr>
  </table>
</div>

---

## 🔐 Permissions

HONGEET asks for permissions strictly needed for playback, downloads, and local media access.

| Permission | Reason |
| :--- | :--- |
| `INTERNET` | For streaming audio, metadata fetching, and optional update checks. |
| `POST_NOTIFICATIONS` <br>*(Android 13+)* | For playback controls in notification/lock screen and download notifications. |
| `FOREGROUND_SERVICE`<br>`FOREGROUND_SERVICE_MEDIA_PLAYBACK`<br>`WAKE_LOCK` | To keep background playback stable while the app is minimized or the screen is locked. |
| `FOREGROUND_SERVICE_DATA_SYNC` | To support background data tasks such as download/stream sync operations. |
| `READ_MEDIA_AUDIO`<br>*(Android 13+)* | To read audio files from device storage (downloads/local tracks). |
| `READ_EXTERNAL_STORAGE`<br>*(Android 12 and below)* | Backward-compatible local audio access on older Android versions. |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | **Optional:** Used to open battery optimization settings on aggressive OEM devices. |
| `MANAGE_EXTERNAL_STORAGE`<br>*(Android 11+)* | **Optional:** Used only if the user opts in to manage local audio/downloaded songs directly from the app. |

> [!NOTE]
> HONGEET **does not** request contacts, location, microphone, or camera permissions.

---

## 🤝 Contributing

Contributions are welcome! Whether it's fixing bugs, improving the UI, or optimizing performance.

1.  **Fork** the repository.
2.  **Create** a feature branch.
3.  **Commit** clean, meaningful changes.
4.  **Open** a Pull Request.

_For detailed info, please check [CONTRIBUTING.md](CONTRIBUTING.md)_

---

## ❤️ Credits & Tech Stack

This project wouldn’t exist without these amazing open-source libraries:

* **youtube_explode_dart** — YouTube stream extraction in pure Dart  
* **JioSaavn API (Unofficial)** — metadata & streaming access from JioSaavn

---

> [!WARNING]
> **Disclaimer:** Hongeet is a personal project built for learning. It is not intended for commercial use. **Do not use this app to distribute copyrighted content.** If you are a rights holder and believe an issue exists, please open an issue immediately.

---

<div align="center">

  ## 📜 License
  *Licensed under GNU-AGPLv3.* [View License](LICENSE)

  <br>

  <a href="https://www.buymeacoffee.com/dxku" target="_blank">
    <img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" width="180" />
  </a>

  <br><br>

  *Now don't cry listening to sad songs :)*

</div>
