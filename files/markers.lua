-- Remembered points of interest: wands, potions, spells, perks and orbs.
--
-- Two problems make this more than "draw every item entity".
--
-- First, Noita streams the world, so an item you saw two biomes ago does not
-- exist as an entity any more. Markers are therefore remembered independently
-- of the entity and keyed by position rather than entity id (ids are not
-- stable across a save/load either).
--
-- Second, remembered markers go stale: you pick the wand up, or it burns. So
-- whenever a marker's position is on screen -- meaning we can actually see
-- whether the item is still there -- it is reconciled against live entities
-- and dropped if it has gone.
--
-- Discovery uses the same rule as the terrain fog: an item counts as found
-- only once it has been inside the rendered camera rect.
--
-- Everything shown in the hover panel, including the wand's sprite path and
-- spell list, is captured at discovery time while the entity is still loaded.
-- Reading it lazily on hover would find nothing.

local C = dofile_once("mods/cartographer/files/config.lua")

local floor = math.floor

local M = {}

M.ORB, M.PERK, M.WAND, M.SPELL, M.POTION, M.ITEM = 1, 2, 3, 4, 5, 6

M.enabled = true
M.items = {}  -- key -> marker
M.count = 0

-- Priority order matters: a wand also carries the item_pickup tag, so the
-- more specific classification has to win.
local SOURCES = {
	{ tag = "this_is_orb" },
	{ tag = "item_perk" },
	{ tag = "wand" },
	{ tag = "card_action" },
	{ tag = "item_pickup" },
}

M.COLOURS = {
	[M.ORB] = C.rgb(0x8AF0FF),
	[M.PERK] = C.rgb(0xC792F0),
	[M.WAND] = C.rgb(0xFFC96B),
	[M.SPELL] = C.rgb(0x7FB6F0),
	[M.POTION] = C.rgb(0x7FE08A),
	[M.ITEM] = C.rgb(0xBFB9A8),
}

M.NAMES = {
	[M.ORB] = "orb",
	[M.PERK] = "perk",
	[M.WAND] = "wand",
	[M.SPELL] = "spell",
	[M.POTION] = "potion",
	[M.ITEM] = "item",
}

-- Position-quantised so the same physical object keeps one key even as
-- physics jostles it a little.
local function key_for(kind, x, y)
	return kind .. ":" .. floor(x / 8) .. ":" .. floor(y / 8)
end

-- ---------------------------------------------------- spell icon lookup

-- gun_actions.lua defines the global `actions` table, each entry carrying the
-- action's id and its inventory sprite. It lives inside data.wak but is
-- perfectly loadable at runtime. Done lazily: it is a big file and is only
-- needed once a wand panel is actually shown.
local action_sprites = nil

local function spell_icon(action_id)
	if action_sprites == nil then
		action_sprites = {}
		pcall(function()
			dofile_once("data/scripts/gun/gun_actions.lua")
			if type(actions) == "table" then
				for i = 1, #actions do
					local a = actions[i]
					if a and a.id and a.sprite then action_sprites[a.id] = a.sprite end
				end
			end
		end)
	end
	return action_sprites[action_id]
end

-- ----------------------------------------------------------- descriptions

local function translate(s)
	if not s or s == "" then return nil end
	local ok, out = pcall(GameTextGetTranslatedOrNot, s)
	if ok and out and out ~= "" then return out end
	return (s:gsub("^%$item_", ""):gsub("^%$", ""):gsub("_", " "))
end

local function item_name(entity)
	local item = EntityGetFirstComponentIncludingDisabled(entity, "ItemComponent")
	if not item then return nil end
	local ok, n = pcall(ComponentGetValue2, item, "item_name")
	if ok then return translate(n) end
	return nil
end

local function obj(comp, object, field)
	local ok, v = pcall(ComponentObjectGetValue2, comp, object, field)
	if ok then return v end
	return nil
end

local function num(comp, field)
	local ok, v = pcall(ComponentGetValue2, comp, field)
	if ok and type(v) == "number" then return v end
	return nil
end

local function sprite_of(entity)
	local sc = EntityGetFirstComponentIncludingDisabled(entity, "SpriteComponent")
	if not sc then return nil end
	local ok, f = pcall(ComponentGetValue2, sc, "image_file")
	if ok and type(f) == "string" and f:match("%.png$") then return f end
	return nil
end

-- Wands get the full inventory-style stat block plus their spell list.
local function describe_wand(entity, out)
	out.sprite = sprite_of(entity)

	local ab = EntityGetFirstComponentIncludingDisabled(entity, "AbilityComponent")
	if not ab then
		out.name = item_name(entity) or "Wand"
		return
	end

	local ok, ui = pcall(ComponentGetValue2, ab, "ui_name")
	out.name = (ok and ui and ui ~= "") and translate(ui) or (item_name(entity) or "Wand")

	out.stats = {
		cap = obj(ab, "gun_config", "deck_capacity"),
		pc = obj(ab, "gun_config", "actions_per_round"),
		sh = obj(ab, "gun_config", "shuffle_deck_when_empty"),
		rc = obj(ab, "gun_config", "reload_time"),
		cd = obj(ab, "gunaction_config", "fire_rate_wait"),
		sp = obj(ab, "gunaction_config", "spread_degrees"),
		mn = num(ab, "mana_max"),
		mc = num(ab, "mana_charge_speed"),
	}

	local spells = {}
	for _, child in ipairs(EntityGetAllChildren(entity) or {}) do
		if EntityHasTag(child, "card_action") then
			local ac = EntityGetFirstComponentIncludingDisabled(child, "ItemActionComponent")
			if ac then
				local okc, id = pcall(ComponentGetValue2, ac, "action_id")
				if okc and id and id ~= "" then spells[#spells + 1] = tostring(id) end
			end
		end
		if #spells >= 12 then break end
	end
	if #spells > 0 then out.spells = spells end
end

local function describe_potion(entity, out)
	out.name = item_name(entity) or "Potion"
	out.sprite = sprite_of(entity)
	local ok, mat = pcall(GetMaterialInventoryMainMaterial, entity)
	if ok and mat and mat > 0 then
		local okn, key = pcall(CellFactory_GetUIName, mat)
		if okn and key then
			local pretty = translate(key)
			if pretty then out.info = { pretty } end
		end
	end
end

local function describe_spell(entity, out)
	local ac = EntityGetFirstComponentIncludingDisabled(entity, "ItemActionComponent")
	if ac then
		local ok, id = pcall(ComponentGetValue2, ac, "action_id")
		if ok and id and id ~= "" then
			out.name = (tostring(id):lower():gsub("_", " "))
			out.spells = { tostring(id) }
			return
		end
	end
	out.name = item_name(entity) or "Spell"
end

local function classify(entity)
	if EntityHasTag(entity, "this_is_orb") then return M.ORB end
	if EntityHasTag(entity, "item_perk") then return M.PERK end
	if EntityHasTag(entity, "wand") then return M.WAND end
	if EntityHasTag(entity, "card_action") then return M.SPELL end
	if EntityHasTag(entity, "potion") then return M.POTION end
	if EntityHasTag(entity, "item_pickup") then return M.ITEM end
	return nil
end

local function describe(entity, kind)
	local out = {}
	local ok = pcall(function()
		if kind == M.WAND then describe_wand(entity, out)
		elseif kind == M.POTION then describe_potion(entity, out)
		elseif kind == M.SPELL then describe_spell(entity, out)
		else
			out.name = item_name(entity) or M.NAMES[kind] or "item"
			out.sprite = sprite_of(entity)
		end
	end)
	if not ok or not out.name or out.name == "" then
		out.name = M.NAMES[kind] or "item"
	end
	return out
end

M.spell_icon = spell_icon

-- ------------------------------------------------------------------ update

function M.reset()
	M.items = {}
	M.count = 0
end

function M.update(cam_x, cam_y, cam_w, cam_h)
	if not M.enabled then return end

	local x1, y1 = cam_x + cam_w, cam_y + cam_h
	local live = {}
	local seen = {}

	for i = 1, #SOURCES do
		local list = EntityGetWithTag(SOURCES[i].tag) or {}
		for j = 1, #list do
			local e = list[j]
			if not seen[e] then
				seen[e] = true
				-- A parent means it is held or inside a container, so it is
				-- not lying in the world to be marked.
				if EntityGetParent(e) == 0 and not EntityHasTag(e, "player_unit") then
					local ex, ey = EntityGetTransform(e)
					if ex and ex >= cam_x and ex <= x1 and ey >= cam_y and ey <= y1 then
						local kind = classify(e)
						if kind then
							local k = key_for(kind, ex, ey)
							live[k] = true
							if not M.items[k] then
								local d = describe(e, kind)
								d.x, d.y, d.kind = ex, ey, kind
								M.items[k] = d
								M.count = M.count + 1
							end
						end
					end
				end
			end
		end
	end

	-- Reconcile: anything remembered inside the rect we can currently see,
	-- but with no matching entity, has been taken or destroyed.
	for k, m in pairs(M.items) do
		if m.x >= cam_x and m.x <= x1 and m.y >= cam_y and m.y <= y1 then
			if not live[k] then
				M.items[k] = nil
				M.count = M.count - 1
			end
		end
	end
end

-- ------------------------------------------------------------ serialisation

-- Records are ";" separated, fields ",". Free text is percent-escaped so a
-- comma inside an item name cannot corrupt the record and the payload stays
-- XML-safe inside a save global. "|" ":" "=" and "/" survive unescaped
-- because the packed sub-fields rely on them.
local function esc(s)
	if s == nil or s == "" then return "" end
	return (tostring(s):gsub("[^%w %.%+%-/'|:=]", function(c)
		return ("%%%02X"):format(c:byte())
	end))
end

local function unesc(s)
	if not s or s == "" then return "" end
	return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local STAT_KEYS = { "cap", "pc", "sh", "rc", "cd", "sp", "mn", "mc" }

local function pack_stats(st)
	if not st then return "" end
	local parts = {}
	for i = 1, #STAT_KEYS do
		local k = STAT_KEYS[i]
		local v = st[k]
		if v ~= nil then
			if type(v) == "boolean" then v = v and 1 or 0 end
			parts[#parts + 1] = k .. ":" .. tostring(v)
		end
	end
	return table.concat(parts, "|")
end

local function unpack_stats(s)
	if not s or s == "" then return nil end
	local st = {}
	for k, v in s:gmatch("(%a+):([%-%d%.]+)") do
		st[k] = tonumber(v)
	end
	if st.sh ~= nil then st.sh = (st.sh ~= 0) end
	return st
end

function M.serialize()
	local parts = {}
	for _, m in pairs(M.items) do
		parts[#parts + 1] = table.concat({
			m.kind,
			floor(m.x),
			floor(m.y),
			esc(m.name),
			esc(m.sprite),
			esc(pack_stats(m.stats)),
			esc(m.spells and table.concat(m.spells, "|") or ""),
			esc(m.info and table.concat(m.info, "|") or ""),
		}, ",")
	end
	return table.concat(parts, ";")
end

local function split(s, sep)
	if not s or s == "" then return nil end
	local out = {}
	for piece in s:gmatch("[^" .. sep .. "]+") do out[#out + 1] = piece end
	if #out == 0 then return nil end
	return out
end

function M.deserialize(s)
	M.reset()
	if not s or s == "" then return end
	for entry in s:gmatch("[^;]+") do
		local f = {}
		for field in (entry .. ","):gmatch("([^,]*),") do f[#f + 1] = field end
		local kind, x, y = tonumber(f[1]), tonumber(f[2]), tonumber(f[3])
		if kind and x and y then
			local k = key_for(kind, x, y)
			if not M.items[k] then
				M.items[k] = {
					x = x, y = y, kind = kind,
					name = unesc(f[4]),
					sprite = (f[5] ~= "" and unesc(f[5])) or nil,
					stats = unpack_stats(unesc(f[6] or "")),
					spells = split(unesc(f[7] or ""), "|"),
					info = split(unesc(f[8] or ""), "|"),
				}
				M.count = M.count + 1
			end
		end
	end
end

return M
