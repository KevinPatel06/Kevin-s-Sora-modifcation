<#
.SYNOPSIS
    Downloads the IPA from the most recent successful GitHub Actions build.

.DESCRIPTION
    The CI workflow uploads the IPA wrapped in a zip, and GitHub wraps artifacts
    in a zip of their own. This unwraps both layers and drops a ready-to-install
    Sulfur.ipa into .\dist\.

    Requires the GitHub CLI, authenticated once with: gh auth login

.PARAMETER Branch
    Branch whose build to fetch. Defaults to the current branch.

.PARAMETER Wait
    Wait for an in-progress run to finish instead of failing.

.EXAMPLE
    .\scripts\fetch-ipa.ps1
.EXAMPLE
    .\scripts\fetch-ipa.ps1 -Wait
#>
[CmdletBinding()]
param(
    [string]$Branch,
    [switch]$Wait
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI not found on PATH. Install it with 'winget install GitHub.cli', then open a new terminal."
}

try { gh auth status 2>&1 | Out-Null } catch { }
if ($LASTEXITCODE -ne 0) {
    throw "GitHub CLI is not authenticated. Run 'gh auth login' first."
}

if (-not $Branch) {
    $Branch = (git rev-parse --abbrev-ref HEAD).Trim()
}
Write-Host "Branch: $Branch" -ForegroundColor Cyan

if ($Wait) {
    $inProgress = gh run list --workflow build.yml --branch $Branch --status in_progress --limit 1 --json databaseId | ConvertFrom-Json
    if ($inProgress.Count -gt 0) {
        Write-Host "A build is running. Waiting for it to finish..." -ForegroundColor Yellow
        gh run watch $inProgress[0].databaseId --exit-status
    }
}

$runs = gh run list --workflow build.yml --branch $Branch --status success --limit 1 --json databaseId,headSha,createdAt | ConvertFrom-Json
if ($runs.Count -eq 0) {
    throw "No successful build found for branch '$Branch'. Push a commit, or check the Actions tab for failures."
}

$run = $runs[0]
Write-Host "Run $($run.databaseId)  commit $($run.headSha.Substring(0,7))  $($run.createdAt)" -ForegroundColor Cyan

$staging = Join-Path $env:TEMP "sulfur-ipa-$($run.databaseId)"
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging | Out-Null

Write-Host "Downloading artifact..." -ForegroundColor Cyan
gh run download $run.databaseId --name Sulfur-iOS-Build --dir $staging
if ($LASTEXITCODE -ne 0) { throw "Artifact download failed. Artifacts expire after 90 days." }

# Inner layer: the workflow zips Sulfur.ipa into Sulfur.zip before uploading.
$innerZip = Get-ChildItem -Path $staging -Filter *.zip -Recurse | Select-Object -First 1
if ($innerZip) {
    Expand-Archive -Path $innerZip.FullName -DestinationPath $staging -Force
}

$ipa = Get-ChildItem -Path $staging -Filter *.ipa -Recurse | Select-Object -First 1
if (-not $ipa) { throw "No .ipa found inside the artifact. Inspect $staging" }

$dist = Join-Path $repoRoot 'dist'
if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist | Out-Null }

$dest = Join-Path $dist 'Sulfur.ipa'
Copy-Item $ipa.FullName $dest -Force
Remove-Item $staging -Recurse -Force

$sizeMb = [math]::Round((Get-Item $dest).Length / 1MB, 1)
Write-Host ""
Write-Host "Ready: $dest  ($sizeMb MB)" -ForegroundColor Green
Write-Host "Copy it to your phone and import it in LiveContainer." -ForegroundColor Green
