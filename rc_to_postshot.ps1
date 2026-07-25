# rc_to_postshot.ps1
# Usage: .\rc_to_postshot.ps1 -ParentFolder "C:\path\to\your\folder"
# Smoke test: .\rc_to_postshot.ps1 -ParentFolder "C:\path\to\your\folder" -ImagesFolder "C:\path\to\your\images" -SmokeTest
#
# Expects:  ParentFolder\
#               <images-subfolder>\   <-- any single subfolder containing your images
#
# Inputs auto-provisioned into the parent folder (bundled in the repo) so
# RealityScan can center/orient/scale the scene on the AprilTags:
#   gcps.csv                -- measured tag coordinates in meters, no header.
#                              Bundled tag36h11 scale-bar template:
#                                "36h11:011" 0.1500000000000000 0.1000000000000000 0.0000000000000000
#                                "36h11:00e" 0.0000000000000000 0.0000000000000000 0.0000000000000000
#                                "36h11:00f" 0.0000000000000000 0.1000000000000000 0.0000000000000000
#   ImportGcpParams.xml     -- GCP import settings (format 'Point X/Lon Y/Lat
#                              Z/Alt', coordinate system 'local:1 - Euclidean',
#                              1 mm position accuracy).
#
# Outputs (written into the images subfolder, which PostShot imports whole):
#   registration.csv        -- Internal/External camera parameters
#   sparse_point_cloud.ply  -- sparse point cloud (binary, vertex colors)
#
# Outputs (written into the parent folder):
#   tag_measurements[_smoketest].csv -- AprilTag image measurements (QC artifact)
#   <capture>.rsproj        -- RealityScan project saved after alignment (debugging)
#   rs_progress.log         -- RealityScan progress feed (liveness monitoring)
#   rs_crash_reports\       -- RealityScan crash reports, if any
#   <capture>.psht          -- trained PostShot project (opened in GUI at end)
#   <capture>-splat.ply     -- exported splat model

param(
    [Parameter(Mandatory = $true, HelpMessage = "Path to the folder that contains your images subfolder")]
    [string]$ParentFolder,

    [Parameter(Mandatory = $false, HelpMessage = "Optional: path to the images folder directly (skips auto-detect of the single subfolder)")]
    [string]$ImagesFolder,

    [Parameter(Mandatory = $false, HelpMessage = "Overwrite ParentFolder\gcps.csv with the bundled tag36h11 scale-bar coordinates before running.")]
    [switch]$OverwriteGcps,

    [Parameter(Mandatory = $false, HelpMessage = "Run RealityScan headless (no GUI) with online communication disabled.")]
    [switch]$HeadlessRs,

    [Parameter(Mandatory = $false, HelpMessage = "Kill RealityScan if it runs longer than this many minutes. 0 = wait indefinitely.")]
    [ValidateRange(0, 10080)]
    [int]$RsTimeoutMinutes = 0,

    [Parameter(Mandatory = $false, HelpMessage = "Abort before training when fewer than this percentage of images registered. 0 = disable the gate.")]
    [ValidateRange(0, 100)]
    [int]$MinRegisteredPct = 80,

    [Parameter(Mandatory = $false, HelpMessage = "PostShot training step limit in kSteps for full runs. 0 = let PostShot auto-compute.")]
    [ValidateRange(0, 100000)]
    [int]$TrainSteps = 0,

    [Parameter(Mandatory = $false, HelpMessage = "PostShot max splats in kSplats for full runs. 0 = PostShot default (3000).")]
    [ValidateRange(0, 100000)]
    [int]$MaxSplats = 0,

    [Parameter(Mandatory = $false, HelpMessage = "PostShot max image size (longer edge, px) for full runs. -1 = PostShot default (3840), 0 = no limit.")]
    [ValidateRange(-1, 20000)]
    [int]$MaxImageSize = -1,

    [Parameter(Mandatory = $false, HelpMessage = "GPU index for PostShot training. -1 = PostShot default.")]
    [ValidateRange(-1, 255)]
    [int]$Gpu = -1,

    [Parameter(Mandatory = $false, HelpMessage = "Enable a fast smoke-test run (links a subset of images into a *_smoketest folder).")]
    [switch]$SmokeTest,

    [Parameter(Mandatory = $false, HelpMessage = "How many images to use for smoke-test mode.")]
    [ValidateRange(1, 1000)]
    [int]$SmokeTestImageCount = 35,

    [Parameter(Mandatory = $false, HelpMessage = "PostShot training step limit (kSteps) for smoke-test mode.")]
    [ValidateRange(1, 1000)]
    [int]$SmokeTestTrainSteps = 2,

    [Parameter(Mandatory = $false, HelpMessage = "PostShot max splats (kSplats) for smoke-test mode.")]
    [ValidateRange(1, 10000)]
    [int]$SmokeTestMaxSplats = 200,

    [Parameter(Mandatory = $false, HelpMessage = "PostShot max image size for smoke-test mode.")]
    [ValidateRange(0, 20000)]
    [int]$SmokeTestMaxImageSize = 3200,

    [Parameter(Mandatory = $false, HelpMessage = "Path to RealityScan.exe")]
    [string]$RealityScanExe = "C:\Program Files\Epic Games\RealityScan_2.2\RealityScan.exe",

    [Parameter(Mandatory = $false, HelpMessage = "Path to postshot.exe (GUI)")]
    [string]$PostShotExe = "C:\Program Files\Jawset Postshot\bin\postshot.exe",

    [Parameter(Mandatory = $false, HelpMessage = "Path to postshot-cli.exe (CLI training requires the PostShot Studio plan)")]
    [string]$PostShotCli = "C:\Program Files\Jawset Postshot\bin\postshot-cli.exe"
)

Set-StrictMode -Version Latest

$SupportedImageExts = @(".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp", ".exr")

function Assert-Path([string]$path, [string]$label) {
    if (-not (Test-Path $path)) {
        Write-Error "$label not found: $path"
        exit 1
    }
}

# -- Validate inputs ---------------------------------------------------
Assert-Path $ParentFolder    "Parent folder"
Assert-Path $RealityScanExe  "RealityScan executable"
Assert-Path $PostShotExe     "PostShot executable"
Assert-Path $PostShotCli     "PostShot CLI executable"

# Determine the images folder: explicit override, or auto-detect the subfolder
if ($ImagesFolder) {
    Assert-Path $ImagesFolder "Images folder (override)"
    $ImagesFolder = (Resolve-Path $ImagesFolder).Path
} else {
    # Ignore *_smoketest folders left behind by earlier smoke runs
    $subfolders = @(Get-ChildItem -Path $ParentFolder -Directory | Where-Object { $_.Name -notlike "*_smoketest" })

    if ($subfolders.Count -eq 0) {
        Write-Error "No subfolders found inside: $ParentFolder"
        exit 1
    }

    if ($subfolders.Count -gt 1) {
        Write-Warning "$($subfolders.Count) subfolders found - using the first: $($subfolders[0].Name). Use -ImagesFolder to pick a specific one."
    }

    $ImagesFolder = $subfolders[0].FullName
}
Write-Host "Images folder : $ImagesFolder"

# -- Optional smoke-test subset -----------------------------------------
if ($SmokeTest) {
    $sourceFolder = $ImagesFolder
    $allImages = @(Get-ChildItem -Path $sourceFolder -File | Where-Object { $SupportedImageExts -contains $_.Extension.ToLowerInvariant() } | Sort-Object Name)
    if ($allImages.Count -eq 0) {
        Write-Error "Smoke test mode found no supported image files in: $sourceFolder"
        exit 1
    }

    $useCount = [Math]::Min($SmokeTestImageCount, $allImages.Count)
    if ($useCount -lt $SmokeTestImageCount) {
        Write-Warning "Requested $SmokeTestImageCount images for smoke test, but only $($allImages.Count) are available. Using $useCount."
    }

    $smokeFolder = Join-Path (Split-Path $sourceFolder -Parent) ((Split-Path $sourceFolder -Leaf) + "_smoketest")
    if (Test-Path $smokeFolder) {
        Remove-Item -Path $smokeFolder -Recurse -Force
    }
    [void](New-Item -ItemType Directory -Path $smokeFolder)

    # Hardlink instead of copy (same volume, instant, no extra disk); fall back
    # to a real copy if linking fails (e.g. unsupported filesystem).
    foreach ($img in ($allImages | Select-Object -First $useCount)) {
        $dest = Join-Path $smokeFolder $img.Name
        try {
            [void](New-Item -ItemType HardLink -Path $dest -Target $img.FullName -ErrorAction Stop)
        } catch {
            Copy-Item -Path $img.FullName -Destination $dest
        }
    }
    $ImagesFolder = $smokeFolder
    Write-Host "Smoke test mode enabled."
    Write-Host "  Source folder : $sourceFolder"
    Write-Host "  Test folder   : $ImagesFolder"
    Write-Host "  Image count   : $useCount"
}

# -- Names and output paths ---------------------------------------------
# Only registration.csv + sparse_point_cloud.ply may live in the images folder:
# PostShot imports that folder as one dataset and allows exactly one pose CSV
# and one point cloud in it. Everything else goes to the parent folder.
$CaptureName         = Split-Path $ImagesFolder -Leaf
$RegistrationCSV     = Join-Path $ImagesFolder "registration.csv"
$SparsePointCloudPLY = Join-Path $ImagesFolder "sparse_point_cloud.ply"
$TagMeasurementsCSV  = if ($SmokeTest) { Join-Path $ParentFolder "tag_measurements_smoketest.csv" } else { Join-Path $ParentFolder "tag_measurements.csv" }
$RsProjFile          = Join-Path $ParentFolder ($CaptureName + ".rsproj")
$RsProgressLog       = Join-Path $ParentFolder "rs_progress.log"
$RsCrashDir          = Join-Path $ParentFolder "rs_crash_reports"
$ProjectFile         = Join-Path $ParentFolder ($CaptureName + ".psht")
$SplatFile           = Join-Path $ParentFolder ($CaptureName + "-splat.ply")

# -- Write settings files (kept in the parent folder) ------------------
# Marker detection: AprilTag 36h11
$DetectMarkersXml = Join-Path $ParentFolder "DetectMarkersParams.xml"
@"
<Configuration id="{2D5793BC-A65D-4318-A1B9-A05044608385}">
  <entry key="detectMarkersMarkerType" value="AprilTag36h11"/>
  <entry key="markerType" value="AprilTag36h11"/>
  <entry key="detectMarkersMinMeasurements" value="2"/>
  <entry key="minMarkerMeasurements" value="2"/>
</Configuration>
"@ | Set-Content -Path $DetectMarkersXml -Encoding ASCII

# Ground control point coordinates: Scan Space NZ tag36h11 scale bar at +90° orientation.
# If gcps.csv doesn't exist, copy the bundled template from the repo. Use
# -OverwriteGcps to refresh an existing capture folder with the bundled template.
$GcpCsv = Join-Path $ParentFolder "gcps.csv"
$BundledGcpCsv = if ($PSScriptRoot) { Join-Path $PSScriptRoot "gcps.csv" } else { $null }
$ShouldWriteBundledGcps = (-not (Test-Path $GcpCsv)) -or $OverwriteGcps
if ($ShouldWriteBundledGcps) {
    if ($BundledGcpCsv -and (Test-Path $BundledGcpCsv)) {
        Copy-Item -Path $BundledGcpCsv -Destination $GcpCsv -Force
    } else {
        @'
"36h11:011" 0.1500000000000000 0.1000000000000000 0.0000000000000000
"36h11:00e" 0.0000000000000000 0.0000000000000000 0.0000000000000000
"36h11:00f" 0.0000000000000000 0.1000000000000000 0.0000000000000000
'@ | Set-Content -Path $GcpCsv -Encoding ASCII
    }
    if ($OverwriteGcps) {
        Write-Host "Overwrote gcps.csv with bundled tag36h11 scale-bar coordinates."
    } else {
        Write-Host "Generated gcps.csv with bundled tag36h11 scale-bar coordinates."
    }
} else {
    Write-Host "Using existing gcps.csv: $GcpCsv"
}

# Ground control point import settings: originally saved from RealityScan's GUI
# dialog (see header) and now bundled in the repo. Copy it into the parent
# folder if missing (or when -OverwriteGcps is used), same as gcps.csv.
$GcpParamsXml = Join-Path $ParentFolder "ImportGcpParams.xml"
$BundledGcpParamsXml = if ($PSScriptRoot) { Join-Path $PSScriptRoot "ImportGcpParams.xml" } else { $null }
if ($BundledGcpParamsXml -and (Test-Path $BundledGcpParamsXml)) {
    if ((-not (Test-Path $GcpParamsXml)) -or $OverwriteGcps) {
        Copy-Item -Path $BundledGcpParamsXml -Destination $GcpParamsXml -Force
        Write-Host "Copied bundled ImportGcpParams.xml into the parent folder."
    }
}

# Registration: "Internal/External Camera Parameters" CSV format
$RegParamsXml = Join-Path $ParentFolder "ExportRegParams.xml"
@"
<Configuration id="{2D5793BC-A65D-4318-A1B9-A05044608385}">
  <entry key="calexTrans" value="1"/>
  <entry key="calexHasDisabled" value="0x0"/>
  <entry key="MvsExportScaleZ" value="1.0"/>
  <entry key="MvsExportIsGeoreferenced" value="0x1"/>
  <entry key="MvsExportIsModelCoordinates" value="0"/>
  <entry key="MvsExportScaleY" value="1.0"/>
  <entry key="MvsExportScaleX" value="1.0"/>
  <entry key="MvsExportRotationY" value="0.0"/>
  <entry key="MvsExportcoordinatesystemtype" value="0"/>
  <entry key="MvsExportNormalFlipZ" value="false"/>
  <entry key="MvsExportRotationX" value="0.0"/>
  <entry key="hasCalexFilePath" value="1"/>
  <entry key="MvsExportNormalFlipY" value="false"/>
  <entry key="MvsExportNormalSpace" value="Mikktspace"/>
  <entry key="calexHasUndistort" value="-1"/>
  <entry key="MvsExportNormalFlipX" value="false"/>
  <entry key="MvsExportRotationZ" value="0.0"/>
  <entry key="calexFileFormat" value="Internal/External camera parameters"/>
  <entry key="MvsExportMoveZ" value="0.0"/>
  <entry key="calexFileFormatId" value="{0CA18733-1EBC-4254-9974-17197EB409BD}"/>
  <entry key="hasCalexFileName" value="1"/>
  <entry key="calexHasImageExport" value="-1"/>
  <entry key="MvsExportMoveX" value="0.0"/>
  <entry key="MvsExportNormalRange" value="ZeroToOne"/>
  <entry key="MvsExportMoveY" value="0.0"/>
</Configuration>
"@ | Set-Content -Path $RegParamsXml -Encoding ASCII

# Sparse point cloud: binary PLY with vertex colors (required by PostShot)
$PlyParamsXml = Join-Path $ParentFolder "ExportPlyParams.xml"
@"
<Configuration id="{2D5793BC-A65D-4318-A1B9-A05044608385}">
  <entry key="calexTrans" value="1"/>
  <entry key="bAscii" value="false"/>
  <entry key="calexHasDisabled" value="0x0"/>
  <entry key="bVertexColor" value="true"/>
  <entry key="MvsExportScaleZ" value="1.0"/>
  <entry key="MvsExportIsGeoreferenced" value="0x1"/>
  <entry key="MvsExportIsModelCoordinates" value="0"/>
  <entry key="MvsExportScaleY" value="1.0"/>
  <entry key="MvsExportScaleX" value="1.0"/>
  <entry key="MvsExportRotationY" value="0.0"/>
  <entry key="MvsExportcoordinatesystemtype" value="0"/>
  <entry key="MvsExportNormalFlipZ" value="false"/>
  <entry key="MvsExportRotationX" value="0.0"/>
  <entry key="hasCalexFilePath" value="1"/>
  <entry key="MvsExportNormalFlipY" value="false"/>
  <entry key="MvsExportNormalSpace" value="Mikktspace"/>
  <entry key="calexHasUndistort" value="-1"/>
  <entry key="MvsExportNormalFlipX" value="false"/>
  <entry key="MvsExportRotationZ" value="0.0"/>
  <entry key="calexFileFormat" value="Sparse point cloud as Polygon File Format (*.ply)"/>
  <entry key="MvsExportMoveZ" value="0.0"/>
  <entry key="calexFileFormatId" value="{B63136B7-2E64-4D08-B5B1-A945F1AED679}"/>
  <entry key="hasCalexFileName" value="1"/>
  <entry key="calexHasImageExport" value="-1"/>
  <entry key="MvsExportMoveX" value="0.0"/>
  <entry key="MvsExportNormalRange" value="ZeroToOne"/>
  <entry key="MvsExportMoveY" value="0.0"/>
</Configuration>
"@ | Set-Content -Path $PlyParamsXml -Encoding ASCII

# -- Run RealityScan via CLI -------------------------------------------
Write-Host "`nLaunching RealityScan (align + export)..."

[void](New-Item -ItemType Directory -Force -Path $RsCrashDir)
if (Test-Path $RsProgressLog) { Remove-Item -Path $RsProgressLog -Force }

# Note: Start-Process does not quote arguments itself, so wrap every path in
# explicit quotes to support folders with spaces (e.g. "Chris Berry").
$rcArgs = @()
if ($HeadlessRs) {
    $rcArgs += @("-headless", "-disableOnlineCommunication")
}
$rcArgs += @(
    # Suppress warning dialogs and crash-report uploads (reports are written to
    # the folder instead), and stream progress to a file for liveness checks.
    "-silent",        "`"$RsCrashDir`""
    "-writeProgress", "`"$RsProgressLog`""
    "-newScene"
    # Without appQuitOnError, RealityScan continues past failed commands and
    # can exit 0 despite errors; with it, the exit code is the real error code.
    "-set", "`"appQuitOnError=true`""
    "-set", "`"suppressErrors=true`""
)

# Alignment settings (per realityscan-postshot-settings reference doc). Pinned
# explicitly so runs don't depend on whatever the app's current defaults are.
$alignmentSettings = @(
    "sfmFeatureDetectionQuality=High"
    "sfmMaxFeaturesPerMpx=10000"
    "sfmMaxFeaturesPerImage=80000"
    "sfmImagesOverlap=Medium"
    "sfmImageDownscaleFactor=1"
    "sfmMaxFeatureReprojectionError=2.0"
    # Camera priors: off (static rig; GCPs handle georeferencing)
    "sfmEnableCameraPrior=false"
    # Control point priors: tag centers detect very precisely
    "sfmControPointImageMeasAccuracy=0.5"
    "sfmControlPointXAccuracy=0.001"
    "sfmControlPointYAccuracy=0.001"
    "sfmControlPointZAccuracy=0.001"
    "sfmDefinedDistanceAccuracy=0.001"
    # Advanced
    "sfmAutoReconRegionAfterAlignment=true"
    "sfmForceComponentRematch=false"
    "sfmPreselectorFeatures=10000"
    "sfmDetectorSensitivity=High"
    "sfmMergeGeoreferencedComponents=false"
    "sfmDistortionModel=Brown3"
)
foreach ($s in $alignmentSettings) {
    $rcArgs += @("-set", "`"$s`"")
}

$rcArgs += @(
    "-addFolder",              "`"$ImagesFolder`""
)

# Ground control points: center/orient/scale the scene on the AprilTags.
# Requires at least 3 tags with measured coordinates in gcps.csv.
if ((Test-Path $GcpCsv) -and (Test-Path $GcpParamsXml)) {
    Write-Host "Using ground control points: $GcpCsv"
    $rcArgs += @("-importGroundControlPoints", "`"$GcpCsv`"", "`"$GcpParamsXml`"")
} else {
    Write-Warning "gcps.csv or ImportGcpParams.xml missing - skipping GCP import; the scene will be UNSCALED and UNCENTERED. Restore the bundled repo files to georeference."
}

$rcArgs += @(
    "-detectMarkers",          "`"$DetectMarkersXml`""
    "-align"
    # Exports operate on the *selected* component; make sure that's the largest
    # one in case alignment split the images into multiple components.
    "-selectMaximalComponent"
    # Keep the aligned project around so failed or odd runs can be opened in
    # the GUI for post-mortems.
    "-save",                   "`"$RsProjFile`""
    "-exportControlPointsMeasurements", "`"$TagMeasurementsCSV`""
    "-exportRegistration",     "`"$RegistrationCSV`"",     "`"$RegParamsXml`""
    "-exportSparsePointCloud", "`"$SparsePointCloudPLY`"", "`"$PlyParamsXml`""
    "-quit"
)

Write-Host "Command: $RealityScanExe $rcArgs`n"

# Run and wait for RealityScan to finish before continuing
$rcProc = Start-Process -FilePath $RealityScanExe -ArgumentList $rcArgs -PassThru
$null = $rcProc.Handle  # cache the handle so .ExitCode is readable after exit
if ($RsTimeoutMinutes -gt 0) {
    if (-not $rcProc.WaitForExit($RsTimeoutMinutes * 60000)) {
        $rcProc.Kill()
        Write-Error "RealityScan did not finish within $RsTimeoutMinutes minutes - killed. Check $RsProgressLog for the last activity."
        exit 1
    }
} else {
    $rcProc.WaitForExit()
}
$rcExit = $rcProc.ExitCode

if ($rcExit -ne 0) {
    Write-Error "RealityScan exited with code $rcExit - check $RsProgressLog and $RsCrashDir, or open $RsProjFile in the GUI."
    exit $rcExit
}

# Verify the outputs actually exist (exit codes are best-effort even with appQuitOnError)
Assert-Path $RegistrationCSV     "Registration CSV (export may have failed)"
Assert-Path $SparsePointCloudPLY "Sparse point cloud PLY (export may have failed)"

Write-Host "`nRealityScan finished successfully."
Write-Host "  Registration CSV  : $RegistrationCSV"
Write-Host "  Sparse point cloud: $SparsePointCloudPLY"
Write-Host "  Project           : $RsProjFile"

# -- Alignment quality gate ----------------------------------------------
# Cheap sanity check before spending GPU time: how many of the input images
# actually ended up registered in the exported (maximal) component?
$imageCount      = @(Get-ChildItem -Path $ImagesFolder -File | Where-Object { $SupportedImageExts -contains $_.Extension.ToLowerInvariant() }).Count
$registeredCount = @(Get-Content $RegistrationCSV | Where-Object { $_ -and -not $_.StartsWith("#") }).Count
if ($imageCount -gt 0) {
    $registeredPct = [Math]::Round(100.0 * $registeredCount / $imageCount, 1)
    Write-Host "  Registered images : $registeredCount of $imageCount ($registeredPct%)"
    if ($MinRegisteredPct -gt 0 -and $registeredPct -lt $MinRegisteredPct) {
        Write-Error "Only $registeredPct% of images registered (threshold $MinRegisteredPct%) - aborting before training. Inspect $RsProjFile in RealityScan, or rerun with -MinRegisteredPct 0 to override."
        exit 1
    }
} else {
    Write-Warning "No supported image files counted in $ImagesFolder - skipping the registration gate."
}

# -- Train in PostShot via postshot-cli ----------------------------------
# PostShot imports the images folder as one dataset: images + registration.csv
# (poses) + sparse_point_cloud.ply (seed points). With imported poses it skips
# its own camera tracking and trains on RealityScan's coordinate frame, which
# already carries origin, orientation, and metric scale from the GCPs. Folder
# import also avoids the ~32k char Windows command-line limit that per-file
# arguments would hit on large captures.
$importFolder = $ImagesFolder.TrimEnd('\', '/')  # trailing backslash breaks postshot-cli paths

Write-Host "`nStarting PostShot training - this can take a while..."

# Profile pinned: PostShot's default changed to Splat3 in v1.1.
$psArgs = @("train", "-i", $importFolder, "--profile", "Splat MCMC")
if ($SmokeTest) {
    $psArgs += @("-s", $SmokeTestTrainSteps.ToString(), "--max-num-splats", $SmokeTestMaxSplats.ToString(), "--max-image-size", $SmokeTestMaxImageSize.ToString())
} else {
    if ($TrainSteps -gt 0)   { $psArgs += @("-s", $TrainSteps.ToString()) }
    if ($MaxSplats -gt 0)    { $psArgs += @("--max-num-splats", $MaxSplats.ToString()) }
    if ($MaxImageSize -ge 0) { $psArgs += @("--max-image-size", $MaxImageSize.ToString()) }
}
if ($Gpu -ge 0) { $psArgs += @("--gpu", $Gpu.ToString()) }
$psArgs += @("-o", $ProjectFile, "--export-splat", $SplatFile)

& $PostShotCli @psArgs
$psExit = $LASTEXITCODE

if ($psExit -ne 0) {
    Write-Error "postshot-cli exited with code $psExit - see $env:LOCALAPPDATA\Postshot\Postshot.log for details."
    exit $psExit
}

Assert-Path $ProjectFile "PostShot project (training may have failed)"
Assert-Path $SplatFile   "Splat export (training may have failed)"

Write-Host "`nTraining finished."
Write-Host "  Project : $ProjectFile"
Write-Host "  Splat   : $SplatFile"

# -- Open the trained project in the PostShot GUI ------------------------
Write-Host "`nOpening PostShot..."
Start-Process -FilePath $PostShotExe -ArgumentList "`"$ProjectFile`""
