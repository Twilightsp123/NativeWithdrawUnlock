# Changelog

## v1.2.0

Unified scripted/generated-battle bootstrap fix.

### Bootstrap architecture
- Removed normal unit selection as the required initialization path.
- After phase `Deployed`, the mod now discovers the local player army directly through CA's battle-manager interfaces.
- Primary fast path: `bm:get_player_army()`.
- Robust fallback: enumerate `bm:alliances() -> armies()` and select an `army:is_player_controlled()` army.
- Uses a unit from the discovered army only to run the existing native UID and army-pointer cross-checks before any write.
- Also checks reinforcement unit collections for scripted/generated battle layouts.
- The unit-selection handler remains only as a last-resort fallback and is no longer required for the mod to initialize.

### Native layout
- No native offset changes from the validated v1.1.0 build.
- `wrapper -> native battle_unit`: `+0x08`
- `battle_unit -> battle_army`: `+0x70`
- `battle_unit -> unique_ui_id`: `+0x3EA0`
- `battle_army -> BATTLE_SETUP_ALLIANCE`: `+0x140`
- `BATTLE_SETUP_ALLIANCE -> can_withdraw`: `+0x248` (`uint8`)

### Safety
- No memory access before `Deployed`.
- Existing UID, army-pointer and `can_withdraw` byte checks are unchanged.
- Writes exactly one byte with `mr.uint8(1)`.
- No per-scenario exceptions were added; ambush/interception/scripted encounters continue to target the shared native alliance gate.

### Logging
- `LOG_ENABLED` remains the single master switch.
- Production default remains `false`.


## v1.1.0

Production baseline validated in campaign battle testing.

### Native layout
- wrapper -> native battle_unit: `+0x08`
- battle_unit -> battle_army: `+0x70`
- battle_unit -> unique_ui_id: `+0x3EA0`
- battle_army -> BATTLE_SETUP_ALLIANCE: `+0x140`
- BATTLE_SETUP_ALLIANCE -> can_withdraw: `+0x248` (`uint8`)

### Fixes
- Preserves a valid Deployment unit anchor across WH3 deselection during the transition into `Deployed`.
- Keeps all original native safety checks and UI recovery behavior.
- No memory access is performed before `Deployed`.

### Logging
- Added one master switch in `native_withdraw_unlock.lua`:

```lua
local LOG_ENABLED = false
```

- Set it to `true` for diagnostic builds.
- Production release defaults to `false`.
- No gameplay/native behavior change from the validated v1.1.0 logic.
