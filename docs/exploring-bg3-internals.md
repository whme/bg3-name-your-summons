# Exploring Baldur's Gate 3 internals

The game's own files are ground truth for how it is built - its UI XAML, templates,
stats, and localisation. When a task depends on any of that, unpack the relevant game
archive with LSLib's `divine.exe` (vendored by this repo) and base the work on the
extracted file rather than a wiki's description.

## divine.exe

Any divine-backed `make.ps1` command downloads the tool into `.tools/`, so run one
build first and then locate the binary by search. Its main actions:

| Action | What it does |
|---|---|
| `list-package` | list every path inside an archive |
| `extract-single-file` / `extract-package` | pull one file, or a whole archive |
| `convert-resource` | binary Larian formats <-> readable text |
| `convert-loca` | binary string tables <-> readable XML |

Ask the user for the game's install path - it moves between stores. The archives to
know are the UI pak (pages and control libraries), the shared/stats paks (templates
and stat definitions), and the per-language localisation paks.

## Anchor findings to a game build

Larian moves and renames assets between patches, so a finding holds only for the build
it came from. Read the game and extender build out of the console startup header and
record it beside anything you derive from a pak; confirm any "patch X moved this"
claim against the user's own files before acting on it.
