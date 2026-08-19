# Exploring Baldur's Gate 3 internals

The game's own files are ground truth for how it is built - its UI XAML,
templates, stats, localisation, and metadata. When a task depends on any of
that, read the installed game's files: unpack the relevant `.pak` with LSLib's
`divine.exe` (already vendored by this repo) and base the implementation on the
extracted file rather than a wiki's description of it.

## Where the game lives

Ask the user for the install path - GOG and non-default Steam libraries move it.
The default Steam one is:

```
C:\Program Files (x86)\Steam\steamapps\common\Baldurs Gate 3\Data\
  Game.pak                   UI: Mods/MainUI/GUI/Pages/*.xaml, .../Library/*.xaml
  Shared.pak, Gustav.pak     stats + templates: Public/<Mod>/Stats/Generated/...
  Localization\English.pak   string tables: Localization/English/english.loca
```

That `Data` folder is what the game-data gates take as `-Bg3Data` (see
[build-and-gates.md](build-and-gates.md)). Everything the game loads sits in a
`.pak` under it; to learn which pak holds a given file, `list-package` the
candidates and grep the paths.

## divine.exe

Any divine-backed `make.ps1` command (`build`, `loca-check`, `xaml-check
-Bg3Data`) downloads the pinned LSLib release into `.tools\lslib-<version>\`, so
run `./make.ps1 build` once, then find the binary by search - its subfolder
inside the release has shifted between versions:

```powershell
$divine = (Get-ChildItem .\.tools -Filter divine.exe -Recurse |
           Select-Object -First 1).FullName
$game   = "C:\Program Files (x86)\Steam\steamapps\common\Baldurs Gate 3\Data\Game.pak"
```

Give `-s` and `-d` absolute paths - divine rejects a relative one outright
(`Cannot proceed without absolute path`), so wrap yours in
`(Resolve-Path ...).Path` or `Join-Path (Get-Location).Path ...`. `-f` is the
opposite: an in-pak path, forward slashes, relative to the pak root.

| Action | What it does |
|---|---|
| `list-package` | list every path inside a pak (tab-separated: path, size) |
| `extract-single-file` | pull one file out by its in-pak path (`-f`) |
| `extract-package` | unpack a whole pak, filtered by `-x "*.xaml"` |
| `convert-resource` | `.lsf` / `.lsb` <-> readable `.lsx` / `.lsj` |
| `convert-loca` | `.loca` <-> readable `.xml` - the action for every `.loca` |

### Recipes (PowerShell)

Find a file - the listing runs to ~29k lines, so filter it. Send divine's log to
`2>$null` so its lines stay out of the pipeline:

```powershell
& $divine -g bg3 -a list-package -s $game 2>$null |
  Select-String -Pattern "Examine" -SimpleMatch
# -> Mods/MainUI/GUI/Pages/Examine.xaml   12506   0
```

Extract one file into the gitignored `.tools\_bg3ui\` scratch dir. Use a
subfolder of your own: `xaml-check` owns `_bg3ui\Game` and wipes it every run.

```powershell
$out  = Join-Path (Get-Location).Path ".tools\_bg3ui\scratch"
New-Item -ItemType Directory -Force $out | Out-Null
$dest = Join-Path $out "Examine.xaml"
& $divine -g bg3 -a extract-single-file -s $game -d $dest -f "Mods/MainUI/GUI/Pages/Examine.xaml"
```

Read `.xaml`, `.xml`, `.txt`, `.lua` straight out of the pak; convert the binary
formats first:

```powershell
& $divine -g bg3 -a convert-resource -s (Join-Path $out "metadata.lsf") -d (Join-Path $out "metadata.lsx")
& $divine -g bg3 -a convert-loca     -s (Join-Path $out "english.loca") -d (Join-Path $out "english.xml")
```

## Recording the game build

Larian moves and renames assets between patches, so a finding holds only for the
build it came from. Read the build out of the SE console header (ask the user
for its first lines) and record it beside anything you derive from a pak:

```
BG3Ext v32 built on Jun 21 2026 21:19:02
Game version v4.73.98.727 OK
    'Name Your Summons': SE v30; flags: Lua
```

- `Game version v4.73.98.727` - the game build, the one that decides where an
  asset lives and what shape it has.
- `BG3Ext v32` - the installed Script Extender build.
- `SE v30` - the API version the mod targets (`RequiredVersion` in
  `Config.json`).

Confirm any "patch X moved this to Y" claim from a wiki against the user's own
paks with `list-package` before acting on it.
