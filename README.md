# RC-to-PS

Automated RealityScan → Postshot pipeline for 3D Gaussian Splatting.

One PowerShell script that:

1. Runs **RealityScan** headlessly via CLI: imports an image folder, detects AprilTag (36h11) markers, aligns cameras, and exports camera registration + a sparse point cloud.
2. Centers the scene on the best-observed AprilTag (by ray triangulation), or uses Ground Control Points if provided.
3. Runs **Postshot** via `postshot-cli`: trains a Gaussian splat (Splat MCMC profile) using the imported camera poses and point cloud — no camera tracking or AprilTag work needed in Postshot.
4. Exports a `.psht` project + splat `.ply`, and opens the result in the Postshot GUI.

## Prerequisites

- Windows, PowerShell 5.1+
- NVIDIA GPU (required by Postshot for training)
- [RealityScan 2.2](https://www.realityscan.com/) — expected at
  `C:\Program Files\Epic Games\RealityScan_2.2\RealityScan.exe`
- [Postshot](https://www.jawset.com/) with CLI (`postshot-cli.exe`) — expected at
  `C:\Program Files\Jawset Postshot\bin\` (CLI training requires a Postshot Pro license)

If your install paths differ, edit the three paths at the top of `rc_to_postshot.ps1`.

## Folder layout

```
ParentFolder\
    <images-subfolder>\     <- your capture images (JPG etc.)
    gcps.csv                <- optional, see below
    ImportGcpParams.xml     <- optional, see below
```

The capture should include an AprilTag 36h11 scale bar / tags visible in multiple images.

## Usage

Full run (all images, full training):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\rc_to_postshot.ps1 `
    -ParentFolder "C:\path\to\ParentFolder" `
    -ImagesFolder "C:\path\to\ParentFolder\MyCapture"
```

Quick smoke test (copies 8 images into a `*_smoketest` folder, short training — use this first to validate your setup):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\rc_to_postshot.ps1 `
    -ParentFolder "C:\path\to\ParentFolder" `
    -ImagesFolder "C:\path\to\ParentFolder\MyCapture" `
    -SmokeTest
```

`-ImagesFolder` is optional — if omitted, the script uses the first subfolder inside `-ParentFolder`.

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-ParentFolder` | (required) | Folder containing the images subfolder; settings XMLs and full-run outputs go here |
| `-ImagesFolder` | auto-detect | Path to the images folder directly |
| `-SmokeTest` | off | Fast test run on a small image subset |
| `-SmokeTestImageCount` | 8 | Images to copy in smoke-test mode |
| `-SmokeTestTrainSteps` | 2 | Training limit (kSteps) in smoke-test mode |
| `-SmokeTestMaxSplats` | 200 | Max splats (kSplats) in smoke-test mode |
| `-SmokeTestMaxImageSize` | 1600 | Image downscale limit in smoke-test mode |

## Outputs

Full run:

- `<images-subfolder>\registration.csv` — camera poses (tag-centered)
- `<images-subfolder>\sparse_point_cloud.ply` — sparse point cloud (tag-centered)
- `ParentFolder\tag_measurements.csv` — AprilTag image measurements
- `ParentFolder\<capture>.psht` — trained Postshot project (opened in GUI at the end)
- `ParentFolder\<capture>-splat.ply` — exported splat model

Smoke test: same files, but everything is written inside the `*_smoketest` folder.

## Scene centering

By default the scene is centered on the most-observed AprilTag via least-squares ray
triangulation (translation only). For full centering + orientation + scale from
measured tag coordinates, place these in the parent folder:

- `gcps.csv` — tag coordinates in meters, no header. **The script auto-generates this file if it doesn't exist** using the standard +90° orientation coordinates:

  ```
  36h11:00e,0,0,0
  36h11:00f,0,0.1,0
  36h11:011,0.15,0.1,0
  ```

  Edit this file if your tag layout differs.

- `ImportGcpParams.xml` — GCP import settings. Must be saved once from RealityScan's GUI:
  ALIGNMENT tab → Import → Ground Control Points → select `gcps.csv` → in the dialog choose
  format `Point X/Lon Y/Lat Z/Alt` and coordinate system `local:1 - Euclidean` → click the
  save-settings (down-arrow) icon → save to this file.

## Notes

- The script writes `DetectMarkersParams.xml`, `ExportRegParams.xml`, and `ExportPlyParams.xml`
  into the parent folder on every run (no manual setup needed).
- Postshot training uses the `Splat MCMC` profile.
- `postshot-cli` has no photometric compensation flag as of v1.1; enable it in the Postshot GUI
  if needed after opening the project.
