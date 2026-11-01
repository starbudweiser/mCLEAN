# mCLEAN — project context

Personal macOS menu bar app, a take on AppYogi's Memory Cleaner: live available memory, breakdown (app, wired, compressed, cache, free), pressure, swap, one-click clean, deep clean, automatic clean under a threshold, inactive apps (notification, Quit button).

## Architecture
- `Sources/MCleanCore`: logic without AppKit (Mach/sysctl probe, computations, cleaning limits, settings, auto/inactive rules, update parsing). Anything testable goes here.
- `Sources/mCLEAN`: AppKit + SwiftUI app (`LSUIElement`), Socle theme (`Socle.swift`, copied by `build.sh`). `AppModel` (state), `AppDelegate` (status item, panel), `PanelView`, `SettingsView`, `Notifier`, `About`, `UpdateManager`.
- Cleaning: allocates pages in 0.5 GB steps (`mmap`) to push the file cache out of RAM, releases them, stops as soon as pressure is not normal, swap/compression grows, a 2 GB reserve is reached or the time limit passes. "Deep" adds `purge` (password through osascript) and also aims at 25 % of app memory.
- Per-app footprint: `proc_pid_rusage` summed on the responsible process.
- Settings: JSON in UserDefaults (`AppSettings`, tolerant decoding).

## Automatic updates
`UpdateManager` reads the GitHub releases of starbudweiser/mCLEAN (unauthenticated; the user's `gh auth token` is only a fallback if the repository is not readable without it). One request a day, downloads `mCLEAN-X.Y.Z.zip`, checks bundle id, version, `codesign --verify` and that the signing requirement equals the running app's, then `InstallScript` replaces the bundle and relaunches (`open -g`). Setting `autoUpdate` (on by default); otherwise an Install button shows in the panel.

Release: bump the version in `Resources/Info.plist`, commit, run `./release.sh` (build, Developer ID signing, notarization, stapling, zip, push, GitHub release). Because updates must keep the same signing requirement, every published build is Developer ID signed; a locally signed build will not auto-update to one.

## Commands
- Tests: `swift test` (21 tests). App: `./build.sh` → `~/Applications/Applications Personnelles/mCLEAN.app` (signed through `sign_app.sh`).
- Real-world checks: `SELFTEST=1 ./build.sh`, then `build/mCLEAN.app/Contents/MacOS/mCLEAN --selftest status|clean|deep|update|login|render <dir>` (`deep` asks for the admin password; `render` writes PNGs of the panel, settings and About).
- Languages (fr, en, es, it): `tools/strings_table.py` → `python3 tools/gen_strings.py`. Icon: `assets/make_icon.py` (PyQt6, `QT_QPA_PLATFORM=offscreen`).
- Logo color (the "m" of the name): green #34D399 (`Brand`).

## Open points
- Deep clean (`purge`) not tested for real (needs the administrator password).
- Notifications and menu clicks not tested in the installed app.
