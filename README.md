# ID Fit

A local macOS app for turning a folder of document scans into a clean, ordered PDF.

You scanned your passport and ended up with 20 files — some A4, some re-scanned pieces at a different size, resolution or DPI, maybe a multi-page PDF the scanner produced instead of separate files. ID Fit opens that folder, lets you put the pages in order and crop them, and exports a uniform PDF you can print or email.

**Your source files are never modified.** Everything you do lives in app state until you explicitly ask for it to be written out.

## What it does

- **Opens a folder** of scans — JPEG, PNG, TIFF, HEIC and PDF. Each page of a PDF becomes a separate page you can reorder and crop on its own.
- **Reorders pages** by dragging: the card follows the cursor and the others slide aside to open a gap.
- **Finds the document in each scan by itself** and proposes a crop, which you then nudge. Uses the Vision framework built into macOS, so nothing is sent anywhere and there is nothing to install. Suggestions that would cover almost the whole scan are discarded rather than shaving a sliver off a page that needed no cropping.
- **Crops each page individually, with one aspect ratio shared by the whole document**, so the export comes out uniform even when the sources differ in size and DPI. Presets for A4, US Letter, ID card, passport photo and square, plus a custom ratio — or just drag a rectangle on a page and its shape becomes the ratio for all of them.
- **Rotates pages** in 90° steps.
- **Exports to PDF** — pages in your order, crops applied, at full resolution. PDF sources stay vector rather than being rasterized. Choose A4, US Letter, or a page that fits the content exactly.
- **Remembers everything in a `.idfit` document inside the folder.** Double-click it to reopen the folder here. No absolute paths, nothing stored elsewhere: sync the folder to another computer, open it there, and the order and crops are exactly as you left them.

Two explicit, separate actions can touch files:

- **Export cropped files to a folder** — writes each page as its own file, numbered in page order, into a folder you pick (never the one you are editing).
- **Apply changes to original files** — rewrites the sources with their crops baked in. Confirmed by a dialog, and untouched copies are kept in `.id-fit-originals/` unless you opt out. Images are re-encoded in their original format; PDFs are cropped through their crop box, so they stay vector and lose no pages.

## Opening a folder

Besides **File → Open Folder…** and dropping a folder on the window:

- **From Finder** — right-click a folder and choose *Open With → ID Fit*, or *Services → Open Folder in ID Fit*.
- **From a terminal** — choose *ID Fit → Install Command Line Tool…* once, then `idfit ~/Scans` (or `idfit .`). The command works whether or not the app is already running, and points at the app by bundle identifier, so moving or updating the app does not break it.

## Requirements

macOS 15 or later.

## Installing

```sh
curl -fsSL https://raw.githubusercontent.com/joshuan/id-fit/main/install.sh | sh
```

This downloads the latest [release](https://github.com/joshuan/id-fit/releases), puts `IdFit.app` in `/Applications` and tells Finder about it, so *Open With* and the *Services* entry work right away. Pin a version with `IDFIT_VERSION=v1.2.3` in front of the command.

You can also download `IdFit.zip` from the releases page and drag the app into `/Applications` yourself. One extra step comes with it: builds are signed ad-hoc rather than notarized by Apple, and macOS refuses to open an app it got from a browser under those terms. Open **System Settings → Privacy & Security**, find the message about ID Fit and press **Open Anyway** — once per version. The script above is not a workaround for a security check so much as a different delivery route: macOS only applies that check to files a browser marked as downloaded.

## Building

Xcode is required. The Xcode project itself is generated, so there is nothing to open before the first build.

```sh
make build     # generate the project and build Debug
make run       # build and launch
make test      # run the unit tests
make package   # Release build, ad-hoc signed, into dist/
```

Tests run on every push and pull request.

## Releasing

Releases are made from GitHub, without touching a tag by hand:

1. Open **Releases → Draft a new release**.
2. Under **Choose a tag**, type the new version — `v1.2.3` — and pick *Create new tag on publish*.
3. Write down what changed and press **Publish release**.

Publishing starts the release workflow. It checks out that tag, runs the tests, builds and signs the app, attaches `IdFit.zip` to the release and appends install instructions to the notes you wrote. The whole thing takes a few minutes, during which the release is already visible but has nothing to download — so let it finish before pointing anyone at the page.

The tag is the only place a version number lives: `v1.2.3` ships as version 1.2.3, and nothing in the repository needs editing to bump it. The build number is the workflow run number.

Publishing is what releases, not tagging. A tag pushed on its own does nothing until a release is published from it, so a mistyped tag is harmless.

The same release can be published from the command line, which does everything the three steps above do — creates the tag, publishes the release, starts the workflow:

```sh
gh release create v1.2.3 --generate-notes
```

`--generate-notes` writes the notes — and the title — from the commits and pull requests since the previous release; replace it with `--notes "…"` to write your own, or drop both flags to be prompted for them. The new tag is created from the latest state of the default branch on GitHub, not from whatever is checked out locally; `--target <branch-or-sha>` points it somewhere else.

Re-running the workflow on an already published release is safe: the asset is replaced rather than duplicated, and notes that already carry install instructions are left alone.

The workflow signs with a Developer ID and notarizes when the repository has the secrets for it, and falls back to ad-hoc signing when it doesn't — see the comments in `.github/workflows/release.yml` for the secrets it looks for.
