# Changelog

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
