# Contributing to DiskLens

Thanks for helping! DiskLens's promise is that it **never breaks anything**, so every change is held to that.

## Ground rules
- **Nothing is ever deleted directly.** Files move to the Trash (`FileManager.trashItem`); data owned by a tool is cleaned through that tool's own command (`xcrun simctl`, `docker … prune`, `brew cleanup`).
- **Nothing runs without the review sheet** and the user's confirmation.
- **Fully local.** No network calls, analytics or AI. Facts come from Spotlight, app bundles, project files and tool output.
- **Explain everything.** Each finding says what depends on it, when it was last used, how to get it back and whether it can be undone.

## Adding a cleanup rule
1. Add a type conforming to `CleanupRule` in `Sources/DiskLensCore/Mac/Rules/` and register it in `RuleCatalog.all`.
2. Choose the tier honestly: **Safe** (re-created automatically, no manual step), **Review first** (depends on how you work), **Leave alone** (explain only).
3. Skip anything that's in use (`DiskMeasure.openFiles(under:)`), and keep versions projects pin.
4. Fill in `facts` (last used, used by, get it back, undo) and `risk`.
5. Mark `quickClean: true` only if removal can't affect any app and needs no follow-up command.
6. Add tests for any decision logic (see `Tests/DiskLensCoreTests`).

## Developing
```bash
swift build && swift test
swift run DiskLens --scan          # read-only scan in the terminal
scripts/build-app.sh               # universal, signed DiskLens.app in build/
scripts/screenshots.sh             # regenerate README screenshots from sample data
```
Screenshots must come from `scripts/screenshots.sh` (sample data), never from a real Mac.
