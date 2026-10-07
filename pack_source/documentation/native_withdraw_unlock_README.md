# Native Withdraw Unlock — Technical Notes

## Purpose

This document records the reverse-engineering and implementation details behind a Total War: WARHAMMER III battle mod that restores the game's **native realtime per-unit Withdraw order** in battles where CA disables it.

The target behavior is the normal battle command:

1. Select one or more player units.
2. Click the game's original **Withdraw** button.
3. The units receive CA's native Withdraw order.
4. They run toward a battlefield edge and leave the battle normally.
5. Normal native reinforcement / active-unit-slot behavior remains in control of the game.

This is **not** campaign strategic Retreat, morale rout, teleport withdrawal, ambush extraction, scripted whole-army retreat, or a custom substitute command.

---


## v1.2.0 — Automatic player-army bootstrap

The native Withdraw solution remains global: different upstream restrictions such as ambushes, interceptions, settlement/garrison cases and scripted encounter battles still converge on the same `BATTLE_SETUP_ALLIANCE.can_withdraw` byte. No per-scenario compatibility list is used.

The bootstrap has changed so that this common native gate can be reached without relying on the normal unit-selection lifecycle. After the battle reaches `Deployed`, the mod now:

1. asks CA's battle manager for the local player army with `bm:get_player_army()`;
2. if needed, enumerates `bm:alliances() -> armies()` and selects an `army:is_player_controlled()` army, mirroring CA's own generated-battle logic;
3. enumerates that army's main units and, when present, reinforcement unit collections;
4. uses a discovered unit only to run the existing `unique_ui_id` and native-army pointer cross-checks;
5. resolves `battle_army + 0x140 -> BATTLE_SETUP_ALLIANCE`;
6. reads and, when needed, writes exactly one byte at `+0x248`;
7. restores the original CA Withdraw UI visibility as before.

The old unit-selection handler is retained only as a fallback. A scripted/generated battle no longer needs to produce a normal player selection event for the mod to initialize.

No native offsets, validator behavior, write width, UI hierarchy or maintenance logic changed in v1.2.0.

---

## v1.1.0 — Deployment anchor lifecycle fix

The current WH3 executable still uses the verified native layout documented below, including `BATTLE_SETUP_ALLIANCE.can_withdraw` at `+0x248`. Runtime logs from a restricted campaign battle exposed a separate lifecycle failure: the battle script loaded successfully and reached `Deployed`, but no native initialization attempt occurred.

The production architecture remains the original architecture: cache a normal player-controlled `battle.unit` selection as the pointer anchor, perform no memory access before `Deployed`, resolve the native chain, set `can_withdraw = 1`, then restore the original CA Withdraw UI visibility.

The fix is deliberately narrow:

- a valid player-unit anchor cached during Deployment is no longer cleared merely because WH3 emits a deselection while transitioning into `Deployed`;
- if a cached pre-Deployed userdata is genuinely stale after the phase transition, the mod discards it without writing and waits for a fresh player-unit selection;
- new one-shot diagnostics report script load, handler registration, anchor acquisition, missing anchor after `Deployed`, stale-anchor rejection, and missing Withdraw UI components.

The native offsets, one-byte write rule, native validator behavior, UI hierarchy and low-frequency maintenance architecture are otherwise unchanged.

---

## Final architecture

The final solution does not simulate Withdraw.

It changes the native alliance-level eligibility byte used by the game's own Withdraw UI and order validator, then restores the hidden original button.

```text
player battle.unit userdata
        |
        | + wrapper/native pointer resolution
        v
native battle_unit*
        |
        | +0x70
        v
native battle_army*
        |
        | +0x140
        v
BATTLE_SETUP_ALLIANCE*
        |
        | +0x248
        v
can_withdraw : uint8
        |
        +------------------------+
        |                        |
        v                        v
native Withdraw UI         native Withdraw validator
        |                        |
        +-----------+------------+
                    |
                    v
             CA's normal Withdraw
```

The mod changes only the common native eligibility state. It does not replace the Withdraw implementation.

---

## Key native discovery

### `BATTLE_SETUP_ALLIANCE.can_withdraw`

The executable contains the serialized/native field name:

```text
BATTLE_SETUP_ALLIANCE
can_withdraw
```

For the researched WARHAMMER III executable build:

```text
BATTLE_SETUP_ALLIANCE + 0x248 = can_withdraw
sizeof(BATTLE_SETUP_ALLIANCE) = 0x390
```

The field is read as a byte by native code.

The important result is that both sides of the feature converge on the same value:

- the Withdraw UI availability/state logic reads `BATTLE_SETUP_ALLIANCE + 0x248`;
- the native per-unit Withdraw validator also reads `BATTLE_SETUP_ALLIANCE + 0x248`.

Therefore forcing only the UI visible is insufficient when `can_withdraw == 0`: the native order is still rejected.

Conversely, once `can_withdraw` is changed to `1`, the native validator accepts the normal Withdraw command.

---

## Verified Lua-to-native pointer chain

The production mod resolves the target structure from a normal battle `unit` userdata.

```text
battle.unit userdata
        |
        | mr.ud_topointer(...)
        v
Lua battle_unit wrapper*
        |
        | +0x08
        v
native battle_unit*
        |
        | +0x70
        v
native battle_army*
        |
        | +0x140
        v
BATTLE_SETUP_ALLIANCE*
        |
        | +0x248
        v
can_withdraw
```

### Safety checks retained in the production script

Before any write, the script validates the pointer chain using two independent checks.

#### Check 1 — unit identity

```text
native battle_unit + 0x3EA0
```

must equal:

```lua
unit:unique_ui_id()
```

#### Check 2 — army pointer identity

The army pointer obtained through:

```text
native battle_unit + 0x70
```

must equal the independently resolved pointer obtained through:

```text
unit:army()
    -> mr.ud_topointer(army userdata)
    -> wrapper + 0x08
```

Only after both checks pass does the script dereference:

```text
battle_army + 0x140
```

as the `BATTLE_SETUP_ALLIANCE*`.

It also reads `+0x248` first and requires the byte to be exactly `0` or `1`.

If a future game update changes these layouts, the intended failure mode is **stop without writing**.

---

## Critical Memreader write-width trap

This was the most dangerous implementation bug encountered during development.

The obvious-looking code is:

```lua
mr.write(setup_alliance_ptr, 0x248, true)
```

Do **not** use it.

Although `can_withdraw` itself is a 1-byte native boolean field, Cpecific's Memreader implementation handles a Lua boolean using a Windows `BOOL`.

In the Memreader C source the boolean branch calls `WriteProcessMemory(..., sizeof(BOOL), ...)`.

On Windows:

```text
sizeof(BOOL) = 4
```

Therefore:

```lua
mr.write(ptr, 0x248, true)
```

can overwrite:

```text
+0x248
+0x241
+0x242
+0x243
```

instead of only the target byte.

During development this caused an immediate game hang/crash directly after all pointer sanity checks had passed.

### Correct write

Use an explicit one-byte Memreader type:

```lua
mr.write(
    setup_alliance_ptr,
    0x248,
    mr.uint8(1)
)
```

The successful probe compared memory before and after the write and found exactly one changed byte:

```text
relative offset 0x8 within a dump beginning at +0x238
00 -> 01
total_changes = 1
```

Because:

```text
0x238 + 0x08 = 0x248
```

This confirmed that only `can_withdraw` was modified.

---

## Battle phase timing

Do not use "N milliseconds after battle script load" as a substitute for "the battle has started".

The player may remain in Deployment for an arbitrary amount of real time.

The relevant progression is:

```text
Startup
PrebattleWeather
PrebattleCinematic
Deployment
    |
    | player presses Start Battle
    v
Deployed
    |
    +-> ScriptEventConflictPhaseBegins
```

The final implementation permits selections to be cached during Deployment, but performs **no memory access** until:

```lua
bm:get_current_phase_name() == "Deployed"
```

This avoids writing or issuing battle logic before the player has actually started the fight.

---

## Why UI-only unlocking failed

An earlier experiment forced the Withdraw UI visible while the underlying native eligibility remained disabled.

The visible button could generate the native Withdraw command/event, but the unit never entered `IsWithdrawing` and did not move toward the map edge.

The public command paths were also tested directly:

```lua
CcoBattleSelection.Withdraw()
```

and:

```lua
script_unit:withdraw(true)
```

Both reached the native command/event machinery, but in a restricted battle the command was rejected/ignored while the native gate remained false.

This established that the restriction was **below the Lua/UI wrapper layer**.

---

## What happens after `can_withdraw = 1`

A successful runtime probe showed:

```text
can_withdraw BEFORE = 0
can_withdraw AFTER  = 1
```

After a short native UI propagation delay, CA changed the Withdraw button from disabled/inactive to active/enabled.

A native Withdraw call then produced:

```text
CcoBattleUnit.IsWithdrawing = true
```

The final manual test also confirmed that the original Withdraw button could be displayed and clicked successfully.

---

## UI handling in the production version

Changing `can_withdraw` fixes the native eligibility and button enabled state, but in restricted battles CA may leave the relevant UI components hidden.

The relevant hierarchy is:

```text
hud_battle
  battle_orders
    battle_orders_pane
      orders_parent
        hud_extension
          button_withdraw
```

The production script restores only visibility:

```lua
hud_extension:SetVisible(true)
button_withdraw:SetVisible(true)
```

It intentionally does **not** continuously force:

```lua
button:SetState("down")
```

or other visual states.

CA should remain responsible for hover, selected, active and disabled state transitions.

During development, repeatedly forcing `"down"` worked functionally but overwrote native UI state changes and was therefore removed from the cleaned implementation.

---

## Low-frequency maintenance

The tested battle kept `can_withdraw == 1` after the initial write.

However, reverse engineering showed that the native structure has multiple writers, so the production version performs a conservative check once per second.

It does not blindly write every second.

Instead:

```text
read can_withdraw
    |
    +-- 1 -> do nothing
    |
    +-- 0 -> write uint8(1), verify
    |
    +-- anything else / read error -> stop writing
```

The same low-frequency maintenance restores the two UI visibility flags only if CA hides them again.

---

## Common predicate vs. upstream causes

The research found that several distinct battle/campaign setup conditions can ultimately disable realtime Withdraw.

Examples discussed during investigation included settlement-related situations, garrison participation, force stance rules, ambush/special battle rules and other setup paths.

The exact names of every upstream source condition were not required for the final implementation.

The useful architectural result is:

```text
multiple upstream "no Withdraw" causes
              |
              v
BATTLE_SETUP_ALLIANCE.can_withdraw
              |
       +------+------+
       |             |
       v             v
      UI       native validator
```

By changing the shared native predicate, the mod does not need separate special cases for each upstream reason.

---

## Things that were explicitly ruled out

The following should not be confused with the target solution:

- campaign strategic Retreat;
- `set_force_has_retreated_this_turn`;
- autoresolver `unit_retreat_mod`;
- forced-march DB effects containing the word `retreat`;
- morale routing;
- teleport withdrawal;
- ambush extraction;
- custom scripted movement to a map edge;
- UI-only visibility changes;
- calling `CcoBattleSelection.Withdraw()` as a bypass;
- calling `script_unit:withdraw(true)` as a bypass.

The final mod keeps CA's actual realtime battle Withdraw implementation and removes its alliance-level eligibility gate.

---

## Version sensitivity

All native offsets in this document are **build-specific implementation details**.

Important offsets for the researched build:

```text
battle_unit wrapper +0x08  -> native battle_unit*
battle_unit +0x70          -> native battle_army*
battle_unit +0x3EA0        -> unique_ui_id sanity value
battle_army +0x140         -> BATTLE_SETUP_ALLIANCE*
BATTLE_SETUP_ALLIANCE
    +0x248                 -> can_withdraw
```

A WARHAMMER III update can change any of them.

After a major game update:

1. Do not assume the mod is safe because it still loads.
2. Keep the pointer sanity checks enabled.
3. If a sanity check fails, stop and re-reverse the relevant binding/validator.
4. Re-anchor the native analysis from `BattleButtonWithdraw`, the battle-unit Lua bindings, or the `can_withdraw` field/string.
5. Never "fix" a failed offset by guessing nearby values.

For a memory-writing mod, a clean failure is preferable to an unsafe write.

---

## Dependency

The Lua implementation requires Cpecific's Memreader to expose:

```lua
_G.memreader
```

Required operations include:

```text
ud_topointer
read_pointer
read_int32
read_uint8
write
uint8
eq
```

The mod does not need to patch `Warhammer3.exe` on disk and does not require a separate injected DLL beyond the Memreader environment already used by the mod setup.

---

## Recommended pack layout

Suggested layout:

```text
script/
  battle/
    mod/
      native_withdraw_unlock.lua

documentation/
  native_withdraw_unlock_README.md
```

The documentation file is not referenced by the Lua script.

### Can the README be inside the `.pack`?

RPFM is a general PackFile editor and supports adding/extracting files in Pack containers. Its current documentation describes Packs as containers for game assets and the editor as able to add files to them.

I did not find an explicit CA/RPFM guarantee specifically stating that WARHAMMER III recognizes or ignores a `.md` file extension.

For that reason the conservative recommendation is:

- placing the README under a non-game path such as `documentation/` is reasonable for archival/source purposes;
- if your RPFM version accepts the `.md` file, it can be stored there as an ordinary packed file;
- do **not** place it under `script/battle/mod/`, because only executable Lua belongs there;
- for maximum compatibility, `documentation/native_withdraw_unlock_README.txt` is an equally good in-pack archival format;
- for Workshop users, keep a copy outside the pack / in the Workshop description as well, because ordinary players will not naturally browse inside a `.pack`.

---

## Final implementation philosophy

The cleaned mod intentionally does as little as possible:

```text
wait until Deployed
        |
auto-discover the local player battle_army
        |
obtain one valid unit from that army for safety cross-checks
        |
validate native pointer chain
        |
read can_withdraw and require 0/1
        |
write exactly one byte if needed
        |
allow CA to update native button state
        |
restore hidden native UI visibility
        |
player uses original Withdraw button
```

Everything after the eligibility change remains CA's battle code.
