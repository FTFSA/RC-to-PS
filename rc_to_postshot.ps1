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
#   dense_point_cloud.ply   -- dense init cloud (binary, vertex colors); with
#                              -SparseInit, sparse_point_cloud.ply sits here instead
#
# Outputs (written into the parent folder):
#   sparse_point_cloud.ply  -- sparse tie points (QC + fallback; dense mode only)
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

    [Parameter(Mandatory = $false, HelpMessage = "Initialize PostShot from the sparse tie-point cloud (old behavior) instead of a dense reconstruction. Useful for A/B-testing init density.")]
    [switch]$SparseInit,

    [Parameter(Mandatory = $false, HelpMessage = "Simplify target (absolute triangle count) for the dense model; vertices ~ half of this. Default 4M triangles ~ 2M points.")]
    [ValidateRange(1000, 100000000)]
    [int]$DenseTargetTris = 4000000,

    [Parameter(Mandatory = $false, HelpMessage = "RealityScan reconstruction quality for the dense cloud. Preview is CPU-based and fastest.")]
    [ValidateSet("Preview", "Normal", "High")]
    [string]$DenseQuality = "Preview",

    [Parameter(Mandatory = $false, HelpMessage = "Minimum images a detected AprilTag must appear in to become a control point. Try 1 to rescue a tag seen only once.")]
    [ValidateRange(1, 100)]
    [int]$MinTagMeasurements = 2,

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

# Anything this run produces must be newer than this moment - guards against
# stale files from earlier runs masquerading as fresh outputs (postshot-cli has
# been seen returning exit 0 after aborting).
$RunStart = (Get-Date).AddSeconds(-5)

$SupportedImageExts = @(".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp", ".exr")

function Assert-Path([string]$path, [string]$label) {
    if (-not (Test-Path $path)) {
        Write-Error "$label not found: $path"
        exit 1
    }
}

function Assert-FreshOutput([string]$path, [string]$label) {
    # Like Assert-Path, but the file must also have been (re)written by THIS
    # run - stale outputs from earlier runs must not fake success.
    Assert-Path $path $label
    if ((Get-Item $path).LastWriteTime -lt $RunStart) {
        Write-Error "$label exists but was not updated by this run (stale leftover from a previous run): $path"
        exit 1
    }
}

function Assert-Writable([string]$path, [string]$label) {
    # Fails fast when an existing output file is locked (typically by a
    # PostShot window still showing a previous run's project).
    if (Test-Path $path) {
        try {
            $fs = [System.IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
            $fs.Close()
        } catch {
            Write-Error "$label is locked by another program (likely a PostShot window showing an earlier run) - close it and re-run: $path"
            exit 1
        }
    }
}

function Get-PlyInfo([string]$PlyPath) {
    # Parses a binary little-endian PLY header. Returns $null when the file is
    # missing or not a supported layout; otherwise a hashtable with the raw
    # Bytes, DataStart offset, vertex Count/Stride/PropTypes/PropNames, and
    # the names of any ExtraElements after the vertex block.
    if (-not (Test-Path $PlyPath)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($PlyPath)
    $headLen = [Math]::Min(8192, $bytes.Length)
    $head = [System.Text.Encoding]::ASCII.GetString($bytes, 0, $headLen)
    $ehIdx = $head.IndexOf("end_header")
    if ($ehIdx -lt 0) { return $null }
    $nlIdx = $head.IndexOf("`n", $ehIdx)
    if ($nlIdx -lt 0) { return $null }
    $headerText = $head.Substring(0, $ehIdx)
    if ($headerText -notmatch "format binary_little_endian") { return $null }

    $elements = @()
    $cur = $null
    foreach ($rawLine in ($headerText -split "`n")) {
        $ln = $rawLine.Trim()
        if ($ln -match '^element\s+(\S+)\s+(\d+)$') {
            $cur = @{ Name = $Matches[1]; Count = [long]$Matches[2]; PropTypes = @(); PropNames = @(); HasList = $false }
            $elements += ,$cur
        } elseif ($ln -match '^property\s+list\s+') {
            if ($null -ne $cur) { $cur.HasList = $true }
        } elseif ($ln -match '^property\s+(\S+)\s+(\S+)$') {
            if ($null -ne $cur) {
                $cur.PropTypes += ,$Matches[1]
                $cur.PropNames += ,$Matches[2]
            }
        }
    }
    if ($elements.Count -eq 0 -or $elements[0].Name -ne "vertex") { return $null }
    $v = $elements[0]
    if ($v.HasList) { return $null }
    $typeSize = @{ char = 1; uchar = 1; int8 = 1; uint8 = 1; short = 2; ushort = 2; int16 = 2; uint16 = 2;
                   int = 4; uint = 4; int32 = 4; uint32 = 4; float = 4; float32 = 4; double = 8; float64 = 8 }
    $stride = 0
    foreach ($t in $v.PropTypes) {
        if (-not $typeSize.ContainsKey($t)) { return $null }
        $stride += $typeSize[$t]
    }
    return @{
        Bytes = $bytes; DataStart = $nlIdx + 1
        Count = $v.Count; Stride = $stride
        PropTypes = $v.PropTypes; PropNames = $v.PropNames
        ExtraElements = @($elements | Select-Object -Skip 1 | ForEach-Object { $_.Name })
    }
}

# Fast vertex repacker (PowerShell loops are too slow for millions of points).
Add-Type -TypeDefinition @"
public static class RsPlyRepack
{
    public static byte[] Repack(byte[] src, int dataStart, int count, int stride,
                                int posOff, int colOff, bool floatColors, bool scale01, byte[] header)
    {
        byte[] dst = new byte[header.Length + count * 15];
        System.Buffer.BlockCopy(header, 0, dst, 0, header.Length);
        int o = header.Length;
        for (int i = 0; i < count; i++)
        {
            int s = dataStart + i * stride;
            System.Buffer.BlockCopy(src, s + posOff, dst, o, 12);
            if (floatColors)
            {
                for (int k = 0; k < 3; k++)
                {
                    float c = System.BitConverter.ToSingle(src, s + colOff + 4 * k);
                    if (scale01) c *= 255f;
                    if (c < 0f) c = 0f;
                    if (c > 255f) c = 255f;
                    dst[o + 12 + k] = (byte)(c + 0.5f);
                }
            }
            else
            {
                dst[o + 12] = src[s + colOff];
                dst[o + 13] = src[s + colOff + 1];
                dst[o + 14] = src[s + colOff + 2];
            }
            o += 15;
        }
        return dst;
    }
}
"@

function Test-AndFixDensePly([string]$PlyPath) {
    # Ensures $PlyPath is a point cloud in the exact layout PostShot's importer
    # accepts: binary little-endian, float x,y,z + uchar red,green,blue, no
    # faces. RealityScan's model export writes FLOAT colors (0..1) and a face
    # block - PostShot silently reads that as an EMPTY cloud - so anything
    # non-canonical is repacked in place. Returns $true when usable.
    $info = Get-PlyInfo $PlyPath
    if ($null -eq $info) { Write-Warning "Dense PLY missing or not a supported binary little-endian layout: $PlyPath"; return $false }
    if ($info.Count -lt 1000) { Write-Warning "Dense PLY has only $($info.Count) vertices."; return $false }

    # Locate x,y,z (three consecutive floats) and red,green,blue (consecutive,
    # all float or all uchar) among the vertex properties.
    $typeSize = @{ char = 1; uchar = 1; int8 = 1; uint8 = 1; short = 2; ushort = 2; int16 = 2; uint16 = 2;
                   int = 4; uint = 4; int32 = 4; uint32 = 4; float = 4; float32 = 4; double = 8; float64 = 8 }
    $offsets = @{}
    $off = 0
    for ($i = 0; $i -lt $info.PropNames.Count; $i++) {
        $offsets[$info.PropNames[$i]] = @{ Offset = $off; Type = $info.PropTypes[$i]; Index = $i }
        $off += $typeSize[$info.PropTypes[$i]]
    }
    foreach ($n in @("x", "y", "z", "red", "green", "blue")) {
        if (-not $offsets.ContainsKey($n)) { Write-Warning "Dense PLY is missing vertex property '$n' - PostShot needs colored points."; return $false }
    }
    $floatTypes = @("float", "float32")
    if (($offsets["x"].Type -notin $floatTypes) -or ($offsets["y"].Index -ne $offsets["x"].Index + 1) -or ($offsets["z"].Index -ne $offsets["x"].Index + 2)) {
        Write-Warning "Dense PLY has an unsupported position layout."; return $false
    }
    $colType = $offsets["red"].Type
    if (($offsets["green"].Index -ne $offsets["red"].Index + 1) -or ($offsets["blue"].Index -ne $offsets["red"].Index + 2) -or ($offsets["green"].Type -ne $colType) -or ($offsets["blue"].Type -ne $colType)) {
        Write-Warning "Dense PLY has an unsupported color layout."; return $false
    }
    $floatColors = $colType -in $floatTypes
    if (-not $floatColors -and $colType -notin @("uchar", "uint8")) {
        Write-Warning "Dense PLY has unsupported color type '$colType'."; return $false
    }

    $vertexBytes = [long]$info.Count * $info.Stride
    if ($info.DataStart + $vertexBytes -gt $info.Bytes.LongLength) { Write-Warning "Dense PLY truncated - vertex data shorter than header promises."; return $false }

    # Already canonical? (exactly x,y,z float + r,g,b uchar, nothing else)
    if (-not $floatColors -and $info.Stride -eq 15 -and $info.PropNames.Count -eq 6 -and $offsets["x"].Offset -eq 0 -and $offsets["red"].Offset -eq 12 -and $info.ExtraElements.Count -eq 0) {
        Write-Host "Dense cloud OK: $($info.Count) colored points."
        return $true
    }

    # Float colors: detect 0..1 vs 0..255 range from a sample
    $scale01 = $false
    if ($floatColors) {
        $maxC = 0.0
        $step = [Math]::Max(1, [Math]::Floor($info.Count / 2000))
        for ($i = 0; $i -lt $info.Count; $i += $step) {
            $vo = $info.DataStart + $i * $info.Stride + $offsets["red"].Offset
            for ($k = 0; $k -lt 3; $k++) {
                $c = [BitConverter]::ToSingle($info.Bytes, $vo + 4 * $k)
                if ($c -gt $maxC) { $maxC = $c }
            }
        }
        $scale01 = $maxC -le 1.001
    }

    Write-Host "Repacking dense PLY to PostShot's layout (float xyz + uchar rgb$(if ($info.ExtraElements.Count) { ", dropping " + ($info.ExtraElements -join ', ') }))..."
    $nl = "`n"
    $newHeader = "ply$nl" + "format binary_little_endian 1.0$nl" + "element vertex $($info.Count)$nl" +
        "property float x$nl" + "property float y$nl" + "property float z$nl" +
        "property uchar red$nl" + "property uchar green$nl" + "property uchar blue$nl" + "end_header$nl"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($newHeader)
    $out = [RsPlyRepack]::Repack($info.Bytes, [int]$info.DataStart, [int]$info.Count, [int]$info.Stride,
        [int]$offsets["x"].Offset, [int]$offsets["red"].Offset, $floatColors, $scale01, $hb)
    [System.IO.File]::WriteAllBytes($PlyPath, $out)
    Write-Host "Dense cloud OK after repack: $($info.Count) colored points."
    return $true
}

function Get-PlyBounds([string]$PlyPath) {
    # Samples up to ~100k vertices and returns @{Min=@(x,y,z); Max=@(x,y,z)},
    # or $null when the layout isn't float x,y,z-first.
    $info = Get-PlyInfo $PlyPath
    if ($null -eq $info -or $info.Count -lt 1) { return $null }
    if ($info.PropNames.Count -lt 3 -or
        $info.PropNames[0] -ne "x" -or $info.PropNames[1] -ne "y" -or $info.PropNames[2] -ne "z" -or
        ($info.PropTypes[0] -notin @("float", "float32"))) { return $null }
    $step = [Math]::Max(1, [Math]::Floor($info.Count / 100000))
    $mins = @([double]::MaxValue, [double]::MaxValue, [double]::MaxValue)
    $maxs = @([double]::MinValue, [double]::MinValue, [double]::MinValue)
    for ($i = 0; $i -lt $info.Count; $i += $step) {
        $off = $info.DataStart + $i * $info.Stride
        for ($k = 0; $k -lt 3; $k++) {
            $val = [BitConverter]::ToSingle($info.Bytes, $off + 4 * $k)
            if ($val -lt $mins[$k]) { $mins[$k] = $val }
            if ($val -gt $maxs[$k]) { $maxs[$k] = $val }
        }
    }
    return @{ Min = $mins; Max = $maxs }
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
    # Ignore folders this pipeline creates itself (smoke subsets, the RealityScan
    # project's sidecar data folder, crash reports)
    $subfolders = @(Get-ChildItem -Path $ParentFolder -Directory | Where-Object {
        $_.Name -notlike "*_smoketest" -and $_.Name -notlike "*_align" -and $_.Name -ne "rs_crash_reports"
    })

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
$DensePointCloudPLY  = Join-Path $ImagesFolder "dense_point_cloud.ply"
# Dense mode: the dense cloud is the one PLY in the images folder and the sparse
# cloud goes to the parent as a QC/fallback artifact. -SparseInit swaps that.
$SparsePointCloudPLY = if ($SparseInit) { Join-Path $ImagesFolder "sparse_point_cloud.ply" } else { Join-Path $ParentFolder "sparse_point_cloud.ply" }
$TagMeasurementsCSV  = if ($SmokeTest) { Join-Path $ParentFolder "tag_measurements_smoketest.csv" } else { Join-Path $ParentFolder "tag_measurements.csv" }
# NOTE: saving <name>.rsproj makes RealityScan create a sidecar data folder
# named <name>\ next to it - the "_align" suffix keeps that folder from
# colliding with the images folder (which must stay clean for PostShot).
$RsProjFile          = Join-Path $ParentFolder ($CaptureName + "_align.rsproj")
$RsProgressLog       = Join-Path $ParentFolder "rs_progress.log"
$RsCrashDir          = Join-Path $ParentFolder "rs_crash_reports"
$ProjectFile         = Join-Path $ParentFolder ($CaptureName + ".psht")
$SplatFile           = Join-Path $ParentFolder ($CaptureName + "-splat.ply")

# Fail fast if a previous run's outputs are still open in PostShot - training
# would otherwise abort hours later when it tries to write them.
Assert-Writable $ProjectFile "PostShot project output"
Assert-Writable $SplatFile   "Splat output"

# -- Write settings files (kept in the parent folder) ------------------
# Marker detection: AprilTag 36h11
$DetectMarkersXml = Join-Path $ParentFolder "DetectMarkersParams.xml"
@"
<Configuration id="{2D5793BC-A65D-4318-A1B9-A05044608385}">
  <entry key="detectMarkersMarkerType" value="AprilTag36h11"/>
  <entry key="markerType" value="AprilTag36h11"/>
  <entry key="detectMarkersMinMeasurements" value="$MinTagMeasurements"/>
  <entry key="minMarkerMeasurements" value="$MinTagMeasurements"/>
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

# Remove the other init cloud if a previous run left it in the images folder -
# PostShot's folder import allows exactly one point cloud in there.
$staleCloud = if ($SparseInit) { $DensePointCloudPLY } else { Join-Path $ImagesFolder "sparse_point_cloud.ply" }
if (Test-Path $staleCloud) {
    Remove-Item -Path $staleCloud -Force
    Write-Host "Removed stale $(Split-Path $staleCloud -Leaf) from the images folder."
}

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
)

if (-not $SparseInit) {
    # Dense init: mesh at the chosen quality, simplify to the triangle target
    # (vertex count ~ half of it), colorize (models are born uncolored), then
    # export the vertices as the dense cloud. Each command operates on the
    # last-created model, so no explicit selection is needed. The export runs
    # WITHOUT a params file (RealityScan's ModelExport params schema is
    # undocumented and a wrong file makes the export silently no-op) - the
    # format comes from the .ply extension and the result is validated below.
    $rcArgs += @(
        "-calculate${DenseQuality}Model"
        "-simplify",            $DenseTargetTris.ToString()
        "-calculateVertexColors"
        "-exportSelectedModel", "`"$DensePointCloudPLY`""
    )
}

$rcArgs += @("-quit")

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

# Verify the outputs exist AND were written by this run (exit codes are
# best-effort even with appQuitOnError, and stale files must not fake success)
Assert-FreshOutput $RegistrationCSV     "Registration CSV (export may have failed)"
Assert-FreshOutput $SparsePointCloudPLY "Sparse point cloud PLY (export may have failed)"

Write-Host "`nRealityScan finished successfully."
Write-Host "  Registration CSV  : $RegistrationCSV"
Write-Host "  Sparse point cloud: $SparsePointCloudPLY"
Write-Host "  Project           : $RsProjFile"

# -- Tag coverage check ---------------------------------------------------
# Full georeferencing (origin + orientation + scale) needs all 3 tags measured
# in at least 2 images each. With only 2 usable tags the rotation about their
# axis is unconstrained and the tag plane can tilt away from Z=0.
if (Test-Path $TagMeasurementsCSV) {
    $tagCounts = @{}
    foreach ($line in (Get-Content $TagMeasurementsCSV)) {
        $f = $line.Split(',')
        if ($f.Count -ge 4) {
            $t = $f[1].Trim()
            if ($tagCounts.ContainsKey($t)) { $tagCounts[$t]++ } else { $tagCounts[$t] = 1 }
        }
    }
    $summary = (@($tagCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" })) -join ", "
    if (-not $summary) { $summary = "none" }
    Write-Host "  Tag sightings     : $summary"
    $usableTags = @($tagCounts.GetEnumerator() | Where-Object { $_.Value -ge 2 }).Count
    if ($usableTags -lt 3) {
        Write-Warning "Only $usableTags of 3 GCP tags have measurements in 2+ images - scene orientation is under-constrained (the tag plane may tilt away from Z=0). Reposition the scale bar so all three tags are visible to several cameras, or try -MinTagMeasurements 1."
    }
} else {
    Write-Warning "No tag measurements were exported - the scene is likely not georeferenced."
}

# -- Dense cloud validation (dense mode only) ------------------------------
if (-not $SparseInit) {
    $denseOk = $false
    if ((Test-Path $DensePointCloudPLY) -and ((Get-Item $DensePointCloudPLY).LastWriteTime -ge $RunStart)) {
        $denseOk = Test-AndFixDensePly $DensePointCloudPLY
    } else {
        Write-Warning "Dense cloud missing or stale - RealityScan's model export produced nothing."
    }
    if ($denseOk) {
        # Frame sanity: the dense cloud must live in the same coordinate frame
        # as the sparse cloud (both come from the same aligned component). A
        # huge offset means the model export used a different coordinate
        # system - do not train on it.
        $db = Get-PlyBounds $DensePointCloudPLY
        $sb = Get-PlyBounds $SparsePointCloudPLY
        if ($null -ne $db -and $null -ne $sb) {
            $dc = @(0, 1, 2 | ForEach-Object { ($db.Min[$_] + $db.Max[$_]) / 2.0 })
            $sc = @(0, 1, 2 | ForEach-Object { ($sb.Min[$_] + $sb.Max[$_]) / 2.0 })
            $sparseDiag = [Math]::Sqrt((0, 1, 2 | ForEach-Object { [Math]::Pow($sb.Max[$_] - $sb.Min[$_], 2) } | Measure-Object -Sum).Sum)
            $centerDist = [Math]::Sqrt((0, 1, 2 | ForEach-Object { [Math]::Pow($dc[$_] - $sc[$_], 2) } | Measure-Object -Sum).Sum)
            $maxAbs = (@($db.Min; $db.Max) | ForEach-Object { [Math]::Abs($_) } | Measure-Object -Maximum).Maximum
            if ($maxAbs -gt 1e5 -or $centerDist -gt (20 * [Math]::Max($sparseDiag, 0.1))) {
                Write-Warning ("Dense cloud frame looks inconsistent with the sparse cloud (center offset {0:f2}, max coord {1:g3}) - not training on it." -f $centerDist, $maxAbs)
                $denseOk = $false
            } else {
                Write-Host ("  Dense/sparse frame check OK (center offset {0:f3} m)" -f $centerDist)
            }
        }
    }
    if (-not $denseOk) {
        Write-Warning "Falling back to the sparse point cloud for this run's training."
        if (Test-Path $DensePointCloudPLY) { Remove-Item -Path $DensePointCloudPLY -Force }
        Copy-Item -Path $SparsePointCloudPLY -Destination (Join-Path $ImagesFolder "sparse_point_cloud.ply") -Force
    }
}

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
# (poses) + the init point cloud (dense by default). With imported poses it skips
# its own camera tracking and trains on RealityScan's coordinate frame, which
# already carries origin, orientation, and metric scale from the GCPs. Folder
# import also avoids the ~32k char Windows command-line limit that per-file
# arguments would hit on large captures.
$importFolder = $ImagesFolder.TrimEnd('\', '/')  # trailing backslash breaks postshot-cli paths

Write-Host "`nStarting PostShot training - this can take a while..."

# Profile pinned (PostShot's default changed to Splat3 in v1.1). Recentering
# disabled so the GCP/tag-anchored RealityScan frame survives into the splat.
$psArgs = @("train", "-i", $importFolder, "--profile", "Splat MCMC", "--no-recenter-points")
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

Assert-FreshOutput $ProjectFile "PostShot project (training may have failed)"
Assert-FreshOutput $SplatFile   "Splat export (training may have failed)"

Write-Host "`nTraining finished."
Write-Host "  Project : $ProjectFile"
Write-Host "  Splat   : $SplatFile"

# -- Open the trained project in the PostShot GUI ------------------------
Write-Host "`nOpening PostShot..."
Start-Process -FilePath $PostShotExe -ArgumentList "`"$ProjectFile`""
