# Changelog

<!-- changelogging: start -->

## 1.3.0 (2026-08-20)

### Features

- In split-screen co-op you can now only rename a summon, and open its settings gear, when it
  belongs to you. Examining another player's summon shows it as a plain vanilla examine panel.
  (#130)

### Bug Fixes

- On keyboard, pressing Escape with the summon settings panel open now closes
  only that panel, leaving the Examine panel open - matching the controller.
  Previously Escape closed the whole Examine panel out from under the open settings. (#135)

- The `.pak` now has a stable filename, so an update overwrites the old file
  instead of leaving a stale copy (delete any old `NameYourSummons-*.pak` once). (#147)

- The Examine panel's rename field and settings gear now work when you manually open Examine
  on a summon in split-screen local co-op; previously they appeared but did nothing outside
  single-player. (#149)

## 1.2.0 (2026-08-18)

### Bug Fixes

- Fixed a bug that could leave a manually-opened Examine panel's rename field
  and settings gear dead on keyboard and mouse right after loading a save, until
  you switched to a controller and back.

## 1.1.0 (2026-08-17)

### Features

- Quieted the Script Extender console by default. Each Lua state now prints
  a single startup line naming the mod version; routine logging is hidden
  behind a new `!nys_debug` command that toggles it in both states.
  Warnings and console-command output (`!nys_diag`, `!nys_list`,
  `!nys_rename`, `!nys_clear`) still always show. (#106)

### Bug Fixes

- Fixed a crash in character creation. Name Your Summons no longer scans the
  game's UI on every click to detect the Examine panel; it now watches a single
  lightweight HUD signal instead, and does no UI scanning on the
  character-creation screen or in menus. (#99)

## 1.0.0 (2026-08-10)

### Features

- Name Your Summons can be used entirely with a controller: its name field,
  settings gear, and settings menu are injected into the controller Examine
  layout and join the game's native focus navigation, and naming a summon uses
  the game's on-screen keyboard. Keyboard and mouse naming works too, and does not
  pop up Steam's on-screen keyboard when Steam Input is active (for example in
  Steam Big Picture mode) - that overlay appears only when naming with a
  controller. (#6)

- When a summon appears, Name Your Summons opens its native Examine panel so you
  can name it right where the game shows the creature. (#19)

- Name Your Summons ships with automated releases: the changelog is generated
  from news fragments via
  [changelogging](https://github.com/nekitdev/changelogging), and each release's
  mod package is built, signed with a build attestation, and published to GitHub
  for you to download. (#24)

- You can rename a summon straight from its Examine screen. A summon's name starts
  as the game's plain, non-editable text; click it and it becomes an editable
  field (with a settings gear). Type a name and it is saved as you go and comes
  back the next time you summon that creature. Story-bound summons (such as "Us"
  or "Shovel") stay plain text and cannot be renamed there unless you turn on the
  "Allow renaming story-bound summons" setting, matching the game's own Examine
  panel; with that setting on, they are prompted on summon like any other summon,
  regardless of the creature-type filter. (#34)

- The settings gear on a summon's Examine screen opens a native settings window
  built from the game's own UI, with prompt options, the per-creature-type filter,
  the multi-summon mode, and the saved-name manager. (#41)

- A setting lets you pause the game in turn-based mode while you name a summon. It
  is off by default, so naming does not interrupt play unless you turn it on. (#43)

- The saved-name list shows each summon's creature type and whether it is a
  familiar (e.g. "Wolf (Beast)", "Imp (Fiend, Familiar)"), so you can see at a
  glance which "Summon types to name" toggle governs a saved name. A Find Familiar
  summon is always treated as a Familiar whatever its creature type, so an undead
  or fiend familiar is covered by the "Familiars" toggle (on by default), not by
  the "Undead" or "Fiend" toggles, which govern non-familiar summons. (#47)

- When one spell summons several creatures at once, you name them all in a single
  Examine panel that swaps from one creature to the next. Each name is saved as you
  type it; a Confirm button moves on to the next creature, and a Skip button leaves
  one unnamed and moves on. Both appear only while another creature is still
  queued, so naming a single summon needs neither. Closing the panel skips any
  creatures you have not named yet. (#51)

- When a summon's naming prompt is withdrawn while its Examine panel is still on
  screen - for example when a multi-summon spell turns out to be a group you chose
  not to name - the panel closes itself and moves on, with no need to dismiss it by
  hand. (#54)

- The multi-summon behaviour is chosen from a single dropdown in the native
  settings panel, styled like the game's own Options menu, with one option active
  at a time: name each creature individually, share one name across the group, or
  do not name them. "Do not name them" leaves a group unnamed for that cast; a
  later cast of the same summon is evaluated afresh under whatever mode is set at
  that time. (#69)

- Name Your Summons is now translatable, and ships translations for French,
  German, Italian, Spanish, Polish, Russian and Chinese alongside English. Every
  label in the Examine name field and the settings panel - buttons, checkboxes,
  the multi-summon options, and the saved-name manager - follows the language your
  game is set to, falling back to English where a translation is missing. (#71)

- The native settings panel has no Save button: every change applies the moment
  you make it. Editing a saved name applies when the field loses focus, and a
  forgotten name keeps its Undo until the panel is closed. (#76)

- Name Your Summons supports local split-screen co-op. The naming panel opens for
  the player who summoned the creature, and each player's saved names are private
  to the summons they currently control, so their name lists stay separate even
  when characters share a name. When a player leaves the game, their character's
  summon names become visible to whoever then controls it (the host). Every player
  can name summons and open the settings panel at the same time, independently. (#86)
