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
-- The script deliberately waits for phase == "Deployed" before any memory
-- access. A unit selected during Deployment may be cached as the pointer anchor and is
-- deliberately retained across the Deployment -> Deployed deselection churn.
-- No memory is touched until the battle actually starts.
-- ============================================================================

local TAG = "[NATIVE_WITHDRAW_UNLOCK]"
local VERSION = "1.1.0"

-- One-switch logging control.
-- false = production/quiet; true = diagnostic logging.
local LOG_ENABLED = false

local mr = rawget(_G, "memreader")

local anchor_unit = nil
local anchor_source_phase = nil
local setup_alliance_ptr = nil
local unlocked = false
local stopped = false
local waiting_for_anchor_logged = false
local ui_missing_logged = false


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
        if anchor_source_phase ~= "Deployed" then
            log("Cached pre-Deployed anchor was not usable after battle start (" ..
                tostring(resolve_error) .. "); waiting for a fresh player-unit selection.")
            anchor_unit = nil
            anchor_source_phase = nil
            return
        end

        stop(resolve_error)
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
-- Selection anchor
--
-- A selection during Deployment is only cached. No memory access occurs until
-- phase == "Deployed".
-- ============================================================================

function NATIVE_WITHDRAW_UNLOCK_SELECTION_HANDLER(unit, is_selected)
    if stopped or unlocked then
        return
    end

    if not is_selected then
        -- IMPORTANT: do not clear a cached Deployment anchor on deselection.
        -- Newer WH3 builds may emit deselection while transitioning from
        -- Deployment -> Deployed. The original script cleared anchor_unit here,
        -- which could leave the mod waiting forever with no native init attempt.
        return
    end

    local ok, controlled = safe(function()
        return unit:is_player_controlled()
    end)

    if ok and controlled == true then
        anchor_unit = unit
        anchor_source_phase = current_phase()
        waiting_for_anchor_logged = false

        local ok_uid, uid = safe(function()
            return unit:unique_ui_id()
        end)

        if ok_uid then
            log("Cached player unit anchor uid=" .. tostring(uid) ..
                " phase=" .. tostring(anchor_source_phase))
        else
            log("Cached player unit anchor phase=" .. tostring(anchor_source_phase))
        end
    end
end


local function poll_for_anchor()
    if stopped or unlocked then
        return
    end

    local phase = current_phase()

    if phase == "Deployed" then
        if anchor_unit then
            local source_phase = anchor_source_phase
            initialize_from_unit(anchor_unit)

            if stopped or unlocked then
                return
            end

            -- initialize_from_unit only returns without stop/unlock if a cached
            -- pre-Deployed anchor was rejected as stale. Wait for a fresh player
            -- selection instead of repeatedly retrying the same userdata.
            if source_phase ~= "Deployed" and not anchor_unit then
                waiting_for_anchor_logged = false
            end
        elseif not waiting_for_anchor_logged then
            waiting_for_anchor_logged = true
            log("Phase=Deployed but no player unit anchor is cached; waiting for the first player-unit selection.")
        end
    end

    bm:callback(poll_for_anchor, 200)
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

local registered = safe(function()
    bm:register_unit_selection_handler(
        "NATIVE_WITHDRAW_UNLOCK_SELECTION_HANDLER"
    )
end)

if not registered then
    log("Failed to register unit selection handler.")
    return
end

log("Unit selection handler registered; preserving Deployment anchors across deselection.")
bm:callback(poll_for_anchor, 200)
