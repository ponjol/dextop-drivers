
<# 
.SYNOPSIS
  Autopilot ESP driver installer that uses GitHub Releases for large assets and raw repo for small metadata.

.DESCRIPTION
  - Reads a model manifest JSON from raw repo (manifests/<model>.json).
  - Downloads release assets (ZIPs) from a given release tag, extracts to local working root.
  - Optionally fetches additional small raw files listed in manifest.
  - Installs all INF drivers using pnputil (64-bit via SysNative).
  - Logs progress and sets an Intune detection marker registry value.

.PARAMETERS
  -Owner         GitHub owner/org (e.g., "your-org")
  -Repo          Repository name (e.g., "win-driver-repo")
  -Branch        Branch for raw content (default: "main")
  -GitHubToken   PAT with repo read access (or GITHUB_TOKEN env var). 
  -ManifestName  e.g., "dell-pro14-pc14250.json"
  -DetectRegPath Detection path (default: HKLM:\SOFTWARE\YourCompany\Drivers)
  -DetectRegName Detection value name (default: RepoDriversInstalled)

.NOTES
  - Requires TLS1.2 and outbound HTTPS.
  - Release asset download uses GitHub Releases API with Accept: application/octet-stream
    (handles 200/302 redirect automatically in Invoke-WebRequest). 
#>

param(
  [Parameter(Mandatory=$true)][string]$Owner,
  [Parameter(Mandatory=$true)][string]$Repo,
  [string]$Branch = "main",
  [string]$GitHubToken,
  [string]$ManifestName,
  [string]$DetectRegPath = "HKLM:\SOFTWARE\YourCompany\Drivers",
  [string]$DetectRegName = "RepoDriversInstalled"
)

# --- Configuration ---
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$BaseRaw = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch"   # raw repo files
$WorkRoot = "$env:ProgramData\MDM\DriverRepo"
$LogFile  = "$env:ProgramData\MDM\Logs\DriverInstall.log"
$PnPUtil  = "$env:WinDir\SysNative\pnputil.exe"  # 64-bit pnputil when running under 32-bit context

# --- Logging & helpers ---
function Write-Log { param([string]$msg)
  $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  "$stamp :: $msg" | Out-File -FilePath $LogFile -Append -Encoding UTF8
}
function Ensure-Dir { param([string]$path)
  if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
}
function Download-RawFile { param([string]$RelativePath, [string]$Dest)
  $uri = "$BaseRaw/$RelativePath".Replace("\","/")
  Write-Log "RAW GET: $uri"
  Invoke-WebRequest -Uri $uri -OutFile $Dest -UseBasicParsing
}

# --- GitHub API (Releases) ---
# Docs: https://docs.github.com/en/rest/releases/releases (list/get by tag) and /assets (download binary) 
# Use Accept: application/octet-stream for asset binary content (private repos) 
# References: 
#   - Releases/Assets endpoints (ID + Accept header): https://docs.github.com/en/rest/releases/assets
#   - Release by tag / upload_url / assets: https://docs.github.com/en/rest/releases/releases
#   - Private asset download via API & Accept: application/octet-stream: https://github.com/orgs/community/discussions/47453

function Get-GitHubApiHeaders {
  param([string]$Token)
  return @{
    "Authorization"        = "Bearer $Token"
    "Accept"               = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "Intune-Autopilot-Driver-Installer"
  }
}
function Get-ReleaseByTag {
  param([string]$Owner,[string]$Repo,[string]$Tag,[string]$Token)
  $headers = Get-GitHubApiHeaders -Token $Token
  $url = "https://api.github.com/repos/$Owner/$Repo/releases/tags/$Tag"
  Write-Log "API: GET $url"
  return Invoke-RestMethod -Uri $url -Headers $headers
}
function Get-ReleaseAssetByName {
  param([object]$Release,[string]$AssetName)
  $asset = $Release.assets | Where-Object { $_.name -eq $AssetName }
  if (-not $asset) { throw "Asset '$AssetName' not found in release tag '$($Release.tag_name)'." }
  return $asset  # includes .id, .name, .browser_download_url
}
function Download-ReleaseAsset {
  param([string]$Owner,[string]$Repo,[int]$AssetId,[string]$Dest,[string]$Token)
  $headers = @{
    "Authorization"        = "Bearer $Token"
    "Accept"               = "application/octet-stream"  # stream binary (handles 200/302)
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "Intune-Autopilot-Driver-Installer"
  }
  $url = "https://api.github.com/repos/$Owner/$Repo/releases/assets/$AssetId"
  Write-Log "API: GET (binary) $url -> $Dest"
  Invoke-WebRequest -Uri $url -Headers $headers -OutFile $Dest -UseBasicParsing
}

# --- Model auto-mapping (optional) ---
function Get-Model {
  try { (Get-CimInstance Win32_ComputerSystem).Model?.Trim() } catch { $null }
}

# --- Bootstrap ---
Ensure-Dir (Split-Path $LogFile)
Ensure-Dir $WorkRoot
Write-Log "===== Driver install START ====="

if (-not $GitHubToken) { $GitHubToken = $env:GITHUB_TOKEN }
if (-not $GitHubToken) { throw "GitHub PAT is required. Pass -GitHubToken or set GITHUB_TOKEN env var." }

# Pick manifest (allow auto by model name if not supplied)
if (-not $ManifestName) {
  $model = Get-Model
  Write-Log "Detected model: $model"
  switch -Regex ($model) {
    ".*PC14250.*" { $ManifestName = "dell-pro14-pc14250.json"; break }
    default       { throw "No auto-mapping for model '$model'. Supply -ManifestName." }
  }
}
Write-Log "Manifest: $ManifestName"

# Fetch manifest from raw repo
$manifestPath = Join-Path $WorkRoot "manifest.json"
Download-RawFile -RelativePath ("manifests/$ManifestName") -Dest $manifestPath
$manifest = Get-Content $manifestPath | ConvertFrom-Json
if (-not $manifest.releaseTag)    { throw "Manifest missing 'releaseTag'." }
if (-not $manifest.driverSubfolders -or $manifest.driverSubfolders.Count -eq 0) {
  throw "Manifest has no driverSubfolders."
}

# Resolve release once
$release = Get-ReleaseByTag -Owner $Owner -Repo $Repo -Tag $manifest.releaseTag -Token $GitHubToken

# --- Download assets ---
$TotalAssets = 0
$driversLocalRoot = Join-Path $WorkRoot "drivers_local"
Ensure-Dir $driversLocalRoot

foreach ($entry in $manifest.driverSubfolders) {
  $assetName = $entry.asset
  if (-not $assetName) {
    Write-Log "WARNING: No asset specified for '$($entry.path)'; skipping (or extend raw mode)."
    continue
  }

  $asset = Get-ReleaseAssetByName -Release $release -AssetName $assetName
  $zip   = Join-Path $WorkRoot $asset.name

  Download-ReleaseAsset -Owner $Owner -Repo $Repo -AssetId $asset.id -Dest $zip -Token $GitHubToken
  $TotalAssets++

  # Extract into drivers_local\<path>
  $destFolder = Join-Path $driversLocalRoot ($entry.path -replace '^drivers/', '')
  Ensure-Dir $destFolder
  Write-Log "Extract: $zip -> $destFolder"
  Expand-Archive -Path $zip -DestinationPath $destFolder -Force
}

# --- Optional: fetch small raw files listed in manifest.rawFiles ---
if ($manifest.rawFiles -and $manifest.rawFiles.Count -gt 0) {
  foreach ($rf in $manifest.rawFiles) {
    $dest = Join-Path $driversLocalRoot $rf
    Ensure-Dir (Split-Path $dest)
    Write-Log "RAW extra: $rf"
    Download-RawFile -RelativePath $rf -Dest $dest
  }
}

Write-Log "Downloaded $TotalAssets release asset(s) and extracted to $driversLocalRoot."

# --- Install INF drivers via pnputil ---
if (-not (Test-Path -LiteralPath $PnPUtil)) { throw "pnputil not found at $PnPUtil" }

$infFiles = Get-ChildItem -Path $driversLocalRoot -Recurse -Filter *.inf
if (-not $infFiles -or $infFiles.Count -eq 0) { throw "No INF files found under $driversLocalRoot." }

$failures = 0
foreach ($inf in $infFiles) {
  Write-Log "Installing INF: $($inf.FullName)"
  $args = "/add-driver `"$($inf.FullName)`" /install"
  $p = Start-Process -FilePath $PnPUtil -ArgumentList $args -PassThru -Wait -WindowStyle Hidden
  Write-Log "pnputil ExitCode=$($p.ExitCode) for $($inf.Name)"
  # 0, 3010 (restart required), 1641 (restart initiated) considered success
  if ($p.ExitCode -notin 0,3010,1641) { $failures++ }
}

# --- Detection marker ---
try {
  Ensure-Dir $DetectRegPath
  New-ItemProperty -Path $DetectRegPath -Name $DetectRegName -Value 1 -PropertyType DWord -Force | Out-Null
  Write-Log "Detection marker set: $DetectRegPath\$DetectRegName=1"
} catch {
  Write-Log "Failed to set detection marker: $($_.Exception.Message)"
}

# --- Finish ---
if ($failures -gt 0) {
  Write-Log "Install finished with $failures failure(s)."
  Write-Log "===== Driver install END (PARTIAL) ====="
  exit 1
} else {
  Write-Log "All INF installs succeeded."
  Write-Log "===== Driver install END (SUCCESS) ====="
  exit 0
