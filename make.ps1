#!/usr/bin/env pwsh
#
# Cargo-style task entrypoint for the Name Your Summons dev tooling.
#
#   ./make.ps1 setup         download all tooling into .tools/ (gitignored)
#   ./make.ps1 format        format Lua with StyLua (writes changes)
#   ./make.ps1 format-check  verify formatting without writing
#   ./make.ps1 lint          run luacheck
#   ./make.ps1 typecheck     run lua-language-server --check
#   ./make.ps1 test          run the LuaUnit suite
#   ./make.ps1 all           format + lint + typecheck + test (verify locally)
#   ./make.ps1 check         format-check + lint + typecheck + test (what CI runs)
#   ./make.ps1 help          show this text
#
# Every tool is a prebuilt binary fetched on first use into .tools/; nothing
# needs a Rust or Lua build toolchain. Runs under Windows PowerShell 5.1 and
# cross-platform PowerShell 7 (pwsh), so CI invokes the same commands.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = "help",
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$Root = $PSScriptRoot
$ToolsDir = Join-Path $Root ".tools"

# Pinned tool versions - bump deliberately; CI caches .tools by this file's hash.
$V = @{
    StyLua        = "v2.5.2"
    Luacheck      = "v1.2.0"
    LuaLS         = "3.18.2"
    Lua           = "54f813a"
    LuaUnit       = "LUAUNIT_V3_5"
    ExtIdeHelpers = "main"
}

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

function Get-Platform {
    # $IsWindows is $null on Windows PowerShell 5.1, where we are always on Windows.
    if ($null -eq $IsWindows) { return "windows" }
    if ($IsWindows) { return "windows" }
    if ($IsMacOS) { return "macos" }
    return "linux"
}

function Get-Arch {
    if ($env:PROCESSOR_ARCHITECTURE -match "ARM64") { return "arm64" }
    try { if ((uname -m) -match "aarch64|arm64") { return "arm64" } } catch {}
    return "x64"
}

$Plat = Get-Platform
$Arch = Get-Arch
$Exe = if ($Plat -eq "windows") { ".exe" } else { "" }

# ---------------------------------------------------------------------------
# Download helpers
# ---------------------------------------------------------------------------

function Get-File($Url, $OutFile) {
    Write-Host "  fetch $Url"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
}

function Expand-Into($Archive, $Dest) {
    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    if ($Archive -match "\.tar\.gz$") {
        & tar -xzf $Archive -C $Dest
        if ($LASTEXITCODE -ne 0) { throw "tar failed for $Archive" }
    }
    else {
        Expand-Archive -Path $Archive -DestinationPath $Dest -Force
    }
}

function Set-Executable($Path) {
    if ($Plat -ne "windows") { & chmod "+x" $Path }
}

# ---------------------------------------------------------------------------
# Tool installers - each returns the path to the runnable binary
# ---------------------------------------------------------------------------

function Get-StyLua {
    $bin = Join-Path $ToolsDir "stylua/stylua$Exe"
    if (Test-Path $bin) { return $bin }
    Write-Host "Installing StyLua $($V.StyLua)..."
    $archName = if ($Arch -eq "arm64") { "aarch64" } else { "x86_64" }
    $asset = "stylua-$Plat-$archName.zip"
    $tmp = Join-Path $ToolsDir "_stylua.zip"
    Get-File "https://github.com/JohnnyMorganz/StyLua/releases/download/$($V.StyLua)/$asset" $tmp
    Expand-Into $tmp (Join-Path $ToolsDir "stylua")
    Remove-Item $tmp -Force
    Set-Executable $bin
    return $bin
}

function Get-Luacheck {
    $bin = Join-Path $ToolsDir "luacheck/luacheck$Exe"
    if (Test-Path $bin) { return $bin }
    Write-Host "Installing luacheck $($V.Luacheck)..."
    # Standalone luastatic binary, itself built on PUC-Rio Lua 5.4.
    $asset = if ($Plat -eq "windows") { "luacheck.exe" } else { "luacheck" }
    Get-File "https://github.com/lunarmodules/luacheck/releases/download/$($V.Luacheck)/$asset" $bin
    Set-Executable $bin
    return $bin
}

function Get-LuaLS {
    $bin = Join-Path $ToolsDir "lua-language-server/bin/lua-language-server$Exe"
    if (Test-Path $bin) { return $bin }
    Write-Host "Installing lua-language-server $($V.LuaLS)..."
    switch ($Plat) {
        "windows" { $asset = "lua-language-server-$($V.LuaLS)-win32-$Arch.zip"; $tmp = "_luals.zip" }
        "linux" { $asset = "lua-language-server-$($V.LuaLS)-linux-$Arch.tar.gz"; $tmp = "_luals.tar.gz" }
        "macos" { $asset = "lua-language-server-$($V.LuaLS)-darwin-$Arch.tar.gz"; $tmp = "_luals.tar.gz" }
    }
    $tmp = Join-Path $ToolsDir $tmp
    Get-File "https://github.com/LuaLS/lua-language-server/releases/download/$($V.LuaLS)/$asset" $tmp
    Expand-Into $tmp (Join-Path $ToolsDir "lua-language-server")
    Remove-Item $tmp -Force
    Set-Executable $bin
    return $bin
}

# Lua interpreter + the single-file LuaUnit framework.
function Get-Lua {
    $luaDir = Join-Path $ToolsDir "lua"
    $bin = Join-Path $luaDir "lua54$Exe"
    if (-not (Test-Path $bin)) {
        Write-Host "Installing Lua 5.4 interpreter ($($V.Lua))..."
        $base = "https://github.com/dyne/luabinaries/releases/download/$($V.Lua)"
        if ($Plat -eq "windows") {
            Get-File "$base/lua54.exe" $bin
            Get-File "$base/lua54.dll" (Join-Path $luaDir "lua54.dll")
        }
        else {
            $asset = switch ($Plat) {
                "linux" { if ($Arch -eq "arm64") { "lua54-linux-arm64" } else { "lua54" } }
                "macos" { if ($Arch -eq "arm64") { "lua54-macos-arm64" } else { "lua54-macos-x64" } }
            }
            Get-File "$base/$asset" $bin
            Set-Executable $bin
        }
    }
    $luaunit = Join-Path $luaDir "luaunit.lua"
    if (-not (Test-Path $luaunit)) {
        Write-Host "Installing LuaUnit $($V.LuaUnit)..."
        Get-File "https://raw.githubusercontent.com/bluebird75/luaunit/$($V.LuaUnit)/luaunit.lua" $luaunit
    }
    return $bin
}

# BG3SE IDE helpers - the authoritative Ext/Osi type definitions. Dropped into
# the gitignored .luals-libs/ that .luarc.json reads, giving lua-language-server
# real engine types for editor autocomplete and the type check.
function Get-ExtIdeHelpers {
    $lib = Join-Path $Root ".luals-libs/ExtIdeHelpers.lua"
    if (Test-Path $lib) { return $lib }
    Write-Host "Fetching BG3SE IdeHelpers ($($V.ExtIdeHelpers))..."
    Get-File "https://raw.githubusercontent.com/Norbyte/bg3se/$($V.ExtIdeHelpers)/BG3Extender/IdeHelpers/ExtIdeHelpers.lua" $lib
    return $lib
}

# ---------------------------------------------------------------------------
# Commands - each returns a process exit code (0 = ok)
# ---------------------------------------------------------------------------

function Cmd-Format([switch]$Check) {
    $stylua = Get-StyLua
    if ($Check) {
        & $stylua --check . | Out-Host
        return $LASTEXITCODE
    }
    # Write changes in place (no diff); this is the fix-it target.
    & $stylua . | Out-Host
    if ($LASTEXITCODE -eq 0) { Write-Host "Formatted." }
    return $LASTEXITCODE
}

function Cmd-Lint {
    $luacheck = Get-Luacheck
    & $luacheck . | Out-Host
    return $LASTEXITCODE
}

function Cmd-Typecheck {
    $luals = Get-LuaLS
    Get-ExtIdeHelpers | Out-Null
    $log = Join-Path $Root "luals-log"
    if (Test-Path $log) { Remove-Item -Recurse -Force $log }
    # Gate on Error level only: the dynamic Ext/Osi surface produces unavoidable
    # Warnings (undefined-field, API drift) that are useful in an editor but are
    # not failures. Errors are real breakage - syntax and parse failures.
    # --check exits 0 regardless, so parse its summary line for the verdict.
    $out = & $luals --check . --checklevel=Error "--logpath=$log" "--configpath=$(Join-Path $Root '.luarc.json')" 2>&1 | Out-String
    Write-Host $out
    if ($out -match "no problems found") { return 0 }
    if ($out -match "(\d+)\s+problems?\s+found") {
        if ([int]$Matches[1] -gt 0) {
            Write-Host "lua-language-server found $($Matches[1]) error-level problem(s)."
            return 1
        }
        return 0
    }
    Write-Host "lua-language-server: could not parse result; treating as pass."
    return 0
}

function Cmd-Test {
    Get-Lua | Out-Null
    $lua = Join-Path $ToolsDir "lua/lua54$Exe"
    & $lua (Join-Path $Root "spec/run.lua") @Rest | Out-Host
    return $LASTEXITCODE
}

function Cmd-Check {
    $fail = 0
    Write-Host "`n== format-check =="; if ((Cmd-Format -Check) -ne 0) { $fail = 1 }
    Write-Host "`n== lint =="; if ((Cmd-Lint) -ne 0) { $fail = 1 }
    Write-Host "`n== typecheck =="; if ((Cmd-Typecheck) -ne 0) { $fail = 1 }
    Write-Host "`n== test =="; if ((Cmd-Test) -ne 0) { $fail = 1 }
    return $fail
}

# Local verify-and-fix: format writes in place, then the read-only gates run.
# This is the single command to run before considering a change done.
function Cmd-All {
    $fail = 0
    Write-Host "`n== format =="; if ((Cmd-Format) -ne 0) { $fail = 1 }
    Write-Host "`n== lint =="; if ((Cmd-Lint) -ne 0) { $fail = 1 }
    Write-Host "`n== typecheck =="; if ((Cmd-Typecheck) -ne 0) { $fail = 1 }
    Write-Host "`n== test =="; if ((Cmd-Test) -ne 0) { $fail = 1 }
    return $fail
}

function Show-Help {
    Get-Content $PSCommandPath | Select-Object -Skip 2 | ForEach-Object {
        if ($_ -match "^#") { $_ -replace "^# ?", "" } else { return }
    } | Select-Object -First 18 | Out-Host
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

Push-Location $Root
try {
    switch ($Command.ToLower()) {
        "setup" {
            Get-StyLua | Out-Null; Get-Luacheck | Out-Null; Get-LuaLS | Out-Null; Get-Lua | Out-Null
            Get-ExtIdeHelpers | Out-Null
            Write-Host "Tooling ready in .tools/"
            $code = 0
        }
        "format" { $code = Cmd-Format }
        { $_ -in "format-check", "fmt-check", "fmtcheck" } { $code = Cmd-Format -Check }
        "lint" { $code = Cmd-Lint }
        "typecheck" { $code = Cmd-Typecheck }
        "test" { $code = Cmd-Test }
        "all" { $code = Cmd-All }
        { $_ -in "check", "ci" } { $code = Cmd-Check }
        default { Show-Help; $code = 0 }
    }
}
finally {
    Pop-Location
}

exit $code
