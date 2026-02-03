# Contributing to Hongeet 🎵

Thank you for your interest in contributing to **Hongeet**!
This guide explains how to contribute responsibly and effectively.

---

## Project Overview

Hongeet is a Flutter-based music streaming app using an unofficial Saavn API and a local backend proxy.
The project focuses on clean UI, stable playback, and respectful API usage.

---

## Tech Stack

- Flutter (Dart)
- Provider (state management)
- Android (Kotlin)
- Local HTTP proxy
- Saavn unofficial API

---

## Ways to Contribute

- Bug fixes
- Performance improvements
- UI/UX enhancements
- Code refactoring
- Documentation improvements
- Testing

Please check existing issues and pull requests before starting.

---

## Project Setup

### Prerequisites
- Flutter SDK (stable)
- Android Studio or VS Code
- Android SDK

### Setup
```
git clone https://github.com/<your-username>/hongeet.git
cd hongeet
flutter pub get
flutter run
```

---

## Branching Strategy

- main → stable branch
- dev → development branch
- feature/<name> → new features
- fix/<name> → bug fixes

Do not commit directly to main.

---

## Commit Guidelines

Use clear, descriptive commit messages.

Examples:
- fix(player): resolve wrong audio playback
- feat(search): cache results to reduce API usage
- refactor(audio): simplify queue handling

---

## Pull Request Guidelines

Before submitting a PR:
- Ensure the app builds successfully
- Follow existing architecture
- Avoid unnecessary API calls
- Clearly explain what changed and why

Include screenshots for UI changes if applicable.

---

## Coding Standards

- Follow Dart and Flutter best practices
- Keep widgets small and reusable
- Avoid unnecessary rebuilds
- Use meaningful names

---

## API Usage Guidelines

Hongeet uses an unofficial Saavn API.

- Do not spam API endpoints
- Do not remove caching mechanisms
- Do not add aggressive prefetching
- Minimize duplicate requests
- Reuse resolved stream URLs

PRs that significantly increase API load may be rejected.

---

## Bug Reports

Include:
- App version
- Device and OS version
- Steps to reproduce
- Expected vs actual behavior
- Logs if available

---

## Feature Requests

Explain:
- The problem being solved
- Why it fits the project goals
- Optional implementation ideas

---

## Security Issues

Do not open public issues for security vulnerabilities.
Contact the maintainer privately.

---

## Final Notes

Hongeet is a passion project focused on quality and sustainability.
Thanks for contributing 🎶
