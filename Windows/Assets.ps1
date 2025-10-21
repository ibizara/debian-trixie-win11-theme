<# 
.SYNOPSIS
  Collect Office Cloud fonts (clean names), Windows fonts, and Windows default wallpapers.

.DESCRIPTION
  - Recurses Office Cloud Fonts cache and exports .ttf/.otf with friendly names (Family-Style.ext)
    to a flat destination under: Fonts\Cloud Fonts
  - Copies Windows fonts from %WINDIR%\Fonts to: Fonts\Windows Fonts (keeps original filenames)
  - Copies Windows default wallpapers from: C:\Windows\Web\Wallpaper\Windows  to: Wallpaper

.PARAMETER CloudFontsSource
  Source folder for Office Cloud Fonts. Default: %LocalAppData%\Microsoft\FontCache\4\CloudFonts

.PARAMETER WindowsFontsSource
  Source folder for Windows fonts. Default: %WINDIR%\Fonts

.PARAMETER WindowsWallpaperSource
  Source folder for Windows default wallpapers. Default: C:\Windows\Web\Wallpaper\Windows

.PARAMETER BaseDestination
  Destination root. Defaults to the folder where this script is located.
  Subfolders created:
    - Fonts\Cloud Fonts
    - Fonts\Windows Fonts
    - Wallpaper

.NOTES
  - Requires Windows PowerShell or PowerShell 7 on Windows with .NET/WPF available (for Cloud font metadata).
  - Cloud fonts: .ttf/.otf are renamed to Family-Style; .ttc not processed for Cloud Fonts (kept as-is only when copying Windows fonts).
  - All operations COPY; nothing is modified in-place.
  - Run without admin; standard user is fine as long as BaseDestination is writable.
#>

[CmdletBinding()]
param(
  [string]$CloudFontsSource       = "$env:LOCALAPPDATA\Microsoft\FontCache\4\CloudFonts",
  [string]$WindowsFontsSource     = "$env:WINDIR\Fonts",
  [string]$BaseDestination,
  [string]$WindowsWallpaperSource = "C:\Windows\Web\Wallpaper\Windows"
)

# --- Helpers -----------------------------------------------------------------

function Get-ScriptRoot {
  if ($PSCommandPath) { return (Split-Path -Parent $PSCommandPath) }
  if ($PSScriptRoot)  { return $PSScriptRoot }
  return (Get-Location).Path
}

function Ensure-Dir {
  param([Parameter(Mandatory)][string]$Path)
  New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Get-UniquePath {
  param(
    [Parameter(Mandatory)][string]$Directory,
    [Parameter(Mandatory)][string]$BaseName,  # without extension
    [Parameter(Mandatory)][string]$Extension  # with dot, e.g. ".ttf"
  )
  $candidate = Join-Path $Directory ($BaseName + $Extension)
  if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
  $i = 1
  do {
    $candidate = Join-Path $Directory ("{0}-{1}{2}" -f $BaseName, $i, $Extension)
    $i++
  } while (Test-Path -LiteralPath $candidate)
  return $candidate
}

function ConvertTo-SafeFileName {
  param([Parameter(Mandatory)][string]$Name)

  # Remove control (Cc) and format (Cf) chars (e.g. LRM/RLM/RTL override) that can break paths
  $safe = [regex]::Replace($Name, '[\p{Cc}\p{Cf}]', '')

  # Remove invalid filename characters per Windows
  $invalid = [System.IO.Path]::GetInvalidFileNameChars()
  foreach ($ch in $invalid) { $safe = $safe.Replace([string]$ch, '') }

  # Normalise whitespace; trim trailing dot/space (illegal on Windows)
  $safe = ($safe -replace '\s+', ' ').Trim().TrimEnd('.', ' ')
  if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'Unnamed' }

  # Keep names comfortably short if long-path support is off
  if ($safe.Length -gt 240) { $safe = $safe.Substring(0,240) }

  return $safe
}

# --- Cloud font metadata (for pretty naming) ---------------------------------

# WPF type needed for GlyphTypeface
try {
  Add-Type -AssemblyName PresentationCore -ErrorAction Stop
} catch {
  Write-Warning "PresentationCore not available; Cloud fonts will fall back to original filenames."
  $script:NoWpf = $true
}

function Get-FontMeta {
  param([Parameter(Mandatory)][string]$Path)
  if ($script:NoWpf) { return $null }

  try {
    $uri = [Uri]::new($Path)
    $gt  = [System.Windows.Media.GlyphTypeface]::new($uri)
  } catch {
    return $null
  }

  $ci = [System.Globalization.CultureInfo]::GetCultureInfo("en-US")

  $family = $gt.Win32FamilyNames[$ci]
  if ([string]::IsNullOrWhiteSpace($family)) { $family = $gt.FamilyNames[$ci] }
  if ([string]::IsNullOrWhiteSpace($family)) { $family = ($gt.FamilyNames.Values | Select-Object -First 1) }

  $face = $gt.Win32FaceNames[$ci]
  if ([string]::IsNullOrWhiteSpace($face)) { $face = $gt.FaceNames[$ci] }
  if ([string]::IsNullOrWhiteSpace($face)) { $face = ($gt.FaceNames.Values | Select-Object -First 1) }

  $weight   = $gt.Weight.ToOpenTypeWeight()
  $isItalic = ($gt.Style -ne [System.Windows.FontStyles]::Normal)

  $faceNorm = $face
  $generic  = @("Regular","Italic","Bold","Bold Italic","BoldItalic","Normal")
  if ($generic -contains $face -or [string]::IsNullOrWhiteSpace($face)) {
    if     ($weight -ge 700 -and $isItalic) { $faceNorm = "BoldItalic" }
    elseif ($weight -ge 700)                { $faceNorm = "Bold" }
    elseif ($isItalic)                      { $faceNorm = "Italic" }
    else                                    { $faceNorm = "Regular" }
  } else {
    $faceNorm = $face -replace '\s+', ' '
    if ($faceNorm -match 'Bold\s+Italic') { $faceNorm = 'BoldItalic' }
  }

  # Final tidy for file names is done by ConvertTo-SafeFileName
  [PSCustomObject]@{
    Family = $family
    Face   = $faceNorm
  }
}

# --- Destinations -------------------------------------------------------------

if (-not $BaseDestination) { $BaseDestination = Get-ScriptRoot }

$DestCloud = Join-Path $BaseDestination "Fonts\Cloud Fonts"
$DestWin   = Join-Path $BaseDestination "Fonts\Windows Fonts"
$DestWall  = Join-Path $BaseDestination "Wallpaper"

Ensure-Dir $DestCloud
Ensure-Dir $DestWin
Ensure-Dir $DestWall

Write-Host "Cloud fonts source       : $CloudFontsSource"
Write-Host "Windows fonts source     : $WindowsFontsSource"
Write-Host "Windows wallpaper source : $WindowsWallpaperSource"
Write-Host "Dest (Cloud Fonts)       : $DestCloud"
Write-Host "Dest (Windows Fonts)     : $DestWin"
Write-Host "Dest (Wallpaper)         : $DestWall"
Write-Host ""

# --- 1) Export Office Cloud Fonts (pretty names, flat) -----------------------

if (Test-Path -LiteralPath $CloudFontsSource) {
  Get-ChildItem -LiteralPath $CloudFontsSource -Recurse -File |
    Where-Object { $_.Extension -match '^\.(ttf|otf)$' } |
    ForEach-Object {
      $meta = Get-FontMeta -Path $_.FullName

      $base = if ($meta -and $meta.Face -and $meta.Face -ne 'Regular') {
        "{0}-{1}" -f $meta.Family, $meta.Face
      } elseif ($meta) {
        "{0}-Regular" -f $meta.Family
      } else {
        # fallback to original filename without extension if metadata fails
        [IO.Path]::GetFileNameWithoutExtension($_.Name)
      }

      # Harden the final filename (strip control/format chars, invalids, trailing dot/space)
      $base = ConvertTo-SafeFileName $base

      # Unique target in flat folder
      $target = Get-UniquePath -Directory $DestCloud -BaseName $base -Extension $_.Extension

      try {
        Copy-Item -LiteralPath $_.FullName -Destination $target -Force -ErrorAction Stop
        Write-Host ("[Cloud] {0} --> {1}" -f $_.FullName, (Split-Path $target -Leaf))
      } catch {
        Write-Warning "Failed to copy: $($_.FullName)  ->  $target  ($_ )"
      }
    }
} else {
  Write-Warning "Cloud fonts source not found: $CloudFontsSource"
}

# --- 2) Copy Windows Fonts (keep original names, flat) -----------------------

if (Test-Path -LiteralPath $WindowsFontsSource) {
  Get-ChildItem -LiteralPath $WindowsFontsSource -File |
    Where-Object { $_.Extension -match '^\.(ttf|otf|ttc|otc|fon|fnt)$' } |
    ForEach-Object {
      $nameNoExt = [IO.Path]::GetFileNameWithoutExtension($_.Name)
      # Keep original filenames — but still guard against trailing dot/space etc.
      $safeBase  = ConvertTo-SafeFileName $nameNoExt
      $target    = Get-UniquePath -Directory $DestWin -BaseName $safeBase -Extension $_.Extension

      try {
        Copy-Item -LiteralPath $_.FullName -Destination $target -Force -ErrorAction Stop
        Write-Host ("[Win ]  {0} --> {1}" -f $_.FullName, (Split-Path $target -Leaf))
      } catch {
        Write-Warning "Failed to copy: $($_.FullName)  ->  $target  ($_ )"
      }
    }
} else {
  Write-Warning "Windows fonts source not found: $WindowsFontsSource"
}

# --- 3) Copy Windows default wallpapers from fixed folder --------------------

if (Test-Path -LiteralPath $WindowsWallpaperSource) {
  Get-ChildItem -LiteralPath $WindowsWallpaperSource -Recurse -File |
    Where-Object { $_.Extension -match '^\.(jpg|jpeg|png|bmp|jfif|webp)$' } |
    ForEach-Object {
      $base   = ConvertTo-SafeFileName ([IO.Path]::GetFileNameWithoutExtension($_.Name))
      $target = Get-UniquePath -Directory $DestWall -BaseName $base -Extension $_.Extension
      try {
        Copy-Item -LiteralPath $_.FullName -Destination $target -Force -ErrorAction Stop
        Write-Host ("[Wall]  {0} --> {1}" -f $_.FullName, (Split-Path $target -Leaf))
      } catch {
        Write-Warning "Failed to copy wallpaper: $($_.FullName) -> $target  ($_ )"
      }
    }
} else {
  Write-Warning "Wallpaper source not found: $WindowsWallpaperSource"
}

Write-Host "`nAll done."
Write-Host " - Cloud fonts     : $DestCloud"
Write-Host " - Windows fonts   : $DestWin"
Write-Host " - Wallpaper files : $DestWall"
