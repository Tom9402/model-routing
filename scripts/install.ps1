[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$CodexHomePath,
    [string]$PackageRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { throw 'PackageRoot is required when install.ps1 is invoked from a script block.' }
    $PackageRoot = Split-Path -Parent $PSScriptRoot
}
$PackageRoot = [System.IO.Path]::GetFullPath($PackageRoot)
if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) { throw "PackageRoot does not exist: $PackageRoot" }
$AssetPath = Join-Path $PackageRoot 'assets\AGENTS.md'
$ManagedFiles = @('SKILL.md', 'assets\AGENTS.md', 'agents\openai.yaml', 'scripts\install.ps1', 'scripts\verify.ps1')
$StartMarker = '<!-- model-routing:start -->'
$EndMarker = '<!-- model-routing:end -->'

function Read-Utf8File([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-Utf8File([string]$Path, [string]$Content) {
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { [System.IO.Directory]::CreateDirectory($directory) | Out-Null }
    $writer = New-Object System.IO.StreamWriter($Path, $false, (New-Object System.Text.UTF8Encoding($false)))
    try { $writer.Write($Content) } finally { $writer.Dispose() }
}

function Assert-NoReparsePath([string]$Path, [string]$Label) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Label is a reparse point and is refused: $Path"
    }
}

function Assert-SafeExistingAncestors([string]$Path, [string]$Label) {
    $cursor = [System.IO.Path]::GetFullPath($Path)
    while (-not (Test-Path -LiteralPath $cursor)) {
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
    while (Test-Path -LiteralPath $cursor) {
        Assert-NoReparsePath $cursor $Label
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Get-OccurrenceCount([string]$Text, [string]$Needle) {
    return [regex]::Matches($Text, [regex]::Escape($Needle)).Count
}

function Get-MergedAgentsContent([string]$Current, [string]$Policy) {
    $starts = Get-OccurrenceCount $Current $StartMarker
    $ends = Get-OccurrenceCount $Current $EndMarker
    if (($starts -ne 0 -or $ends -ne 0) -and ($starts -ne 1 -or $ends -ne 1)) {
        throw 'Global AGENTS.md has malformed or duplicate model-routing markers. Resolve them manually before installing.'
    }
    if ($starts -eq 1) {
        $startIndex = $Current.IndexOf($StartMarker, [StringComparison]::Ordinal)
        $endIndex = $Current.IndexOf($EndMarker, [StringComparison]::Ordinal)
        if ($endIndex -le $startIndex) { throw 'Global AGENTS.md has model-routing markers in invalid order. Resolve them manually before installing.' }
        $before = $Current.Substring(0, $startIndex)
        $after = $Current.Substring($endIndex + $EndMarker.Length)
        if (($before + $after).IndexOf('tom-model-routing-v1', [StringComparison]::Ordinal) -ge 0) {
            throw 'Global AGENTS.md already contains an unmarked tom-model-routing-v1 policy. Resolve the manual migration before installing.'
        }
        return $before + $StartMarker + "`r`n" + $Policy.TrimEnd("`r", "`n") + "`r`n" + $EndMarker + $after
    }
    if ($Current.IndexOf('tom-model-routing-v1', [StringComparison]::Ordinal) -ge 0) {
        throw 'Global AGENTS.md already contains an unmarked tom-model-routing-v1 policy. Resolve the manual migration before installing.'
    }
    if ($Current.Length -eq 0) { return $StartMarker + "`r`n" + $Policy.TrimEnd("`r", "`n") + "`r`n" + $EndMarker + "`r`n" }
    $separator = if ($Current.EndsWith("`n", [StringComparison]::Ordinal)) { "`r`n" } else { "`r`n`r`n" }
    return $Current + $separator + $StartMarker + "`r`n" + $Policy.TrimEnd("`r", "`n") + "`r`n" + $EndMarker + "`r`n"
}

if ([string]::IsNullOrWhiteSpace($CodexHomePath)) {
    $userProfile = if ($env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile) }
    $CodexHomePath = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $userProfile '.codex' }
}
$CodexHomePath = [System.IO.Path]::GetFullPath($CodexHomePath)
$InstallRoot = Join-Path $CodexHomePath 'skills\model-routing'
$GlobalAgentsPath = Join-Path $CodexHomePath 'AGENTS.md'

Assert-SafeExistingAncestors $PackageRoot 'Package source'
foreach ($relative in $ManagedFiles) {
    $source = Join-Path $PackageRoot $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Required package file is missing: $relative" }
    Assert-SafeExistingAncestors $source "Package file $relative"
    Assert-NoReparsePath $source "Package file $relative"
}
Assert-SafeExistingAncestors $CodexHomePath 'Codex home'
if (Test-Path -LiteralPath $InstallRoot) {
    if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) { throw "Installed skill path is not a directory: $InstallRoot" }
    Assert-NoReparsePath $InstallRoot 'Installed skill directory'
}
if (Test-Path -LiteralPath $GlobalAgentsPath) {
    if (-not (Test-Path -LiteralPath $GlobalAgentsPath -PathType Leaf)) { throw "Global AGENTS.md is not a file: $GlobalAgentsPath" }
    Assert-NoReparsePath $GlobalAgentsPath 'Global AGENTS.md'
}

$policy = Read-Utf8File $AssetPath
if ($policy.IndexOf($StartMarker, [StringComparison]::Ordinal) -ge 0 -or $policy.IndexOf($EndMarker, [StringComparison]::Ordinal) -ge 0) {
    throw 'assets/AGENTS.md must contain the policy body only, without model-routing markers.'
}
$currentAgents = if (Test-Path -LiteralPath $GlobalAgentsPath) { Read-Utf8File $GlobalAgentsPath } else { '' }
$mergedAgents = Get-MergedAgentsContent $currentAgents $policy

$changes = @()
if ($mergedAgents -cne $currentAgents) { $changes += [pscustomobject]@{ Kind = 'Global AGENTS.md'; Source = $null; Target = $GlobalAgentsPath; Content = $mergedAgents } }
foreach ($relative in $ManagedFiles) {
    $source = Join-Path $PackageRoot $relative
    $target = Join-Path $InstallRoot $relative
    Assert-SafeExistingAncestors $target "Installed file $relative"
    if ((Test-Path -LiteralPath $target) -and (-not (Test-Path -LiteralPath $target -PathType Leaf))) { throw "Installed target is not a file: $target" }
    $samePath = [string]::Equals([System.IO.Path]::GetFullPath($source), [System.IO.Path]::GetFullPath($target), [StringComparison]::OrdinalIgnoreCase)
    $current = if (Test-Path -LiteralPath $target -PathType Leaf) { Assert-NoReparsePath $target "Installed file $relative"; Read-Utf8File $target } else { $null }
    $desired = Read-Utf8File $source
    if (-not $samePath -and ($null -eq $current -or $current -cne $desired)) { $changes += [pscustomobject]@{ Kind = "Skill file $relative"; Source = $source; Target = $target; Content = $desired } }
}

if ($changes.Count -eq 0) { Write-Output 'model-routing is already installed and current.'; return }
if (-not $PSCmdlet.ShouldProcess($CodexHomePath, 'Install or update model-routing')) { return }

$backupRoot = $null
foreach ($change in $changes) {
    if (Test-Path -LiteralPath $change.Target -PathType Leaf) {
        if ($null -eq $backupRoot) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backupRoot = Join-Path $CodexHomePath ("backups\model-routing-$stamp-" + [Guid]::NewGuid().ToString('N'))
        }
        $backupPath = Join-Path $backupRoot (($change.Target.Substring($CodexHomePath.Length)).TrimStart('\', '/'))
        Assert-SafeExistingAncestors $backupPath 'Backup destination'
        $backupDir = Split-Path -Parent $backupPath
        [System.IO.Directory]::CreateDirectory($backupDir) | Out-Null
        [System.IO.File]::Copy($change.Target, $backupPath, $false)
    }
    Write-Utf8File $change.Target $change.Content
    Write-Output ("Updated " + $change.Kind)
}
if ($backupRoot) { Write-Output "Backed up replaced files to $backupRoot" }
