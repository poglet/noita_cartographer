-- Shared tunables and the colour palette. Kept in one place so the look of
-- the map can be adjusted without touching any of the logic.

local C = {}

-- ---------------------------------------------------------------- geometry

-- World units per map cell. This is the resolution of the fog-of-war and of
-- the terrain silhouette. 4 is a good balance: the camera is ~431x242 world
-- units, so a screenful is ~108x61 cells.
C.CELL = 4

-- Cells per chunk side. Chunks are the unit of allocation, LOD and saving.
C.CHUNK = 64
C.CHUNK_WORLD = C.CELL * C.CHUNK -- 256 world units

-- Cell values. Stored as raw bytes inside row strings, so keep them small.
C.UNKNOWN = 0
C.AIR = 1
C.SOLID = 2
C.LIQUID = 3

-- ------------------------------------------------------------------ input

-- SDL scancodes (data/scripts/debug/keycodes.lua).
C.KEY_MAP = 16 -- M
C.KEY_ESCAPE = 41
C.KEY_HOME = 74
C.KEY_PLUS = 46 -- =/+
C.KEY_MINUS = 45

C.MOUSE_LEFT = 1
C.MOUSE_RIGHT = 3
C.WHEEL_UP = 4
C.WHEEL_DOWN = 5

-- --------------------------------------------------------------- scanning

-- Terrain probes allowed per frame for never-before-seen cells. Each probe is
-- 1-2 raytraces, so this is the main cost knob.
C.SCAN_BUDGET = 900

-- Probes per frame spent re-checking cells we already know, so that digging
-- and exploding terrain shows up on the map.
C.REFRESH_BUDGET = 220

-- --------------------------------------------------------------- map view

-- Gui pixels per world unit at the zoomed-out extreme. 0.004 frames roughly
-- 160000 x 90000 world units, comfortably more than the whole world including
-- a full descent, so the limit is never reached in practice. Costs nothing:
-- the coarsest LOD is one cell per chunk, so the sprite count at this zoom is
-- just the number of explored chunks however far out you go.
C.SCALE_MIN = 0.004
C.SCALE_MAX = 1.600 -- roughly in-game 1:1
C.SCALE_DEFAULT = 0.220
C.ZOOM_STEP = 1.18 -- per wheel notch
C.ZOOM_SMOOTH = 0.28 -- lerp factor toward target zoom
C.PAN_FRICTION = 0.86 -- momentum decay after a flick
C.FADE_SPEED = 0.18

-- LOD selection: prefer the finest level whose cells still cover at least
-- this many gui pixels...
C.LOD_MIN_PIXELS = 1.0

-- ...but never emit more than this many sprites in one frame. The renderer
-- steps to a coarser level until it fits, so zooming out costs detail rather
-- than framerate. Measured in game: a full-detail view of ~22k explored cells
-- came to 846 sprites, so there is plenty of room above that.
C.WIDGET_BUDGET = 6000

-- ---------------------------------------------------------------- palette

-- Lua 5.1 has no integer division, so every channel extraction has to floor
-- explicitly or the fractional part leaks into the next channel.
local floor = math.floor

local function rgb(hex)
	return {
		(floor(hex / 0x10000) % 0x100) / 255,
		(floor(hex / 0x100) % 0x100) / 255,
		(floor(hex) % 0x100) / 255,
	}
end
C.rgb = rgb

C.COL_BACKDROP = rgb(0x07080C) -- behind everything, unexplored
C.COL_FRAME = rgb(0x8A7A5C)
C.COL_FRAME_DARK = rgb(0x2A2620)
C.COL_PLAYER = rgb(0xFFE9A0)
C.COL_TEXT = rgb(0xD8CDB4)
C.COL_TEXT_DIM = rgb(0x7A7263)

C.BACKDROP_ALPHA = 0.93

-- Biome tints. Solid rock takes the biome colour; air is a much darker
-- version of it so caves read as hollow without going pure black.
C.BIOME_COLOURS = {
	mines = 0x6E5B44,
	coalmine = 0x4A4038,
	coalmine_alt = 0x4A4038,
	excavationsite = 0x6A5A4A,
	fungicave = 0x5E4A63,
	snowcave = 0x5C6C7A,
	snowcastle = 0x6A7A88,
	rainforest = 0x4C6A44,
	rainforest_dark = 0x3C5638,
	rainforest_open = 0x557347,
	vault = 0x4E5A70,
	vault_frozen = 0x546A7C,
	crypt = 0x4A4450,
	sandcave = 0x8A7248,
	desert = 0x9A8250,
	hell = 0x7A3A34,
	wandcave = 0x5A4A6A,
	pyramid = 0x8C7A50,
	wizardcave = 0x4A4258,
	lake = 0x3A5A70,
	forest = 0x54683F,
	tower = 0x5A5248,
	robobase = 0x556065,
	liquidcave = 0x4E5A54,
	meat = 0x7A4046,
	boss_arena = 0x6A4A4A,
	the_end = 0x3A3A46,
	default = 0x5A5548,
}

-- Fallback so unlisted / modded biomes still get a stable, distinct tint
-- rather than all collapsing to grey.
function C.biome_colour(name)
	if not name or name == "" then return C.BIOME_COLOURS.default end
	local key = name:gsub("^%$biome_", ""):gsub("^%$", "")
	local hit = C.BIOME_COLOURS[key]
	if hit then return hit end

	local h = 5381
	for i = 1, #key do
		h = (h * 33 + key:byte(i)) % 0x1000000
	end
	-- Constrain to muted earthy tones so procedural colours match the palette.
	local r = 0x44 + (h % 0x40)
	local g = 0x40 + (floor(h / 0x40) % 0x38)
	local b = 0x38 + (floor(h / 0x1000) % 0x34)
	return r * 0x10000 + g * 0x100 + b
end

return C
