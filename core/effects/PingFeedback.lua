-- core/effects/PingFeedback.lua
--
-- Feedback for macros that PING instead of casting: patch 12.1's /ping,
-- /pingspell and /pingitem. Wise:ResolveMacroData (modules/Actions.lua) tags a
-- macro line built from one of these with feedback = "ping", and the display
-- passes in core/GUI.lua store that on the button as meta.pingFeedback. This
-- file answers the questions the ordinary spell/item path would get wrong:
--
--   * Usable? A ping goes out when the ping system is on, this group lets you
--     ping (a raid can restrict pings to the leader, assistants, or tanks and
--     healers) and the ping rate-limit cooldown is not running. Whether the
--     SPELL could be cast is irrelevant: "/pingspell Fireball" while out of
--     mana is exactly when you would ping it.
--   * Cooldown? /pingspell and /pingitem keep their spell's or item's cooldown
--     swipe, which is the information the ping reports. Bare /ping has no
--     spell, so it shows the ping rate-limit cooldown instead.
--   * Range? Never tinted (RangeTint.lua skips these). A ping does not care
--     how far away the target is.
--   * A small ping-marker badge marks the button, so a /pingspell slot is not
--     mistaken for one that casts.
--
-- Event-driven (Rule 12): permission changes ride GROUP_ROSTER_UPDATE and
-- PARTY_LEADER_CHANGED, coalesced into one deferred pass. The end of a ping
-- cooldown is a single one-shot timer, armed when a ping button is painted
-- mid-cooldown. No ticker.
--
-- Loaded after GUI.lua: it calls UpdateButtonUsability/UpdateButtonCooldown at
-- runtime, and GUI.lua reaches it through Wise.PingFeedback at call time, never
-- as a load-time upvalue. Every game API is resolved off _G at call time so the
-- tests can stub it, and absent means "no restriction / no cooldown", never an
-- error (WoW Forever and the simulator may lack some of them).

local addonName, Wise = ...

local _G = _G
local type = type
local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local math_max = math.max
local GetTime = GetTime
local CreateFrame = CreateFrame

local PF = Wise.PingFeedback or {}
Wise.PingFeedback = PF

-- The neutral ping marker. Atlas names are case-insensitive.
PF.BADGE_ATLAS = "Ping_Marker_Icon_NonThreat"

-- Enum.RestrictPingsTo (PartyConstants): None = 0, Lead = 1, Assist = 2,
-- TankHealer = 3. Literal fallbacks for a client without the enum.
local function RestrictValue(name, fallback)
	local enum = _G.Enum and _G.Enum.RestrictPingsTo
	local v = enum and enum[name]
	if type(v) == "number" then
		return v
	end
	return fallback
end

-- A number we can safely compare: nil for a secret or non-number value.
local function PlainNumber(v)
	local isSecret = _G.issecretvalue
	if isSecret and isSecret(v) then
		return nil
	end
	if type(v) ~= "number" then
		return nil
	end
	return v
end

local function PlayerIs(fnName)
	local fn = _G[fnName]
	if type(fn) ~= "function" then
		return false
	end
	local ok, v = pcall(fn, "player")
	return ok and v and true or false
end

-- May this player ping in the current group at all? Solo play is never
-- restricted, and the leader may always ping. When the game's answer is
-- unreadable we allow it: a lit icon the server then refuses is no worse than
-- having no feedback, while a wrongly dimmed one hides a working button.
function PF.HasPingPermission()
	local inGroup = _G.IsInGroup
	if type(inGroup) == "function" and not inGroup() then
		return true
	end
	if PlayerIs("UnitIsGroupLeader") then
		return true
	end
	local party = _G.C_PartyInfo
	if not (party and type(party.GetRestrictPings) == "function") then
		return true
	end
	local ok, restrictTo = pcall(party.GetRestrictPings)
	restrictTo = ok and PlainNumber(restrictTo) or nil
	if not restrictTo or restrictTo == RestrictValue("None", 0) then
		return true
	end
	if restrictTo == RestrictValue("Lead", 1) then
		return false -- the leader returned above
	end
	local isAssist = PlayerIs("UnitIsGroupAssistant")
	if restrictTo == RestrictValue("Assist", 2) then
		return isAssist
	end
	if restrictTo == RestrictValue("TankHealer", 3) then
		if isAssist then
			return true
		end
		local roleFn = _G.UnitGroupRolesAssigned
		if type(roleFn) == "function" then
			local okRole, role = pcall(roleFn, "player")
			return okRole and (role == "TANK" or role == "HEALER") or false
		end
		return true
	end
	return true -- an unknown future restriction level: do not guess
end

-- Ping rate-limit cooldown as (start, duration) in GetTime() seconds; (0, 0)
-- when none is running. C_Ping reports milliseconds on the GetTime clock.
function PF.GetCooldown()
	local ping = _G.C_Ping
	if not (ping and type(ping.GetCooldownInfo) == "function") then
		return 0, 0
	end
	local ok, info = pcall(ping.GetCooldownInfo)
	if not ok or type(info) ~= "table" then
		return 0, 0
	end
	local startMs = PlainNumber(info.startTimeMs)
	local endMs = PlainNumber(info.endTimeMs)
	if not startMs or not endMs or endMs <= startMs then
		return 0, 0
	end
	if endMs <= GetTime() * 1000 then
		return 0, 0
	end
	return startMs / 1000, (endMs - startMs) / 1000
end

-- Repaint only the buttons that carry ping feedback. Allocates nothing.
local function RefreshPingButtons()
	local metaByButton = Wise.buttonMeta
	if not metaByButton then
		return
	end
	for btn, meta in pairs(metaByButton) do
		if meta.pingFeedback then
			if Wise.UpdateButtonCooldown then
				Wise:UpdateButtonCooldown(btn)
			end
			if Wise.UpdateButtonUsability then
				Wise:UpdateButtonUsability(btn)
			end
		end
	end
end
PF.RefreshPingButtons = RefreshPingButtons

-- One pending cooldown-end timer at a time. Its callback is hoisted so arming
-- it allocates nothing.
local cooldownTimerPending = false
local function OnCooldownEnd()
	cooldownTimerPending = false
	RefreshPingButtons()
end

local function ArmCooldownEnd(remaining)
	if cooldownTimerPending then
		return
	end
	local timer = _G.C_Timer
	if not (timer and timer.After) then
		return
	end
	cooldownTimerPending = true
	-- A small margin so the repaint lands after the game clears the cooldown.
	timer.After(math_max(remaining, 0) + 0.05, OnCooldownEnd)
end

-- The usable state of a ping macro right now.
function PF.CanPingNow()
	local ping = _G.C_Ping
	if ping and type(ping.IsPingSystemEnabled) == "function" then
		local ok, enabled = pcall(ping.IsPingSystemEnabled)
		if ok and enabled == false then
			return false
		end
	end
	if not PF.HasPingPermission() then
		return false
	end
	local start, duration = PF.GetCooldown()
	if duration > 0 then
		ArmCooldownEnd(start + duration - GetTime())
		return false
	end
	return true
end

-- ── Badge ──────────────────────────────────────────────────────────────────
-- A ping marker in the bottom-left quarter of the icon. It sits on the text
-- overlay frame (core/Text.lua) when the button has one, so the cooldown swipe
-- never darkens it. Anchored to the button's centre, so it scales with any
-- button size. `false` in host._wisePingBadge means "this client has no such
-- atlas": we stop trying rather than retrying on every pass.

local function EnsureBadge(host)
	local badge = host._wisePingBadge
	if badge ~= nil then
		return badge or nil
	end
	local textureApi = _G.C_Texture
	local hasAtlas = textureApi
		and type(textureApi.GetAtlasInfo) == "function"
		and textureApi.GetAtlasInfo(PF.BADGE_ATLAS)
	if not hasAtlas then
		host._wisePingBadge = false
		return nil
	end
	local parent = host._textOverlay or host
	badge = parent:CreateTexture(nil, "OVERLAY", nil, 2)
	badge:SetAtlas(PF.BADGE_ATLAS)
	badge:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 1, 1)
	badge:SetPoint("TOPRIGHT", host, "CENTER", -2, -2)
	badge:Hide()
	host._wisePingBadge = badge
	return badge
end

local function SetBadgeShown(host, want)
	if (host._wisePingBadgeShown == true) == want then
		return
	end
	if want then
		local badge = EnsureBadge(host)
		if badge then
			badge:Show()
			host._wisePingBadgeShown = true
		end
	else
		local badge = host._wisePingBadge
		if badge then
			badge:Hide()
		end
		host._wisePingBadgeShown = nil
	end
end

-- Show the badge on a button (and its visual clone) exactly when its meta
-- carries ping feedback. Called from every usability pass. In the steady state
-- it compares one flag per host and touches nothing.
function PF.SyncBadge(btn, meta)
	if not btn then
		return
	end
	local want = (meta and meta.pingFeedback) and true or false
	SetBadgeShown(btn, want)
	local clone = (meta and meta.visualClone) or btn.visualClone
	if clone then
		SetBadgeShown(clone, want)
	end
end

-- ── Events ─────────────────────────────────────────────────────────────────
-- Permission can change with the roster (promotions, role swaps, the restrict
-- setting). Coalesce a burst into one deferred pass, like GUI.lua's scheduler.
local refreshPending = false
local function OnDeferredRefresh()
	refreshPending = false
	RefreshPingButtons()
end

local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function()
	if refreshPending then
		return
	end
	local timer = _G.C_Timer
	if timer and timer.After then
		refreshPending = true
		timer.After(0, OnDeferredRefresh)
	else
		RefreshPingButtons()
	end
end)
for _, event in ipairs({ "GROUP_ROSTER_UPDATE", "PARTY_LEADER_CHANGED", "PLAYER_ROLES_ASSIGNED" }) do
	pcall(eventFrame.RegisterEvent, eventFrame, event)
end
PF.eventFrame = eventFrame
