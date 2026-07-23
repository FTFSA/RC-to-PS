# rc_to_postshot.ps1
# Usage: .\rc_to_postshot.ps1 -ParentFolder "C:\path\to\your\folder"
# Smoke test: .\rc_to_postshot.ps1 -ParentFolder "C:\path\to\your\folder" -ImagesFolder "C:\path\to\your\images" -SmokeTest
#
# Expects:  ParentFolder\
#               <images-subfolder>\   <-- any single subfolder containing your images
#
# Optional inputs (in the parent folder) to center the scene on the AprilTags:
#   gcps.csv                -- measured tag coordinates (Name,X,Y,Z in meters,
#                              no header). Needs at least 3 tags, e.g.:
#                                36h11:00b,0,0,0
#                                36h11:00c,0.30,0,0
#                                36h11:00d,0,0.25,0
#   ImportGcpParams.xml     -- GCP import settings. Save ONCE from RealityScan:
#                              ALIGNMENT tab > Import > Ground Control Points >
#                              select gcps.csv > in the import dialog choose
#                              format 'Point X/Lon Y/Lat Z/Alt' and coordinate
#                              system 'local:1 - Euclidean' > click the save
#                              settings (down-arrow) icon > save to this file.
#
# Outputs (written into the images subfolder):
#   registration.csv        -- Internal/External camera parameters
#   sparse_point_cloud.ply  -- sparse point cloud (binary, vertex colors)
#
# Outputs (written into the parent folder):
#   <capture>.psht          -- trained PostShot project (opened in GUI at end)
#   <capture>-splat.ply     -- exported splat model

param(
    [Parameter(Mandatory = $true, HelpMessage = "Path to the folder that contains your images subfolder")]
    [string]$ParentFolder,

    [Parameter(Mandatory = $false, HelpMessage = "Optional: path to the images folder directly (skips auto-detect of the single subfolder)")]
    [string]$ImagesFolder,

    [Parameter(Mandatory = $false, HelpMessage = "Enable a fast smoke-test run (copies a subset of images into a *_smoketest folder).")]
    [switch]$SmokeTest,

    [Parameter(Mandatory = $false, HelpMessage = "How many images to copy for smoke-test mode.")]
    [ValidateRange(1, 1000)]
    [int]$SmokeTestImageCount = 8,

    [Parameter(Mandatory = $false, HelpMessage = "PostShot training step limit (kSteps) for smoke-test mode.")]
    [ValidateRange(1, 1000)]
    [int]$SmokeTestTrainSteps = 2,

    [Parameter(Mandatory = $false, HelpMessage = "PostShot max splats (kSplats) for smoke-test mode.")]
    [ValidateRange(1, 10000)]
    [int]$SmokeTestMaxSplats = 200,

    [Parameter(Mandatory = $false, HelpMessage = "PostShot max image size for smoke-test mode.")]
    [ValidateRange(0, 20000)]
    [int]$SmokeTestMaxImageSize = 1600
)

# -- Adjust these paths to match your installations --------------------
$RealityScanExe = "C:\Program Files\Epic Games\RealityScan_2.2\RealityScan.exe"
$PostShotExe    = "C:\Program Files\Jawset Postshot\bin\postshot.exe"
$PostShotCli    = "C:\Program Files\Jawset Postshot\bin\postshot-cli.exe"
# ----------------------------------------------------------------------

Set-StrictMode -Version Latest

function Assert-Path([string]$path, [string]$label) {
    if (-not (Test-Path $path)) {
        Write-Error "$label not found: $path"
        exit 1
    }
}

$Inv = [System.Globalization.CultureInfo]::InvariantCulture

function Get-JpegDimensions([string]$Path) {
    # Minimal JPEG SOF parser: returns @(width, height) or $null
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $b = New-Object byte[] 2
        if ($fs.Read($b, 0, 2) -ne 2 -or $b[0] -ne 0xFF -or $b[1] -ne 0xD8) { return $null }
        while ($true) {
            $m = $fs.ReadByte()
            if ($m -lt 0) { return $null }
            if ($m -ne 0xFF) { continue }
            $code = $fs.ReadByte()
            while ($code -eq 0xFF) { $code = $fs.ReadByte() }
            if ($code -lt 0) { return $null }
            if ($code -ge 0xD0 -and $code -le 0xD9) { continue }
            if ($fs.Read($b, 0, 2) -ne 2) { return $null }
            $len = $b[0] * 256 + $b[1]
            $isSOF = ($code -ge 0xC0 -and $code -le 0xCF -and $code -ne 0xC4 -and $code -ne 0xC8 -and $code -ne 0xCC)
            if ($isSOF) {
                $seg = New-Object byte[] 5
                if ($fs.Read($seg, 0, 5) -ne 5) { return $null }
                return @(($seg[3] * 256 + $seg[4]), ($seg[1] * 256 + $seg[2]))
            }
            [void]$fs.Seek($len - 2, 'Current')
        }
    } finally { $fs.Close() }
}

function Get-RcRotationMatrix([double]$YawDeg, [double]$PitchDeg, [double]$RollDeg) {
    # RealityScan camera rotation from yaw/pitch/roll (per Epic dev community)
    $d = [Math]::PI / 180.0
    $cx = [Math]::Cos($RollDeg * $d);  $sx = [Math]::Sin($RollDeg * $d)
    $cy = [Math]::Cos($PitchDeg * $d); $sy = [Math]::Sin($PitchDeg * $d)
    $cz = [Math]::Cos($YawDeg * $d);   $sz = [Math]::Sin($YawDeg * $d)
    return @(
        ($cx*$cz + $sx*$sy*$sz), (-$cx*$sz + $cz*$sx*$sy), (-$cy*$sx),
        (-$cy*$sz),              (-$cy*$cz),               (-$sy),
        ($cx*$sy*$sz - $cz*$sx), ($cx*$cz*$sy + $sx*$sz),  (-$cx*$cy)
    )
}

function Invoke-TagTriangulation($Obs, [int]$RotMode, [int]$VFlip) {
    # Least-squares intersection of the observation rays (lines), plus residual
    $A  = New-Object 'double[]' 9
    $bv = New-Object 'double[]' 3
    $dirs = @(); $cams = @()
    foreach ($o in $Obs) {
        $R   = $o.R
        $fpx = $o.F35 * $o.W / 36.0
        $cxp = $o.W / 2.0 + $o.PxN * $o.W
        $cyp = $o.H / 2.0 + $o.PyN * $o.W
        $u = ($o.U - $cxp) / $fpx
        $v = ($o.V - $cyp) / $fpx
        if ($VFlip -eq 1) { $v = -$v }
        $dc = @($u, $v, 1.0)
        # NOTE: every element must be parenthesized - PowerShell's comma
        # operator binds tighter than arithmetic operators.
        if ($RotMode -eq 0) {
            $dw = @(
                ($R[0]*$dc[0] + $R[1]*$dc[1] + $R[2]*$dc[2]),
                ($R[3]*$dc[0] + $R[4]*$dc[1] + $R[5]*$dc[2]),
                ($R[6]*$dc[0] + $R[7]*$dc[1] + $R[8]*$dc[2])
            )
        } else {
            $dw = @(
                ($R[0]*$dc[0] + $R[3]*$dc[1] + $R[6]*$dc[2]),
                ($R[1]*$dc[0] + $R[4]*$dc[1] + $R[7]*$dc[2]),
                ($R[2]*$dc[0] + $R[5]*$dc[1] + $R[8]*$dc[2])
            )
        }
        $n = [Math]::Sqrt($dw[0]*$dw[0] + $dw[1]*$dw[1] + $dw[2]*$dw[2])
        $dw = @(($dw[0]/$n), ($dw[1]/$n), ($dw[2]/$n))
        $dirs += ,$dw
        $cams += ,$o.C
        for ($r = 0; $r -lt 3; $r++) {
            for ($c = 0; $c -lt 3; $c++) {
                $mij = -$dw[$r] * $dw[$c]
                if ($r -eq $c) { $mij = 1.0 + $mij }
                $A[$r*3+$c] += $mij
                $bv[$r] += $mij * $o.C[$c]
            }
        }
    }
    $det = $A[0]*($A[4]*$A[8]-$A[5]*$A[7]) - $A[1]*($A[3]*$A[8]-$A[5]*$A[6]) + $A[2]*($A[3]*$A[7]-$A[4]*$A[6])
    if ([Math]::Abs($det) -lt 1e-12) { return $null }
    $d0 = $bv[0]*($A[4]*$A[8]-$A[5]*$A[7]) - $A[1]*($bv[1]*$A[8]-$A[5]*$bv[2]) + $A[2]*($bv[1]*$A[7]-$A[4]*$bv[2])
    $d1 = $A[0]*($bv[1]*$A[8]-$A[5]*$bv[2]) - $bv[0]*($A[3]*$A[8]-$A[5]*$A[6]) + $A[2]*($A[3]*$bv[2]-$bv[1]*$A[6])
    $d2 = $A[0]*($A[4]*$bv[2]-$bv[1]*$A[7]) - $A[1]*($A[3]*$bv[2]-$bv[1]*$A[6]) + $bv[0]*($A[3]*$A[7]-$A[4]*$A[6])
    $P = @(($d0/$det), ($d1/$det), ($d2/$det))
    $sumSq = 0.0; $dists = @()
    for ($i = 0; $i -lt $dirs.Count; $i++) {
        $w = @(($P[0]-$cams[$i][0]), ($P[1]-$cams[$i][1]), ($P[2]-$cams[$i][2]))
        $t = $w[0]*$dirs[$i][0] + $w[1]*$dirs[$i][1] + $w[2]*$dirs[$i][2]
        $px = $w[0] - $t*$dirs[$i][0]; $py = $w[1] - $t*$dirs[$i][1]; $pz = $w[2] - $t*$dirs[$i][2]
        $sumSq += $px*$px + $py*$py + $pz*$pz
        $dists += [Math]::Sqrt($w[0]*$w[0] + $w[1]*$w[1] + $w[2]*$w[2])
    }
    $rms = [Math]::Sqrt($sumSq / $dirs.Count)
    $sorted = $dists | Sort-Object
    $median = $sorted[[int](($sorted.Count - 1) / 2)]
    return @{ P = $P; Rms = $rms; MedianDist = $median }
}

function Center-SceneOnTag([string]$RegCsv, [string]$PlyFile, [string]$CpmCsv, [string]$ImgFolder) {
    # Triangulates the most-observed AprilTag and translates the exported
    # registration CSV + sparse PLY so the tag becomes the scene origin.
    $inv = [System.Globalization.CultureInfo]::InvariantCulture

    $meas = @()
    foreach ($line in (Get-Content $CpmCsv)) {
        $f = $line.Split(',')
        if ($f.Count -ge 4) {
            $meas += ,@{ File = [System.IO.Path]::GetFileName($f[0].Trim()); Tag = $f[1].Trim();
                         U = [double]::Parse($f[2].Trim(), $inv); V = [double]::Parse($f[3].Trim(), $inv) }
        }
    }
    if ($meas.Count -eq 0) { Write-Warning "No tag measurements found - skipping centering."; return $false }

    $best = $meas | Group-Object { $_.Tag } | Sort-Object Count -Descending | Select-Object -First 1
    if ($best.Count -lt 2) { Write-Warning "Tag '$($best.Name)' seen in fewer than 2 images - cannot triangulate."; return $false }
    Write-Host "Centering scene on tag '$($best.Name)' ($($best.Count) observations)"

    $cameras = @{}
    foreach ($line in (Get-Content $RegCsv)) {
        if ($line.StartsWith("#") -or [string]::IsNullOrWhiteSpace($line)) { continue }
        $f = $line.Split(',')
        $cameras[$f[0].Trim()] = @{
            C   = @([double]::Parse($f[1], $inv), [double]::Parse($f[2], $inv), [double]::Parse($f[3], $inv))
            R   = Get-RcRotationMatrix ([double]::Parse($f[4], $inv)) ([double]::Parse($f[5], $inv)) ([double]::Parse($f[6], $inv))
            F35 = [double]::Parse($f[7], $inv)
            PxN = [double]::Parse($f[8], $inv)
            PyN = [double]::Parse($f[9], $inv)
        }
    }

    $dims = @{}
    $obs = @()
    foreach ($m in ($best.Group)) {
        if (-not $cameras.ContainsKey($m.File)) { continue }
        if (-not $dims.ContainsKey($m.File)) { $dims[$m.File] = Get-JpegDimensions (Join-Path $ImgFolder $m.File) }
        $wh = $dims[$m.File]
        if ($null -eq $wh) { continue }
        $cam = $cameras[$m.File]
        $obs += ,@{ C = $cam.C; R = $cam.R; F35 = $cam.F35; PxN = $cam.PxN; PyN = $cam.PyN;
                    U = $m.U; V = $m.V; W = [double]$wh[0]; H = [double]$wh[1] }
    }
    if ($obs.Count -lt 2) { Write-Warning "Not enough usable observations - skipping centering."; return $false }

    # RealityScan's exact projection conventions are undocumented; try both
    # rotation directions and image-V orientations, keep the best fit.
    $bestSol = $null
    foreach ($rot in 0, 1) {
        foreach ($vf in 0, 1) {
            $sol = Invoke-TagTriangulation $obs $rot $vf
            if ($null -ne $sol) {
                if ($null -eq $bestSol -or $sol.Rms -lt $bestSol.Rms) { $bestSol = $sol }
            }
        }
    }
    if ($null -eq $bestSol) { Write-Warning "Triangulation failed - skipping centering."; return $false }

    $rel = $bestSol.Rms / $bestSol.MedianDist
    Write-Host ("Tag position: [{0:f4}, {1:f4}, {2:f4}]  ray RMS: {3:f5} ({4:p2} of camera distance)" -f `
        $bestSol.P[0], $bestSol.P[1], $bestSol.P[2], $bestSol.Rms, $rel)
    if ([double]::IsNaN($rel) -or [double]::IsInfinity($rel) -or $rel -gt 0.02) {
        Write-Warning "Triangulation uncertainty too high - leaving exports uncentered."
        return $false
    }
    $P = $bestSol.P

    # Prepare translated registration CSV (in memory)
    $out = foreach ($line in (Get-Content $RegCsv)) {
        if ($line.StartsWith("#") -or [string]::IsNullOrWhiteSpace($line)) { $line; continue }
        $f = $line.Split(',')
        for ($k = 0; $k -lt 3; $k++) {
            $f[1 + $k] = ([double]::Parse($f[1 + $k], $inv) - $P[$k]).ToString('R', $inv)
        }
        $f -join ','
    }

    # Prepare translated binary PLY (in memory)
    $bytes = [System.IO.File]::ReadAllBytes($PlyFile)
    $headLen = [Math]::Min(4096, $bytes.Length)
    $head = [System.Text.Encoding]::ASCII.GetString($bytes, 0, $headLen)
    $endTok = "end_header`n"
    $endIdx = $head.IndexOf($endTok)
    if ($endIdx -lt 0 -or $head -notmatch "format binary_little_endian" -or $head -notmatch "element vertex (\d+)") {
        Write-Warning "Unexpected PLY layout - exports left uncentered."
        return $false
    }
    $count = [int]$Matches[1]
    $off = $endIdx + $endTok.Length
    for ($i = 0; $i -lt $count; $i++) {
        $rec = $off + $i * 15
        for ($k = 0; $k -lt 3; $k++) {
            $val = [BitConverter]::ToSingle($bytes, $rec + 4 * $k) - $P[$k]
            [Array]::Copy([BitConverter]::GetBytes([float]$val), 0, $bytes, $rec + 4 * $k, 4)
        }
    }

    # Write both files only after all math succeeded
    [System.IO.File]::WriteAllBytes($PlyFile, $bytes)
    Set-Content -Path $RegCsv -Value $out -Encoding ASCII

    Write-Host "Scene centered on tag '$($best.Name)' (translation only)."
    return $true
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
    $subfolders = @(Get-ChildItem -Path $ParentFolder -Directory)

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
    $supported = @(".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp")
    $allImages = @(Get-ChildItem -Path $sourceFolder -File | Where-Object { $supported -contains $_.Extension.ToLowerInvariant() } | Sort-Object Name)
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

    foreach ($img in ($allImages | Select-Object -First $useCount)) {
        Copy-Item -Path $img.FullName -Destination (Join-Path $smokeFolder $img.Name)
    }
    $ImagesFolder = $smokeFolder
    Write-Host "Smoke test mode enabled."
    Write-Host "  Source folder : $sourceFolder"
    Write-Host "  Test folder   : $ImagesFolder"
    Write-Host "  Image count   : $useCount"
}

# -- Define output paths (same folder as images) -----------------------
$RegistrationCSV     = Join-Path $ImagesFolder "registration.csv"
$SparsePointCloudPLY = Join-Path $ImagesFolder "sparse_point_cloud.ply"
$TagMeasurementsCSV  = if ($SmokeTest) { Join-Path $ImagesFolder "tag_measurements.csv" } else { Join-Path $ParentFolder "tag_measurements.csv" }

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

# Ground control point coordinates: standard 36h11 tags at +90° orientation
# If gcps.csv doesn't exist, generate it with default coordinates.
$GcpCsv = Join-Path $ParentFolder "gcps.csv"
if (-not (Test-Path $GcpCsv)) {
    @"
36h11:00e,0,0,0
36h11:00f,0,0.1,0
36h11:011,0.15,0.1,0
"@ | Set-Content -Path $GcpCsv -Encoding ASCII
    Write-Host "Generated default gcps.csv with standard tag coordinates."
}

# Ground control point import settings: RealityScan requires this file to be
# saved from its GUI dialog (see header). The script never generates it.
$GcpParamsXml = Join-Path $ParentFolder "ImportGcpParams.xml"

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

# Note: Start-Process does not quote arguments itself, so wrap every path in
# explicit quotes to support folders with spaces (e.g. "Chris Berry").
$rcArgs = @(
    "-newScene"
    "-addFolder",              "`"$ImagesFolder`""
)

# Ground control points: center/orient/scale the scene on the AprilTags.
# Requires at least 3 tags with measured coordinates in gcps.csv.
$UsedGcp = $false
if ((Test-Path $GcpCsv) -and (Test-Path $GcpParamsXml)) {
    Write-Host "Using ground control points: $GcpCsv"
    $rcArgs += @("-importGroundControlPoints", "`"$GcpCsv`"", "`"$GcpParamsXml`"")
    $UsedGcp = $true
} elseif (Test-Path $GcpCsv) {
    Write-Warning "gcps.csv found but ImportGcpParams.xml is missing - save it once from RealityScan's Import Ground Control Points dialog (see script header). Falling back to triangulation centering."
} else {
    Write-Host "No gcps.csv - will center on the best-observed tag by triangulation instead."
}

$rcArgs += @(
    "-detectMarkers",          "`"$DetectMarkersXml`""
    "-align"
    "-exportControlPointsMeasurements", "`"$TagMeasurementsCSV`""
    "-exportRegistration",     "`"$RegistrationCSV`"",     "`"$RegParamsXml`""
    "-exportSparsePointCloud", "`"$SparsePointCloudPLY`"", "`"$PlyParamsXml`""
    "-quit"
)

Write-Host "Command: $RealityScanExe $rcArgs`n"

# Run and wait for RealityScan to finish before continuing
$rcProc = Start-Process -FilePath $RealityScanExe -ArgumentList $rcArgs -PassThru -Wait
$rcExit = $rcProc.ExitCode

if ($rcExit -ne 0) {
    Write-Error "RealityScan exited with code $rcExit - check the RealityScan log for details."
    exit $rcExit
}

# Verify the outputs actually exist
Assert-Path $RegistrationCSV     "Registration CSV (export may have failed)"
Assert-Path $SparsePointCloudPLY "Sparse point cloud PLY (export may have failed)"

Write-Host "`nRealityScan finished successfully."
Write-Host "  Registration CSV  : $RegistrationCSV"
Write-Host "  Sparse point cloud: $SparsePointCloudPLY"

# -- Center scene on tag (when GCPs were not used) ----------------------
if (-not $UsedGcp) {
    if (Test-Path $TagMeasurementsCSV) {
        try {
            $ErrorActionPreference = 'Stop'
            [void](Center-SceneOnTag $RegistrationCSV $SparsePointCloudPLY $TagMeasurementsCSV $ImagesFolder)
        } catch {
            Write-Warning "Centering failed ($($_.Exception.Message)) - exports left uncentered."
        } finally {
            $ErrorActionPreference = 'Continue'
        }
    } else {
        Write-Warning "No tag measurements were exported - scene left uncentered."
    }
}

# -- Train in PostShot via postshot-cli ----------------------------------
# PostShot imports the RealityScan poses (registration.csv) + point cloud
# (sparse_point_cloud.ply) alongside the images, so it skips its own camera
# tracking and trains on RealityScan's coordinate frame. No AprilTag work is
# needed in PostShot - the RealityScan export already carries origin,
# orientation, and metric scale.
$CaptureName = Split-Path $ImagesFolder -Leaf
$ProjectOutDir = if ($SmokeTest) { $ImagesFolder } else { $ParentFolder }
$ProjectFile = Join-Path $ProjectOutDir ($CaptureName + ".psht")
$SplatFile   = Join-Path $ProjectOutDir ($CaptureName + "-splat.ply")

$supportedImportImages = @(".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp", ".exr")
$importImages = @(Get-ChildItem -Path $ImagesFolder -File | Where-Object { $supportedImportImages -contains $_.Extension.ToLowerInvariant() } | Sort-Object Name | ForEach-Object { $_.FullName })
$importFiles = @()
$importFiles += $importImages
$importFiles += $RegistrationCSV
$importFiles += $SparsePointCloudPLY

Write-Host "`nStarting PostShot training ($($importFiles.Count) inputs) - this can take a while..."

$psArgs = @("train", "-i")
$psArgs += $importFiles
$psArgs += @("--profile", "Splat MCMC")
if ($SmokeTest) {
    $psArgs += @("-s", $SmokeTestTrainSteps.ToString(), "--max-num-splats", $SmokeTestMaxSplats.ToString(), "--max-image-size", $SmokeTestMaxImageSize.ToString())
}
$psArgs += @("-o", $ProjectFile, "--export-splat", $SplatFile)

& $PostShotCli @psArgs
$psExit = $LASTEXITCODE

if ($psExit -ne 0) {
    Write-Error "postshot-cli exited with code $psExit."
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
