# RC-to-PS

Automated RealityScan → Postshot pipeline for 3D Gaussian Splatting.

One PowerShell script that:

1. Runs **RealityScan** headlessly via CLI: imports an image folder, imports AprilTag
   ground control points, detects AprilTag (36h11) markers, aligns cameras, selects the
   largest component, saves the project, and exports camera registration + a sparse
   point cloud — all georeferenced (origin, orientation, metric scale) to the tags.
2. Sanity-checks the alignment (percentage of images registered) before spending GPU time.
3. Runs **Postshot** via `postshot-cli`: imports the images folder (poses + point cloud
   included) and trains a Gaussian splat (Splat MCMC profile) — no camera tracking or
   AprilTag work needed in Postshot.
4. Exports a `.psht` project + splat `.ply`, and opens the result in the Postshot GUI.

## Prerequisites

- Windows, PowerShell 5.1+
- NVIDIA GPU (required by Postshot for training)
- [RealityScan 2.2](https://www.realityscan.com/) — expected at
  `C:\Program Files\Epic Games\RealityScan_2.2\RealityScan.exe`
- [Postshot](https://www.jawset.com/) with CLI (`postshot-cli.exe`) — expected at
  `C:\Program Files\Jawset Postshot\bin\` (the CLI is a **Postshot Studio**-plan feature)

If your install paths differ, pass `-RealityScanExe` / `-PostShotExe` / `-PostShotCli`.

## Folder layout

```
ParentFolder\
    <images-subfolder>\     <- your capture images (JPG etc.)
    gcps.csv                <- auto-copied from this repo if missing
    ImportGcpParams.xml     <- auto-copied from this repo if missing
```

The capture should include the AprilTag 36h11 scale bar visible in multiple images.

## Usage

Full run (all images, full training):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\rc_to_postshot.ps1 `
    -ParentFolder "C:\path\to\ParentFolder" `
    -ImagesFolder "C:\path\to\ParentFolder\MyCapture"
```

Quick smoke test (hardlinks a few images into a `*_smoketest` folder, short training —
use this first to validate your setup):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\rc_to_postshot.ps1 `
    -ParentFolder "C:\path\to\ParentFolder" `
    -ImagesFolder "C:\path\to\ParentFolder\MyCapture" `
    -SmokeTest
```

`-ImagesFolder` is optional — if omitted, the script uses the first subfolder inside
`-ParentFolder` (ignoring `*_smoketest` folders from earlier runs).

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-ParentFolder` | (required) | Folder containing the images subfolder; settings XMLs and outputs go here |
| `-ImagesFolder` | auto-detect | Path to the images folder directly |
| `-OverwriteGcps` | off | Overwrite `ParentFolder\gcps.csv` + `ImportGcpParams.xml` with the bundled templates |
| `-HeadlessRs` | off | Run RealityScan with `-headless` (no GUI) and online communication disabled |
| `-RsTimeoutMinutes` | 0 (no limit) | Kill RealityScan if it runs longer than this (guards against stuck dialogs) |
| `-MinRegisteredPct` | 80 | Abort before training if fewer % of images registered (0 = disable gate) |
| `-TrainSteps` | 0 (auto) | Full-run training limit in kSteps (Postshot auto-computes when 0) |
| `-MaxSplats` | 0 (Postshot default: 3000) | Full-run max splats in kSplats |
| `-MaxImageSize` | -1 (Postshot default: 3840) | Full-run image downscale limit in px (0 = no limit) |
| `-Gpu` | -1 (default GPU) | GPU index for Postshot training |
| `-SmokeTest` | off | Fast test run on a small image subset |
| `-SmokeTestImageCount` | 35 | Images to link in smoke-test mode |
| `-SmokeTestTrainSteps` | 2 | Training limit (kSteps) in smoke-test mode |
| `-SmokeTestMaxSplats` | 200 | Max splats (kSplats) in smoke-test mode |
| `-SmokeTestMaxImageSize` | 3200 | Image downscale limit in smoke-test mode |
| `-RealityScanExe` / `-PostShotExe` / `-PostShotCli` | standard install paths | Override tool locations |

## Outputs

- `<images-subfolder>\registration.csv` — camera poses (tag-referenced)
- `<images-subfolder>\sparse_point_cloud.ply` — sparse point cloud (tag-referenced)
- `ParentFolder\tag_measurements.csv` — AprilTag image measurements (QC artifact)
- `ParentFolder\<capture>.rsproj` — RealityScan project saved after alignment (open in
  the GUI to debug a bad run)
- `ParentFolder\rs_progress.log` — RealityScan progress feed (watch it to monitor long runs)
- `ParentFolder\rs_crash_reports\` — crash reports, if RealityScan ever crashes
- `ParentFolder\<capture>.psht` — trained Postshot project (opened in GUI at the end)
- `ParentFolder\<capture>-splat.ply` — exported splat model

Smoke test: same layout, with the capture name suffixed `_smoketest` (e.g.
`MyCapture_smoketest.psht`) and measurements in `tag_measurements_smoketest.csv`. Only
`registration.csv` + `sparse_point_cloud.ply` live in the images folder — Postshot
imports that folder as a single dataset and expects exactly one pose CSV and one point
cloud in it.

## Georeferencing

The scene is centered, oriented, and metrically scaled by RealityScan from AprilTag
ground control points:

- `gcps.csv` — tag coordinates in meters, no header. **If the parent folder doesn't
  have one, the script copies the bundled template (`gcps.csv` in this repo)**, which
  holds the Scan Space NZ 10×15 cm tag36h11 scale-bar coordinates at +90° orientation:

  ```
  "36h11:011" 0.15 0.1 0
  "36h11:00e" 0    0   0
  "36h11:00f" 0    0.1 0
  ```

  Since the same scale bar is used for every capture, this makes batch runs across many
  parent folders zero-setup. Pass `-OverwriteGcps` to refresh a folder that already has
  an older `gcps.csv`. Edit the repo template if your tag layout ever changes.

- `ImportGcpParams.xml` — GCP import settings (format `Point X/Lon Y/Lat Z/Alt`,
  coordinate system `local:1 - Euclidean`, 1 mm position accuracy). **Bundled in this
  repo and copied into the parent folder automatically** (also refreshed by
  `-OverwriteGcps`).

If both files are somehow missing the script warns and continues without GCPs — the
scene will then be unscaled and uncentered.

## Notes

- The script writes `DetectMarkersParams.xml`, `ExportRegParams.xml`, and
  `ExportPlyParams.xml` into the parent folder on every run (no manual setup needed).
- RealityScan alignment settings are pinned explicitly via `-set` commands (High feature
  detection quality, 80k max features/image, downscale factor 1, Brown3 distortion,
  camera priors off, 1 mm control-point accuracy, etc.), so runs don't depend on the
  app's current GUI defaults. See `$alignmentSettings` in the script to adjust.
- Robustness: the run sets `appQuitOnError=true` + `suppressErrors=true` (so failures
  actually stop the pipeline and surface as exit codes), `-silent` (no crash-report
  dialogs), `-selectMaximalComponent` (exports always come from the largest alignment
  component), and verifies exported files exist regardless of exit code.
- Postshot training uses the `Splat MCMC` profile, pinned explicitly (Postshot's
  default profile changed to `Splat3` in v1.1). Poses and points are recentered to the
  world origin by Postshot's default behavior — this is a translation only, and the
  original origin is preserved in the exported PLY metadata.
- `postshot-cli` has no photometric compensation flag as of v1.1; enable it in the
  Postshot GUI if needed after opening the project. Postshot's engine log is at
  `%LOCALAPPDATA%\Postshot\Postshot.log` if training fails.
