-- ============================================================================
-- Native Withdraw Unlock
-- Total War: WARHAMMER III
--
-- Requires Cpecific's Memreader (_G.memreader).
--
-- Purpose:
--   Re-enable the game's native per-unit Withdraw order in battles where CA
--   sets BATTLE_SETUP_ALLIANCE.can_withdraw to false.
--
-- Important:
--   can_withdraw is a 1-byte field at BATTLE_SETUP_ALLIANCE + 0x248.
--   NEVER write it with:
--
--       mr.write(ptr, 0x248, true)
--
--   Memreader writes a Lua boolean as a 4-byte Windows BOOL.
--   Always use:
--
--       mr.write(ptr, 0x248, mr.uint8(1))
--
-- Verified pointer chain for the target game build:
--
--   battle.unit userdata
--       -> wrapper + 0x08
--       -> native battle_unit*
--       -> + 0x70
--       -> native battle_army*
--       -> + 0x140
--       -> BATTLE_SETUP_ALLIANCE*
--       -> + 0x248
--       -> can_withdraw (uint8)
--
-- Never touch memory before battle phase == "Deployed".
-- Do not monopolize the native unit selection handler; other mods use it too.
-- Use the shared CA phase callback and a short phase-watch fallback, then
-- bounded retry attempts to obtain a battle_unit through the player alliance.
-- ============================================================================

local TAG = "[NATIVE_WITHDRAW_UNLOCK]"
local VERSION = "1.1.2-event-safe-candidate"

-- One-switch logging control.
-- false = production/quiet; true = diagnostic logging.
local LOG_ENABLED = false

local mr = rawget(_G, "memreader")

local setup_alliance_ptr = nil
local unlocked = false
local stopped = false
local ui_missing_logged = false
local bootstrap_started = false
local bootstrap_attempts = 0
-- Initial attempt at Deployed, followed by eight increasingly sparse retries.
-- Total additional scan window: 60.75 seconds. No scan runs after success.
local RETRY_DELAYS_MS = {250, 500, 1000, 2000, 4000, 8000, 15000, 30000}


local function log(message)
    if not LOG_ENABLED then
        return
    end

    out(TAG .. " " .. tostring(message))
end


local function safe(fn)
    local ok, value = pcall(fn)
    return ok, value
end


local function current_phase()
    local ok, phase = safe(function()
        return bm:get_current_phase_name()
    end)

    return ok and phase or nil
end


local function is_null_pointer(ptr)
    if not ptr then
        return true
    end

    local ok, result = safe(function()
        return mr.eq(ptr, "\0\0\0\0\0\0\0\0")
    end)

    return (not ok) or result == true
end


local function same_pointer(a, b)
    if is_null_pointer(a) or is_null_pointer(b) then
        return false
    end

    local ok, result = safe(function()
        return mr.eq(a, b)
    end)

    return ok and result == true
end


local function stop(reason)
    if stopped then
        return
    end

    stopped = true
    log("Stopped: " .. tostring(reason))
end


-- ============================================================================
-- Native pointer resolution
--
-- Keep two independent sanity checks before any write:
--
--   1. battle_unit + 0x3EA0 must equal unit:unique_ui_id()
--   2. battle_unit + 0x70 and unit:army() wrapper + 0x08 must resolve to the
--      same native battle_army pointer.
--
-- If a future game update changes the layouts, the script stops instead of
-- writing through an unverified pointer chain.
-- ============================================================================

local function resolve_setup_alliance(unit)
    local ok_uid, lua_uid = safe(function()
        return unit:unique_ui_id()
    end)

    if not ok_uid then
        return nil, "unit:unique_ui_id() failed"
    end


    local ok_wrapper, unit_wrapper = safe(function()
        return mr.ud_topointer(unit)
    end)

    if not ok_wrapper or is_null_pointer(unit_wrapper) then
        return nil, "invalid battle.unit userdata wrapper"
    end


    local ok_native, native_unit = safe(function()
        return mr.read_pointer(unit_wrapper, 0x08)
    end)

    if not ok_native or is_null_pointer(native_unit) then
        return nil, "invalid native battle_unit pointer"
    end


    local ok_mem_uid, mem_uid = safe(function()
        return mr.read_int32(native_unit, 0x3EA0)
    end)

    if not ok_mem_uid or mem_uid ~= lua_uid then
        return nil, "battle_unit sanity check failed"
    end


    local ok_army, native_army = safe(function()
        return mr.read_pointer(native_unit, 0x70)
    end)

    if not ok_army or is_null_pointer(native_army) then
        return nil, "invalid native battle_army pointer"
    end


    local ok_army_obj, army_obj = safe(function()
        return unit:army()
    end)

    if not ok_army_obj or not army_obj then
        return nil, "unit:army() failed"
    end


    local ok_army_wrapper, army_wrapper = safe(function()
        return mr.ud_topointer(army_obj)
    end)

    if not ok_army_wrapper or is_null_pointer(army_wrapper) then
        return nil, "invalid battle_army userdata wrapper"
    end


    local ok_army_2, native_army_2 = safe(function()
        return mr.read_pointer(army_wrapper, 0x08)
    end)

    if not ok_army_2 or not same_pointer(native_army, native_army_2) then
        return nil, "battle_army pointer cross-check failed"
    end


    local ok_setup, setup = safe(function()
        return mr.read_pointer(native_army, 0x140)
    end)

    if not ok_setup or is_null_pointer(setup) then
        return nil, "invalid BATTLE_SETUP_ALLIANCE pointer"
    end


    local ok_gate, gate = safe(function()
        return mr.read_uint8(setup, 0x248)
    end)

    if not ok_gate or (gate ~= 0 and gate ~= 1) then
        return nil, "unexpected can_withdraw byte"
    end


    return setup
end


-- ============================================================================
-- Native gate
-- ============================================================================

local function read_can_withdraw()
    if not setup_alliance_ptr then
        return false, nil
    end

    return safe(function()
        return mr.read_uint8(setup_alliance_ptr, 0x248)
    end)
end


local function ensure_can_withdraw()
    local ok, value = read_can_withdraw()

    if not ok or (value ~= 0 and value ~= 1) then
        return false, "failed can_withdraw safety read"
    end

    if value == 0 then
        local write_ok, write_error = safe(function()
            -- EXACTLY ONE BYTE.
            mr.write(
                setup_alliance_ptr,
                0x248,
                mr.uint8(1)
            )
        end)

        if not write_ok then
            return false, write_error
        end

        local verify_ok, verify = read_can_withdraw()

        if not verify_ok or verify ~= 1 then
            return false, "can_withdraw write verification failed"
        end
    end

    return true
end


-- ============================================================================
-- Native Withdraw UI
--
-- After can_withdraw becomes 1, CA's native state propagation already updates
-- the button's active/disabled state. The remaining hidden visibility flags are
-- restored here.
--
-- Do NOT force CurrentState("down") in the production version. Let CA own hover,
-- selected and disabled state transitions.
-- ============================================================================

local function get_withdraw_ui()
    local root = core:get_ui_root()

    if not root then
        return nil, nil
    end

    local hud_extension = find_uicomponent(
        root,
        "hud_battle",
        "battle_orders",
        "battle_orders_pane",
        "orders_parent",
        "hud_extension"
    )

    local button_withdraw = find_uicomponent(
        root,
        "hud_battle",
        "battle_orders",
        "battle_orders_pane",
        "orders_parent",
        "hud_extension",
        "button_withdraw"
    )

    return hud_extension, button_withdraw
end


local function ensure_withdraw_ui_visible()
    local hud_extension, button_withdraw = get_withdraw_ui()

    if not hud_extension or not button_withdraw then
        if not ui_missing_logged then
            ui_missing_logged = true
            log("Withdraw UI lookup: hud_extension=" ..
                (hud_extension and "FOUND" or "MISSING") ..
                " button_withdraw=" ..
                (button_withdraw and "FOUND" or "MISSING"))
        end
    else
        ui_missing_logged = false
    end

    if hud_extension then
        local ok, visible = safe(function()
            return hud_extension:Visible()
        end)

        if ok and not visible then
            safe(function()
                hud_extension:SetVisible(true)
            end)
        end
    end

    if button_withdraw then
        local ok, visible = safe(function()
            return button_withdraw:Visible()
        end)

        if ok and not visible then
            safe(function()
                button_withdraw:SetVisible(true)
            end)
        end
    end
end


-- ============================================================================
-- Low-frequency maintenance
--
-- The tested battle kept can_withdraw == 1 after the initial write, but the
-- native structure has other writers. Recheck once per second and only write
-- again if CA actually resets the byte to 0.
-- ============================================================================

local function maintenance()
    if stopped or not unlocked then
        return
    end

    if current_phase() ~= "Deployed" then
        return
    end

    local ok, value = read_can_withdraw()

    if not ok or (value ~= 0 and value ~= 1) then
        stop("can_withdraw became unsafe to read")
        return
    end

    if value == 0 then
        local restore_ok, restore_error = ensure_can_withdraw()

        if not restore_ok then
            stop("failed restoring can_withdraw: " .. tostring(restore_error))
            return
        end

        log("Native can_withdraw was reset and has been restored.")
    end

    ensure_withdraw_ui_visible()

    bm:callback(maintenance, 1000)
end


-- ============================================================================
-- One-time initialization
-- ============================================================================

local function initialize_from_unit(unit)
    if stopped or unlocked or current_phase() ~= "Deployed" then
        return
    end

    local setup, resolve_error = resolve_setup_alliance(unit)

    if not setup then
        -- Do not write through a failed native pointer chain. In the rare case
        -- that a unit disappears between validation and initialization, let
        -- the bounded retry find a different valid unit instead.
        log("Validated unit became unusable: " .. tostring(resolve_error))
        return
    end

    setup_alliance_ptr = setup

    local gate_ok, gate_error = ensure_can_withdraw()

    if not gate_ok then
        stop("failed enabling native Withdraw: " .. tostring(gate_error))
        return
    end

    unlocked = true
    log("Native Withdraw unlocked for the local player's alliance.")

    -- Give CA a short window to propagate the native button state.
    bm:callback(function()
        if not stopped and current_phase() == "Deployed" then
            ensure_withdraw_ui_visible()
            maintenance()
        end
    end, 300)
end



-- ============================================================================
-- Player alliance unit discovery (no unit selection handler needed)
--
-- Search the player's alliance only. This is not an alternative memory
-- layout: each candidate passes the original UID and independent army-pointer
-- checks before the native gate is changed. Calls happen only during the
-- bounded bootstrap attempts, never each simulation frame.
-- ============================================================================

local function find_valid_unit_in_collection(units)
    if not units then
        return nil
    end

    local ok_count, count = safe(function()
        return units:count()
    end)
    if not ok_count or type(count) ~= "number" or count < 1 then
        return nil
    end

    for i = 1, count do
        local ok_unit, unit = safe(function()
            return units:item(i)
        end)
        if ok_unit and unit then
            local setup = resolve_setup_alliance(unit)
            if setup then
                return unit
            end
        end
    end
    return nil
end

local function find_fallback_player_unit()
    -- CA defines get_player_alliance() relative to the local player. Do not
    -- scan the enemy alliance or infer ownership from a potentially AI-controlled
    -- garrison unit; membership in this alliance is the authoritative filter.
    local ok_alliance, alliance = safe(function()
        return bm:get_player_alliance()
    end)
    if not ok_alliance or not alliance then
        return nil
    end

    local ok_armies, armies = safe(function()
        return alliance:armies()
    end)
    if not ok_armies or not armies then
        return nil
    end

    local ok_army_count, army_count = safe(function()
        return armies:count()
    end)
    if not ok_army_count or type(army_count) ~= "number" or army_count < 1 then
        return nil
    end

    for i = 1, army_count do
        local ok_army, army = safe(function()
            return armies:item(i)
        end)
        if ok_army and army then
            local ok_units, units = safe(function()
                return army:units()
            end)
            if ok_units then
                local valid = find_valid_unit_in_collection(units)
                if valid then
                    return valid
                end
            end

            -- CA exposes a separate list for some reinforcement groups.
            local ok_rein_count, rein_count = safe(function()
                return army:num_reinforcement_units()
            end)
            if ok_rein_count and type(rein_count) == "number" and rein_count > 0 then
                for k = 1, rein_count do
                    local ok_rein, rein_units = safe(function()
                        return army:get_reinforcement_units(k)
                    end)
                    if ok_rein then
                        local valid = find_valid_unit_in_collection(rein_units)
                        if valid then
                            return valid
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- ============================================================================
-- Race-safe one-time bootstrap
--
-- 1. CA phase change callback (shared list, no exclusive unit selection hook).
-- 2. Inexpensive phase watch, only until Deployed; no native reads prebattle.
-- 3. Eight bounded, spaced unit-acquisition retries if the objects are late.
-- Each route goes through the same guard and same native-safety checks.
-- ============================================================================

local attempt_bootstrap

attempt_bootstrap = function()
    if stopped or unlocked or current_phase() ~= "Deployed" then
        return
    end

    bootstrap_attempts = bootstrap_attempts + 1
    local unit = find_fallback_player_unit()
    if unit then
        log("Validated player-alliance unit on attempt " .. tostring(bootstrap_attempts))
        initialize_from_unit(unit)
    else
        log("No validated player-alliance unit on attempt " .. tostring(bootstrap_attempts))
    end

    if stopped or unlocked then
        return
    end

    local delay = RETRY_DELAYS_MS[bootstrap_attempts]
    if delay then
        bm:callback(attempt_bootstrap, delay)
    else
        log("Bootstrap retry budget exhausted; no further native scans will run.")
    end
end

local function on_deployed(trigger)
    if bootstrap_started or stopped or unlocked or current_phase() ~= "Deployed" then
        return
    end

    bootstrap_started = true
    log("Deployed bootstrap source=" .. tostring(trigger))
    attempt_bootstrap()
end

local function phase_watch()
    if stopped or unlocked or bootstrap_started then
        return
    end

    if current_phase() == "Deployed" then
        on_deployed("phase_watch")
    else
        -- Only a phase-name read, never a unit scan or native memory read.
        bm:callback(phase_watch, 500)
    end
end

-- ============================================================================
-- Init
-- ============================================================================

if not bm then
    return
end

log("Loaded version=" .. VERSION .. " can_withdraw_offset=0x248")

if not mr then
    log("Memreader is required but _G.memreader is nil.")
    return
end

-- This CA wrapper appends to a callback LIST, unlike the native single
-- register_unit_selection_handler() slot used by AI Army Control.
local phase_handler_ok = safe(function()
    bm:register_phase_change_callback("Deployed", function()
        on_deployed("phase_change")
    end)
end)
if not phase_handler_ok then
    log("Phase-change callback could not be registered; phase-watch remains active.")
end

-- The fallback is always armed even if CA's phase callback registration
-- succeeded, in case another script alters the phase notifications.
bm:callback(phase_watch, 500)
