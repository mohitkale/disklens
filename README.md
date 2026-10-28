# DiskLens

A macOS app that shows what's filling your drive, explains what each item is for and what depends on it, and cleans up only when you confirm. Fully local: no network, no AI, no accounts.

- **Overview**: used-space ring, a color-coded storage bar per category, **Scan Now** / **Quick Clean** with the last scan's date and duration, stat tiles, and local **Insights** (free-space trend, biggest safe win, projects untouched for 6+ months, simulators last used months ago, apps you haven't opened, hidden space).
- **Clean Up**: findings grouped as **Safe**, **Review first** and **Leave alone**, each with a *What depends on this* panel (last used, used by, size, how to get it back, undo) and an item table (used by · last used · size · Show in Finder). Filter by group, tick cards (or **Select all** in the current group), then **Review Selected…**. Cleaning only happens when you press **Clean** in the review sheet.
- **Quick Clean**: a ~15-second scan of caches, logs and leftovers that no app depends on (nothing that needs a re-install command, nothing used today, nothing open). Always shows what it will do and waits for your confirmation.
- **Explore**: drill into any folder by size, filter by name, or search every subfolder with Spotlight. Show in Finder or copy the path.
- **First run**: a welcome screen recommends a full scan. Every full scan starts from scratch, and Quick Scan then looks where that scan found things. You're nudged when the full scan is over a week old. DiskLens never scans or cleans on its own.
- **History**: an interactive free/used line chart, free space per scan, a before/after table for any two scans, and a log of every cleanup.

### Works on any Mac
Nothing is tied to one machine. Projects (node_modules, Gradle pins) and files over 1 GB are found in a single pass over the whole home folder. Apps are located by bundle ID, wherever they're installed. The startup disk's own name is used. Rules cover the usual suspects on most Macs: Xcode and simulators, Docker, Homebrew, npm/yarn/pnpm/bun, Gradle, Cargo, Go, conda, Maven, NuGet, Dart, CocoaPods, VS Code-family editors, iPhone firmware and macOS installers, Mail downloads, iPhone backups, logs, unused apps and large files. Each appears only if it exists. The app is built as a universal binary (Apple Silicon and Intel).

## Safety model

- Nothing runs without the review sheet. It re-checks every item, explains what happens and what could go wrong, leaves blocked items out (e.g. "Quit Cursor first"), and needs an explicit "I understand" tick for anything that isn't reversible or is in *Review first*.
- Files are only ever **moved to the Trash** (`FileManager.trashItem`), never deleted. Space is freed when you empty the Trash yourself. DiskLens never empties it.
- Data owned by a tool is cleaned **through that tool**: `xcrun simctl` for simulators, `docker … prune` for Docker, `brew cleanup` for Homebrew.
- Just before acting, DiskLens re-checks that required apps are quit, that no process has the files open (one `lsof` listing, filtered per item), and that the path is inside your home folder and not a top-level folder, or is a single app bundle in Applications that isn't running or App Store-managed (`Executor.isSafeToTrash`).
- Dependency facts are local: Spotlight metadata (last opened, download source), app bundles (versions), project files (lockfiles, Gradle pins), and each tool's own output.
- Version-aware rules keep what your projects use: Android NDK and build-tools versions pinned in Gradle files or React Native's version catalog, the running cursor-agent, the installed editor version's cache, and npx packages that running tools use.
- Recently touched projects' `node_modules` aren't preselected. Downloads, archives, backups and tool caches with history are never preselected.

## Build and run

```bash
scripts/build-app.sh          # builds build/DiskLens.app, signed with your Apple Development identity
open build/DiskLens.app
```

To share it: zip `build/DiskLens.app`. It's signed with a development certificate, so on another Mac the first launch needs right-click → **Open** (or sign with a Developer ID and notarize for a warning-free install).

Optional: grant **Full Disk Access** (System Settings → Privacy & Security → Full Disk Access → add DiskLens) so it can measure the Trash, iPhone backups and Mail.

Command-line scan (read-only, saves nothing):

```bash
swift run DiskLens --scan            # human-readable
swift run DiskLens --scan --json     # machine-readable
swift run DiskLens --scan --quick    # what Quick Clean would find
```

## Tests

```bash
swift test                                   # unit tests
DISKLENS_LIVE_TEST=1 swift test --filter Live   # moves two throwaway folders to your Trash
```

`DISKLENS_SNAPSHOT_DIR=<dir> build/DiskLens.app/Contents/MacOS/DiskLens` renders each screen and both review sheets to PNGs (only read-only checks run; nothing is cleaned). Add `DISKLENS_DATA_DIR=<empty dir>` to see the first-run experience without touching your history.

## Layout

| Path | What |
|---|---|
| `Sources/DiskLensCore/Models.swift`, `Store.swift`, `Versions.swift` | Shared models, history store, version logic (platform-neutral, ready for an iOS companion) |
| `Sources/DiskLensCore/Mac/` | Scanner, disk measurement, executor (macOS only) |
| `Sources/DiskLensCore/Mac/Rules/` | One file per area: Xcode, caches, projects (node_modules, Android), apps (Docker, editors, Homebrew, Downloads, Trash) |
| `Sources/DiskLensApp/` | SwiftUI app |

History lives in `~/Library/Application Support/DiskLens/`.

## iPhone companion (later)

iOS doesn't let apps inspect the phone's storage, so an iPhone app would be a viewer for the Mac's scans. `DiskLensCore`'s models and `HistoryStore` already compile for iOS. The remaining work is syncing `snapshots.json` through iCloud (CloudKit) and adding an iOS target.
