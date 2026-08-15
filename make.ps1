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
#   ./make.ps1 validate-xml  well-formedness of every XAML / meta.lsx / loca.xml
#   ./make.ps1 ascii-check   reject non-ASCII typography in tracked text
#   ./make.ps1 xaml-check    resolve mod XAML keys/controls/pack assets vs the game (or the committed oracle in CI)
#   ./make.ps1 xaml-extract  regenerate the committed xaml-check oracle from the installed game
#   ./make.ps1 loca-check    compile every .loca.xml with divine (Windows only)
#   ./make.ps1 build         pack the mod into build/ (.pak + .zip); -Clean wipes first
#   ./make.ps1 deploy        build, then copy the .pak into BG3's Mods folder
#   ./make.ps1 all           format + lint + typecheck + test + validate-xml + ascii-check
#   ./make.ps1 check         format-check + lint + typecheck + test + validate-xml + ascii-check
#   ./make.ps1 changelog     assemble news/ fragments into CHANGELOG.md (changelogging)
#   ./make.ps1 prepare-release      bump version, changelog, branch, commit, push, open PR
#   ./make.ps1 create-release-tag   tag the release commit and push (fires release.yml)
#   ./make.ps1 help          show this text
#
# Every tool is a prebuilt binary fetched on first use into .tools/; nothing
# needs a Rust or Lua build toolchain. Runs under Windows PowerShell 5.1 and
# cross-platform PowerShell 7 (pwsh), so CI invokes the same commands.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = "help",
    # Installed game's Data folder for xaml-check / xaml-extract, e.g.
    # ./make.ps1 xaml-check -Bg3Data 'C:\...\Data'.
    [string]$Bg3Data,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$Root = $PSScriptRoot
$ToolsDir = Join-Path $Root ".tools"
# Committed HMAC oracle that lets xaml-check run in CI without a game install.
$OracleFile = Join-Path $Root "xaml-oracle.txt"

# Pinned tool versions - bump deliberately; CI caches .tools by this file's hash.
$V = @{
    StyLua        = "v2.5.2"
    Luacheck      = "v1.2.0"
    LuaLS         = "3.18.2"
    Lua           = "54f813a"
    LuaUnit       = "LUAUNIT_V3_5"
    ExtIdeHelpers = "main"
    LSLib         = "v1.20.4"
    Changelogging = "0.7.0"
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

# Norbyte's LSLib CLI (divine.exe) - the packer behind the Modder's Multitool's
# Create Package. Needs the .NET 8 Desktop Runtime to run. The ExportTool zip
# lays divine.exe next to its DLLs; the exact subfolder has shifted between
# releases, so locate it by search rather than a fixed path.
function Get-Divine {
    $lslibDir = Join-Path $ToolsDir "lslib-$($V.LSLib)"
    $existing = Get-ChildItem -Path $lslibDir -Filter "divine.exe" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($existing) { return $existing.FullName }
    Write-Host "Installing LSLib $($V.LSLib)..."
    $asset = "ExportTool-$($V.LSLib).zip"
    $tmp = Join-Path $ToolsDir "_lslib.zip"
    Get-File "https://github.com/Norbyte/lslib/releases/download/$($V.LSLib)/$asset" $tmp
    Expand-Into $tmp $lslibDir
    Remove-Item $tmp -Force
    $divine = Get-ChildItem -Path $lslibDir -Filter "divine.exe" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $divine) {
        throw "divine.exe not found in $asset after extraction - the release layout may have changed."
    }
    return $divine.FullName
}

# Locate a named tool inside the already-vendored LSLib ExportTool. divine.exe,
# StoryCompiler.exe and StatParser.exe all live side by side in Packed/Tools, so
# Get-Divine's download covers them; this just finds one by filename.
function Get-LslibTool($Name) {
    Get-Divine | Out-Null
    $lslibDir = Join-Path $ToolsDir "lslib-$($V.LSLib)"
    $tool = Get-ChildItem -Path $lslibDir -Filter $Name -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $tool) {
        throw "$Name not found in LSLib $($V.LSLib) - the release layout may have changed."
    }
    return $tool.FullName
}

# nekitdev's changelogging CLI - consumes news/ fragments into CHANGELOG.md.
# Prebuilt per-target binaries; the archive layout has the binary at the root,
# but locate it by search to stay robust across releases.
function Get-Changelogging {
    $clDir = Join-Path $ToolsDir "changelogging-$($V.Changelogging)"
    $existing = Get-ChildItem -Path $clDir -Filter "changelogging$Exe" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($existing) { return $existing.FullName }
    Write-Host "Installing changelogging $($V.Changelogging)..."
    $arch = if ($Arch -eq "arm64") { "aarch64" } else { "x86_64" }
    switch ($Plat) {
        "windows" { $triple = "$arch-pc-windows-msvc"; $ext = "zip"; $tmp = "_changelogging.zip" }
        "linux" { $triple = "$arch-unknown-linux-gnu"; $ext = "tar.gz"; $tmp = "_changelogging.tar.gz" }
        "macos" { $triple = "$arch-apple-darwin"; $ext = "tar.gz"; $tmp = "_changelogging.tar.gz" }
    }
    $asset = "changelogging-$($V.Changelogging)-$triple.$ext"
    $tmp = Join-Path $ToolsDir $tmp
    Get-File "https://github.com/nekitdev/changelogging/releases/download/v$($V.Changelogging)/$asset" $tmp
    Expand-Into $tmp $clDir
    Remove-Item $tmp -Force
    $cl = Get-ChildItem -Path $clDir -Filter "changelogging$Exe" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $cl) {
        throw "changelogging binary not found in $asset after extraction - the release layout may have changed."
    }
    Set-Executable $cl.FullName
    return $cl.FullName
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

# Well-formedness of every shipped XML asset (XAML, meta.lsx, loca.xml) via
# System.Xml, so it needs no external tool and runs on both the Ubuntu gate and a
# Windows box (xmllint is not on Windows by default). This proves the XML parses,
# NOT that the Noesis semantics hold (unknown ls:/se: control, bad binding,
# unresolved StaticResource) - see xaml-check for the game-data-backed pass that
# resolves those against the installed game (local-only; not on the CI gate).
function Cmd-ValidateXml {
    $targets = @()
    $guiDir = Join-Path $Root "NameYourSummons/Mods/NameYourSummons/GUI"
    if (Test-Path $guiDir) {
        $targets += Get-ChildItem -Path $guiDir -Filter "*.xaml" -Recurse -ErrorAction SilentlyContinue
    }
    $locaDir = Join-Path $Root "NameYourSummons/Localization"
    if (Test-Path $locaDir) {
        $targets += Get-ChildItem -Path $locaDir -Filter "*.loca.xml" -Recurse -ErrorAction SilentlyContinue
    }
    $meta = Join-Path $Root "NameYourSummons/Mods/NameYourSummons/meta.lsx"
    if (Test-Path $meta) { $targets += Get-Item $meta }

    $fail = 0
    foreach ($file in $targets) {
        try {
            $doc = New-Object System.Xml.XmlDocument
            $doc.XmlResolver = $null # never fetch external DTDs/entities
            $doc.Load($file.FullName)
        }
        catch {
            Write-Host "validate-xml: NOT well-formed: $($file.FullName)"
            Write-Host "  $($_.Exception.Message)"
            $fail = 1
        }
    }
    if ($fail -eq 0) { Write-Host "validate-xml: $($targets.Count) XML file(s) well-formed." }
    return $fail
}

# CI/local port of the .githooks/pre-commit typography rule: reject decorative
# Unicode punctuation in tracked text (see AGENTS.md "Typography"). The hook scans
# staged blobs; this scans the tracked working tree, so CI - which has no staging
# area - enforces the same rule. Keep this extension list in sync with the hook's
# is_text(). loca.xml is excluded on purpose: translations legitimately carry
# non-ASCII punctuation (CJK dashes/quotes/ellipsis, French non-breaking space).
function Cmd-AsciiCheck {
    # U+00A0 U+00B7 U+00D7 U+00F7 U+2013 U+2014 U+2018 U+2019 U+201C U+201D
    # U+2022 U+2026 U+2190-U+21FF arrows U+2260 U+2264 U+2265 U+26A0
    $forbidden = [regex]"[\u00A0\u00B7\u00D7\u00F7\u2013\u2014\u2018\u2019\u201C\u201D\u2022\u2026\u2190-\u21FF\u2260\u2264\u2265\u26A0]"
    $exts = @("*.lua", "*.md", "*.json", "*.lsx", "*.txt", "*.toml", "*.sh", "*.yml", "*.yaml", "*.xaml", "*.ps1")
    $files = & git ls-files @exts ".gitignore" ".githooks/*"
    $fail = 0
    foreach ($file in $files) {
        if ([string]::IsNullOrWhiteSpace($file)) { continue }
        $full = Join-Path $Root $file
        if (-not (Test-Path $full)) { continue }
        $lineNo = 0
        foreach ($line in [System.IO.File]::ReadAllLines($full)) {
            $lineNo++
            if ($forbidden.IsMatch($line)) {
                if ($fail -eq 0) {
                    Write-Host "ascii-check: forbidden Unicode punctuation (use ASCII, see AGENTS.md):"
                }
                Write-Host "  ${file}:${lineNo}"
                $fail = 1
            }
        }
    }
    if ($fail -eq 0) { Write-Host "ascii-check: no forbidden punctuation in tracked text." }
    return $fail
}

# Unpack the game's UI XAML from Game.pak and build the reference universe the mod
# resolves against: every x:Key, every ls:/se:/noesis: control name, and every GUI
# asset path (the Core content root Public/Game/GUI/, extension-stripped and
# lowercased since the URI says .png but the pak holds .DDS). Returns $null on any
# extraction failure so the caller reports it rather than flagging a false cascade.
function Get-GameUniverse([string]$GamePak) {
    $divine = Get-Divine
    $cache = Join-Path $ToolsDir "_bg3ui/Game"
    # Extract fresh each run so a patch that removes a XAML cannot leave a stale
    # definition behind and mask a real miss. Fast (<1s).
    if (Test-Path $cache) { Remove-Item -Recurse -Force $cache }
    New-Item -ItemType Directory -Force $cache | Out-Null
    & $divine -g bg3 -a extract-package -s $GamePak -d $cache -x "*.xaml" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "xaml-check: divine failed to extract Game.pak (exit $LASTEXITCODE)."; return $null }
    $gameXaml = Get-ChildItem $cache -Recurse -Filter "*.xaml" -ErrorAction SilentlyContinue
    if (-not $gameXaml) { Write-Host "xaml-check: divine extracted no game XAML - cannot validate."; return $null }

    $keys = [System.Collections.Generic.HashSet[string]]::new()
    $controls = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($f in @($gameXaml)) {
        $text = [System.IO.File]::ReadAllText($f.FullName)
        foreach ($m in [regex]::Matches($text, 'x:Key="([^"]+)"')) { [void]$keys.Add($m.Groups[1].Value) }
        foreach ($m in [regex]::Matches($text, '(?:<|x:Type\s+)((?:ls|se|noesis):[A-Za-z0-9_]+)')) { [void]$controls.Add($m.Groups[1].Value) }
    }

    $assets = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($line in (& $divine -g bg3 -a list-package -s $GamePak 2>$null)) {
        $p = (($line -split "`t")[0]).ToLowerInvariant()
        if ($p -like "public/game/gui/*") { [void]$assets.Add(([System.IO.Path]::ChangeExtension($p, $null)).TrimEnd('.')) }
    }
    if ($assets.Count -eq 0) { Write-Host "xaml-check: no GUI assets from list-package - cannot validate assets."; return $null }
    return @{ Keys = $keys; Controls = $controls; Assets = $assets }
}

# 128-bit keyed digest of one identifier. Truncating HMAC-SHA-256 to 16 bytes
# keeps the committed oracle lean; collision odds for a membership test are
# negligible. The salt makes the oracle irreversible - short game identifiers
# would otherwise be trivially recovered from a bare hash by dictionary attack.
function Get-OracleDigest([System.Security.Cryptography.HMAC]$Hmac, [string]$Value) {
    $digest = $Hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
    return [System.BitConverter]::ToString($digest, 0, 16).Replace('-', '').ToLowerInvariant()
}

# Local step (needs the installed game + divine): hash the game's UI identifier
# universe into the committed HMAC oracle so xaml-check can run in CI without a
# game install. Regenerate after a game patch. The salt lives in
# $env:NYS_XAML_ORACLE_SALT and must match the one CI uses.
function Cmd-XamlExtract {
    if (-not $Bg3Data) { Write-Host "xaml-extract: pass -Bg3Data <the game's Data folder>."; return 1 }
    $gamePak = Join-Path $Bg3Data "Game.pak"
    if (-not (Test-Path $gamePak)) { Write-Host "xaml-extract: no Game.pak under -Bg3Data '$Bg3Data'."; return 1 }
    $salt = $env:NYS_XAML_ORACLE_SALT
    if (-not $salt) { Write-Host "xaml-extract: set `$env:NYS_XAML_ORACLE_SALT to the shared oracle salt first."; return 1 }

    $universe = Get-GameUniverse $gamePak
    if (-not $universe) { return 1 }

    $hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($salt))
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $universe.Keys) { $lines.Add("key " + (Get-OracleDigest $hmac $k)) }
    foreach ($c in $universe.Controls) { $lines.Add("ctl " + (Get-OracleDigest $hmac $c)) }
    foreach ($a in $universe.Assets) { $lines.Add("asset " + (Get-OracleDigest $hmac $a)) }
    $hmac.Dispose()

    $header = @(
        '# Name Your Summons xaml-check oracle. Keyed HMAC-SHA-256 (128-bit) of the',
        "# game's UI resource keys, ls:/se:/noesis: control names, and GUI asset paths,",
        '# salted by $env:NYS_XAML_ORACLE_SALT. Contains NO readable game data.',
        "# Regenerate after a game patch: ./make.ps1 xaml-extract -Bg3Data '<Data>'."
    )
    Set-Content -Path $OracleFile -Value ($header + ($lines | Sort-Object)) -Encoding ascii
    Write-Host "xaml-extract: wrote $($lines.Count) entries ($($universe.Keys.Count) keys, $($universe.Controls.Count) controls, $($universe.Assets.Count) assets) to $OracleFile."
    return 0
}

# Resolve the mod's XAML StaticResource/DynamicResource keys, ls:/se:/noesis:
# controls, and pack:// assets against the game's real UI, catching the "unresolved
# resource / typo'd asset" class validate-xml cannot. The universe comes either
# live from -Bg3Data (exact, always current) or from the committed HMAC oracle +
# $env:NYS_XAML_ORACLE_SALT (the CI path, no game install). With neither available
# (e.g. a fork with no secret) it skips cleanly so it never blocks a build it
# cannot run. Only the game can confirm the runtime binding semantics.
function Cmd-XamlCheck {
    $modXaml = Get-ChildItem (Join-Path $Root "NameYourSummons") -Recurse -Filter "*.xaml" -ErrorAction SilentlyContinue
    if (-not $modXaml) { Write-Host "xaml-check: no mod XAML found."; return 0 }

    $salt = $env:NYS_XAML_ORACLE_SALT
    if ($Bg3Data) {
        $gamePak = Join-Path $Bg3Data "Game.pak"
        if (-not (Test-Path $gamePak)) { Write-Host "xaml-check: no Game.pak under -Bg3Data '$Bg3Data'."; return 1 }
        $universe = Get-GameUniverse $gamePak
        if (-not $universe) { return 1 }
        $keyMember = { param($v) $universe.Keys.Contains($v) }
        $controlMember = { param($v) $universe.Controls.Contains($v) }
        $assetMember = { param($v) $universe.Assets.Contains($v) }
        $source = "the installed game"
    }
    elseif ((Test-Path $OracleFile) -and $salt) {
        $keyHashes = [System.Collections.Generic.HashSet[string]]::new()
        $controlHashes = [System.Collections.Generic.HashSet[string]]::new()
        $assetHashes = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($line in [System.IO.File]::ReadAllLines($OracleFile)) {
            $parts = $line -split ' ', 2
            switch ($parts[0]) {
                "key" { [void]$keyHashes.Add($parts[1]) }
                "ctl" { [void]$controlHashes.Add($parts[1]) }
                "asset" { [void]$assetHashes.Add($parts[1]) }
            }
        }
        $hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($salt))
        $keyMember = { param($v) $keyHashes.Contains((Get-OracleDigest $hmac $v)) }
        $controlMember = { param($v) $controlHashes.Contains((Get-OracleDigest $hmac $v)) }
        $assetMember = { param($v) $assetHashes.Contains((Get-OracleDigest $hmac $v)) }
        $source = "the committed oracle"
    }
    else {
        Write-Host "xaml-check: no -Bg3Data and no oracle+salt - skipping (pass -Bg3Data or set NYS_XAML_ORACLE_SALT)."
        return 0
    }

    # A key resolves if it is defined in the mod's own XAML (mod-local x:Key is
    # legitimate) or exists in the game universe.
    $modKeys = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($f in @($modXaml)) {
        foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($f.FullName), 'x:Key="([^"]+)"')) { [void]$modKeys.Add($m.Groups[1].Value) }
    }

    $keyErrors = @()
    $assetErrors = @()
    $controlWarnings = @()
    foreach ($f in $modXaml) {
        $text = [System.IO.File]::ReadAllText($f.FullName)
        foreach ($m in [regex]::Matches($text, '(?:Static|Dynamic)Resource\s+([A-Za-z0-9_]+)')) {
            $key = $m.Groups[1].Value
            if (-not $modKeys.Contains($key) -and -not (& $keyMember $key)) { $keyErrors += "$($f.Name): unresolved resource key '$key'" }
        }
        foreach ($m in [regex]::Matches($text, '(?:<|x:Type\s+)((?:ls|se|noesis):[A-Za-z0-9_]+)')) {
            $ctl = $m.Groups[1].Value
            if (-not (& $controlMember $ctl)) { $controlWarnings += "$($f.Name): control '$ctl' not seen in game XAML" }
        }
        foreach ($m in [regex]::Matches($text, 'pack://application:,,,/Core;component/([^"'' <>]+)')) {
            $rel = ([System.IO.Path]::ChangeExtension($m.Groups[1].Value, $null)).TrimEnd('.')
            if (-not (& $assetMember "public/game/gui/$rel".ToLowerInvariant())) {
                $assetErrors += "$($f.Name): missing pack asset 'Core;component/$($m.Groups[1].Value)'"
            }
        }
    }

    foreach ($w in ($controlWarnings | Select-Object -Unique)) { Write-Host "xaml-check: WARNING $w" }
    $errors = @($keyErrors) + @($assetErrors) | Select-Object -Unique
    foreach ($e in $errors) { Write-Host "xaml-check: ERROR $e" }
    if ($errors.Count -gt 0) { return 1 }
    Write-Host "xaml-check: $($modXaml.Count) mod XAML file(s) resolve against $source - keys, controls, and pack assets OK."
    return 0
}

# Compile every Localization/**/*.loca.xml with divine to a throwaway dir,
# failing on any malformed table. Same conversion the build stages, run in
# isolation so a bad loca is caught without a full pack. divine's CLI crashes on
# POSIX paths (TryToValidatePath), so this is a Windows-side gate.
function Cmd-LocaCheck {
    if ($Plat -ne "windows") {
        Write-Host "loca-check: divine's CLI only runs on Windows (POSIX paths crash it) - skipping."
        return 0
    }
    $locaRoot = Join-Path $Root "NameYourSummons/Localization"
    if (-not (Test-Path $locaRoot)) { Write-Host "loca-check: no Localization/ - nothing to check."; return 0 }
    $xmls = @(Get-ChildItem -Path $locaRoot -Filter "*.loca.xml" -Recurse -ErrorAction SilentlyContinue)
    if (-not $xmls) { Write-Host "loca-check: no .loca.xml files."; return 0 }
    $divine = Get-Divine
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "nys-loca-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $fail = 0
    try {
        foreach ($xml in $xmls) {
            $out = Join-Path $tmp ("$($xml.Directory.Name)-$($xml.Name).loca")
            & $divine --game bg3 --action convert-loca --source $xml.FullName --destination $out --loglevel warn
            if ($LASTEXITCODE -ne 0) {
                Write-Host "loca-check: convert-loca FAILED for $($xml.FullName)"
                $fail = 1
            }
        }
    }
    finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($fail -eq 0) { Write-Host "loca-check: $($xmls.Count) file(s) compiled cleanly." }
    return $fail
}

function Cmd-Check {
    $fail = 0
    Write-Host "`n== format-check =="; if ((Cmd-Format -Check) -ne 0) { $fail = 1 }
    Write-Host "`n== lint =="; if ((Cmd-Lint) -ne 0) { $fail = 1 }
    Write-Host "`n== typecheck =="; if ((Cmd-Typecheck) -ne 0) { $fail = 1 }
    Write-Host "`n== test =="; if ((Cmd-Test) -ne 0) { $fail = 1 }
    Write-Host "`n== validate-xml =="; if ((Cmd-ValidateXml) -ne 0) { $fail = 1 }
    Write-Host "`n== ascii-check =="; if ((Cmd-AsciiCheck) -ne 0) { $fail = 1 }
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
    Write-Host "`n== validate-xml =="; if ((Cmd-ValidateXml) -ne 0) { $fail = 1 }
    Write-Host "`n== ascii-check =="; if ((Cmd-AsciiCheck) -ne 0) { $fail = 1 }
    return $fail
}

# Decode the mod's packed Version64 for self-identifying artefacts. BG3 packs
# major.minor.revision.build; the trailing build field is dropped when zero. The
# top-level <version> node is the LSX file-format version, not the mod's.
function Get-ModVersion($MetaPath) {
    try {
        $node = Select-Xml -Path $MetaPath -XPath "//attribute[@id='Version64']" | Select-Object -First 1
        $packed = [int64]$node.Node.value
        $major = ($packed -shr 55) -band 0x7f
        $minor = ($packed -shr 47) -band 0xff
        $revision = ($packed -shr 31) -band 0xffff
        $build = $packed -band 0x7fffffff
        if ($build -ne 0) { return "$major.$minor.$revision.$build" }
        return "$major.$minor.$revision"
    }
    catch {
        Write-Warning "Could not read version from meta.lsx: $($_.Exception.Message)"
        return "0.0.0"
    }
}

# Absolute path to the mod manifest that carries the version.
function Get-MetaPath {
    $modName = "NameYourSummons"
    return (Join-Path $Root "$modName/Mods/$modName/meta.lsx")
}

# Encode a semantic version (X.Y.Z) into BG3's packed Version64 int64 - the
# inverse of Get-ModVersion (major<<55 | minor<<47 | revision<<31 | build).
# Releases carry a zero build field, so only the first three fields are set.
function ConvertTo-Version64([string]$SemVer) {
    $parts = $SemVer -split "\."
    if ($parts.Count -ne 3) { throw "version '$SemVer' is not X.Y.Z" }
    $major = [int64]$parts[0]
    $minor = [int64]$parts[1]
    $revision = [int64]$parts[2]
    return ($major -shl 55) -bor ($minor -shl 47) -bor ($revision -shl 31)
}

# Repoint every Version64 attribute in meta.lsx (the ModuleInfo node and its
# nested PublishVersion) at the packed value. A targeted regex keeps the file's
# formatting and UTF-8 (no BOM) encoding intact.
function Set-ModVersion([string]$MetaPath, [string]$SemVer) {
    $packed = ConvertTo-Version64 $SemVer
    $content = Get-Content -Raw -Path $MetaPath
    $updated = [regex]::Replace(
        $content,
        '(id="Version64" type="int64" value=")\d+(")',
        "`${1}$packed`${2}"
    )
    [System.IO.File]::WriteAllText($MetaPath, $updated, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------------------
# Git helpers for the release commands - each throws on a non-zero git exit so
# a failed step aborts the release rather than silently continuing.
# ---------------------------------------------------------------------------

function Invoke-GitOut([string[]]$GitArgs) {
    $out = & git @GitArgs
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed with exit code $LASTEXITCODE" }
    return ($out | Out-String).Trim()
}

function Invoke-Git([string[]]$GitArgs) {
    & git @GitArgs | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed with exit code $LASTEXITCODE" }
}

# git show-ref exits 0 when the ref exists, non-zero otherwise.
function Test-GitRef([string]$Ref) {
    & git show-ref --verify --quiet $Ref *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-GitCount([string]$Range) {
    $n = & git rev-list --count $Range
    if ($LASTEXITCODE -ne 0) { throw "git rev-list --count $Range failed with exit code $LASTEXITCODE" }
    return [int](($n | Out-String).Trim())
}

function Read-Prompt([string]$Message) {
    return (Read-Host -Prompt $Message).Trim()
}

# Compile every Localization/**/*.loca.xml in the stage into a sibling binary
# .loca (what the game loads) and drop the .xml so it does not ship. Runs on the
# STAGE copy, so no binaries are produced in the source tree.
function Convert-StageLoca($Divine, $Stage) {
    $locaRoot = Join-Path $Stage "Localization"
    if (-not (Test-Path $locaRoot)) { return }
    $xmls = Get-ChildItem -Path $locaRoot -Filter "*.loca.xml" -Recurse -ErrorAction SilentlyContinue
    foreach ($xml in $xmls) {
        $out = $xml.FullName -replace '\.loca\.xml$', '.loca'
        & $Divine --game bg3 --action convert-loca --source $xml.FullName --destination $out --loglevel warn
        if ($LASTEXITCODE -ne 0) {
            throw "divine convert-loca failed for $($xml.FullName) (exit $LASTEXITCODE)"
        }
        Remove-Item $xml.FullName -Force
    }
}

# After packing, list the pak and assert the members that prove the build wired
# up: the manifest, at least one COMPILED .loca (not the .xml source), and the UI
# page. Guards the empty/partial-pak and loca-did-not-compile regressions on top
# of the raw size check. Tolerant of a quiet list-package (never false-fails on a
# logging quirk); still catches a genuinely missing member.
function Assert-PakContents($Divine, $Pak) {
    $listing = (& $Divine --game bg3 --action list-package --source $Pak 2>&1 | Out-String)
    $listExit = $LASTEXITCODE
    if ($listExit -ne 0) {
        throw "verify-pak: list-package failed (exit ${listExit}): $listing"
    }
    if ([string]::IsNullOrWhiteSpace($listing)) {
        Write-Warning "verify-pak: list-package produced no output; skipping the membership check."
        return
    }
    foreach ($member in @("meta.lsx", "Examine.xaml")) {
        if ($listing -notmatch [regex]::Escape($member)) {
            throw "verify-pak: packed .pak is missing expected member '$member'"
        }
    }
    if ($listing -notmatch "NameYourSummons\.loca") {
        throw "verify-pak: packed .pak has no compiled .loca - localisation did not compile"
    }
    Write-Host "verify-pak: meta.lsx, Examine.xaml, and a compiled .loca are present."
}

# Pack the mod into build/ via divine.exe, exactly like the Modder's Multitool
# Create Package. Pass -Clean (via `./make.ps1 build -Clean`) to wipe build/ first.
function Cmd-Build {
    $clean = @($Rest) -match "^-{0,2}[Cc]lean$"
    $modName = "NameYourSummons"
    $sourceDir = Join-Path $Root $modName
    $buildDir = Join-Path $Root "build"
    $meta = Join-Path $sourceDir "Mods/$modName/meta.lsx"
    if (-not (Test-Path $meta)) {
        Write-Host "Source folder '$sourceDir' does not look like the mod (no Mods/$modName/meta.lsx)."
        return 1
    }

    if ($clean -and (Test-Path $buildDir)) { Remove-Item $buildDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

    $version = Get-ModVersion $meta
    $pak = Join-Path $buildDir "$modName-$version.pak"
    $zipOut = Join-Path $buildDir "$modName-$version.zip"
    $divine = Get-Divine

    # divine drops any file whose ABSOLUTE path has a dot-segment (e.g. a .paseo
    # worktree) and offers no flag to disable it, silently emitting an empty pak.
    # Stage into a dot-free temp dir and pack from there.
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) "nys-build-$([Guid]::NewGuid().ToString('N'))"
    if ($stage -split '[\\/]' | Where-Object { $_.StartsWith('.') }) {
        throw "Temp path '$stage' contains a dot-segment; divine would exclude all files. Set a TEMP without leading-dot folders."
    }

    Write-Host "Packing $modName $version ..."
    try {
        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        Copy-Item -Path (Join-Path $sourceDir "*") -Destination $stage -Recurse -Force
        Convert-StageLoca $divine $stage
        & $divine --game bg3 --action create-package --source $stage --destination $pak --loglevel warn
        if ($LASTEXITCODE -ne 0) {
            throw "divine.exe failed with exit code $LASTEXITCODE. If it complained about a missing runtime, install the .NET 8 Desktop Runtime: https://dotnet.microsoft.com/download/dotnet/8.0"
        }
    }
    finally {
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ((Get-Item $pak).Length -le 64) {
        throw "Packed .pak is empty ($((Get-Item $pak).Length) bytes) - divine found no files to include."
    }

    Assert-PakContents $divine $pak

    if (Test-Path $zipOut) { Remove-Item $zipOut -Force }
    Compress-Archive -Path $pak -DestinationPath $zipOut

    Write-Host ""
    Write-Host "Built:"
    Write-Host "  $pak"
    Write-Host "  $zipOut"
    return 0
}

# The folder BG3 loads .pak mods from. It lives under %LOCALAPPDATA% (AppData\
# Local), NOT %APPDATA% (Roaming) - the Script Extender and the game both read
# mods from here.
function Get-Bg3ModsDir {
    if (-not $env:LOCALAPPDATA) { return $null }
    return (Join-Path $env:LOCALAPPDATA "Larian Studios/Baldur's Gate 3/Mods")
}

# Build the mod, then drop the packed .pak into the game's Mods folder so BG3
# loads it on next launch. Passes through -Clean to the build step.
function Cmd-Deploy {
    $buildCode = Cmd-Build
    if ($buildCode -ne 0) { return $buildCode }

    $modName = "NameYourSummons"
    $meta = Get-MetaPath
    $version = Get-ModVersion $meta
    $pak = Join-Path $Root "build/$modName-$version.pak"
    if (-not (Test-Path $pak)) {
        Write-Host "Expected packed mod '$pak' but it is missing - build did not produce it."
        return 1
    }

    $modsDir = Get-Bg3ModsDir
    if (-not $modsDir) {
        Write-Host "%LOCALAPPDATA% is not set - deploy targets a Windows BG3 install."
        return 1
    }
    if (-not (Test-Path $modsDir)) {
        Write-Host "BG3 Mods folder not found at '$modsDir'. Is Baldur's Gate 3 installed for this user?"
        return 1
    }

    $dest = Join-Path $modsDir "$modName-$version.pak"
    Copy-Item -Path $pak -Destination $dest -Force
    Write-Host ""
    Write-Host "Deployed:"
    Write-Host "  $dest"
    return 0
}

# Assemble the pending news/ fragments into CHANGELOG.md via changelogging.
# The version (source of truth: meta.lsx) is synced into changelogging.toml
# first so the new section is headed with the version being released.
function Cmd-Changelog {
    $meta = Get-MetaPath
    $version = Get-ModVersion $meta
    Write-Host "Generating changelog for version $version"

    $configPath = Join-Path $Root "changelogging.toml"
    $config = Get-Content -Raw -Path $configPath
    $updated = [regex]::Replace($config, '(?m)^version = ".*"$', "version = `"$version`"")
    [System.IO.File]::WriteAllText($configPath, $updated, (New-Object System.Text.UTF8Encoding($false)))

    $cl = Get-Changelogging
    & $cl build --remove | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "changelogging build --remove failed with exit code $LASTEXITCODE" }
    return 0
}

# Suggest the next version and release type from the current branch:
# main -> minor bump; *-maintenance -> patch bump.
function Get-SuggestedVersion([string]$Current, [string]$Branch) {
    $p = $Current -split "\."
    $maj = [int]$p[0]; $min = [int]$p[1]; $pat = [int]$p[2]
    if ($Branch -eq "main") {
        return @{ Type = "minor"; Version = "$maj.$($min + 1).0" }
    }
    elseif ($Branch -like "*-maintenance") {
        return @{ Type = "patch"; Version = "$maj.$min.$($pat + 1)" }
    }
    else {
        throw "must be on 'main' or a '*-maintenance' branch to prepare a release (current branch: $Branch)"
    }
}

# Most significant component that changed between two versions.
function Get-ReleaseType([string]$Current, [string]$Next) {
    $c = $Current -split "\."; $n = $Next -split "\."
    if ([int]$n[0] -gt [int]$c[0]) { return "major" }
    elseif ([int]$n[1] -gt [int]$c[1]) { return "minor" }
    else { return "patch" }
}

# Ensure the maintenance branch exists and is checked out before a release
# prepared from main. Fetches once (fatal on failure - every subsequent
# decision depends on origin refs being current), then handles the four
# (local exists, origin exists) combinations.
function Assert-MaintenanceBranchReady([string]$Branch) {
    Write-Host "INFO - Fetching origin to check maintenance branch state"
    Invoke-Git @("fetch")
    $local = Test-GitRef "refs/heads/$Branch"
    $origin = Test-GitRef "refs/remotes/origin/$Branch"
    if (-not $local -and -not $origin) {
        Write-Host "INFO - Maintenance branch $Branch does not exist; creating from current HEAD and pushing to origin"
        Invoke-Git @("checkout", "-b", $Branch)
        Invoke-Git @("push", "-u", "origin", $Branch)
    }
    elseif ($local -and -not $origin) {
        Write-Host "INFO - Maintenance branch $Branch exists locally only; switching to it and pushing to origin"
        Invoke-Git @("checkout", $Branch)
        Invoke-Git @("push", "-u", "origin", $Branch)
    }
    elseif (-not $local -and $origin) {
        Write-Host "INFO - Maintenance branch $Branch exists on origin only; creating a local tracking branch"
        Invoke-Git @("checkout", $Branch)
    }
    else {
        Write-Host "INFO - Maintenance branch $Branch exists locally and on origin; switching to local branch"
        Invoke-Git @("checkout", $Branch)
        $behind = Get-GitCount "HEAD..origin/$Branch"
        if ($behind -gt 0) {
            throw "local maintenance branch $Branch is $behind commit(s) behind origin - run 'git pull' first"
        }
        # Unpushed local commits would otherwise leak into the release PR.
        $ahead = Get-GitCount "origin/$Branch..HEAD"
        if ($ahead -gt 0) {
            throw "local maintenance branch $Branch is $ahead commit(s) ahead of origin - push it before preparing a release"
        }
    }
}

# Prepare a new release: bump the version, generate the changelog, commit, and
# push. A major/minor release from main branches off release-X.Y.Z and opens a
# PR against the X.Y-maintenance branch (created if missing); a patch release
# commits straight onto the maintenance branch.
function Cmd-PrepareRelease {
    $status = Invoke-GitOut @("status", "--porcelain")
    if ($status -ne "") {
        throw "git working directory is not clean - commit or stash changes first:`n$status"
    }

    $branch = Invoke-GitOut @("branch", "--show-current")
    $meta = Get-MetaPath
    $current = Get-ModVersion $meta
    Write-Host "INFO - Current branch: $branch"
    Write-Host "INFO - Current version: $current"

    $suggest = Get-SuggestedVersion $current $branch
    $answer = Read-Prompt "Preparing $($suggest.Type) release: $current -> $($suggest.Version). Continue? [Y/n]"
    if ($answer -match "^(n|no)$") {
        $custom = Read-Prompt "Enter custom version (current: $current)"
        if ($custom -eq "") { throw "version cannot be empty" }
        if ($custom -notmatch "^\d+\.\d+\.\d+$") {
            throw "invalid version format - use semantic versioning (e.g. 1.2.3)"
        }
        $next = $custom
        $type = Get-ReleaseType $current $next
    }
    elseif ($answer -eq "" -or $answer -match "^(y|yes)$") {
        $next = $suggest.Version
        $type = $suggest.Type
    }
    else {
        throw "invalid input - please enter Y or n"
    }

    $fromMain = ($branch -eq "main")
    $opensPr = $fromMain -and ($type -in @("major", "minor"))
    $nparts = $next -split "\."
    $maintenance = if ($fromMain) { "$($nparts[0]).$($nparts[1])-maintenance" } else { $branch }
    $prBranch = if ($opensPr) { "release-$next" } else { $null }

    Write-Host "INFO - Preparing $type release: $current -> $next"
    Write-Host "INFO - Maintenance branch: $maintenance"

    if ($fromMain) { Assert-MaintenanceBranchReady $maintenance }
    if ($prBranch) {
        Write-Host "INFO - Creating release branch: $prBranch"
        Invoke-Git @("checkout", "-b", $prBranch)
    }

    Write-Host "INFO - Updating meta.lsx version to $next"
    Set-ModVersion $meta $next

    Write-Host "INFO - Generating changelog"
    Cmd-Changelog | Out-Null

    # Stage `news` too: changelogging consumed the fragments, and the version
    # bump must commit those deletions, not leave them dangling in the tree.
    $metaRel = "NameYourSummons/Mods/NameYourSummons/meta.lsx"
    Invoke-Git @("add", $metaRel, "CHANGELOG.md", "changelogging.toml", "news")
    Write-Host "INFO - Committing: Version $next"
    Invoke-Git @("commit", "-m", "Version $next")

    if ($prBranch) {
        Write-Host "INFO - Pushing release branch: $prBranch"
        Invoke-Git @("push", "-u", "origin", $prBranch)
        Write-Host "INFO - Opening PR against $maintenance"
        & gh pr create --base $maintenance --fill | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "gh pr create --base $maintenance failed with exit code $LASTEXITCODE" }
        Write-Host "INFO - Release $next prepared on branch $prBranch with a PR against $maintenance"
        Write-Host "INFO - After the PR is merged, switch to $maintenance, pull, and run './make.ps1 create-release-tag'"
    }
    else {
        Write-Host "INFO - Pushing to remote"
        Invoke-Git @("push")
        Write-Host "INFO - Release $next prepared on branch $maintenance"
        Write-Host "INFO - Run './make.ps1 create-release-tag' to tag the release"
    }
    return 0
}

# Create and push the annotated tag for the version recorded in meta.lsx. The
# tag push is what fires the release workflow. Validates the branch, the tag is
# new, the HEAD commit is the version bump, and the branch is not behind origin.
function Cmd-CreateReleaseTag {
    $branch = Invoke-GitOut @("branch", "--show-current")
    if ($branch -notlike "*-maintenance") {
        throw "must be on a maintenance branch to create a release tag (current branch: $branch) - run './make.ps1 prepare-release' first"
    }

    $meta = Get-MetaPath
    $version = Get-ModVersion $meta
    Write-Host "INFO - Current branch: $branch"
    Write-Host "INFO - Version to tag: $version"

    $existing = Invoke-GitOut @("tag", "-l", $version)
    if ($existing -ne "") { throw "tag $version already exists" }

    $subject = Invoke-GitOut @("log", "-1", "--pretty=format:%s")
    if ($subject -ne "Version $version") {
        throw "latest commit message does not match expected version commit`nexpected: Version $version`nactual:   $subject`nrun './make.ps1 prepare-release' first"
    }

    Write-Host "INFO - Fetching latest changes from remote"
    try { Invoke-Git @("fetch") } catch { Write-Warning "Failed to fetch from remote, continuing anyway: $($_.Exception.Message)" }

    $behind = Get-GitCount "HEAD..origin/$branch"
    if ($behind -gt 0) { throw "local branch is $behind commit(s) behind remote - run 'git pull' first" }

    $answer = Read-Prompt "About to create and push tag '$version'. Continue? [Y/n]"
    if ($answer -match "^(n|no)$") { Write-Host "INFO - Tag creation cancelled"; return 0 }

    Write-Host "INFO - Creating annotated tag: $version"
    Invoke-Git @("tag", "-a", $version, "-m", "Version $version")
    Write-Host "INFO - Pushing tag to remote"
    Invoke-Git @("push", "origin", $version)
    Write-Host "INFO - Tag '$version' created and pushed"
    Write-Host "INFO - Check: https://github.com/whme/bg3-name-your-summons/actions/workflows/release.yml"
    return 0
}

function Show-Help {
    # Print the header banner (lines 3+); the first non-comment line ends it.
    foreach ($line in (Get-Content $PSCommandPath | Select-Object -Skip 2)) {
        if ($line -notmatch "^#") { break }
        Write-Host ($line -replace "^# ?", "")
    }
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
        { $_ -in "validate-xml", "xml-check" } { $code = Cmd-ValidateXml }
        { $_ -in "ascii-check", "ascii" } { $code = Cmd-AsciiCheck }
        { $_ -in "xaml-check", "xamlcheck" } { $code = Cmd-XamlCheck }
        { $_ -in "xaml-extract", "xamlextract" } { $code = Cmd-XamlExtract }
        { $_ -in "loca-check", "loca" } { $code = Cmd-LocaCheck }
        "build" { $code = Cmd-Build }
        "deploy" { $code = Cmd-Deploy }
        "all" { $code = Cmd-All }
        { $_ -in "check", "ci" } { $code = Cmd-Check }
        "changelog" { $code = Cmd-Changelog }
        { $_ -in "prepare-release", "prepare_release" } { $code = Cmd-PrepareRelease }
        { $_ -in "create-release-tag", "create_release_tag" } { $code = Cmd-CreateReleaseTag }
        default { Show-Help; $code = 0 }
    }
}
finally {
    Pop-Location
}

exit $code
