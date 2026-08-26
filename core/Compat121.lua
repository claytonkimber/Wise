local addonName, Wise = ...

-- ─────────────────────────────────────────────────────────────────────
-- Patch 12.1 compatibility layer
-- ─────────────────────────────────────────────────────────────────────
--
-- Single place where Wise feature-detects 12.1-only client capabilities, so
-- callers never repeat `if X and X.Y then` chains and 12.0.x keeps working
-- unchanged. Everything here is detection + thin wrappers ONLY: no behaviour
-- is switched on merely because a capability exists — callers opt in.
--
-- Why a layer instead of inline checks: the TOC ships one build for every
-- supported interface version (120000..120100), so every 12.1 call site needs
-- a guard anyway. Centralising them means one place to delete when 12.0.x
-- support is eventually dropped, and one place to read to answer "what does
-- Wise do differently on 12.1?".
--
-- See AGENTS.md "Patch 12.1 Readiness" for the full change survey, including
-- the changes deliberately NOT adapted to and why.

Wise.Compat = Wise.Compat or {}
local Compat = Wise.Compat

-- ─── Capability detection ────────────────────────────────────────────
-- Probed once at load. Each flag answers "can I call this?", never "should I".

-- AuraContainer/AuraButton intrinsics (12.1). The sanctioned way to display
-- aura state — including live stack counts — while aura data is secret: the
-- client owns the data and renders it, addon code only styles and anchors.
-- This is the route to an in-combat Abundance counter (see Wise.Compat.CanUseAuraWidgets).
--
-- Detected by probing for the METHOD, not the template name: CreateFrame with an
-- unknown template name does NOT throw — it silently returns an ordinary Frame
-- (verified in wow-ui-sim 12.0.7). A name-only probe therefore reports a false
-- positive on every 12.0.x client, which would send callers down the 12.1 path
-- and fail at the first AddAuraSlot call. Probe the capability, not the label.
Compat.hasAuraWidgets = (function()
	local ok, frame = pcall(CreateFrame, "Frame", nil, UIParent, "AuraContainerTemplate")
	if not ok or not frame then
		return false
	end
	local supported = type(frame.AddAuraSlot) == "function"
	frame:Hide()
	frame:SetParent(nil)
	return supported
end)()

-- Frame:SetOnUpdateMode(mode) (12.1) — lets the client gate an OnUpdate script
-- instead of the handler early-returning on every frame. Modes: "Disabled",
-- "RunWhenVisible", "RunWhenVisibleOnce", "RunOnce", "RunAlways".
Compat.hasOnUpdateMode = type(UIParent.SetOnUpdateMode) == "function"

-- issecretvalue / issecrettable: real 12.0 globals, but guard anyway — they are
-- the only reliable secrecy test (a tostring→tonumber round-trip does NOT
-- detect a secret; see AGENTS.md "Numeric Taint Stripping").
Compat.hasSecretPrimitives = type(_G.issecretvalue) == "function"

-- C_Secrets.ShouldAurasBeSecret(): true while the client is withholding aura
-- data (combat in M+/raid/PvP-style content). Distinct from InCombatLockdown —
-- ordinary open-world combat does not flip it. Used to decide when the
-- by-spellID aura reads are worth attempting at all.
Compat.hasSecretsQuery = type(_G.C_Secrets) == "table" and type(C_Secrets.ShouldAurasBeSecret) == "function"

-- ─── Aura secrecy ────────────────────────────────────────────────────

-- Are aura reads currently being withheld by the client?
--
-- Prefer the client's own answer. Falling back to InCombatLockdown() is
-- deliberately CONSERVATIVE: it over-reports secrecy in open-world combat,
-- where reads would actually have succeeded. Callers must treat a true here as
-- "don't trust aura reads", never as "hide the UI" — over-reporting must cost
-- accuracy, not function.
function Compat.AreAurasSecret()
	if Compat.hasSecretsQuery then
		local ok, secret = pcall(C_Secrets.ShouldAurasBeSecret)
		if ok then
			return secret == true
		end
	end
	return InCombatLockdown() and true or false
end

-- ─── Aura display widgets (12.1) ─────────────────────────────────────

-- Can Wise put a client-rendered aura widget on screen right now?
--
-- Two gates, both required:
--   * the intrinsics must exist (12.1+), and
--   * we must be out of combat. AuraButtons/AuraContainers carry Forbidden
--     Aspects while auras are secret — script handlers, event registration and
--     input APIs all refuse tainted callers — so they must be CREATED and
--     CONFIGURED out of combat and merely shown/hidden afterwards.
function Compat.CanUseAuraWidgets()
	if not Compat.hasAuraWidgets then
		return false
	end
	return not InCombatLockdown()
end

-- Attach a client-rendered stack counter for `spellID` to `parent`.
--
-- Returns the container frame on success, nil otherwise. The caller owns
-- showing/hiding it; the CLIENT owns the number, which is why this keeps
-- working while auras are secret — Wise never reads the count and so never
-- touches (or taints) the aura record. Contrast the removed 12.0.7 slot-scan
-- resolver, which read aura data directly and spread taint into Blizzard's
-- CooldownViewer (see AGENTS.md "Combat Aura Secrecy").
--
-- `options` is passed through to AddAuraSlot untouched so callers can style
-- without this wrapper growing a parallel option schema.
function Compat.CreateStackCounter(parent, spellID, options)
	if not (parent and spellID) or not Compat.CanUseAuraWidgets() then
		return nil
	end

	local ok, container = pcall(CreateFrame, "Frame", nil, parent, "AuraContainerTemplate")
	if not ok or not container then
		return nil
	end

	-- Filter by the exact spell so the slot binds to one aura. By-spellID
	-- addressing is the access path that SURVIVES secrecy in 12.1 (index, slot
	-- and instanceID lookups hard Lua-error while auras are secret).
	local filter = ("HELPFUL SPELL:%d"):format(spellID)
	local added = pcall(container.AddAuraSlot, container, "wiseStacks", filter, options)
	if not added then
		container:Hide()
		container:SetParent(nil)
		return nil
	end

	return container
end

-- ─── OnUpdate gating (12.1) ──────────────────────────────────────────

-- Ask the client to stop running a frame's OnUpdate while it is hidden.
--
-- Wise's per-frame loops already early-return when idle, but the handler is
-- still dispatched every frame to do so. "RunWhenVisible" moves that decision
-- into the client: a hidden frame costs nothing at all. Safe no-op pre-12.1,
-- where the handler's own early-return remains the only gate — so callers must
-- keep those early-returns rather than relying on this.
function Compat.SetOnUpdateWhenVisible(frame)
	if not (frame and Compat.hasOnUpdateMode) then
		return false
	end
	local ok = pcall(frame.SetOnUpdateMode, frame, "RunWhenVisible")
	return ok and true or false
end

-- ─── Diagnostics ─────────────────────────────────────────────────────

-- Snapshot of what this client supports; surfaced by `/wise compat`.
function Compat.GetReport()
	return {
		auraWidgets = Compat.hasAuraWidgets,
		onUpdateMode = Compat.hasOnUpdateMode,
		secretPrimitives = Compat.hasSecretPrimitives,
		secretsQuery = Compat.hasSecretsQuery,
		aurasSecretNow = Compat.AreAurasSecret(),
	}
end
