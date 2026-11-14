-- Tests for ping macro feedback: /ping, /pingspell and /pingitem
-- (Wise:ResolveMacroData in modules/Actions.lua, core/effects/PingFeedback.lua,
-- and the paint paths in core/GUI.lua that read meta.pingFeedback).
--
-- API fields are stubbed on the existing namespaces and restored afterwards.
-- Global functions read off _G at call time (IsInGroup, UnitIsGroupLeader, ...)
-- are swapped on _G the same way.

local PF = Wise.PingFeedback
local GROUP = "__PingFeedbackTest"
local SPELL_ID, SPELL_NAME, SPELL_ICON = 990811, "Wise Ping Test Bolt", 136243
local ITEM_ID, ITEM_ICON = 990812, 134414

-- Swap fields on a table for the duration of fn; always restore. `fields` maps
-- name -> replacement (use the token NIL to install nil).
local NIL = {}
local function withFields(tbl, fields, fn)
	local saved = {}
	for k, v in pairs(fields) do
		saved[k] = { value = tbl[k] }
		if v == NIL then
			tbl[k] = nil
		else
			tbl[k] = v
		end
	end
	local ok, err = pcall(fn)
	for k, s in pairs(saved) do
		tbl[k] = s.value
	end
	if not ok then
		error(err, 0)
	end
end

-- Known spell / item stubs so ResolveMacroData can resolve the test names.
local function withKnownSpellAndItem(fn)
	local realSpellInfo = C_Spell.GetSpellInfo
	local realItemInstant = C_Item.GetItemInfoInstant
	withFields(C_Spell, {
		GetSpellInfo = function(ref)
			if ref == SPELL_ID or ref == SPELL_NAME then
				return { spellID = SPELL_ID, name = SPELL_NAME, iconID = SPELL_ICON }
			end
			return realSpellInfo(ref)
		end,
	}, function()
		withFields(C_Item, {
			GetItemInfoInstant = function(ref)
				if ref == ITEM_ID then
					return ITEM_ID, "Consumable", "Potion", "", ITEM_ICON
				end
				return realItemInstant(ref)
			end,
		}, fn)
	end)
end

-- A ping environment: group state, raid restriction, ping cooldown. `env` is
-- mutable so a test can change the answer between calls.
local function withPingEnv(env, fn)
	local nowMs = GetTime() * 1000
	withFields(_G, {
		IsInGroup = function()
			return env.inGroup
		end,
		UnitIsGroupLeader = function()
			return env.leader
		end,
		UnitIsGroupAssistant = function()
			return env.assist
		end,
		UnitGroupRolesAssigned = function()
			return env.role or "NONE"
		end,
	}, function()
		withFields(C_PartyInfo, {
			GetRestrictPings = function()
				return env.restrict or 0
			end,
		}, function()
			withFields(C_Ping, {
				GetCooldownInfo = function()
					if env.cooldownLeft then
						return { startTimeMs = nowMs - 1000, endTimeMs = nowMs + env.cooldownLeft * 1000 }
					end
					return { startTimeMs = nowMs - 5000, endTimeMs = nowMs - 1000 }
				end,
				IsPingSystemEnabled = function()
					return env.enabled ~= false
				end,
			}, fn)
		end)
	end)
end

-- One button registered the way the display pass registers them.
local function withButton(meta, fn)
	local savedGroup = WiseDB.groups[GROUP]
	WiseDB.groups[GROUP] = {}
	local btn = CreateFrame("Button", nil, UIParent)
	btn:SetSize(30, 30)
	btn.icon = btn:CreateTexture(nil, "ARTWORK")
	btn.icon:SetAllPoints()
	btn.groupName = GROUP
	Wise.buttonMeta = Wise.buttonMeta or {}
	Wise.buttonMeta[btn] = meta
	Wise.frames = Wise.frames or {}
	Wise.frames[GROUP] = { buttons = { btn } }
	local ok, err = pcall(fn, btn)
	Wise.frames[GROUP] = nil
	Wise.buttonMeta[btn] = nil
	WiseDB.groups[GROUP] = savedGroup
	if not ok then
		error(err, 0)
	end
end

local function PingMeta(feedback)
	return {
		baseSpellID = nil,
		spellID = SPELL_ID,
		actionType = "misc",
		actionValue = "custom_macro",
		actionData = { macroText = "/pingspell " .. SPELL_NAME },
		pingFeedback = feedback,
	}
end

-- ── ResolveMacroData ───────────────────────────────────────────────────────

test("Ping: /pingspell resolves to the spell, tagged as ping feedback", function()
	withKnownSpellAndItem(function()
		local t, v, icon, fb = Wise:ResolveMacroData("#showtooltip\n/pingspell " .. SPELL_NAME)
		assertEquals("spell", t)
		assertEquals(SPELL_ID, v)
		assertEquals(SPELL_ICON, icon)
		assertEquals("ping", fb)
		-- By ID too, and through a passing condition.
		t, v, _, fb = Wise:ResolveMacroData("/pingspell [@target] " .. SPELL_ID)
		assertEquals("spell", t)
		assertEquals(SPELL_ID, v)
		assertEquals("ping", fb)
	end)
end)

test("Ping: /pingitem resolves to the item, tagged as ping feedback", function()
	withKnownSpellAndItem(function()
		local t, v, icon, fb = Wise:ResolveMacroData("/pingitem " .. ITEM_ID)
		assertEquals("item", t)
		assertEquals(ITEM_ID, v)
		assertEquals(ITEM_ICON, icon)
		assertEquals("ping", fb)
	end)
end)

test("Ping: bare /ping and /ping with a type resolve to the ping pseudo-type", function()
	for _, text in ipairs({ "/ping", "/ping [@target] attack", "/ping [@mouseover] warning", "/PING onmyway" }) do
		local t, v, icon, fb = Wise:ResolveMacroData(text)
		assertEquals("ping", t, text)
		assertEquals(nil, v, text)
		assertEquals(nil, icon, text)
		assertEquals("ping", fb, text)
	end
end)

test("Ping: ordinary lines carry no feedback tag, and line order decides", function()
	withKnownSpellAndItem(function()
		local t, v, _, fb = Wise:ResolveMacroData("/cast " .. SPELL_NAME)
		assertEquals("spell", t)
		assertEquals(nil, fb)
		-- First resolving line wins, exactly as for /cast lines.
		t, _, _, fb = Wise:ResolveMacroData("/pingspell " .. SPELL_NAME .. "\n/use " .. ITEM_ID)
		assertEquals("spell", t)
		assertEquals("ping", fb)
		t, v, _, fb = Wise:ResolveMacroData("/use " .. ITEM_ID .. "\n/pingspell " .. SPELL_NAME)
		assertEquals("item", t)
		assertEquals(nil, fb)
		-- A /pingspell naming nothing falls through to the next line.
		t, v, _, fb = Wise:ResolveMacroData("/pingspell No Such Spell Zzz\n/cast " .. SPELL_NAME)
		assertEquals("spell", t)
		assertEquals(SPELL_ID, v)
		assertEquals(nil, fb)
		-- An explicit #showtooltip target is still a plain display target.
		t, _, _, fb = Wise:ResolveMacroData("#showtooltip " .. SPELL_NAME .. "\n/ping")
		assertEquals("spell", t)
		assertEquals(nil, fb)
	end)
end)

test("Ping: a failing condition defers to the strip-conditions pass", function()
	withKnownSpellAndItem(function()
		-- [nocombat] passes out of combat; [combat] does not, so pass 1 skips the
		-- line and pass 2 still identifies it as a ping of the spell.
		local t, v, _, fb = Wise:ResolveMacroData("/pingspell [combat] " .. SPELL_NAME)
		assertEquals("spell", t)
		assertEquals(SPELL_ID, v)
		assertEquals("ping", fb)
	end)
end)

-- ── Permission and cooldown ────────────────────────────────────────────────

test("Ping: permission follows the raid restriction setting", function()
	local env = { inGroup = false }
	withPingEnv(env, function()
		assertEquals(true, PF.HasPingPermission(), "solo")
		env.inGroup = true
		env.restrict = 1 -- Lead
		assertEquals(false, PF.HasPingPermission(), "lead-only, not leader")
		env.leader = true
		assertEquals(true, PF.HasPingPermission(), "leader always")
		env.leader = false
		env.restrict = 0 -- None
		assertEquals(true, PF.HasPingPermission(), "no restriction")
		env.restrict = 2 -- Assist
		assertEquals(false, PF.HasPingPermission(), "assist-only, plain member")
		env.assist = true
		assertEquals(true, PF.HasPingPermission(), "assist-only, assistant")
		env.assist = false
		env.restrict = 3 -- TankHealer
		env.role = "DAMAGER"
		assertEquals(false, PF.HasPingPermission(), "tank/healer-only, dps")
		env.role = "HEALER"
		assertEquals(true, PF.HasPingPermission(), "tank/healer-only, healer")
	end)
end)

test("Ping: cooldown and the system switch gate CanPingNow", function()
	local env = { inGroup = false }
	withPingEnv(env, function()
		local s, d = PF.GetCooldown()
		assertEquals(0, d, "expired cooldown reads as none")
		assertEquals(true, PF.CanPingNow())
		env.cooldownLeft = 4
		s, d = PF.GetCooldown()
		assertTrue(d > 4.9 and d < 5.1, "duration " .. tostring(d))
		assertTrue(s > 0)
		assertEquals(false, PF.CanPingNow())
		env.cooldownLeft = nil
		env.enabled = false
		assertEquals(false, PF.CanPingNow(), "ping system off")
	end)
end)

-- ── Paint paths ────────────────────────────────────────────────────────────

test("Ping: usable means can-ping, even when the spell itself is not usable", function()
	local env = { inGroup = false }
	withPingEnv(env, function()
		withFields(Wise, {
			IsSpellUsable = function()
				return false, false
			end,
		}, function()
			withButton(PingMeta("ping"), function(btn)
				Wise:UpdateButtonUsability(btn)
				assertEquals(1, btn.icon:GetAlpha(), "lit while a ping would go out")
				env.cooldownLeft = 3
				Wise:UpdateButtonUsability(btn)
				assertTrue(btn.icon:GetAlpha() < 0.5, "dimmed during the ping cooldown")
			end)
			-- Control: the same spell without the ping tag follows the spell.
			withButton(PingMeta(nil), function(btn)
				env.cooldownLeft = nil
				Wise:UpdateButtonUsability(btn)
				assertTrue(btn.icon:GetAlpha() < 0.5, "unusable spell dims a casting slot")
			end)
		end)
	end)
end)

test("Ping: the badge follows meta.pingFeedback", function()
	local env = { inGroup = false }
	withPingEnv(env, function()
		local meta = PingMeta("ping")
		withButton(meta, function(btn)
			Wise:UpdateButtonUsability(btn)
			assertTrue(btn._wisePingBadge, "badge created")
			assertTrue(btn._wisePingBadge:IsShown(), "badge shown")
			meta.pingFeedback = nil
			Wise:UpdateButtonUsability(btn)
			assertFalse(btn._wisePingBadge:IsShown(), "badge hidden once the slot stops pinging")
			-- Also cleared on a button the display pass marked invalid.
			meta.pingFeedback = "ping"
			Wise:UpdateButtonUsability(btn)
			assertTrue(btn._wisePingBadge:IsShown())
			meta.pingFeedback = nil
			btn.isValid = false
			Wise:UpdateButtonUsability(btn)
			assertFalse(btn._wisePingBadge:IsShown(), "invalid button keeps no stale badge")
		end)
	end)
end)

test("Ping: range tint never marks a ping slot", function()
	withFields(C_Spell, {
		IsSpellInRange = function()
			return false
		end,
	}, function()
		local savedTint = WiseDB.settings.rangeTint
		WiseDB.settings.rangeTint = true
		local ok, err = pcall(withButton, PingMeta("ping"), function(btn)
			Wise.RangeTint.Pass(true)
			assertFalse(btn._wiseOutOfRange == true, "ping slot not tinted")
			-- Control: the same spell as a casting slot IS tinted.
			Wise.buttonMeta[btn].pingFeedback = nil
			Wise.RangeTint.Pass(true)
			assertTrue(btn._wiseOutOfRange == true, "casting slot tinted")
			Wise.RangeTint.Pass(false)
		end)
		WiseDB.settings.rangeTint = savedTint
		if not ok then
			error(err, 0)
		end
	end)
end)

test("Ping: bare /ping shows the ping cooldown swipe", function()
	local env = { inGroup = false, cooldownLeft = 4 }
	withPingEnv(env, function()
		local meta = PingMeta("ping")
		meta.spellID = nil
		meta.actionData = { macroText = "/ping" }
		withButton(meta, function(btn)
			btn.cooldown = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
			local got
			btn.cooldown.SetCooldown = function(_, start, duration)
				if duration and duration > 0 then
					got = duration
				end
			end
			Wise:UpdateButtonCooldown(btn)
			assertTrue(got and got > 4.9 and got < 5.1, "swipe duration " .. tostring(got))
		end)
	end)
end)

test("Ping: cast-time text calls a ping macro instant and off-GCD", function()
	withKnownSpellAndItem(function()
		local castText, gcdText = Wise:GetCastTimeText("misc", "custom_macro", { macroText = "/pingspell " .. SPELL_NAME })
		assertEquals("Inst", castText)
		assertEquals("Off-GCD", gcdText)
	end)
end)
