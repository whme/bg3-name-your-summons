# Debugging and exploring in game

The user runs Baldur's Gate 3; you write the instrumented Lua, agree the exact
in-game steps, and reason from the console output and trace files the user pastes
back. Every run costs the user a full restart, so batch the investigation - one run
should answer many questions - and back every "this works in game" claim with a
pasted log.

## The loop

Pin the goal, work out which approaches are viable and what would confirm each, then
instrument broadly (behind a debug flag) so a single run shows which paths are real
instead of costing one restart per guess. Agree an exact runbook with the user so a
log line that never appears is itself an answer. When you cannot tell whether a
failure is your change or the mechanism, ship a byte-for-byte minimal variant to
bisect it.

Deploy by building the pak and dropping it in the game's Mods folder. Say which
reload the change needs every time: a Lua-only change needs an in-console `reset`,
while a XAML, asset, or packaging change needs a full restart.

## The console

The Script Extender console is a separate window. Read it for the startup header (it
records the game and extender build), the mod's own two startup lines (one per state -
if one is missing, that state failed to load), and engine errors, which are literal
and name the state or property at fault. A command lives in the state that registered
it, so switch the console between server and client context to reach it.

## Console commands

Ask the user to run the one that answers your question and paste the output.

| Command | State | What it does |
|---|---|---|
| `!nys_list` | server | list every saved name |
| `!nys_diag` | server | dump what the game thinks the host's summons are named |
| `!nys_rename <name>` | server | rename the host's summons on the spot, no prompt |
| `!nys_reapply` | server | re-run the load-time reapply pass without reloading |
| `!nys_clear` | server | wipe all saved names |
| `!nys_debug` | both | toggle routine log output |
| `!nys_trace` | both | toggle JSONL tracing |
| `!nys_uidump` | client | dump the visual-tree landmark map to the trace file |

Reach for `!nys_diag` first when a name will not stick - it prints the whole handle
chain next to what the game currently shows. Tracing writes structured JSONL to disk
and beats pasted excerpts for a reproducible issue, since the last line before a crash
is already saved; ask for the files rather than a paste.

## Logging policy

The console is quiet by default so the startup lines stay visible. Routine progress
goes through the debug-gated log; only real failures and command output print
unprompted; diagnosis goes through tracing, which costs nothing while off. Keep
diagnostics cheap - do the expensive lookup once, on a real signal, never on a timer.
Strip all throwaway discovery tooling and debug logging before the change reaches a
PR.

## Where to settle a question

Answer each in the cheapest place that can: code correctness with `./make.ps1 all`
([build-and-gates.md](build-and-gates.md)); facts about the game's own data by
unpacking its paks ([exploring-bg3-internals.md](exploring-bg3-internals.md)); and
ECS, net, native-UI, or timing behaviour with an in-game run - say so plainly and
name the console command that would confirm it.
