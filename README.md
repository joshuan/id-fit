# ID Fit

An app for managing document scans. It works locally on a folder, shows its own UI, and saves all state to a `.id-fit.json` file — so it survives moving the folder around, even to another computer. The first version targets macOS only.

Main scenario:

- the user scanned their passport and now has 20 A4-format files in a folder (or another format); they may have re-scanned some parts separately, so some files may differ in size, resolution, or even DPI;
- they open this folder with the app;
- they sort the page order of the document;
- they export it to PDF (e.g. to print it or email it to someone);
- they can crop (each file individually, but with the same aspect ratio across all files, so the export comes out uniform);
- with a separate, explicit button they can apply the changes to the real files (e.g. if all files were cropped, the app crops the actual files) or export the modified files to a separate folder — BUT BY DEFAULT WE NEVER TOUCH THE SOURCE FILES;
- they close the app; the folder now contains `.id-fit.json`, which can sync to the cloud along with everything else, so that opening the same folder in our app on another computer restores everything done above (crop, sorting, etc.).
