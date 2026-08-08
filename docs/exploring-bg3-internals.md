# Exploring Baldur's Gate 3 internals

Given the BG3 installation path, an AI agent has everything it needs to read the
game's own "source" - its UI XAML, templates, stats, localisation, and mod
metadata - **without the user unpacking anything by hand**. This repo already
downloads the one tool required (LSLib's `divine.exe`, used by `make.ps1 build`),
so an agent can unpack and inspect the game's `.pak` files itself.

This is the single most useful move when a task depends on how the game is built
internally (native UI, stats, templates): **stop guessing from wikis and read
the actual files the installed game ships.** The wikis lag behind patches; the
paks are ground truth for the exact version the user is running.

## Where the game lives

Default Steam install (ask the user for the path if it differs - GOG, and other
stores, and non-default Steam libraries move it):

```
C:\Program Files (x86)\Steam\steamapps\common\Baldurs Gate 3\
  Data\
    Game.pak          <- the UI lives here (Mods/MainUI/GUI/...)
    Gustav.pak, Shared.pak, ... <- content, stats, templates, localisation
```

Everything the game loads is inside a `.pak` in `Data\`. To find which pak holds
what, list a pak's contents and grep the paths (see below) - do not assume.

## The tool: `divine.exe`

`divine.exe` is Norbyte's LSLib CLI - the same packer the BG3 Modder's Multitool
wraps. `make.ps1` already fetches a pinned copy into `.tools\` on first use. If
it is not there yet, run `./make.ps1 setup` (or any `build`) once. Locate it
robustly rather than hard-coding the version subfolder:

```powershell
$divine = (Get-ChildItem .\.tools -Filter divine.exe -Recurse |
           Select-Object -First 1).FullName
$game   = "C:\Program Files (x86)\Steam\steamapps\common\Baldurs Gate 3\Data\Game.pak"
```

**`divine.exe` needs absolute paths for `-s`/`-d`/`-f`.** Relative paths fail or
silently misbehave; wrap every path in `(Resolve-Path ...).Path` or
`Join-Path (Get-Location).Path ...`.

### The four actions you need

| Action | What it does | Example |
|---|---|---|
| `list-package` | list every file path inside a pak | see recipe below |
| `extract-single-file` | pull one file out by its in-pak path | see recipe below |
| `extract-package` | unpack a whole pak to a folder | `-a extract-package -s <pak> -d <outDir>` |
| `convert-resource` | convert Larian binary `.lsf`/`.loca` <-> readable `.lsx`/`.xml` | see recipe below |

(`create-package` is the packer used by `make.ps1 build`; it is documented in
the toolchain guide, not here.)

### Recipes (PowerShell)

Find a file inside a pak (list, then filter - the listing is thousands of lines):

```powershell
& $divine -g bg3 -a list-package -s $game 2>&1 |
  Select-String -Pattern "Examine" -SimpleMatch
# -> Mods/MainUI/GUI/Pages/Examine.xaml   (12.5 KB)
```

Extract one file to a gitignored scratch dir (`.tools\_bg3ui\` is ignored):

```powershell
$out  = Join-Path (Get-Location).Path ".tools\_bg3ui"
New-Item -ItemType Directory -Force $out | Out-Null
$dest = Join-Path $out "Examine.xaml"
& $divine -g bg3 -a extract-single-file -s $game -d $dest -f "Mods/MainUI/GUI/Pages/Examine.xaml"
```

Convert a binary resource to readable text (metadata, stats, saves - most
non-`.xaml` Larian assets are binary `.lsf`/`.loca` and must be converted before
you can read them):

```powershell
& $divine -g bg3 -a convert-resource -s $someFile.lsf -d $someFile.lsx
Get-Content $someFile.lsx -Raw
```

`.xaml`, `.xml`, `.txt`, `.lua` inside paks are already plain text - extract and
`Read` them directly. `.lsf`, `.lsb`, `.loca` are binary - `convert-resource`
them to `.lsx`/`.xml` first.

## Finding the game version (and why it matters)

The Script Extender console/log prints the exact build in its startup header -
ask the user to paste the first lines, or read them yourself if you have the log:

```
BG3Ext v32 built on Jun 21 2026 21:19:02
Game version v4.73.98.727 OK
    'Name Your Summons': SE v30; flags: Lua
```

- `Game version v4.73.98.727` - the game build. **This gates where things live
  and what shape they have.** Larian moves and renames assets between patches
  (for example, the UI moved from `Public/Game/GUI/Widgets/*.xaml` pre-Patch-8 to
  `Mods/MainUI/GUI/Pages/*.xaml` in Patch 7/8), and BG3SE component layouts
  drift too (a field can be renamed or removed while the API version stays the
  same).
- `BG3Ext v32` - the Script Extender build.
- `SE v30` - the API version the mod targets (`RequiredVersion` in `Config.json`).
  Note this can lag the installed extender (v32 here) - it guards the API
  version, not the component layout.

The practical rule: **do not trust "patch X moved this to path Y" claims from
docs; confirm the layout against the user's actual paks with `list-package`.**
The transcript that motivated this guide burned several iterations on an
override path that a wiki said was current but the installed game had already
changed.

## Checklist for "how is the game built internally?"

1. Confirm the install path with the user (default Steam path above; ask if
   unsure).
2. Get `divine.exe`: `Get-ChildItem .\.tools -Filter divine.exe -Recurse`; if
   absent, `./make.ps1 setup`.
3. Confirm the game version from the SE console header, so you know which asset
   layout to expect - then verify it, do not assume it.
4. `list-package` the likely pak (UI -> `Game.pak`) and grep for the feature's
   keywords to find the real file paths.
5. `extract-single-file` the file(s) into `.tools\_bg3ui\` (gitignored). Convert
   binary `.lsf`/`.loca` with `convert-resource`; read `.xaml`/`.xml`/`.txt`
   directly.
6. Base your implementation on the extracted ground-truth file, not on a wiki's
   description of it.
