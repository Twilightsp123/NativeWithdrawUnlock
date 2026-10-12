# Changelog

## v1.1.2 — Event-safe compatibility (2026-10-12)

**Status:** Promoted from the previously supplied v1.1.2 event-safe candidate after the user reported a successful real-game test. This is an observed success, not proof of compatibility with all battles or third-party Mod combinations.

### Root cause and fix

- An affected player supplied a log where the mod loaded, the battle reached `Deployed`, and a player unit card was clicked, but NWU had no cached player-unit anchor; native unlock did not run.
- Source audit of **AI Army Control** revealed use of `bm:register_unit_selection_handler("battle_manager_unit_selection_handler")` after NWU had registered its own handler. The CA interface maintains one currently registered native selection handler, creating a concrete contention risk; the exact overwrite was **not directly captured** in the player's log.
- NWU **no longer registers any native unit selection handler**, so it cannot displace that handler or require one to function.
- A shared `bm:register_phase_change_callback("Deployed", ...)` initiates one-time native setup. An independent `bm:callback` phase check runs every **500 ms** until the phase is `Deployed` or initialization has started.
- Player units are sourced from `bm:get_player_alliance():armies()`, including exposed reinforcement groups, and validated before any native write. One initial scan and at most eight delayed attempts (250/500/1000/2000/4000/8000/15000/30000 ms; 60.75 seconds in total); no further unit search after success or exhaustion.
- Idempotent guards prevent phase notification + fallback from starting duplicate bootstraps.

### Kept unchanged

- Requires Cpecific's Memreader (`_G.memreader`).
- Native offsets `+0x08`, `+0x70`, `+0x140`, `+0x3EA0`, `+0x248`.
- UID identity and independently obtained army-pointer cross-checks.
- Exact **one-byte** `mr.uint8(1)` write to `can_withdraw`, followed by verification.
- Original Withdraw UI visibility recovery and once-per-second native gate maintenance after unlock.
- No native memory read/write before `Deployed`. Logging remains off by default (`LOG_ENABLED = false`).

### Verification and package provenance

- Eleven offline Lua-mock scenarios passed (phase event, phase watcher, registration failure, delayed units, bounded exhaustion, bad UID, bad army pointer, reinforcement, gate already enabled, dual-trigger race, post-unlock gate restore).
- Candidate Pack originally verified as PFH5 and compared to v1.1.0 for non-Lua payload integrity; no in-game claim from offline tests.
- **Actual game confirmation:** user reported v1.1.2 worked. Specific battle combinations not independently enumerated.
- To preserve identity of the exact working binary, the official `release/native_withdraw_unlock.pack` uses that byte-identical candidate payload. Internal `VERSION="1.1.2-event-safe-candidate"` and candidate technical banner are historical markers; no gameplay code was changed in promotion.
- SHA256: Pack `949827c7aa7810348b68c9f3b07e9747181e7b645c77931a766f748c252faafa`; Lua `621611e93fedc62579ee0b80b46494e87d6b5be36157cf4bcd5adf8887640a8e`.

---


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
