dofile_once("data/scripts/lib/mod_settings.lua")

local mod_id = "cartographer" -- must match the mod's folder name

mod_settings_version = 2
mod_settings = {
	{
		id = "persist",
		ui_name = "Remember the map across saves",
		ui_description = "Explored terrain is stored in the save file, so quitting\nand resuming a run keeps everything you have uncovered.",
		value_default = true,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "markers",
		ui_name = "Mark discovered items",
		ui_description = "Pins wands, potions, spells, perks and orbs you have\nactually seen. Pins disappear once you pick the item up.",
		value_default = true,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "safe_while_open",
		ui_name = "Invulnerable while the map is open",
		ui_description = "Noita cannot truly pause, so the world keeps running while\nyou read the map. This stops you being killed while looking.",
		value_default = true,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "try_engine_pause",
		ui_name = "Experimental: force engine pause",
		ui_description = "Drives the private inventory-pause flag to try to halt the\nsimulation. Unverified, and may interact badly with the\ninventory. Leave off unless you want to experiment.",
		value_default = false,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "scan_budget",
		ui_name = "Terrain scan budget",
		ui_description = "Cells mapped per frame in newly seen areas.\nLower this if you notice a framerate cost.",
		value_default = 900,
		value_min = 100,
		value_max = 3000,
		value_display_multiplier = 1,
		value_display_formatting = " $0 cells/frame",
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "refresh_budget",
		ui_name = "Terrain refresh budget",
		ui_description = "Cells re-checked per frame so digging and explosions\nshow up on the map. Set to 0 to disable refreshing.",
		value_default = 220,
		value_min = 0,
		value_max = 1200,
		value_display_multiplier = 1,
		value_display_formatting = " $0 cells/frame",
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
	{
		id = "show_stats",
		ui_name = "Show render statistics",
		ui_description = "Displays draw batch counts on the map. Useful for tuning.",
		value_default = false,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
}

function ModSettingsUpdate( init_scope )
	mod_settings_update( mod_id, mod_settings, init_scope )
end

function ModSettingsGuiCount()
	return mod_settings_gui_count( mod_id, mod_settings )
end

function ModSettingsGui( gui, in_main_menu )
	mod_settings_gui( mod_id, mod_settings, gui, in_main_menu )
end
