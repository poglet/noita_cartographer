-- Cartographer: a fullscreen map for Noita.
--
-- Press M for a fullscreen map with drag panning, wheel zoom and fog of war
-- that matches exactly what has been on screen.

dofile_once("data/scripts/lib/utilities.lua")

local C = dofile_once("mods/cartographer/files/config.lua")
local store = dofile_once("mods/cartographer/files/store.lua")
local scanner = dofile_once("mods/cartographer/files/scanner.lua")
local mapview = dofile_once("mods/cartographer/files/mapview.lua")
local persist = dofile_once("mods/cartographer/files/persist.lua")
local markers = dofile_once("mods/cartographer/files/markers.lua")

local settings_frame = -1

local function num_setting(id, fallback)
	local v = ModSettingGet("cartographer." .. id)
	if type(v) == "number" then return v end
	return fallback
end

local function bool_setting(id, fallback)
	local v = ModSettingGet("cartographer." .. id)
	if type(v) == "boolean" then return v end
	return fallback
end

-- Settings are cheap to read but not free, so refresh them about once a
-- second rather than every frame.
local function refresh_settings()
	local frame = GameGetFrameNum()
	if settings_frame > 0 and frame - settings_frame < 60 then return end
	settings_frame = frame

	scanner.scan_budget = num_setting("scan_budget", C.SCAN_BUDGET)
	scanner.refresh_budget = num_setting("refresh_budget", C.REFRESH_BUDGET)
	markers.enabled = bool_setting("markers", true)
	mapview.opt_immortal = bool_setting("safe_while_open", true)
	mapview.opt_pause = bool_setting("try_engine_pause", false)
	mapview.opt_show_stats = bool_setting("show_stats", false)
	mapview.key_map = num_setting("map_key", C.KEY_MAP)

	if bool_setting("persist", true) then
		persist.autosave_interval = 1800
	else
		persist.autosave_interval = math.huge
	end
end

function OnPlayerSpawned(player_entity)
	if bool_setting("persist", true) then
		persist.load()
	end
end

function OnWorldPostUpdate()
	refresh_settings()
	scanner.update()
	mapview.update()
	persist.tick()
end

-- The map has to keep working while the game is paused, and OnWorldPostUpdate
-- does not run then.
function OnPausePreUpdate()
	mapview.update()
end

function OnPlayerDied(player_entity)
	if bool_setting("persist", true) then
		persist.save_now()
	end
end
