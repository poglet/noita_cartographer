-- Sparse, chunked store of everything the player has seen.
--
-- A chunk holds CHUNK rows, each row a plain Lua string of CHUNK bytes where
-- every byte is one cell (UNKNOWN/AIR/SOLID/LIQUID). Strings rather than
-- tables matter a lot here: a fully explored chunk costs ~6 KB this way
-- versus ~50 KB as a table of numbers, and a long run can touch a thousand
-- chunks.
--
-- Writes are batched. Strings are immutable, so rebuilding a row per cell
-- would allocate constantly; instead writes land in a pending table and each
-- touched row is rebuilt exactly once per flush.
--
-- Each chunk also caches downsampled copies (LOD 1 and 2). Without them,
-- zooming out would mean scanning millions of cells per frame.

local C = dofile_once("mods/cartographer/files/config.lua")

local CHUNK = C.CHUNK
local UNKNOWN, AIR, SOLID, LIQUID = C.UNKNOWN, C.AIR, C.SOLID, C.LIQUID
local EMPTY_ROW = string.rep(string.char(UNKNOWN), CHUNK)

local floor = math.floor
local schar, sbyte, ssub = string.char, string.byte, string.sub
local concat = table.concat

local M = {}

M.chunks = {}    -- chunks[gy][gx]
M.chunk_count = 0
M.known_cells = 0

-- Explored bounds in cell coordinates, for "fit to explored".
M.min_cx, M.min_cy, M.max_cx, M.max_cy = nil, nil, nil, nil

local dirty_writes = {} -- chunks awaiting flush

function M.reset()
	M.chunks = {}
	M.chunk_count = 0
	M.known_cells = 0
	M.min_cx, M.min_cy, M.max_cx, M.max_cy = nil, nil, nil, nil
	dirty_writes = {}
end

local function new_chunk(gx, gy)
	return {
		gx = gx,
		gy = gy,
		rows = {},     -- [0 .. CHUNK-1] = string, absent means all-unknown
		lods = {},     -- [1] and [2] = downsampled row tables
		lod_stale = true,
		pending = nil,
		biome = nil,
		known = 0,
	}
end

function M.chunk(gx, gy, create)
	local col = M.chunks[gy]
	if not col then
		if not create then return nil end
		col = {}
		M.chunks[gy] = col
	end
	local ch = col[gx]
	if not ch and create then
		ch = new_chunk(gx, gy)
		col[gx] = ch
		M.chunk_count = M.chunk_count + 1
	end
	return ch
end

function M.row(chunk, ry)
	return chunk.rows[ry] or EMPTY_ROW
end

-- Reads go through pending writes so a cell reads back correctly in the same
-- frame it was written.
function M.get(cx, cy)
	local gx, gy = floor(cx / CHUNK), floor(cy / CHUNK)
	local ch = M.chunk(gx, gy, false)
	if not ch then return UNKNOWN end
	local rx, ry = cx - gx * CHUNK, cy - gy * CHUNK
	local p = ch.pending
	if p then
		local pr = p[ry]
		if pr and pr[rx] then return pr[rx] end
	end
	local row = ch.rows[ry]
	if not row then return UNKNOWN end
	return sbyte(row, rx + 1)
end

function M.set(cx, cy, v)
	local gx, gy = floor(cx / CHUNK), floor(cy / CHUNK)
	local ch = M.chunk(gx, gy, true)
	local rx, ry = cx - gx * CHUNK, cy - gy * CHUNK

	local p = ch.pending
	if not p then
		p = {}
		ch.pending = p
		dirty_writes[#dirty_writes + 1] = ch
	end
	local pr = p[ry]
	if not pr then
		pr = {}
		p[ry] = pr
	end
	pr[rx] = v

	if not M.min_cx then
		M.min_cx, M.max_cx, M.min_cy, M.max_cy = cx, cx, cy, cy
	else
		if cx < M.min_cx then M.min_cx = cx end
		if cx > M.max_cx then M.max_cx = cx end
		if cy < M.min_cy then M.min_cy = cy end
		if cy > M.max_cy then M.max_cy = cy end
	end
end

-- Rebuilds one row by splicing only the spans that actually changed.
local function rebuild_row(old, writes)
	local keys = {}
	for k in pairs(writes) do keys[#keys + 1] = k end
	table.sort(keys)

	local parts, last, added = {}, 0, 0
	for i = 1, #keys do
		local x = keys[i]
		if x > last then
			parts[#parts + 1] = ssub(old, last + 1, x)
		end
		if sbyte(old, x + 1) == UNKNOWN and writes[x] ~= UNKNOWN then
			added = added + 1
		end
		parts[#parts + 1] = schar(writes[x])
		last = x + 1
	end
	if last < CHUNK then
		parts[#parts + 1] = ssub(old, last + 1)
	end
	return concat(parts), added
end

function M.flush()
	if #dirty_writes == 0 then return end
	for i = 1, #dirty_writes do
		local ch = dirty_writes[i]
		local p = ch.pending
		if p then
			for ry, writes in pairs(p) do
				local row, added = rebuild_row(ch.rows[ry] or EMPTY_ROW, writes)
				ch.rows[ry] = row
				ch.known = ch.known + added
				M.known_cells = M.known_cells + added
			end
			ch.pending = nil
			ch.lod_stale = true
		end
		dirty_writes[i] = nil
	end
end

-- --------------------------------------------------------------------- LOD

-- Majority vote over a factor x factor block. Ties resolve toward SOLID so
-- cave walls stay legible when zoomed out instead of dissolving into air.
local function downsample(rows, src_n, factor)
	local n = floor(src_n / factor)
	local out = {}
	for oy = 0, n - 1 do
		local parts = {}
		for ox = 0, n - 1 do
			local air, solid, liquid = 0, 0, 0
			for dy = 0, factor - 1 do
				local row = rows[oy * factor + dy]
				if row then
					local base = ox * factor
					for dx = 1, factor do
						local b = sbyte(row, base + dx)
						if b == SOLID then solid = solid + 1
						elseif b == AIR then air = air + 1
						elseif b == LIQUID then liquid = liquid + 1 end
					end
				end
			end
			local v, best = UNKNOWN, 0
			if air > 0 then v, best = AIR, air end
			if liquid >= best and liquid > 0 then v, best = LIQUID, liquid end
			if solid >= best and solid > 0 then v = SOLID end
			parts[#parts + 1] = schar(v)
		end
		out[oy] = concat(parts)
	end
	return out
end

-- Single place that drops every derived cache after the cells changed.
local function ensure_fresh(chunk)
	if chunk.lod_stale then
		chunk.lods = {}
		chunk.runs_cache = {}
		chunk.lod_stale = false
	end
end

-- How many cells one cell at each level stands for. Level 3 collapses a whole
-- chunk to a single cell, which is what keeps a fully zoomed out view of a
-- long run inside the sprite budget.
local LOD_FACTOR = { [0] = 1, [1] = 4, [2] = 16, [3] = 64 }
M.MAX_LOD = 3

function M.lod_rows(chunk, lod)
	ensure_fresh(chunk)
	if lod == 0 then return chunk.rows, CHUNK end

	local n = floor(CHUNK / (LOD_FACTOR[lod] or 16))
	local cached = chunk.lods[lod]
	if not cached then
		-- Build each level from the next finer one rather than from full
		-- resolution every time: 4096 + 256 + 16 samples per chunk instead of
		-- 4096 three times over. That difference is a visible hitch the first
		-- time a big map is zoomed right out.
		local src, src_n = M.lod_rows(chunk, lod - 1)
		cached = downsample(src, src_n, 4)
		chunk.lods[lod] = cached
	end
	return cached, n
end

-- Horizontal runs of identical cells, cached per chunk per LOD.
--
-- The decomposition depends only on the cell data, never on the camera, so
-- doing it once and reusing it is the difference between scanning a quarter
-- of a million cells every frame and simply walking a few hundred runs.
-- Flat numeric array, four entries per run: row, x0, x1 (exclusive), value.
function M.runs(chunk, lod)
	ensure_fresh(chunk)
	chunk.runs_cache = chunk.runs_cache or {}
	local hit = chunk.runs_cache[lod]
	if hit then return hit end

	local rows, n = M.lod_rows(chunk, lod)
	local out = { n = 0 }
	local count = 0
	for ry = 0, n - 1 do
		local row = rows[ry]
		if row then
			local start, val = 0, sbyte(row, 1)
			for rx = 1, n do
				local v = (rx < n) and sbyte(row, rx + 1) or -1
				if v ~= val then
					if val and val ~= UNKNOWN then
						local b = count * 4
						out[b + 1] = ry
						out[b + 2] = start
						out[b + 3] = rx
						out[b + 4] = val
						count = count + 1
					end
					start, val = rx, v
				end
			end
		end
	end
	out.n = count
	chunk.runs_cache[lod] = out
	return out
end

function M.world_per_cell(lod)
	return C.CELL * (LOD_FACTOR[lod] or 16)
end

function M.has_explored()
	return M.min_cx ~= nil
end

return M
