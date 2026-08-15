-- The fullscreen map: input capture, zoom, panning and rendering.
--
-- Rendering note: Noita gives no way to blit a dynamically generated texture.
-- ModImageSetPixel edits the CPU copy fine, but GuiImage uploads a texture
-- once and caches it forever, so a live pixel canvas is off the table
-- (verified in game). Everything here is therefore drawn with stretched 1x1
-- sprites -- but batched by run length. Terrain is horizontally coherent, so
-- a row of 40 identical cells costs one widget instead of forty, which is
-- what keeps a full resolution fullscreen map affordable.

dofile_once("data/scripts/lib/utilities.lua") -- GUI_OPTION

local C = dofile_once("mods/cartographer/files/config.lua")
local store = dofile_once("mods/cartographer/files/store.lua")
local markers = dofile_once("mods/cartographer/files/markers.lua")
local persist = dofile_once("mods/cartographer/files/persist.lua")

local PX = "mods/cartographer/files/px.png"
local CHUNK_WORLD = C.CHUNK_WORLD
local AIR, SOLID, LIQUID = C.AIR, C.SOLID, C.LIQUID

local min, max = math.min, math.max

local M = {}

local gui = nil
local widget_id = 0

local V = {
	open = false,
	alpha = 0,
	scale = C.SCALE_DEFAULT,
	target_scale = C.SCALE_DEFAULT,
	x = 0, y = 0,          -- world position at the centre of the view
	dragging = false,
	drag_mx = 0, drag_my = 0,
	drag_ox = 0, drag_oy = 0,
	vel_x = 0, vel_y = 0,
	last_mx = nil, last_my = nil,
	stats = { runs = 0, chunks = 0, lod = 0 },
}
M.state = V

M.opt_pause = false
M.opt_immortal = true
M.opt_show_stats = false
M.widget_budget = C.WIDGET_BUDGET
M.key_map = C.KEY_MAP

-- ------------------------------------------------------------------ helpers

local function next_id()
	widget_id = widget_id + 1
	return 40000 + widget_id
end

local function player_entity()
	return EntityGetWithTag("player_unit")[1]
end

local function player_pos()
	local p = player_entity()
	if not p then return nil end
	local x, y = EntityGetFirstHitboxCenter(p)
	if not x then x, y = EntityGetTransform(p) end
	return x, y
end

-- Mouse in gui coordinates, derived from the world-space mouse and the camera
-- rect. Resolution independent, unlike scaling the raw screen position.
local function mouse_gui(gw, gh)
	local cx, cy, cw, ch = GameGetCameraBounds()
	if not cw or cw <= 0 or ch <= 0 then return nil end
	local mwx, mwy = DEBUG_GetMouseWorld()
	if not mwx then return nil end
	return ((mwx - cx) / cw) * gw, ((mwy - cy) / ch) * gh
end

local function rect(x, y, w, h, col, alpha)
	if w <= 0 or h <= 0 then return end
	GuiColorSetForNextWidget(gui, col[1], col[2], col[3], 1)
	GuiImage(gui, next_id(), x, y, PX, alpha, w, h, 0)
end

local function decompose(hex)
	return (math.floor(hex / 0x10000) % 0x100) / 255,
		(math.floor(hex / 0x100) % 0x100) / 255,
		(math.floor(hex) % 0x100) / 255
end

-- Cached per chunk: solid takes the biome tint, air is a dimmed version of it
-- so caves read as hollow, liquid shifts toward blue.
--
-- Air deliberately keeps a floor well above the backdrop. Explored-but-empty
-- space has to be obviously distinct from never-seen space, otherwise the fog
-- boundary is invisible and the map cannot answer "have I been here".
local function palette_for(chunk)
	if chunk.palette then return chunk.palette end
	local r, g, b = decompose(C.biome_colour(chunk.biome))
	local p = {
		[SOLID] = { r, g, b },
		[AIR] = { r * 0.30 + 0.050, g * 0.30 + 0.055, b * 0.30 + 0.075 },
		[LIQUID] = { r * 0.30 + 0.06, g * 0.42 + 0.14, b * 0.55 + 0.26 },
	}
	chunk.palette = p
	return p
end

local function pick_lod(scale)
	if C.CELL * scale >= C.LOD_MIN_PIXELS then return 0 end
	if C.CELL * 4 * scale >= C.LOD_MIN_PIXELS then return 1 end
	if C.CELL * 16 * scale >= C.LOD_MIN_PIXELS then return 2 end
	return 3
end

-- --------------------------------------------------------------- open/close

-- Every held-button flag on ControlsComponent. Disabling the component while
-- a button happens to be down can leave one of these latched true, and the
-- game then never sees a fresh press. Cleared on the way out.
local BUTTON_FLAGS = {
	"mButtonDownFire", "mButtonDownFire2", "mButtonDownAction", "mButtonDownThrow",
	"mButtonDownInteract", "mButtonDownLeft", "mButtonDownRight", "mButtonDownUp",
	"mButtonDownDown", "mButtonDownJump", "mButtonDownRun", "mButtonDownFly",
	"mButtonDownDig", "mButtonDownChangeItemR", "mButtonDownChangeItemL",
	"mButtonDownInventory", "mButtonDownHolsterItem", "mButtonDownDropItem",
	"mButtonDownKick", "mButtonDownEat", "mButtonDownLeftClick", "mButtonDownRightClick",
}

local function clear_button_state(ctrl)
	for i = 1, #BUTTON_FLAGS do
		pcall(ComponentSetValue2, ctrl, BUTTON_FLAGS[i], false)
	end
end

-- Locking input is the part that actually matters. Noita has no way to pause
-- from Lua, so without this a left click to drag the map would fire your wand
-- and WASD would walk you into a pit. Disabling ControlsComponent stops
-- movement, casting, throwing and interacting in one go.
local function take_controls(on)
	local p = player_entity()
	if not p then return end

	local ctrl = EntityGetFirstComponentIncludingDisabled(p, "ControlsComponent")
	if ctrl then
		if on then
			-- Remember the prior value so closing the map does not hand
			-- control back to a player who was disabled for some other
			-- reason (polymorph, cutscene, another mod).
			if V.prev_controls == nil then
				V.prev_controls = ComponentGetValue2(ctrl, "enabled")
			end
			ComponentSetValue2(ctrl, "enabled", false)
		else
			clear_button_state(ctrl)
			ComponentSetValue2(ctrl, "enabled", V.prev_controls ~= false)
			V.prev_controls = nil
		end
	end

	if M.opt_pause then
		local inv = EntityGetFirstComponentIncludingDisabled(p, "InventoryGuiComponent")
		if inv then ComponentSetValue2(inv, "mActive", on) end
	end
end

-- Other game logic can re-enable controls underneath us, so reassert every
-- frame the map is up rather than trusting the one call on open.
local function enforce_controls()
	local p = player_entity()
	if not p then return end
	local ctrl = EntityGetFirstComponentIncludingDisabled(p, "ControlsComponent")
	if ctrl and ComponentGetValue2(ctrl, "enabled") ~= false then
		ComponentSetValue2(ctrl, "enabled", false)
	end
end

local function keep_safe()
	if not M.opt_immortal then return end
	local p = player_entity()
	if not p then return end
	local dmg = EntityGetFirstComponentIncludingDisabled(p, "DamageModelComponent")
	if dmg then ComponentSetValue2(dmg, "invincibility_frames", 12) end
end

function M.open()
	if V.open then return end
	V.open = true
	V.alpha = 0
	V.vel_x, V.vel_y = 0, 0
	V.dragging = false
	V.last_mx, V.last_my = nil, nil
	local px, py = player_pos()
	if px then V.x, V.y = px, py end
	take_controls(true)
end

function M.close()
	if not V.open then return end
	V.open = false
	V.dragging = false
	take_controls(false)
end

function M.toggle()
	if V.open then M.close() else M.open() end
end

-- Frames the whole explored region.
local function fit_to_explored(gw, gh)
	if not store.has_explored() then return end
	local x0 = store.min_cx * C.CELL
	local x1 = (store.max_cx + 1) * C.CELL
	local y0 = store.min_cy * C.CELL
	local y1 = (store.max_cy + 1) * C.CELL
	V.x = (x0 + x1) * 0.5
	V.y = (y0 + y1) * 0.5
	local sx = gw / max(x1 - x0, 1)
	local sy = gh / max(y1 - y0, 1)
	V.target_scale = max(C.SCALE_MIN, min(C.SCALE_MAX, min(sx, sy) * 0.92))
end

-- -------------------------------------------------------------------- input

local function handle_input(gw, gh)
	local mx, my = mouse_gui(gw, gh)

	-- Zoom, anchored on the cursor so the point under the mouse stays put.
	local notches = 0
	if InputIsMouseButtonJustDown(C.WHEEL_UP) then notches = notches + 1 end
	if InputIsMouseButtonJustDown(C.WHEEL_DOWN) then notches = notches - 1 end
	if InputIsKeyJustDown(C.KEY_PLUS) then notches = notches + 1 end
	if InputIsKeyJustDown(C.KEY_MINUS) then notches = notches - 1 end

	if notches ~= 0 then
		local before = V.target_scale
		V.target_scale = max(C.SCALE_MIN, min(C.SCALE_MAX, before * (C.ZOOM_STEP ^ notches)))
		if mx and V.target_scale ~= before then
			-- Keep the world point under the cursor fixed across the zoom.
			local wx = (mx - gw * 0.5) / V.scale + V.x
			local wy = (my - gh * 0.5) / V.scale + V.y
			local k = V.scale / V.target_scale
			V.x = wx - (wx - V.x) * k
			V.y = wy - (wy - V.y) * k
		end
	end

	if InputIsKeyJustDown(C.KEY_HOME) then fit_to_explored(gw, gh) end

	-- Click and drag panning, with a little momentum on release.
	local down = InputIsMouseButtonDown(C.MOUSE_LEFT)
	if down and mx then
		if not V.dragging then
			V.dragging = true
			V.drag_mx, V.drag_my = mx, my
			V.drag_ox, V.drag_oy = V.x, V.y
			V.vel_x, V.vel_y = 0, 0
		else
			local nx = V.drag_ox - (mx - V.drag_mx) / V.scale
			local ny = V.drag_oy - (my - V.drag_my) / V.scale
			if V.last_mx then
				V.vel_x = (V.last_mx - mx) / V.scale
				V.vel_y = (V.last_my - my) / V.scale
			end
			V.x, V.y = nx, ny
		end
		V.last_mx, V.last_my = mx, my
	else
		V.dragging = false
		V.last_mx, V.last_my = nil, nil
	end

	if not V.dragging then
		V.x = V.x + V.vel_x
		V.y = V.y + V.vel_y
		V.vel_x = V.vel_x * C.PAN_FRICTION
		V.vel_y = V.vel_y * C.PAN_FRICTION
		if math.abs(V.vel_x) < 0.01 then V.vel_x = 0 end
		if math.abs(V.vel_y) < 0.01 then V.vel_y = 0 end
	end

	-- Right click recentres on the player.
	if InputIsMouseButtonJustDown(C.MOUSE_RIGHT) then
		local px, py = player_pos()
		if px then
			V.x, V.y = px, py
			V.vel_x, V.vel_y = 0, 0
		end
	end
end

-- ------------------------------------------------------------------ drawing

-- Draws one chunk from its cached run list, clamped to the viewport.
local function draw_chunk(chunk, lod, view, alpha, budget)
	local runs = store.runs(chunk, lod)
	local count = runs.n
	if count == 0 then return 0 end

	local wpc = store.world_per_cell(lod)
	local scale = view.scale
	local cell_px = wpc * scale
	local bleed = 0.6 -- overlap so neighbouring cells never show a seam

	local cwx = chunk.gx * CHUNK_WORLD
	local cwy = chunk.gy * CHUNK_WORLD
	local pal = palette_for(chunk)
	local ox = view.gw * 0.5 - view.x * scale
	local oy = view.gh * 0.5 - view.y * scale
	local drawn = 0

	for i = 0, count - 1 do
		if drawn >= budget then break end
		local b = i * 4
		local ry = runs[b + 1]
		local x0 = runs[b + 2]
		local x1 = runs[b + 3]
		local v = runs[b + 4]

		local top = (cwy + ry * wpc) * scale + oy
		local h = cell_px + bleed
		if top < view.clip_y0 then
			h = h - (view.clip_y0 - top)
			top = view.clip_y0
		end
		if top + h > view.clip_y1 then h = view.clip_y1 - top end

		if h > 0 then
			local sx = (cwx + x0 * wpc) * scale + ox
			local w = (x1 - x0) * cell_px + bleed
			if sx < view.clip_x0 then
				w = w - (view.clip_x0 - sx)
				sx = view.clip_x0
			end
			if sx + w > view.clip_x1 then w = view.clip_x1 - sx end

			if w > 0 then
				local col = pal[v]
				if col then
					GuiColorSetForNextWidget(gui, col[1], col[2], col[3], 1)
					GuiImage(gui, next_id(), sx, top, PX, alpha, w, h, 0)
					drawn = drawn + 1
				end
			end
		end
	end
	return drawn
end

-- Collects the chunks touching the view, then picks the coarsest LOD needed
-- to stay inside the widget budget. Zooming out therefore degrades detail
-- gracefully instead of dropping the framerate off a cliff.
local function draw_terrain(view, alpha)
	local visible = {}
	for gy, col in pairs(store.chunks) do
		local cwy = gy * CHUNK_WORLD
		if cwy + CHUNK_WORLD >= view.wy0 and cwy <= view.wy1 then
			for gx, chunk in pairs(col) do
				local cwx = gx * CHUNK_WORLD
				if cwx + CHUNK_WORLD >= view.wx0 and cwx <= view.wx1 then
					visible[#visible + 1] = chunk
				end
			end
		end
	end

	-- Draw from the middle of the view outwards. If the budget does run out
	-- despite the coarsening below, the chunks that get dropped are then the
	-- ones at the edges rather than an arbitrary scatter of holes, because
	-- chunk iteration order is otherwise unspecified.
	for i = 1, #visible do
		local ch = visible[i]
		local dx = (ch.gx * CHUNK_WORLD + CHUNK_WORLD * 0.5) - view.x
		local dy = (ch.gy * CHUNK_WORLD + CHUNK_WORLD * 0.5) - view.y
		ch.sort_d = dx * dx + dy * dy
	end
	table.sort(visible, function(a, b) return a.sort_d < b.sort_d end)

	-- Coarsen until the whole visible set fits, all the way to one cell per
	-- chunk. Stopping short of that was what left holes in the map when
	-- zoomed far out.
	local lod = pick_lod(view.scale)
	while lod < store.MAX_LOD do
		local est = 0
		for i = 1, #visible do
			est = est + store.runs(visible[i], lod).n
		end
		if est <= M.widget_budget then break end
		lod = lod + 1
	end

	local budget = M.widget_budget
	local total = 0
	for i = 1, #visible do
		local used = draw_chunk(visible[i], lod, view, alpha, budget - total)
		total = total + used
		if total >= budget then break end
	end

	V.stats.runs, V.stats.chunks, V.stats.lod = total, #visible, lod
end

-- Reconstruction of the inventory wand tooltip.
--
-- Noita's own item panel is drawn by the engine and cannot be summoned from
-- Lua, so this rebuilds it: the vanilla nine-piece background, the item's
-- real sprite, the same stat rows the inventory shows, and actual spell icons
-- pulled from gun_actions.lua. Everything it needs was captured at discovery.
local PANEL_BG = "data/ui_gfx/decorations/9piece0_gray.png"

local function stat_rows(m)
	local st = m.stats
	if not st then return nil end
	local rows = {}
	local function add(label, value)
		if value ~= nil then rows[#rows + 1] = { label, value } end
	end
	if st.sh ~= nil then add("Shuffle", st.sh and "Yes" or "No") end
	if st.pc then add("Spells/Cast", ("%d"):format(st.pc)) end
	if st.cd then add("Cast delay", ("%.2f s"):format(st.cd / 60)) end
	if st.rc then add("Recharge", ("%.2f s"):format(st.rc / 60)) end
	if st.mn then add("Mana max", ("%d"):format(st.mn)) end
	if st.mc then add("Mana chg", ("%d/s"):format(st.mc)) end
	if st.cap then add("Capacity", ("%d"):format(st.cap)) end
	if st.sp and st.sp ~= 0 then add("Spread", ("%.1f deg"):format(st.sp)) end
	if #rows == 0 then return nil end
	return rows
end

local function draw_item_panel(m, ax, ay, view, alpha)
	local title = m.name or markers.NAMES[m.kind] or "item"
	local rows = stat_rows(m)
	local info = m.info or {}
	local spells = m.spells or {}

	local ICON = 10       -- spell icon cell size in gui units
	local PER_ROW = 8
	local pad = 5

	-- Measure.
	local w = #title * 4.4
	if rows then
		for i = 1, #rows do
			local rw = #rows[i][1] * 4.2 + #rows[i][2] * 4.2 + 26
			if rw > w then w = rw end
		end
	end
	for i = 1, #info do
		local rw = #info[i] * 4.2
		if rw > w then w = rw end
	end
	local spell_rows = (#spells > 0) and math.ceil(#spells / PER_ROW) or 0
	if #spells > 0 then
		local sw = math.min(#spells, PER_ROW) * ICON
		if sw > w then w = sw end
	end
	if m.sprite then w = math.max(w, 60) end

	local h = 11
	if m.sprite then h = h + 20 end
	if rows then h = h + #rows * 9 + 2 end
	h = h + #info * 9
	if spell_rows > 0 then h = h + spell_rows * ICON + 4 end

	local pw, ph = w + pad * 2, h + pad * 2

	-- Keep the panel on screen; flip sides near the edges.
	local bx = ax + 7
	local by = ay - 6
	if bx + pw > view.clip_x1 then bx = ax - 7 - pw end
	if bx < view.clip_x0 then bx = view.clip_x0 end
	if by + ph > view.clip_y1 then by = view.clip_y1 - ph end
	if by < view.clip_y0 then by = view.clip_y0 end

	-- Vanilla panel chrome, so it reads as part of the game's UI.
	GuiZSetForNextWidget(gui, -7300)
	GuiImageNinePiece(gui, next_id(), bx, by, pw, ph, alpha * 0.98, PANEL_BG, PANEL_BG)

	local cx, cy = bx + pad, by + pad

	local col = markers.COLOURS[m.kind] or C.COL_TEXT
	GuiZSetForNextWidget(gui, -7310)
	GuiColorSetForNextWidget(gui, col[1], col[2], col[3], alpha)
	GuiText(gui, cx, cy, title)
	cy = cy + 11

	if m.sprite then
		GuiZSetForNextWidget(gui, -7310)
		GuiImage(gui, next_id(), cx, cy, m.sprite, alpha, 1, 1, 0)
		cy = cy + 20
	end

	if rows then
		for i = 1, #rows do
			GuiZSetForNextWidget(gui, -7310)
			GuiColorSetForNextWidget(gui, C.COL_TEXT_DIM[1], C.COL_TEXT_DIM[2], C.COL_TEXT_DIM[3], alpha)
			GuiText(gui, cx, cy, rows[i][1])
			GuiZSetForNextWidget(gui, -7310)
			GuiColorSetForNextWidget(gui, C.COL_TEXT[1], C.COL_TEXT[2], C.COL_TEXT[3], alpha)
			GuiText(gui, cx + w - #rows[i][2] * 4.2, cy, rows[i][2])
			cy = cy + 9
		end
		cy = cy + 2
	end

	for i = 1, #info do
		GuiZSetForNextWidget(gui, -7310)
		GuiColorSetForNextWidget(gui, C.COL_TEXT[1], C.COL_TEXT[2], C.COL_TEXT[3], alpha)
		GuiText(gui, cx, cy, info[i])
		cy = cy + 9
	end

	-- Spell icons, falling back to a coloured slot if the sprite is unknown.
	for i = 1, #spells do
		local col_i = (i - 1) % PER_ROW
		local row_i = math.floor((i - 1) / PER_ROW)
		local sx = cx + col_i * ICON
		local sy = cy + row_i * ICON
		local icon = markers.spell_icon(spells[i])
		if icon then
			GuiZSetForNextWidget(gui, -7310)
			GuiImage(gui, next_id(), sx, sy, icon, alpha, 1, 1, 0)
		else
			GuiZSetForNextWidget(gui, -7310)
			rect(sx + 1, sy + 1, 7, 7, markers.COLOURS[markers.SPELL], alpha * 0.8)
		end
	end
end

-- Markers keep a constant screen size at every zoom, so a wand is findable
-- whether you are inspecting one room or the whole run. Drawn as a dark
-- outline plus a coloured core so they stay readable over any terrain.
local function draw_markers(view, alpha)
	if not markers.enabled then return end
	local scale = view.scale
	local ox = view.gw * 0.5 - view.x * scale
	local oy = view.gh * 0.5 - view.y * scale
	local hovered, hx, hy = nil, 0, 0
	local mx, my = view.mouse_x, view.mouse_y

	for _, m in pairs(markers.items) do
		local sx = m.x * scale + ox
		local sy = m.y * scale + oy
		if sx >= view.clip_x0 and sx <= view.clip_x1 and sy >= view.clip_y0 and sy <= view.clip_y1 then
			local col = markers.COLOURS[m.kind] or C.COL_TEXT
			rect(sx - 2, sy - 2, 4, 4, C.COL_FRAME_DARK, alpha * 0.85)
			rect(sx - 1, sy - 1, 2, 2, col, alpha)
			if mx and not hovered then
				local dx, dy = mx - sx, my - sy
				if dx * dx + dy * dy <= 16 then
					hovered, hx, hy = m, sx, sy
				end
			end
		end
	end

	if hovered then
		draw_item_panel(hovered, hx, hy, view, alpha)
	end
end

local function draw_player(view, alpha)
	local px, py = player_pos()
	if not px then return end
	local sx = (px - view.x) * view.scale + view.gw * 0.5
	local sy = (py - view.y) * view.scale + view.gh * 0.5
	if sx < view.clip_x0 or sx > view.clip_x1 or sy < view.clip_y0 or sy > view.clip_y1 then
		-- Off screen: pin an arrow-ish marker to the edge so the player can
		-- always tell which way they are.
		sx = max(view.clip_x0 + 2, min(view.clip_x1 - 2, sx))
		sy = max(view.clip_y0 + 2, min(view.clip_y1 - 2, sy))
		rect(sx - 2, sy - 2, 4, 4, C.COL_PLAYER, alpha * 0.55)
		return
	end

	local pulse = 0.72 + 0.28 * math.sin(GameGetFrameNum() * 0.09)
	rect(sx - 3.5, sy - 0.5, 7, 1, C.COL_PLAYER, alpha * pulse)
	rect(sx - 0.5, sy - 3.5, 1, 7, C.COL_PLAYER, alpha * pulse)
	rect(sx - 1, sy - 1, 2, 2, C.COL_PLAYER, alpha)
end

local function draw_frame(view, alpha)
	local x0, y0 = view.clip_x0, view.clip_y0
	local x1, y1 = view.clip_x1, view.clip_y1
	local t = 1
	rect(x0 - t, y0 - t, (x1 - x0) + t * 2, t, C.COL_FRAME, alpha * 0.85)
	rect(x0 - t, y1, (x1 - x0) + t * 2, t, C.COL_FRAME, alpha * 0.85)
	rect(x0 - t, y0, t, y1 - y0, C.COL_FRAME, alpha * 0.85)
	rect(x1, y0, t, y1 - y0, C.COL_FRAME, alpha * 0.85)
end

local function text(x, y, s, col, alpha)
	GuiColorSetForNextWidget(gui, col[1], col[2], col[3], alpha)
	GuiText(gui, x, y, s)
end

local function draw_chrome(view, alpha)
	local px, py = player_pos()
	local biome = "unknown"
	if px then
		local ok, name = pcall(BiomeMapGetName, px, py)
		if ok and name then
			biome = tostring(name):gsub("^%$biome_", ""):gsub("^_+", ""):gsub("_+$", ""):gsub("_", " ")
			biome = biome:lower()
			-- The open sky above the mines has no biome of its own.
			if biome == "" or biome == "empty" then biome = "the surface" end
		end
	end

	text(view.clip_x0 + 3, view.clip_y0 - 11, "MAP  -  " .. biome, C.COL_TEXT, alpha)

	local right = ("%.0f, %.0f    x%.2f"):format(V.x, V.y, V.scale)
	text(view.clip_x1 - 96, view.clip_y0 - 11, right, C.COL_TEXT_DIM, alpha)

	text(view.clip_x0 + 3, view.clip_y1 + 2,
		"M close   drag pan   wheel zoom   right click centre   Home fit",
		C.COL_TEXT_DIM, alpha * 0.9)

	if M.opt_show_stats then
		local s = ("runs %d  chunks %d  lod %d  cells %d"):format(
			V.stats.runs, V.stats.chunks, V.stats.lod, store.known_cells)
		text(view.clip_x1 - 150, view.clip_y1 + 2, s, C.COL_TEXT_DIM, alpha * 0.8)
	end

	-- Never fail silently: if the map has outgrown what we will write into
	-- the save, say so, because reloading will lose the newest exploration.
	if persist.oversized then
		text(view.clip_x0 + 3, view.clip_y0 - 11 + 9,
			"map too large to save - newest exploration will not persist",
			markers.COLOURS[markers.WAND], alpha)
	end
end

-- --------------------------------------------------------------------- tick

function M.update()
	if gui == nil then gui = GuiCreate() end

	-- Toggle. Guarded so it does not fire while a real inventory screen is up.
	if InputIsKeyJustDown(M.key_map) and not (GameIsInventoryOpen() and not V.open) then
		M.toggle()
	end
	if V.open and InputIsKeyJustDown(C.KEY_ESCAPE) then M.close() end

	-- Start a GUI frame every single frame, even with the map shut.
	--
	-- Noita's GUI is immediate mode. Once a Gui object exists, skipping
	-- GuiStartFrame leaves the widgets from the last frame we drew resident,
	-- and a leftover fullscreen backdrop goes on eating mouse clicks -- which
	-- is why firing stayed broken after closing the map until the game was
	-- restarted. Starting the frame and drawing nothing clears the set.
	GuiStartFrame(gui)
	widget_id = 0
	if GUI_OPTION then
		if GUI_OPTION.NoPositionTween then
			GuiOptionsAdd(gui, GUI_OPTION.NoPositionTween)
		end
		-- Belt and braces: nothing the map draws should ever be clickable.
		if GUI_OPTION.NonInteractive then
			GuiOptionsAdd(gui, GUI_OPTION.NonInteractive)
		end
	end
	GuiZSet(gui, -7000)

	if not V.open then
		if V.alpha > 0 then V.alpha = max(0, V.alpha - C.FADE_SPEED) end
		if V.alpha <= 0 then return end
	else
		V.alpha = min(1, V.alpha + C.FADE_SPEED)
		keep_safe()
		enforce_controls()
	end

	local gw, gh = GuiGetScreenDimensions(gui)
	local alpha = V.alpha

	if V.open then handle_input(gw, gh) end

	-- Smooth the zoom toward its target.
	V.scale = V.scale + (V.target_scale - V.scale) * C.ZOOM_SMOOTH
	if math.abs(V.target_scale - V.scale) < 0.0001 then V.scale = V.target_scale end

	local margin_x, margin_top, margin_bottom = 8, 14, 12
	local view = {
		x = V.x, y = V.y, scale = V.scale,
		gw = gw, gh = gh,
		clip_x0 = margin_x,
		clip_y0 = margin_top,
		clip_x1 = gw - margin_x,
		clip_y1 = gh - margin_bottom,
	}
	view.wx0 = V.x - (gw * 0.5) / V.scale
	view.wx1 = V.x + (gw * 0.5) / V.scale
	view.wy0 = V.y - (gh * 0.5) / V.scale
	view.wy1 = V.y + (gh * 0.5) / V.scale

	view.mouse_x, view.mouse_y = mouse_gui(gw, gh)

	rect(0, 0, gw, gh, C.COL_BACKDROP, alpha * C.BACKDROP_ALPHA)
	draw_terrain(view, alpha)
	draw_markers(view, alpha)
	draw_player(view, alpha)
	draw_frame(view, alpha)
	draw_chrome(view, alpha)
end

return M
