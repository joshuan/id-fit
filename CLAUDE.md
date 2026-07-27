# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Language

Everything in this repository — code, comments, documentation, commit messages, UI text — is written in English only.

## Project status

Greenfield. The repository currently contains only `README.md` with the product vision — no code, no build system, no git repo yet. The tech stack has not been chosen; agree on it with the user before scaffolding anything.

## What ID Fit is

A local macOS application (macOS-only for now) for organizing scanned documents. The user points it at a folder full of scan files (e.g. 20 A4 scans of a passport, possibly with mixed page sizes, resolutions, and DPI), and the app provides a UI to:

- reorder pages of the document;
- crop each file individually, but with a single shared aspect ratio across all files so the export comes out uniform;
- export the result to PDF (for printing or emailing).

## Hard constraints (from README)

- **Source files are never modified by default.** Edits (crop, ordering, etc.) live only in app state. Actually touching the originals happens only via an explicit, separate user action — either "apply changes to real files" or "export modified files to a separate folder".
- **All state persists to `.id-fit.json` inside the working folder.** The folder plus this file must be fully portable: if the folder syncs through the cloud to another computer, opening it there in ID Fit must restore everything (order, crops, etc.). This implies no absolute paths and no state outside the folder.
