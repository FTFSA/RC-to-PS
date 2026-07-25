# RC-to-PS

Automated RealityScan → Postshot pipeline for 3D Gaussian Splatting.

One PowerShell script that:

1. Runs **RealityScan** headlessly via CLI: imports an image folder, imports AprilTag
   ground control points, detects AprilTag (36h11) markers, aligns cameras, selects the
   largest component, saves the project, exports camera registration, and builds a
   **dense, vertex-colored init cloud** (preview-quality mesh → simplify → colorize →
   export vertices) — all georeferenced (origin, orientation, metric scale) to the tags.
2. Sanity-checks the run (registered-image percentage, tag coverage, init-cloud
   validity) before spending GPU time.
3. Runs **Postshot** via `postshot-cli`: imports the images folder (poses + point cloud
   included) and trains a Gaussian splat (Splat MCMC profile) with recentering disabled,
   so the tag-anchored coordinate frame survives into the splat.
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

The capture must include the AprilTag 36h11 scale bar, with **all three tags visible to
several cameras** (see Georeferencing below).

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
`-ParentFolder` (ignoring the pipeline's own `*_smoketest`, `*_align`, and
`rs_crash_reports` folders).

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-ParentFolder` | (required) | Folder containing the images subfolder; settings XMLs and outputs go here |
| `-ImagesFolder` | auto-detect | Path to the images folder directly |
| `-OverwriteGcps` | off | Overwrite `ParentFolder\gcps.csv` + `ImportGcpParams.xml` with the bundled templates |
| `-SparseInit` | off | Initialize Postshot from the sparse tie-point cloud instead of the dense cloud (A/B testing) |
| `-DenseTargetTris` | 4000000 | Simplify target (triangles) for the dense model; points ≈ half of this |
| `-DenseQuality` | Preview | Reconstruction quality for the dense cloud: Preview (CPU, fastest), Normal, High |
| `-MinTagMeasurements` | 2 | Min images a tag must appear in to become a control point (try 1 to rescue a tag seen once) |
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
- `<images-subfolder>\dense_point_cloud.ply` — dense init cloud (binary, vertex colors);
  with `-SparseInit`, `sparse_point_cloud.ply` sits here instead
- `ParentFolder\sparse_point_cloud.ply` — sparse tie points (QC + automatic fallback if
  the dense export ever fails; dense mode only)
- `ParentFolder\tag_measurements.csv` — AprilTag image measurements (QC artifact)
- `ParentFolder\<capture>_align.rsproj` (+ `<capture>_align\` data folder) — RealityScan
  project saved after alignment (open in the GUI to debug a bad run)
- `ParentFolder\rs_progress.log` — RealityScan progress feed (watch it to monitor long runs)
- `ParentFolder\rs_crash_reports\` — crash reports, if RealityScan ever crashes
- `ParentFolder\<capture>.psht` — trained Postshot project (opened in GUI at the end)
- `ParentFolder\<capture>-splat.ply` — exported splat model

Smoke test: same layout, with the capture name suffixed `_smoketest` (e.g.
`MyCapture_smoketest.psht`) and measurements in `tag_measurements_smoketest.csv`. The
images folder holds exactly one pose CSV and one point cloud — Postshot imports that
folder as a single dataset and requires it.

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

**All three tags must be measured in at least 2 images each.** With only two usable
tags, RealityScan can fix the origin and scale but the rotation around the axis through
those two tags is unconstrained — the tag plane can tilt away from Z = 0. The script
prints per-tag sighting counts after alignment and warns when coverage is short. If a
tag was seen in exactly one image, `-MinTagMeasurements 1` may rescue it; if it was seen
in none, reposition the scale bar and recapture.

If both files are somehow missing the script warns and continues without GCPs — the
scene will then be unscaled and uncentered.

## Doing it manually in the GUI

Every setting the script pins, for replicating the pipeline by hand in RealityScan and
Postshot. Values in parentheses are the script parameter that overrides them.

### RealityScan — Alignment settings

| Setting | Value |
|---|---|
| Feature detection quality | High |
| Max features per megapixel | 10 000 |
| Max features per image | 80 000 |
| Image overlap | Medium |
| Image downscale factor | 1 |
| Max feature reprojection error | 2.0 |
| Use camera priors for georeferencing | **No** |
| Control point image measurement accuracy [px] | 0.5 |
| Control point Position X / Y / Z accuracy | 0.001 m |
| Defined distance accuracy | 0.001 |
| Add reconstruction region after alignment | Yes |
| Force component rematch | No |
| Preselector features | 10 000 |
| Detector sensitivity | High |
| Merge georeferenced components | No |
| Distortion model | Brown3 |

### RealityScan — Detect Markers tool

| Setting | Value |
|---|---|
| Marker type | Square / AprilTag, family **tag36h11** |
| Minimal measurements per marker | 2 (`-MinTagMeasurements`) |

### RealityScan — Ground control points

Import `gcps.csv` (coordinates in the Georeferencing section above) with:

| Setting | Value |
|---|---|
| Point type | Ground Control Point (not tie point) |
| Coordinate system | `local:1 - Euclidean` |
| Position accuracy X / Y / Z | 0.001 m |
| CSV format | `"name" X Y Z`, space-separated, no header |

On the Coordinate System Change dialog choose **"Set to the Project"** (leave "Set
output coordinate system" ticked) — never "Convert Coordinates".

### RealityScan — run order

1. Add the images folder
2. Import ground control points (as above)
3. Detect Markers (AprilTag 36h11)
4. **Align Images** (not Update)
5. Select the **largest component**; confirm all cameras landed in one component and
   GCP residuals are ~1–2 mm in the alignment report
6. Save the project (debugging safety net)

### RealityScan — exports

Both exports must use the same coordinate system (`local:1 - Euclidean`), transform at
identity (Move/Rotate 0, Scale 1).

| Export | Settings |
|---|---|
| Registration | Save as type: **Internal/External camera parameters (.csv)** → `registration.csv` in the images folder |
| Sparse point cloud | PLY, Export ascii: **False**, Export vertex colors: **True** |

### RealityScan — dense init cloud (default pipeline)

1. Reconstruction in **Preview** quality (`-DenseQuality`; Normal/High for more detail)
2. Simplify: Absolute, target **4 000 000 triangles** (`-DenseTargetTris`) — vertices
   come out at roughly half the triangle count
3. Colorize (calculate vertex colors — models are born uncolored)
4. Export Model as **PLY, binary, vertex colors on, no normals/textures** →
   `dense_point_cloud.ply` in the images folder

> ⚠ RealityScan's model export writes **float** vertex colors, which Postshot silently
> reads as an *empty* point cloud. The script converts the file to `uchar` RGB
> automatically; if you export manually, convert it yourself (e.g. CloudCompare:
> open → save as binary PLY with 8-bit colors) or Postshot will train from nothing.
> Keep exactly **one** point cloud in the images folder.

### Postshot

Import the images folder as one drop (images + `registration.csv` + the one PLY).

| Setting | Value |
|---|---|
| Camera Poses | Import (skips Postshot's own tracking) |
| Image Selection | Use All Images |
| Profile | **Splat MCMC** |
| Recenter Poses & Points | **Unchecked** (keeps the tag-anchored frame; script passes `--no-recenter-points`) |
| Max Splats | 3000 kSplats = Postshot default (`-MaxSplats`; MCMC always fills the budget — 1000 ≈ 225 MB is plenty for a bust) |
| Training steps | auto (≈30 kSteps for 30 images; `-TrainSteps`) |
| Max image size | 3840 = Postshot default (`-MaxImageSize`; smoke test uses 3200) |

Then export the splat as PLY. Photometric compensation (GUI-only as of v1.1) can be
enabled before training if needed.

## Notes

- The script writes `DetectMarkersParams.xml`, `ExportRegParams.xml`, and
  `ExportPlyParams.xml` into the parent folder on every run (no manual setup needed).
  The dense model export deliberately runs without a params file — RealityScan's
  ModelExport params schema is undocumented and a wrong file makes the export silently
  no-op; the result is validated after the run instead.
- RealityScan alignment settings are pinned explicitly via `-set` commands (High feature
  detection quality, 80k max features/image, downscale factor 1, Brown3 distortion,
  camera priors off, 1 mm control-point accuracy, etc.), so runs don't depend on the
  app's current GUI defaults. See `$alignmentSettings` in the script to adjust.
- Robustness: the run sets `appQuitOnError=true` + `suppressErrors=true` (so failures
  actually stop the pipeline and surface as exit codes), `-silent` (no crash-report
  dialogs), `-selectMaximalComponent` (exports always come from the largest alignment
  component), and verifies exported files exist regardless of exit code.
- Dense init: sparse tie points starve 3DGS initialization (soft results), so by
  default the script meshes at Preview quality (CPU-based), simplifies to
  `-DenseTargetTris` triangles (~half that in points, targeting ~1–3M), colorizes, and
  exports the vertices as the init cloud. The exported PLY is validated (binary, RGB
  colors, faces stripped if present, coordinate frame cross-checked against the sparse
  cloud); on any problem the run falls back to the sparse cloud with a warning. Use
  `-SparseInit` to A/B the old behavior.
- Outputs are also checked for freshness (a file left over from an earlier run can
  never fake success), and the run fails fast at startup if a previous run's `.psht`
  is still open — and therefore locked — in a PostShot window.
- Postshot training uses the `Splat MCMC` profile, pinned explicitly (Postshot's
  default profile changed to `Splat3` in v1.1), with `--no-recenter-points` so the
  tag-anchored frame is preserved — tag `00e` at the origin, tag plane at Z = 0
  (RealityScan +Z-up maps to Postshot +Y-up on import).
- `postshot-cli` has no photometric compensation flag as of v1.1; enable it in the
  Postshot GUI if needed after opening the project. Postshot's engine log is at
  `%LOCALAPPDATA%\Postshot\Postshot.log` if training fails.
