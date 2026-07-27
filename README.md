# ID Fit

A local macOS app for turning a folder of document scans into a clean, ordered PDF.

You scanned your passport and ended up with 20 files — some A4, some re-scanned pieces at a different size, resolution or DPI, maybe a multi-page PDF the scanner produced instead of separate files. ID Fit opens that folder, lets you put the pages in order and crop them, and exports a uniform PDF you can print or email.

**Your source files are never modified.** Everything you do lives in app state until you explicitly ask for it to be written out.

## What it does

- **Opens a folder** of scans — JPEG, PNG, TIFF, HEIC and PDF. Each page of a PDF becomes a separate page you can reorder and crop on its own.
- **Reorders pages** by dragging: the card follows the cursor and the others slide aside to open a gap.
- **Crops each page individually, with one aspect ratio shared by the whole document**, so the export comes out uniform even when the sources differ in size and DPI. Presets for A4, US Letter, ID card, passport photo and square, plus a custom ratio.
- **Rotates pages** in 90° steps.
- **Exports to PDF** — pages in your order, crops applied, at full resolution. PDF sources stay vector rather than being rasterized. Choose A4, US Letter, or a page that fits the content exactly.
- **Remembers everything in `.id-fit.json` inside the folder.** No absolute paths, nothing stored elsewhere: sync the folder to another computer, open it there, and the order and crops are exactly as you left them.

Two explicit, separate actions can touch files:

- **Export cropped files to a folder** — writes each page as its own file, numbered in page order, into a folder you pick (never the one you are editing).
- **Apply changes to original files** — rewrites the sources with their crops baked in. Confirmed by a dialog, and untouched copies are kept in `.id-fit-originals/` unless you opt out. Images are re-encoded in their original format; PDFs are cropped through their crop box, so they stay vector and lose no pages.

## Opening a folder

Besides **File → Open Folder…** and dropping a folder on the window:

- **From Finder** — right-click a folder and choose *Open With → ID Fit*, or *Services → Open Folder in ID Fit*.
- **From a terminal** — choose *ID Fit → Install Command Line Tool…* once, then `idfit ~/Scans` (or `idfit .`). The command works whether or not the app is already running, and points at the app by bundle identifier, so moving or updating the app does not break it.

## Requirements

macOS 15 or later.

## Building

Xcode is required. The Xcode project itself is generated, so there is nothing to open before the first build.

```sh
make build     # generate the project and build Debug
make run       # build and launch
make test      # run the unit tests
make package   # Release build, ad-hoc signed, into dist/
```
