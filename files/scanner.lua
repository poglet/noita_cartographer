-- Records what the player has seen and what it looks like.
--
-- Fog of war is taken straight from GameGetCameraBounds(): the rectangle the
-- engine just rendered is, by definition, exactly what was on screen. Every
-- cell inside it is marked seen. There is no reveal radius and no
-- line-of-sight guesswork -- if it was drawn, it is on the map, and if it
-- never was, it never appears.
--
-- Terrain appearance is a separate, slower problem. Noita exposes no "what
-- material is at this pixel" call, so each cell is classified with zero
-- length raytraces (the same trick the Minimap workshop mod uses). That is
-- far too slow to do for a whole screen every frame, so it runs on a budget
-- with a wrapping cursor: newly seen cells are filled in over a few frames,
-- and a second, smaller sweep re-checks known cells so digging and
-- explosions show up.

local C = dofile_once("mods/cartographer/files/config.lua")
local store = dofile_once("mods/cartographer/files/store.lua")
local markers = dofile_once("mods/cartographer/files/markers.lua")

local CHUNK = C.CHUNK
local CELL = C.CELL
local UNKNOWN, AIR, SOLID, LIQUID = C.UNKNOWN, C.AIR, C.SOLID, C.LIQUID

local floor = math.floor
local sbyte = string.byte

local M = {}

M.scan_budget = C.SCAN_BUDGET
M.refresh_budget = C.REFRESH_BUDGET

local scan_cursor = 0    -- row offset within the camera rect
local refresh_cursor = 0
local exists_cache = {}  -- per frame: has this chunk streamed in?
local exists_frame = -1

local function chunk_exists(gx, gy)
	local frame = GameGetFrameNum()
	if frame ~= exists_frame then
		exists_cache = {}
		exists_frame = frame
	end
	-- Biased so negative chunk coordinates cannot collide with positive ones.
	local key = (gx + 32768) * 65536 + (gy + 32768)
	local hit = exists_cache[key]
	if hit == nil then
		local wx, wy = gx * C.CHUNK_WORLD, gy * C.CHUNK_WORLD
		hit = DoesWorldExistAt(wx, wy, wx + C.CHUNK_WORLD - 1, wy + C.CHUNK_WORLD - 1)
		exists_cache[key] = hit
	end
	return hit
end

-- A zero length raytrace acts as a point sample of the terrain.
local function classify(wx, wy)
	if RaytraceSurfaces(wx, wy, wx, wy) then return SOLID end
	if RaytraceSurfacesAndLiquiform(wx, wy, wx, wy) then return LIQUID end
	return AIR
end

local function tag_biome(chunk)
	if chunk.biome then return end
	local wx = chunk.gx * C.CHUNK_WORLD + C.CHUNK_WORLD * 0.5
	local wy = chunk.gy * C.CHUNK_WORLD + C.CHUNK_WORLD * 0.5
	local ok, name = pcall(BiomeMapGetName, wx, wy)
	chunk.biome = (ok and name) or "default"
end

-- Walks one row of the camera rect, sampling cells that match `want`.
-- Returns how much budget was consumed.
local function sweep_row(cy, cx0, cx1, budget, want_unknown)
	local used = 0
	local gy = floor(cy / CHUNK)
	local ry = cy - gy * CHUNK

	local cx = cx0
	while cx <= cx1 and used < budget do
		local gx = floor(cx / CHUNK)
		local chunk_end = (gx + 1) * CHUNK - 1
		local stop = (chunk_end < cx1) and chunk_end or cx1

		if chunk_exists(gx, gy) then
			local ch = store.chunk(gx, gy, true)
			tag_biome(ch)
			local row = ch.rows[ry]
			local base = gx * CHUNK

			for c = cx, stop do
				if used >= budget then break end
				local rx = c - base
				local v = row and sbyte(row, rx + 1) or UNKNOWN
				local interested = want_unknown and (v == UNKNOWN) or ((not want_unknown) and v ~= UNKNOWN)
				if interested then
					store.set(c, cy, classify(c * CELL, cy * CELL))
					used = used + 1
				end
			end
		end
		cx = stop + 1
	end
	return used
end

function M.update()
	local x, y, w, h = GameGetCameraBounds()
	if not x or not w or w <= 0 then return end

	local cx0 = floor(x / CELL)
	local cy0 = floor(y / CELL)
	local cx1 = floor((x + w) / CELL)
	local cy1 = floor((y + h) / CELL)
	local rows = cy1 - cy0 + 1
	if rows <= 0 then return end

	-- Pass 1: fill in cells never seen before. The cursor wraps so that a
	-- fast moving player still gets even coverage instead of only the top.
	local budget = M.scan_budget
	if scan_cursor >= rows then scan_cursor = 0 end
	local i = 0
	while i < rows and budget > 0 do
		local cy = cy0 + ((scan_cursor + i) % rows)
		budget = budget - sweep_row(cy, cx0, cx1, budget, true)
		i = i + 1
	end
	scan_cursor = (scan_cursor + i) % rows

	-- Pass 2: re-check already known cells so terrain changes propagate.
	local rbudget = M.refresh_budget
	if rbudget > 0 then
		if refresh_cursor >= rows then refresh_cursor = 0 end
		local j = 0
		while j < rows and rbudget > 0 do
			local cy = cy0 + ((refresh_cursor + j) % rows)
			rbudget = rbudget - sweep_row(cy, cx0, cx1, rbudget, false)
			j = j + 1
		end
		refresh_cursor = (refresh_cursor + j) % rows
	end

	store.flush()

	-- Items are discovered by the same rule as terrain: inside the rect that
	-- was actually rendered. Entity queries are not cheap enough to run every
	-- frame, and items do not appear that fast, so this runs periodically.
	if GameGetFrameNum() % 12 == 0 then
		markers.update(x, y, w, h)
	end
end

return M
