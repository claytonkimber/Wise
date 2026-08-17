-- In-game probe for the ported OPie conditionals.
--
-- Covers what wow-ui-sim CANNOT: real cooldowns, real bag contents, real auras.
-- The simulator proved these tokens do not throw and route correctly; only the
-- live client can prove they return the RIGHT ANSWER.
--
-- This file is listed in Wise.toc inside a #@debug@ block, so it loads in dev
-- and is stripped from packaged builds. It must load LAST — it calls into the
-- fully-initialised addon.
--
-- Usage in game:
--
--   /wiseprobe
--   /wiseprobe Fireball
--   /wiseprobe Fireball; Healthstone; Arcane Intellect
--
-- The three optional arguments are readySpell; haveItem; selfBuff, separated by
-- semicolons (names contain spaces, so semicolons rather than spaces). Anything
-- omitted is auto-detected from your character.
--
-- Also callable directly: /run Wise_ProbeConditionals({ readySpell = "Fireball" })

function Wise_ProbeConditionals(opts)
	opts = opts or {}

	local function say(fmt, ...)
		print("|cff33ff99WiseProbe|r " .. string.format(fmt, ...))
	end

	local function ev(cond)
		local ok, result = pcall(Wise.EvalConditionExact, Wise, cond)
		if not ok then
			return "THREW: " .. tostring(result)
		end
		return tostring(result)
	end

	-- ── Pick sensible defaults from what the character actually has ──────────

	-- A spell we know is off cooldown right now: the GCD spell itself is a poor
	-- probe, so prefer an explicitly supplied one, else the first known spell.
	local readySpell = opts.readySpell
	local haveItem = opts.haveItem
	local selfBuff = opts.selfBuff

	-- Find a buff actually on the player, so [selfbuff:] has a true case.
	if not selfBuff and C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
		for i = 1, 40 do
			local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
			if not ok or not data then
				break
			end
			local sOk, isSecret = pcall(function()
				return issecretvalue and issecretvalue(data.name)
			end)
			if data.name and sOk and not isSecret then
				selfBuff = data.name
				break
			end
		end
	end

	-- Find an item actually in bags, so [have:] has a true case.
	if not haveItem and C_Container then
		for bag = 0, 4 do
			local slots = C_Container.GetContainerNumSlots(bag) or 0
			for slot = 1, slots do
				local info = C_Container.GetContainerItemInfo(bag, slot)
				if info and info.itemID then
					local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(info.itemID)
					haveItem = name or tostring(info.itemID)
					break
				end
			end
			if haveItem then
				break
			end
		end
	end

	say("=== environment ===")
	say("aurasSecret=%s inCombat=%s", tostring(Wise.Compat and Wise.Compat.AreAurasSecret and Wise.Compat.AreAurasSecret()), tostring(InCombatLockdown()))

	local gcd = "n/a"
	if C_Spell and C_Spell.GetSpellCooldown then
		local ok, info = pcall(C_Spell.GetSpellCooldown, 61304)
		if ok and info then
			gcd = string.format("start=%s dur=%s", tostring(info.startTime), tostring(info.duration))
		end
	end
	say("gcd(61304): %s", gcd)

	-- ── [ready:] ────────────────────────────────────────────────────────────
	say("=== [ready:] — expect TRUE for a spell off cooldown, FALSE mid-cooldown ===")
	if readySpell then
		-- Distinguish "on cooldown" from "spell does not resolve": a false from an
		-- unknown name means the ARGUMENT is wrong, not that the token is broken.
		local resolved = "unknown"
		if C_Spell and C_Spell.GetSpellCooldown then
			local ok, info = pcall(C_Spell.GetSpellCooldown, readySpell)
			if ok and info and info.duration then
				resolved = string.format("resolves (start=%s dur=%s)", tostring(info.startTime), tostring(info.duration))
			else
				resolved = "DOES NOT RESOLVE as a spell — check the name/spelling"
			end
		end
		say("  %s -> %s", readySpell, resolved)
		say("[ready:%s] = %s", readySpell, ev("[ready:" .. readySpell .. "]"))
		say("[noready:%s] = %s   (must be the opposite)", readySpell, ev("[noready:" .. readySpell .. "]"))
	else
		say("no readySpell given — try: /wiseprobe Fireball")
	end
	say("[ready:NoSuchSpellXYZ] = %s   (expect false)", ev("[ready:NoSuchSpellXYZ]"))
	if readySpell then
		say(
			"[ready:NoSuchSpellXYZ/%s] = %s   (alternation: expect same as [ready:%s])",
			readySpell,
			ev("[ready:NoSuchSpellXYZ/" .. readySpell .. "]"),
			readySpell
		)
	end
	say("TEST: put %s on cooldown, re-run, and confirm it flips to false.", tostring(readySpell))

	-- ── [have:] ─────────────────────────────────────────────────────────────
	say("=== [have:] — expect TRUE for an item in your bags ===")
	if haveItem then
		local count = "n/a"
		if C_Item and C_Item.GetItemCount then
			local ok, c = pcall(C_Item.GetItemCount, haveItem)
			count = ok and tostring(c) or ("threw: " .. tostring(c))
		end
		say("  %s -> GetItemCount=%s   (0 means you don't have it; token false is CORRECT then)", haveItem, count)
		say("[have:%s] = %s   (expect true when count > 0)", haveItem, ev("[have:" .. haveItem .. "]"))
		say("[nohave:%s] = %s   (must be the opposite)", haveItem, ev("[nohave:" .. haveItem .. "]"))
	else
		say("could not auto-find a bag item — try: /wiseprobe ; Healthstone")
	end
	say("[have:NoSuchItemXYZ] = %s   (expect false)", ev("[have:NoSuchItemXYZ]"))

	-- ── auras ───────────────────────────────────────────────────────────────
	say("=== [selfbuff:]/[buff:] — expect TRUE for an aura you actually have ===")
	if selfBuff then
		say("[selfbuff:%s] = %s   (expect true)", selfBuff, ev("[selfbuff:" .. selfBuff .. "]"))
		say("[noselfbuff:%s] = %s   (must be the opposite)", selfBuff, ev("[noselfbuff:" .. selfBuff .. "]"))
		say("[selfbuff:%s] case-insensitive = %s", selfBuff:lower(), ev("[selfbuff:" .. selfBuff:lower() .. "]"))
	else
		say("no player buff found — buff yourself and re-run, or pass {selfBuff='Arcane Intellect'}")
	end
	say("[selfbuff:NoSuchAuraXYZ] = %s   (expect false)", ev("[selfbuff:NoSuchAuraXYZ]"))
	say("[buff:NoSuchAuraXYZ] = %s   (expect false; needs a target)", ev("[buff:NoSuchAuraXYZ]"))
	say("TEST: target a friendly with a visible buff and check [buff:<name>].")
	say("TEST: in an M+/raid pull, confirm aura tokens report false rather than erroring (secrecy).")

	-- ── second-wave OPie tokens ─────────────────────────────────────────────
	say("=== ported OPie tokens — compare each against what you can see ===")
	say("[warbank] = %s   (true only where you can reach the warband bank)", ev("[warbank]"))
	say("[prey] = %s   (true only while actively hunting Prey)", ev("[prey]"))
	say("[myth] = %s   (true only during an M+ keystone run)", ev("[myth]"))
	say("[housereturn] = %s", ev("[housereturn]"))
	say("[coven] = %s   (Shadowlands covenant; false on a modern character)", ev("[coven]"))
	say("[uslot:trinket1] = %s   (true if trinket1 has an ON-USE effect)", ev("[uslot:trinket1]"))
	say("[uslot:trinket2] = %s", ev("[uslot:trinket2]"))
	say("[superflyable] = %s   (skyriding available here)", ev("[superflyable]"))
	say("[anyflyable] = %s", ev("[anyflyable]"))
	say("[blockedflyable] = %s", ev("[blockedflyable]"))
	say("[worldhover] = %s   (move the cursor OFF all UI and re-run: should flip)", ev("[worldhover]"))
	say("TEST: [uslot:trinket1] must be FALSE for a passive-only trinket.")
	say("TEST: [superflyable] true in skyriding zones, false in old-world no-fly.")

	-- ── combat freeze ───────────────────────────────────────────────────────
	say("=== combat freeze — the sim cannot test this against real combat ===")
	say("[moving] now = %s", ev("[moving]"))
	say("TEST: set an interface's Show to [moving]; run, enter combat while running,")
	say("      stop moving. It must STAY shown for the whole fight, then go live on exit.")

	say("=== done ===")
end

-- Slash command. Registered at load; the probe itself only runs when invoked, so
-- nothing here fires during addon startup.
SLASH_WISEPROBE1 = "/wiseprobe"
SlashCmdList["WISEPROBE"] = function(msg)
	local opts = {}
	if msg and msg:match("%S") then
		-- Semicolon-separated because ability and item names contain spaces.
		local fields = { "readySpell", "haveItem", "selfBuff" }
		local i = 1
		for piece in msg:gmatch("[^;]+") do
			piece = piece:match("^%s*(.-)%s*$")
			if piece ~= "" and fields[i] then
				opts[fields[i]] = piece
			end
			i = i + 1
		end
	end
	Wise_ProbeConditionals(opts)
end
