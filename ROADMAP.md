# DiskLens roadmap

DiskLens aims to be **one trustworthy utility instead of five apps**. It cleans, protects, creates and converts, and it always follows the same rules: on-device only, explain before acting, confirm before changing anything, undo wherever possible.

Have an idea or want something sooner? [Open an issue](https://github.com/mohitkale/disklens/issues/new/choose), or 👍 an existing one. The most-wanted items move up.

## Done

- **1.0**: full scan, Quick Scan / Quick Clean, Safe / Review first / Leave alone, dependency details for every item, the review sheet with safety checks, Explore with Spotlight search, History with trends, a universal app.
- **1.2**: **Media Studio**: events → video (title, zoom-and-pan, crossfades, music, free up space afterwards), collages, and converting and resizing photos and videos (formats, sizes, target file size, GIF).
- **1.1**: **Privacy Shield** (what files reveal: GPS location, device and serial numbers, names; places your files point to; lossless removal with originals in the Trash) and **Duplicates** (content-based, detects APFS clones, suggests the copy to keep).

## Next

### Clean
- [ ] **App uninstaller**: remove an app together with its leftover settings, caches and containers, showing each item's size and why it belongs to the app
- [ ] Scheduled reminders when free space runs low, and a menu-bar mini view
- [ ] A "what grew this month" report

### Protect
- [ ] **Finder Quick Action "Share without location"**: right-click → shares a stripped copy
- [ ] Office documents: remove author, company and editor names in place (reported only today)
- [ ] Sensitive screenshot finder: on-device text recognition flags card numbers, passwords, OTPs, IDs and QR codes
- [ ] A read-only list of background helpers, login items and browser extensions, with what each one is

### Media (shared with the iPhone app)
- [ ] Similar photos (not just identical), blurry photos and burst cleanup in folders and the Photos library
- [x] Converter and resizer, event videos and collages (1.2)
- [ ] Video trimming and reordering before building an event video
- [ ] Bundled royalty-free music tracks
- [ ] Batch photo enhancement (exposure, colour, noise), with a before/after slider

### Distribution
- [ ] Notarized releases (no first-launch warning)
- [ ] Homebrew cask

## Sibling apps (separate repos)

| Platform | What it is |
|---|---|
| **iPhone** | Photo, video and privacy utility: duplicates and clutter cleanup, Privacy Audit and Safe Share, event videos, converter, enhancement. iOS doesn't let apps scan the phone's storage, so it works with your photo library and the files you pick. |
| **Android** | The iPhone app's sibling, plus shared-storage file cleanup (Downloads, APKs, chat media) and a per-app storage view. |
| **Windows** | A full disk cleaner like DiskLens: temp and update caches, browsers, developer tools, WSL/Docker disks, Recycle Bin only, Restart Manager checks before acting. |

## Never

RAM "boosters", "battery doctors", registry cleaners, fake antivirus scans, accounts, ads, telemetry or anything that sends your data anywhere.
