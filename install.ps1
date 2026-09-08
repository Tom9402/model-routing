[CmdletBinding()]
param([string]$CodexHomePath)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repo = 'Tom9402/model-routing'
$headers = @{ 'User-Agent' = 'model-routing-installer'; 'Accept' = 'application/vnd.github+json' }
$commit = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/commits/main" -Headers $headers -TimeoutSec 60
$revision = [string]$commit.sha
if ($revision -notmatch '^[0-9a-f]{40}$') { throw 'GitHub returned an invalid commit ID.' }
$stage = Join-Path ([IO.Path]::GetTempPath()) ('model-routing-' + [guid]::NewGuid().ToString('N'))
$files = @('SKILL.md', 'assets/AGENTS.md', 'agents/openai.yaml', 'scripts/install.ps1', 'scripts/verify.ps1')
try {
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    foreach ($relative in $files) {
        $target = Join-Path $stage $relative
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$repo/$revision/$relative" -UseBasicParsing -OutFile $target -TimeoutSec 60
    }
    $parameters = @{}
    if ($CodexHomePath) { $parameters.CodexHomePath = $CodexHomePath }
    # Invoke the downloaded script without changing machine execution policy.
    $installer = Join-Path $stage 'scripts/install.ps1'
    $source = [IO.File]::ReadAllText($installer, [Text.Encoding]::UTF8)
    & ([scriptblock]::Create($source)) -PackageRoot $stage @parameters
    if (-not $?) { throw 'Installation failed.' }
    $verifier = [IO.File]::ReadAllText((Join-Path $stage 'scripts/verify.ps1'), [Text.Encoding]::UTF8)
    & ([scriptblock]::Create($verifier)) -PackageRoot $stage @parameters
    if (-not $?) { throw 'Installation verification failed.' }
    Write-Output "Source commit: $revision"
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $resolvedStage = [IO.Path]::GetFullPath($stage)
    if ($resolvedStage.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedStage) -match '^model-routing-[0-9a-f]{32}$' -and
        (Test-Path -LiteralPath $resolvedStage)) {
        Remove-Item -LiteralPath $resolvedStage -Recurse -Force
    }
}
