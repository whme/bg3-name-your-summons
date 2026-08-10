# Exploring Baldur's Gate 3 internals

The game's own files are the ground truth for how it is built - its UI XAML,
templates, stats, localisation, and metadata. When a task depends on that (native
UI, stats, templates), **read the installed game's files instead of guessing from
wikis, which lag behind patches.** This repo already downloads the only tool
needed - LSLib's `divine.exe`, used by `make.ps1 build` - so you can unpack and
inspect BG3's `.pak` files yourself, no manual step from the user.

## Where the game lives

Default Steam install (ask the user if it differs - GOG and non-default Steam
libraries move it):

```
C:\Program Files (x86)\Steam\steamapps\common\Baldurs Gate 3\
  Data\
    Game.pak          <- the UI lives here (Mods/MainUI/GUI/...)
    Gustav.pak, Shared.pak, ... <- content, stats, templates, localisation
```

Everything the game loads is in a `.pak` under `Data\`. To find which pak holds
what, list its contents and grep the paths - do not assume.

## The tool: `divine.exe`

`divine.exe` is Norbyte's LSLib CLI - the packer the BG3 Modder's Multitool
wraps. `make.ps1` fetches a pinned copy into `.tools\` (run `./make.ps1 setup`
once if it is missing). Locate it without hard-coding the version subfolder:

```powershell
$divine = (Get-ChildItem .\.tools -Filter divine.exe -Recurse |
           Select-Object -First 1).FullName
$game   = "C:\Program Files (x86)\Steam\steamapps\common\Baldurs Gate 3\Data\Game.pak"
```

**`divine.exe` needs absolute paths for `-s`/`-d`/`-f`** - wrap each in
`(Resolve-Path ...).Path` or `Join-Path (Get-Location).Path ...`.

### The four actions you need

| Action | What it does |
|---|---|
| `list-package` | list every file path inside a pak |
| `extract-single-file` | pull one file out by its in-pak path |
| `extract-package` | unpack a whole pak: `-a extract-package -s <pak> -d <outDir>` |
| `convert-resource` | convert Larian binary (`.lsf`, `.loca`) to/from readable text (`.lsx`, `.xml`) |

(`create-package`, the packer behind `make.ps1 build`, lives in the toolchain
guide.)

### Recipes (PowerShell)

Find a file (the listing is thousands of lines, so filter):

```powershell
& $divine -g bg3 -a list-package -s $game 2>&1 |
  Select-String -Pattern "Examine" -SimpleMatch
# -> Mods/MainUI/GUI/Pages/Examine.xaml
```

Extract one file to the gitignored `.tools\_bg3ui\` scratch dir:

```powershell
$out  = Join-Path (Get-Location).Path ".tools\_bg3ui"
New-Item -ItemType Directory -Force $out | Out-Null
$dest = Join-Path $out "Examine.xaml"
& $divine -g bg3 -a extract-single-file -s $game -d $dest -f "Mods/MainUI/GUI/Pages/Examine.xaml"
```

Convert a binary resource to readable text:

```powershell
$src = Join-Path $out "metadata.lsf"
$dst = Join-Path $out "metadata.lsx"
& $divine -g bg3 -a convert-resource -s $src -d $dst
Get-Content $dst -Raw
```

`.xaml`, `.xml`, `.txt`, `.lua` are already plain text - extract and read them
directly. `.lsf`, `.lsb`, `.loca` are binary - `convert-resource` them first.

## Finding the game version (and why it matters)

The SE console prints the build in its startup header - ask the user for the
first lines, or read them from the log:

```
BG3Ext v32 built on Jun 21 2026 21:19:02
Game version v4.73.98.727 OK
    'Name Your Summons': SE v30; flags: Lua
```

- `Game version v4.73.98.727` - the game build. **It gates where assets live and
  what shape they have**: Larian moves and renames things between patches, and
  BG3SE component layouts drift too.
- `BG3Ext v32` - the Script Extender build.
- `SE v30` - the API version the mod targets (`RequiredVersion` in `Config.json`);
  it can lag the installed extender and guards the API version, not the layout.

The rule: **do not trust "patch X moved this to Y" claims from docs; confirm the
layout against the user's actual paks with `list-package`.**

## Checklist

1. Confirm the install path with the user (default Steam path above).
2. Get `divine.exe` (`./make.ps1 setup` if `.tools\` lacks it).
3. Read the game version from the SE console header, then verify the layout - do
   not assume it.
4. `list-package` the likely pak (UI -> `Game.pak`) and grep for the feature's
   keywords.
5. `extract-single-file` into `.tools\_bg3ui\`; `convert-resource` binary assets;
   read text assets directly.
6. Base the implementation on the extracted file, not a wiki's description of it.
