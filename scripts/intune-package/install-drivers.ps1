
<# One-ZIP-per-model Autopilot ESP installer

Usage (example):
  # Inline set token and run (recommended for Intune Win32 install command)
  cmd /c ^
  set "GITHUB_TOKEN=<your-PAT>" && ^
  powershell -ExecutionPolicy Bypass -File .\Install-Drivers.ps1 `
    -Owner "your-org" `
    -Repo "your-repo" `
    -Branch "main"

Parameters:
  -Owner         GitHub owner/org (e.g., "your-org")
  -Repo          Repository name (e.g., "your-repo")
  -Branch        Branch for raw content (default: "main")
  -GitHubToken   PAT with repo read access; if omitted, script uses $env:GITHUB_TOKEN
  -DetectRegPath Detection marker path (default: HKLM:\SOFTWARE\YourCompany\Drivers)
  -DetectRegName Detection marker name (default: RepoDriversInstalled)

Notes:
  - Private repos: use a fine-grained PAT with Contents: read for the target repo.
  - Raw content (catalog/manifest) fetched from raw.githubusercontent.com.
  - Release asset (ZIP) downloaded via Releases API with Accept: application/octet-stream.
  - Exit codes: 0 success; 1 partial/failure (good for ESP detection).
#>

param(
  [Parameter(Mandatory=$true)][string]$Owner,
  [Parameter(Mandatory=$true)][string]$Repo,
  [string]$Branch = "main",
  [string]$GitHubToken,
  [string]$DetectRegPath = "HKLM:\SOFTWARE\YourCompany\Drivers",
  [string]$DetectRegName = "RepoDriversInstalled"
)

# ------- Setup -------
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$BaseRaw  = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch"
$WorkRoot = "$env:ProgramData\MDM\DriverRepo"
$LogFile  = "$env:ProgramData\MDM\Logs\DriverInstall.log"
$PnPUtil  = "$env:WinDir\SysNative\pnputil.exe"  # ensure 64-bit pnputil

function Write-Log { param([string]$msg)
  $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  "$stamp :: $msg" | Out-File -FilePath $LogFile -Append -Encoding UTF8
}
function Ensure-Dir { param([string]$path)
  if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
}
function Download-Raw { param([string]$rel, [string]$dest)
  $uri = "$BaseRaw/$rel".Replace("\","/")
  Write-Log "RAW GET: $uri"
  Invoke-WebRequest -Uri $uri -OutFile $dest -UseBasicParsing
}
function Invoke-Retry {
  param(
    [scriptblock]$Action,
    [int]$MaxRetries = 3,
    [int]$DelaySeconds = 5,
    [string]$Description = "operation"
  )
  for ($i=1; $i -le $MaxRetries; $i++) {
    try { return & $Action } catch {
      Write-Log "Retry $i/$MaxRetries failed for $Description: $($_.Exception.Message)"
      if ($i -eq $MaxRetries) { throw }
      Start-Sleep -Seconds $DelaySeconds
    }
  }
}

function Get-Model {
  try { (Get-CimInstance Win32_ComputerSystem).Model?.Trim() } catch { $null }
}

function Get-GitHubApiHeaders {
  param([string]$Token, [string]$Accept = "application/vnd.github+json")
  return @{
    "Authorization"        = "Bearer $Token"
    "Accept"               = $Accept
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "Intune-Autopilot-Driver-Installer"
  }
}
function Get-ReleaseByTag {
  param([string]$tag,[string]$token)
  $headers = Get-GitHubApiHeaders -Token $token
  $url = "https://api.github.com/repos/$Owner/$Repo/releases/tags/$tag"
  Write-Log "API: GET $url"
  Invoke-RestMethod -Uri $url -Headers $headers
}
function Get-AssetByName {
  param([object]$release,[string]$name)
  $a = $release.assets | Where-Object { $_.name -eq $name }
  if (-not $a) { throw "Asset '$name' not found in release '$($release.tag_name)'." }
  $a
}
function Download-AssetBinary {
  param([int]$assetId,[string]$dest,[string]$token)
  $headers = Get-GitHubApiHeaders -Token $token -Accept "application/octet-stream"
  $url = "https://api.github.com/repos/$Owner/$Repo/releases/assets/$assetId"
  Write-Log "API: GET (binary) $url -> $dest"
  Invoke-WebRequest -Uri $url -Headers $headers -OutFile $dest -UseBasicParsing
}

# ------- Bootstrap -------
Ensure-Dir (Split-Path $LogFile)
Ensure-Dir $WorkRoot
Write-Log "===== Driver install START ====="

if (-not $GitHubToken) { $GitHubToken = $env:GITHUB_TOKEN }
if (-not $GitHubToken) { throw "GitHub PAT required. Pass -GitHubToken or set GITHUB_TOKEN." }

# Step 1: Detect model and resolve manifest from catalog.json
$model = Get-Model
if (-not $model) { throw "Unable to detect device model." }
Write-Log "Detected model: $model"

$catalogLocal = Join-Path $WorkRoot "catalog.json"
Invoke-Retry -Description "download catalog.json" -Action { Download-Raw -rel "manifests/catalog.json" -dest $catalogLocal }
$catalog = Get-Content $catalogLocal | ConvertFrom-Json

$manifestName = ($catalog.models | Where-Object { $model -like ("*" + $_.model + "*") }).manifest
if (-not $manifestName) { throw "No manifest mapping found for model '$model' in catalog.json." }
Write-Log "Manifest: $manifestName"

# Step 2: Download manifest and read tag/asset
$manifestLocal = Join-Path $WorkRoot "manifest.json"
Invoke-Retry -Description "download manifest" -Action { Download-Raw -rel ("manifests/$manifestName") -dest $manifestLocal }
$manifest = Get-Content $manifestLocal | ConvertFrom-Json
if (-not $manifest.releaseTag) { throw "Manifest missing 'releaseTag'." }
if (-not $manifest.asset)      { throw "Manifest missing 'asset' (zip filename)." }

# Step 3: Resolve release & asset, download single ZIP
$release = Invoke-Retry -Description "get release by tag" -Action { Get-ReleaseByTag -tag $manifest.releaseTag -token $GitHubToken }
$asset   = Get-AssetByName -release $release -name $manifest.asset

$zipPath = Join-Path $WorkRoot $asset.name
Invoke-Retry -Description "download asset" -Action { Download-AssetBinary -assetId $asset.id -dest $zipPath -token $GitHubToken }

# Step 4: Extract ZIP into drivers_local
$driversLocal = Join-Path $WorkRoot "drivers_local"
Ensure-Dir $driversLocal

$destFolder = if ($manifest.extractTo) { Join-Path $driversLocal $manifest.extractTo } else { $driversLocal }
Ensure-Dir $destFolder

Write-Log "Extract: $zipPath -> $destFolder"
Expand-Archive -Path $zipPath -DestinationPath $destFolder -Force

# Step 5: Install INFs via pnputil
if (-not (Test-Path -LiteralPath $PnPUtil)) { throw "pnputil not found at $PnPUtil" }
$infFiles = Get-ChildItem -Path $driversLocal -Recurse -Filter *.inf
if (-not $infFiles -or $infFiles.Count -eq 0) { throw "No INF files found under $driversLocal." }

$failures = 0
foreach ($inf in $infFiles) {
  Write-Log "Installing INF: $($inf.FullName)"
  $args = "/add-driver `"$($inf.FullName)`" /install"
  $p = Start-Process -FilePath $PnPUtil -ArgumentList $args -PassThru -Wait -WindowStyle Hidden
  Write-Log "pnputil ExitCode=$($p.ExitCode) for $($inf.Name)"
  if ($p.ExitCode -notin 0,3010,1641) { $failures++ }
}

# Step 6: Detection marker
try {
  if (-not (Test-Path -LiteralPath $DetectRegPath)) { New-Item -Path $DetectRegPath -Force | Out-Null }
  New-ItemProperty -Path $DetectRegPath -Name $DetectRegName -Value 1 -PropertyType DWord -Force | Out-Null
  Write-Log "Detection marker set: $DetectRegPath\$DetectRegName=1"
} catch {
  Write-Log "Failed to set detection marker: $($_.Exception.Message)"
}

# Finish
if ($failures -gt 0) {
  Write-Log "Install finished with $failures failure(s)."
  Write-Log "===== Driver install END (PARTIAL) ====="
  exit 1
} else {
  Write-Log "All INF installs succeeded."
  Write-Log "===== Driver install END (SUCCESS) ====="
  exit 0
}
