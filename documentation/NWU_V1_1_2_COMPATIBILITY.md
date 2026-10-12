# NWU v1.1.2 — Event-safe initialization and AI Army Control compatibility

**Published:** 2026-10-12. **Evidence level:** user-reported in-game success, plus 11 passing offline simulated scenarios. Not a claim that all campaign/battle types are validated.

## Incident and investigation

The reporter's `script_log_111026_2121.txt` had NWU loaded and its native unit-selection registration call completed before battle. A player-unit card interaction happened during Deployment. On entering `Deployed`, NWU logged that no unit-selection anchor was cached, so it never attempted the native pointer chain or `can_withdraw` write.

A static inspection of the provided `AI_Army_Control.pack` showed its `script/pancake_lib/aigeneral_bm_ext.lua` uses the same single-slot native unit selection registration and a global `battle_manager_unit_selection_handler` wrapper, after setup during PrebattleWeather. CA `lib_battle_manager.lua` also registers the handler in its callback API. Two independent scripts using that native slot risk replacing each other. **The log did not capture the exact handler replacement**, so attribution to that particular mod remains an evidence-backed compatibility explanation, not a proved sole cause.

## v1.1.2 execution

1. Load only when Memreader exists. Register a *shared* `Deployed` phase-change callback, and schedule a lightweight 500ms phase watcher. No native memory read/write during Deployment.
2. On first observation of `Deployed`, latch `bootstrap_started` to avoid a duplicate initializer.
3. Enumerate the local player's CA battle-alliance armies, regular units and, where exposed, reinforcement units; accept only a unit passing all original native UID and army-pointer checks.
4. If none validates, schedule up to eight spaced retries (250, 500, 1000, 2000, 4000, 8000, 15000, 30000 ms). After a successful write, **no unit-list scanning continues**. After exhaustion, **no further initialization retries**.
5. Read `BATTLE_SETUP_ALLIANCE.can_withdraw` at `+0x248`. Write **exactly one byte** with `mr.uint8(1)` only if the existing byte equals zero. Verify. Then restore native Withdraw visibility and maintain the gate at a low 1-second cadence until battle phase ends.

## Compatibility and performance limits

- NWU does **not** use `bm:register_unit_selection_handler()` in v1.1.2; it cannot compete for that specific single-slot handler.
- Shared CA phase change listener plus independent phase watcher are fallback *triggers*, not overlapping tight unit scans.
- 500ms pre-Deployed timer only obtains the current phase; if a player stays on Deployment for a long time, this cheap check continues until battle starts. It is **not zero cost**.
- Maximum nine alliance scans after battle starts. Regular/reinforcement unit count bounds work per scan. After success, only the pre-existing 1-second gate/UI maintenance continues.
- Other modifications that replace CA phase infrastructure, corrupt battle userdata, change native layout, or remove HUD nodes may still be incompatible. The retry budget is finite.
- v1.1.0 previously depended on player selecting a unit and could lose that initialization event; v1.1.1 candidate added a fallback but still competed for the native handler. v1.1.2 removes that competition.
- The v1.1.2 Pack is **byte-identical to the candidate tested successfully**, including its embedded *candidate/unverified* historical notice. Top-level documentation has now been updated to reflect later real-game confirmation. Keeping the binary unchanged preserves exact validation provenance.
- When diagnosing, set `LOG_ENABLED = true` **inside the Lua stored in the actual Pack** and rebuild it; changing a loose source file does not affect an installed Pack.

## Native invariants

```text
battle.unit Lua userdata
  wrapper +0x08 -> battle_unit*
  battle_unit +0x3EA0 -> UID (must equal unit:unique_ui_id())
  battle_unit +0x70 -> battle_army*
  unit:army() userdata wrapper +0x08 -> same battle_army*
  battle_army +0x140 -> BATTLE_SETUP_ALLIANCE*
  setup +0x248 -> can_withdraw (uint8; must originally be 0 or 1)
```

**Never** use `mr.write(ptr, 0x248, true)`: Memreader Lua boolean writes a 4-byte Windows BOOL. Use `mr.uint8(1)` and verify.

## Game update status

The native offset chain was established using static reverse engineering; WH3 9.0.3 follow-up found P1–P4 offsets unchanged, but a broad P5 vector-size signature was non-unique. This does not imply full future-update compatibility, and the observed success is not a substitute for testing on arbitrary future executables. Original reports in `reverse_engineering/` are preserved as historical evidence; no binary addresses are altered by v1.1.2.

## QA evidence

The development candidate included Lua 5.4 mock checks for: standard Deployed phase callback; no phase event; phase callback registration throwing; late player units; no alliance; bad native UID; bad independent army pointer; reinforcement-only unit; native gate already 1; simultaneous phase notifier and watcher; reset gate restored in maintenance. All eleven completed. These tests verify Lua logic and guards, not real WH3 engine behavior.

## Reverting

The original v1.1.0 remains in repository history at commit `dcd0baf4e410228c4896c4f61df988ca172f6cc1`. Its Pack SHA256 is `e68ea1be87a272d1ff00da604f62bf0c8ad8ff45f7948fd04be72cd45eb55516`. Install **one** Pack with the `script/battle/mod/native_withdraw_unlock.lua` internal path, never both versions.
