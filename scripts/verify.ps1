[CmdletBinding()]
param(
    [string]$CodexHomePath,
    [string]$PackageRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { throw 'PackageRoot is required when verify.ps1 is invoked from a script block.' }
    $PackageRoot = Split-Path -Parent $PSScriptRoot
}
$PackageRoot = [System.IO.Path]::GetFullPath($PackageRoot)
if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) { throw "PackageRoot does not exist: $PackageRoot" }
$Expected = @('SKILL.md', 'assets\AGENTS.md', 'agents\openai.yaml', 'scripts\install.ps1', 'scripts\verify.ps1')
$StartMarker = '<!-- model-routing:start -->'
$EndMarker = '<!-- model-routing:end -->'

function Read-Utf8File([string]$Path) { [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) }
function Count-Text([string]$Text, [string]$Needle) { [regex]::Matches($Text, [regex]::Escape($Needle)).Count }
function Normalize-PolicyText([string]$Text) {
    return ($Text -replace "`r`n", "`n").TrimEnd("`n")
}

if ([string]::IsNullOrWhiteSpace($CodexHomePath)) {
    $userProfile = if ($env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile) }
    $CodexHomePath = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $userProfile '.codex' }
}
$CodexHomePath = [System.IO.Path]::GetFullPath($CodexHomePath)
$InstallRoot = Join-Path $CodexHomePath 'skills\model-routing'
$failed = @()
foreach ($relative in $Expected) {
    $path = Join-Path $InstallRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $failed += "Missing $relative"; continue }
    $item = Get-Item -LiteralPath $path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $failed += "Reparse point $relative"; continue }
    $source = Join-Path $PackageRoot $relative
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        if ((Read-Utf8File $path) -cne (Read-Utf8File $source)) { $failed += "Different content $relative" }
    }
}
$agents = Join-Path $CodexHomePath 'AGENTS.md'
if (-not (Test-Path -LiteralPath $agents -PathType Leaf)) { $failed += 'Missing global AGENTS.md' }
else {
    $text = Read-Utf8File $agents
    if ((Count-Text $text $StartMarker) -ne 1 -or (Count-Text $text $EndMarker) -ne 1) { $failed += 'Global AGENTS.md has invalid markers' }
    else {
        $startIndex = $text.IndexOf($StartMarker, [StringComparison]::Ordinal)
        $endIndex = $text.IndexOf($EndMarker, [StringComparison]::Ordinal)
        if ($endIndex -le $startIndex) { $failed += 'Global AGENTS.md has model-routing markers in invalid order' }
        else {
            $bodyStart = $startIndex + $StartMarker.Length
            $body = $text.Substring($bodyStart, $endIndex - $bodyStart).TrimStart("`r", "`n").TrimEnd("`r", "`n")
            if ($body.IndexOf('tom-model-routing-v1', [StringComparison]::Ordinal) -lt 0) { $failed += 'Managed model-routing block lacks tom-model-routing-v1' }
            $assetPath = Join-Path $InstallRoot 'assets\AGENTS.md'
            if (Test-Path -LiteralPath $assetPath -PathType Leaf) {
                $expectedBody = Read-Utf8File $assetPath
                if ((Normalize-PolicyText $body) -cne (Normalize-PolicyText $expectedBody)) {
                    $failed += 'Managed model-routing block differs from installed assets/AGENTS.md; it may have been customized'
                }
            }
        }
    }
}
if ($failed.Count) { $failed | ForEach-Object { Write-Error $_ }; exit 1 }
Write-Output "model-routing installation verified at $InstallRoot"
