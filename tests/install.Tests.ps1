# Standalone regression suite: powershell/pwsh -NoProfile -File tests/install.Tests.ps1
# No Pester, network, user configuration, or writes outside the unique temp sandbox.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$managed = @('SKILL.md', 'assets\AGENTS.md', 'agents\openai.yaml', 'scripts\install.ps1', 'scripts\verify.ps1')
$start = '<!-- model-routing:start -->'
$end = '<!-- model-routing:end -->'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$engine = Join-Path $PSHOME 'pwsh.exe'
if (-not (Test-Path -LiteralPath $engine)) { $engine = Join-Path $PSHOME 'powershell.exe' }
if (-not (Test-Path -LiteralPath $engine)) { $engine = Join-Path $PSHOME 'pwsh' }
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$sandbox = Join-Path $tempParent ('model-routing-tests-' + [Guid]::NewGuid().ToString('N'))
$results = New-Object 'System.Collections.Generic.List[object]'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -cne $Actual) { throw $Message }
}
function Assert-NoLinks([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            Assert-True (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Unsafe reparse path: $cursor"
        }
        $parent = Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}
function Assert-SandboxPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $prefix = $sandbox + [IO.Path]::DirectorySeparatorChar
    Assert-True ($full.Equals($sandbox, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) "Path escapes test sandbox: $full"
    Assert-NoLinks $full
}
function Write-TestFile([string]$Path, [string]$Text) {
    Assert-SandboxPath $Path
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}
function Read-TestFile([string]$Path) { [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) }
function New-TestHome([string]$Name) {
    $path = Join-Path $sandbox $Name
    Assert-SandboxPath $path
    [IO.Directory]::CreateDirectory($path) | Out-Null
    return $path
}
function Get-TreeSnapshot([string]$Root) {
    Assert-SandboxPath $Root
    # Include directories, byte content and file timestamps (also catches backup creation).
    $rows = @(Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName | ForEach-Object {
        Assert-SandboxPath $_.FullName
        $relative = $_.FullName.Substring($Root.Length)
        if ($_.PSIsContainer) { 'D|' + $relative }
        else { 'F|' + $relative + '|' + $_.LastWriteTimeUtc.Ticks + '|' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName)) }
    })
    return ($rows -join "`n")
}
function Invoke-PackageScript([string]$Name, [string]$TargetHome) {
    Assert-SandboxPath $TargetHome
    Assert-True (-not [string]::IsNullOrWhiteSpace($TargetHome)) 'Explicit test home is required.'
    $scriptPath = Join-Path $package ('scripts\' + $Name + '.ps1')
    # Child process isolates verify.ps1's exit and installer function definitions.
    # Explicit parameters and -NoProfile prevent fallback to the real Codex home.
    $command = "`$ErrorActionPreference='Stop'; try { & '" + $scriptPath.Replace("'", "''") + "' -CodexHomePath '" + $TargetHome.Replace("'", "''") + "' -PackageRoot '" + $package.Replace("'", "''") + "'; exit 0 } catch { [Console]::Error.WriteLine(`$_.Exception.Message); exit 1 }"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $engine
    $info.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { $process.Kill(); $process.WaitForExit(); throw "$Name timed out" }
        return [pscustomobject]@{ Code = $process.ExitCode; Text = $stdout.Result + $stderr.Result }
    } finally { $process.Dispose() }
}
function Assert-Success($Result) { Assert-Equal 0 $Result.Code ("Unexpected script failure: " + $Result.Text) }
function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        $results.Add([pscustomobject]@{ Name = $Name; Passed = $true })
        Write-Host "PASS $Name"
    } catch {
        $results.Add([pscustomobject]@{ Name = $Name; Passed = $false })
        Write-Host "FAIL $Name : $($_.Exception.Message)"
    }
}
function Assert-RejectedUnchanged([string]$Name, [string]$Text, [string]$Reason) {
    $targetHome = New-TestHome $Name
    Assert-Success (Invoke-PackageScript 'install' $targetHome)
    Write-TestFile (Join-Path $targetHome 'AGENTS.md') $Text
    # Force a pending installed-file update: rejection must happen before any write.
    Write-TestFile (Join-Path $targetHome 'skills\model-routing\SKILL.md') 'existing customized skill'
    $before = Get-TreeSnapshot $targetHome
    $result = Invoke-PackageScript 'install' $targetHome
    Assert-True ($result.Code -ne 0) 'Installer accepted invalid global rules.'
    Assert-True ($result.Text -match $Reason) ('Failure was not the expected validation: ' + $result.Text)
    Assert-Equal $before (Get-TreeSnapshot $targetHome) 'Rejected install changed target bytes, timestamps, directories or backups.'
}
function Remove-TestSandbox {
    $full = [IO.Path]::GetFullPath($sandbox)
    Assert-Equal $tempParent (Split-Path -Parent $full) 'Cleanup root is not directly under the temporary directory.'
    Assert-True ((Split-Path -Leaf $full) -match '^model-routing-tests-[0-9a-f]{32}$') 'Unexpected cleanup directory name.'
    Assert-SandboxPath $full
    if (-not (Test-Path -LiteralPath $full)) { return }
    # Inspect one level at a time before descending; never follow a junction/symlink.
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($full)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        Assert-SandboxPath $directory
        foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
            Assert-SandboxPath $item.FullName
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
    Remove-Item -LiteralPath $full -Recurse -Force
    Assert-True (-not (Test-Path -LiteralPath $full)) 'Temporary sandbox was not removed.'
}

try {
    Assert-NoLinks $tempParent
    Assert-True (-not (Test-Path -LiteralPath $sandbox)) 'Test sandbox already exists.'
    $package = New-TestHome 'package snapshot'
    # Freeze only managed package inputs; concurrent edits by another task stay untouched.
    foreach ($relative in $managed) {
        $source = Join-Path $repo $relative
        Assert-NoLinks $source
        $destination = Join-Path $package $relative
        Assert-SandboxPath $destination
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        [IO.File]::Copy($source, $destination, $false)
    }
    $policy = Read-TestFile (Join-Path $package 'assets\AGENTS.md')
    $block = $start + "`r`n" + $policy.TrimEnd("`r", "`n") + "`r`n" + $end
    Write-Host "PowerShell $($PSVersionTable.PSVersion); sandbox: $sandbox"

    Test-Case 'Fresh empty home installs and verifies' {
        $h = New-TestHome 'fresh'
        Assert-Success (Invoke-PackageScript 'install' $h)
        Assert-Equal ($block + "`r`n") (Read-TestFile (Join-Path $h 'AGENTS.md')) 'Unexpected managed block.'
        Assert-Success (Invoke-PackageScript 'verify' $h)
    }
    Test-Case 'New installation preserves original global text and backup' {
        $h = New-TestHome 'preserve'
        $original = "# 用户全局指令`n保留 Unicode：中文 / café / 🚀`r`n最后一行无换行  "
        Write-TestFile (Join-Path $h 'AGENTS.md') $original
        Assert-Success (Invoke-PackageScript 'install' $h)
        Assert-Equal ($original + "`r`n`r`n" + $block + "`r`n") (Read-TestFile (Join-Path $h 'AGENTS.md')) 'Original global text was changed.'
        $backups = @(Get-ChildItem -LiteralPath (Join-Path $h 'backups') -Recurse -Filter AGENTS.md)
        Assert-Equal 1 $backups.Count 'Expected one original global backup.'
        Assert-Equal $original (Read-TestFile $backups[0].FullName) 'Backup differs from original.'
        Assert-Success (Invoke-PackageScript 'verify' $h)
    }
    Test-Case 'Repeated installation is a byte and timestamp no-op' {
        $h = New-TestHome 'idempotent'
        Write-TestFile (Join-Path $h 'AGENTS.md') "Existing instructions`n"
        Assert-Success (Invoke-PackageScript 'install' $h)
        $before = Get-TreeSnapshot $h
        Assert-Success (Invoke-PackageScript 'install' $h)
        Assert-Equal $before (Get-TreeSnapshot $h) 'Repeat install changed files or created backups.'
    }
    Test-Case 'Update replaces only managed block, preserving prefix and suffix' {
        $h = New-TestHome 'update'
        Assert-Success (Invoke-PackageScript 'install' $h)
        $prefix = "# 前置指令`nkeep leading content  `r`n"
        $suffix = "`n# 后置指令`r`nkeep trailing content  "
        Write-TestFile (Join-Path $h 'AGENTS.md') ($prefix + $start + "`nold tom-model-routing-v1 policy`n" + $end + $suffix)
        Assert-Success (Invoke-PackageScript 'install' $h)
        Assert-Equal ($prefix + $block + $suffix) (Read-TestFile (Join-Path $h 'AGENTS.md')) 'Update modified text outside the managed block.'
        Assert-Success (Invoke-PackageScript 'verify' $h)
    }
    Test-Case 'Missing end marker refuses without changes' { Assert-RejectedUnchanged 'missing-end' ($start + ' old policy') 'malformed or duplicate' }
    Test-Case 'Missing start marker refuses without changes' { Assert-RejectedUnchanged 'missing-start' ('old policy ' + $end) 'malformed or duplicate' }
    Test-Case 'Reversed markers refuse without changes' { Assert-RejectedUnchanged 'reversed' ($end + $start) 'invalid order' }
    Test-Case 'Duplicate blocks refuse without changes' { Assert-RejectedUnchanged 'duplicates' ($block + "`n" + $block) 'malformed or duplicate' }
    Test-Case 'Unmarked legacy policy refuses without changes' { Assert-RejectedUnchanged 'unmarked' "# Existing rules`ntom-model-routing-v1" 'unmarked' }
    Test-Case 'Legacy policy before block refuses without changes' { Assert-RejectedUnchanged 'legacy-before' ('tom-model-routing-v1' + $block) 'unmarked' }
    Test-Case 'Legacy policy after block refuses without changes' { Assert-RejectedUnchanged 'legacy-after' ($block + 'tom-model-routing-v1') 'unmarked' }
    Test-Case 'Verify detects managed block tampering without writes' {
        $h = New-TestHome 'tamper-block'
        Assert-Success (Invoke-PackageScript 'install' $h)
        Assert-Success (Invoke-PackageScript 'verify' $h)
        Write-TestFile (Join-Path $h 'AGENTS.md') ($start + "`n" + $policy + "`nUnauthorized instruction`n" + $end)
        $before = Get-TreeSnapshot $h
        $result = Invoke-PackageScript 'verify' $h
        Assert-True ($result.Code -ne 0 -and $result.Text -match 'differs from installed') ('Tampering not detected: ' + $result.Text)
        Assert-Equal $before (Get-TreeSnapshot $h) 'Verify modified target.'
    }
    Test-Case 'Verify detects installed file tampering without writes' {
        $h = New-TestHome 'tamper-file'
        Assert-Success (Invoke-PackageScript 'install' $h)
        Assert-Success (Invoke-PackageScript 'verify' $h)
        Write-TestFile (Join-Path $h 'skills\model-routing\SKILL.md') 'tampered'
        $before = Get-TreeSnapshot $h
        $result = Invoke-PackageScript 'verify' $h
        Assert-True ($result.Code -ne 0 -and $result.Text -match 'Different content SKILL.md') ('File tampering not detected: ' + $result.Text)
        Assert-Equal $before (Get-TreeSnapshot $h) 'Verify modified target.'
    }
    # Text-level contract guards, not a claim of semantic proof. Keep independent so
    # in-progress policy edits produce focused failures rather than hiding regressions.
    Test-Case 'Policy does not hard-code old model names' {
        Assert-True ($policy -notmatch '(?i)gpt-5\.6-(?:luna|terra|sol)|gpt-6-astra') 'Policy still contains a fixed legacy model name.'
    }
    Test-Case 'Policy declares the dynamic routing contract version' {
        # dynamic-routing-v2 identifies discovery, joint model/reasoning selection,
        # unknown-information fallback and the shared retry limit. This is a version
        # guard, not semantic verification of prose; review the contract separately.
        Assert-True ($policy -cmatch '(?<![A-Za-z0-9_-])dynamic-routing-v2(?![A-Za-z0-9_-])') 'Missing dynamic-routing-v2 policy contract.'
        Assert-True ($policy -cmatch '(?<![A-Za-z0-9_-])tom-model-routing-v1(?![A-Za-z0-9_-])') 'Missing stable installer policy identifier.'
    }
    Test-Case 'Policy names model and reasoning tool parameters' {
        Assert-True ($policy.Contains('`model`')) 'Missing model tool parameter contract.'
        Assert-True ($policy.Contains('`reasoning_effort`')) 'Missing reasoning_effort tool parameter contract.'
    }
} finally {
    Remove-TestSandbox
    Write-Host 'Temporary sandbox safely removed.'
}
$failed = @($results | Where-Object { -not $_.Passed }).Count
Write-Host ("Results: {0} passed, {1} failed, {2} total." -f ($results.Count - $failed), $failed, $results.Count)
if ($failed -gt 0) { exit 1 }
exit 0