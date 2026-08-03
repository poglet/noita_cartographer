-- Per-run persistence.
--
-- Globals are the only storage a sandboxed mod has that survives quitting and
-- resuming a run, and they end up in the save's XML, so the payload is RLE
-- compressed and base64 encoded. Cell data is only ever one of four values,
-- which RLE flattens extremely well.
--
-- Serialising a thousand chunks at once would cost a visible hitch, so the
-- work is spread over frames: a snapshot of the chunk list is taken and a
-- handful are encoded per frame until the job finishes and the globals are
-- written.

local C = dofile_once("mods/cartographer/files/config.lua")
local store = dofile_once("mods/cartographer/files/store.lua")
local markers = dofile_once("mods/cartographer/files/markers.lua")

local CHUNK = C.CHUNK
local UNKNOWN = C.UNKNOWN
local EMPTY_ROW = string.rep(string.char(UNKNOWN), CHUNK)

local floor = math.floor
local schar, sbyte, ssub = string.char, string.byte, string.sub
local concat = table.concat

local KEY_COUNT = "CARTOGRAPHER_PARTS"
local KEY_PART = "CARTOGRAPHER_DATA_"
local KEY_MARKERS = "CARTOGRAPHER_MARKERS"

-- Keys used before the mod was renamed. Read as a fallback so a run started
-- under the old name keeps everything it had explored; the next autosave
-- rewrites it under the current keys.
local LEGACY_COUNT = "VALHEIM_MAP_PARTS"
local LEGACY_PART = "VALHEIM_MAP_DATA_"
local LEGACY_MARKERS = "VALHEIM_MAP_MARKERS"
local PART_SIZE = 60000
local VERSION = "VM1"

local M = {}

M.chunks_per_frame = 24
M.autosave_interval = 1800 -- frames (~30s at 60fps)

-- Refuse to write more than this into the save. See finish_job().
M.max_bytes = 2 * 1024 * 1024
M.oversized = false

local job = nil
local last_save_frame = 0
local loaded = false

-- ------------------------------------------------------------------ base64

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64R = {}
for i = 1, #B64 do B64R[ssub(B64, i, i)] = i - 1 end

local function b64encode(data)
	local out = {}
	local n = #data
	local i = 1
	while i + 2 <= n do
		local a, b, c = sbyte(data, i, i + 2)
		local v = a * 65536 + b * 256 + c
		out[#out + 1] = ssub(B64, floor(v / 262144) + 1, floor(v / 262144) + 1)
			.. ssub(B64, floor(v / 4096) % 64 + 1, floor(v / 4096) % 64 + 1)
			.. ssub(B64, floor(v / 64) % 64 + 1, floor(v / 64) % 64 + 1)
			.. ssub(B64, v % 64 + 1, v % 64 + 1)
		i = i + 3
	end
	local rem = n - i + 1
	if rem == 1 then
		local a = sbyte(data, i)
		local v = a * 16
		out[#out + 1] = ssub(B64, floor(v / 64) + 1, floor(v / 64) + 1)
			.. ssub(B64, v % 64 + 1, v % 64 + 1) .. "=="
	elseif rem == 2 then
		local a, b = sbyte(data, i, i + 1)
		local v = (a * 256 + b) * 4
		out[#out + 1] = ssub(B64, floor(v / 4096) + 1, floor(v / 4096) + 1)
			.. ssub(B64, floor(v / 64) % 64 + 1, floor(v / 64) % 64 + 1)
			.. ssub(B64, v % 64 + 1, v % 64 + 1) .. "="
	end
	return concat(out)
end

local function b64decode(s)
	s = s:gsub("[^A-Za-z0-9+/=]", "")
	local out = {}
	local i = 1
	while i + 3 <= #s do
		local c1, c2, c3, c4 = ssub(s, i, i), ssub(s, i + 1, i + 1), ssub(s, i + 2, i + 2), ssub(s, i + 3, i + 3)
		local v = (B64R[c1] or 0) * 262144 + (B64R[c2] or 0) * 4096
		if c3 == "=" then
			out[#out + 1] = schar(floor(v / 65536) % 256)
		elseif c4 == "=" then
			v = v + (B64R[c3] or 0) * 64
			out[#out + 1] = schar(floor(v / 65536) % 256, floor(v / 256) % 256)
		else
			v = v + (B64R[c3] or 0) * 64 + (B64R[c4] or 0)
			out[#out + 1] = schar(floor(v / 65536) % 256, floor(v / 256) % 256, v % 256)
		end
		i = i + 4
	end
	return concat(out)
end

-- --------------------------------------------------------------------- RLE

local function rle_encode(s)
	local out = {}
	local i, n = 1, #s
	while i <= n do
		local v = sbyte(s, i)
		local j = i + 1
		while j <= n and sbyte(s, j) == v and (j - i) < 255 do j = j + 1 end
		out[#out + 1] = schar(v, j - i)
		i = j
	end
	return concat(out)
end

local function rle_decode(s, expect)
	local out = {}
	local i = 1
	while i + 1 <= #s do
		out[#out + 1] = string.rep(schar(sbyte(s, i)), sbyte(s, i + 1))
		i = i + 2
	end
	local r = concat(out)
	if expect and #r < expect then r = r .. string.rep(schar(UNKNOWN), expect - #r) end
	return r
end

-- ------------------------------------------------------------------ packing

local function u16(n) return schar(n % 256, floor(n / 256) % 256) end
local function u32(n)
	return schar(n % 256, floor(n / 256) % 256, floor(n / 65536) % 256, floor(n / 16777216) % 256)
end
local function ru16(s, i) return sbyte(s, i) + sbyte(s, i + 1) * 256, i + 2 end
local function ru32(s, i)
	return sbyte(s, i) + sbyte(s, i + 1) * 256 + sbyte(s, i + 2) * 65536 + sbyte(s, i + 3) * 16777216, i + 4
end

local function encode_chunk(ch)
	local rows = {}
	for ry = 0, CHUNK - 1 do
		rows[#rows + 1] = ch.rows[ry] or EMPTY_ROW
	end
	local body = rle_encode(concat(rows))
	local biome = tostring(ch.biome or "")
	if #biome > 255 then biome = ssub(biome, 1, 255) end
	return u16(ch.gx + 32768) .. u16(ch.gy + 32768)
		.. schar(#biome) .. biome
		.. u32(#body) .. body
end

-- ---------------------------------------------------------------- save job

local function begin_job()
	local list = {}
	for _, col in pairs(store.chunks) do
		for _, ch in pairs(col) do
			if ch.known > 0 then list[#list + 1] = ch end
		end
	end
	job = { list = list, i = 1, parts = { VERSION, u32(#list) } }
end

local function finish_job()
	local raw = concat(job.parts)
	local encoded = b64encode(raw)

	-- Hard ceiling on what we are willing to push into someone's save file.
	--
	-- This data ends up inside the run's world state, and a long run can
	-- explore a lot of chunks. Rather than let the payload grow without
	-- limit, stop writing past the cap and keep the last good copy: an
	-- out-of-date map is a far better failure than a bloated save.
	if #encoded > M.max_bytes then
		M.oversized = true
		job = nil
		last_save_frame = GameGetFrameNum()
		return
	end
	M.oversized = false

	local count = math.ceil(#encoded / PART_SIZE)
	for p = 1, count do
		GlobalsSetValue(KEY_PART .. p, ssub(encoded, (p - 1) * PART_SIZE + 1, p * PART_SIZE))
	end
	-- Clear any parts left over from a previously larger save.
	local old = tonumber(GlobalsGetValue(KEY_COUNT, "0")) or 0
	for p = count + 1, old do
		GlobalsSetValue(KEY_PART .. p, "")
	end
	GlobalsSetValue(KEY_COUNT, tostring(count))
	GlobalsSetValue(KEY_MARKERS, markers.serialize())

	job = nil
	last_save_frame = GameGetFrameNum()
end

function M.tick()
	if job then
		local n = 0
		while job.i <= #job.list and n < M.chunks_per_frame do
			job.parts[#job.parts + 1] = encode_chunk(job.list[job.i])
			job.i = job.i + 1
			n = n + 1
		end
		if job.i > #job.list then finish_job() end
		return
	end

	if not loaded then return end
	if GameGetFrameNum() - last_save_frame >= M.autosave_interval and store.chunk_count > 0 then
		begin_job()
	end
end

-- Runs the whole save immediately, for shutdown-ish moments.
function M.save_now()
	if not loaded then return end
	begin_job()
	while job do
		local n = 0
		while job.i <= #job.list and n < 4096 do
			job.parts[#job.parts + 1] = encode_chunk(job.list[job.i])
			job.i = job.i + 1
			n = n + 1
		end
		if job.i > #job.list then finish_job() end
	end
end

-- -------------------------------------------------------------------- load

function M.load()
	-- OnPlayerSpawned can fire more than once in a session (respawns, polymorph
	-- shenanigans). Reloading would reset the store and throw away everything
	-- explored since the last autosave, so only ever load once.
	if loaded then return false end
	loaded = true
	last_save_frame = GameGetFrameNum()

	-- Prefer the current keys, but fall back to the pre-rename ones so a run
	-- started under the old mod name does not lose what it had explored.
	local count = tonumber(GlobalsGetValue(KEY_COUNT, "0")) or 0
	local kpart, kmarkers = KEY_PART, KEY_MARKERS
	if count <= 0 then
		local legacy = tonumber(GlobalsGetValue(LEGACY_COUNT, "0")) or 0
		if legacy > 0 then
			count, kpart, kmarkers = legacy, LEGACY_PART, LEGACY_MARKERS
		end
	end

	markers.deserialize(GlobalsGetValue(kmarkers, ""))
	if count <= 0 then return false end

	local parts = {}
	for p = 1, count do
		parts[#parts + 1] = GlobalsGetValue(kpart .. p, "")
	end
	local raw = b64decode(concat(parts))
	if #raw < 7 or ssub(raw, 1, 3) ~= VERSION then return false end

	local i = 4
	local total
	total, i = ru32(raw, i)

	store.reset()
	for _ = 1, total do
		if i + 4 > #raw then break end
		local gx, gy, blen
		gx, i = ru16(raw, i)
		gy, i = ru16(raw, i)
		gx, gy = gx - 32768, gy - 32768
		blen = sbyte(raw, i); i = i + 1
		local biome = ssub(raw, i, i + blen - 1); i = i + blen
		local blen2
		blen2, i = ru32(raw, i)
		local body = ssub(raw, i, i + blen2 - 1); i = i + blen2

		local flat = rle_decode(body, CHUNK * CHUNK)
		local ch = store.chunk(gx, gy, true)
		ch.biome = (biome ~= "") and biome or nil
		local known = 0
		for ry = 0, CHUNK - 1 do
			local row = ssub(flat, ry * CHUNK + 1, (ry + 1) * CHUNK)
			if row ~= EMPTY_ROW then
				ch.rows[ry] = row
				for k = 1, CHUNK do
					if sbyte(row, k) ~= UNKNOWN then known = known + 1 end
				end
			end
		end
		ch.known = known
		ch.lod_stale = true
		store.known_cells = store.known_cells + known

		-- Rebuild explored bounds from what we restored.
		if known > 0 then
			local x0, y0 = gx * CHUNK, gy * CHUNK
			local x1, y1 = x0 + CHUNK - 1, y0 + CHUNK - 1
			if not store.min_cx then
				store.min_cx, store.max_cx, store.min_cy, store.max_cy = x0, x1, y0, y1
			else
				if x0 < store.min_cx then store.min_cx = x0 end
				if x1 > store.max_cx then store.max_cx = x1 end
				if y0 < store.min_cy then store.min_cy = y0 end
				if y1 > store.max_cy then store.max_cy = y1 end
			end
		end
	end

	return true
end

function M.clear()
	local count = tonumber(GlobalsGetValue(KEY_COUNT, "0")) or 0
	for p = 1, count do GlobalsSetValue(KEY_PART .. p, "") end
	GlobalsSetValue(KEY_COUNT, "0")
	GlobalsSetValue(KEY_MARKERS, "")
end

return M
