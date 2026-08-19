## Changelog

{{CHANGELOG}}

## Requirements

| Mod name | Notes |
|---|---|
| [Baldur's Gate 3 Script Extender](https://github.com/Norbyte/bg3se) (BG3SE) | **Required.** Built against Script Extender API v30 - install a build that supports v30 or newer. |

## Installing

Install both parts in order.

| Step | How |
|---|---|
| 1. Script Extender | Download the latest updater from the [BG3SE releases](https://github.com/Norbyte/bg3se/releases) page and extract `DWrite.dll` into the game's `bin` folder, next to `bg3.exe` (e.g. `...\steamapps\common\Baldurs Gate 3\bin\`). It downloads and updates itself the next time you launch the game. |
| 2. Name Your Summons | Download `NameYourSummons-{{VERSION}}.zip` below, extract the `.pak`, and drop it in `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Mods\`. |
| 3. Enable it | Launch the game and enable **Name Your Summons** from the **Mods** menu. |

**Updating from 1.2.0 or earlier?** Delete the old versioned `NameYourSummons-*.pak`
from that folder first - the pak now has a stable filename, so leaving the old one
behind would make the game load a stale copy.

## Verifying the download
The release `.zip` is signed with a [GitHub build attestation](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds) produced by this repository's release workflow.
Verifying the attestation cryptographically proves that the archive came from the `whme/bg3-name-your-summons` release workflow at the tagged commit - i.e. the `.zip` you have is byte-for-byte the one GitHub built for this release and was not modified or repackaged after upload.

Verify it with the [GitHub CLI](https://cli.github.com/):
```sh
gh attestation verify NameYourSummons-{{VERSION}}.zip --repo whme/bg3-name-your-summons
```

# <a href="https://github.com/whme/bg3-name-your-summons/releases/download/{{VERSION}}/NameYourSummons-{{VERSION}}.zip">NameYourSummons-{{VERSION}}.zip</a> [![Downloads](https://img.shields.io/github/downloads/whme/bg3-name-your-summons/{{VERSION}}/total?label=downloads)](https://github.com/whme/bg3-name-your-summons/releases/download/{{VERSION}}/NameYourSummons-{{VERSION}}.zip)

---

Name Your Summons is an unofficial, free, fan-made mod, not affiliated with or endorsed by Larian Studios or Wizards of the Coast.
The mod's code is under the [MIT License](https://github.com/whme/bg3-name-your-summons/blob/{{VERSION}}/LICENSE); see [NOTICE.md](https://github.com/whme/bg3-name-your-summons/blob/{{VERSION}}/NOTICE.md) for game-content, trademark, and attribution details.
