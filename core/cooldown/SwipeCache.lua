-- core/cooldown/SwipeCache.lua
--
-- The swipe-repaint guard, extracted from core/GUI.lua.
--
-- Cooldown:SetCooldown() and SetCooldownFromDurationObject() ALWAYS restart the
-- swipe animation, even when handed values identical to what the frame already
-- shows. UNIT_AURA (player + target) fires constantly in combat -- DoT ticks,
-- buff refreshes, nearby enemy auras -- so UpdateAllCooldowns() re-runs far more
-- often than any cooldown actually changes. Unconditional writes re-painted every
-- active swipe on every tick, visibly "pulsing" short timers like the GCD. These
-- helpers cache the last applied tuple per Cooldown frame and skip the call when
-- nothing changed.
--
-- The cached tuple is (start, duration, reverse). `source` is stored for
-- debugging but deliberately NOT compared: the rendered swipe depends only on
-- the numeric tuple and the reverse flag, so comparing source would produce
-- false negatives across layers (CD -> buff -> CD) where nothing actually
-- changed from the frame's point of view.
--
-- Secret numbers make the comparison itself dangerous -- in combat the values
-- throw on any comparison (see core/cooldown/SecretValues.lua) -- so the whole
-- check is wrapped. A throw is treated as "not matched", which forces a
-- re-write: always safe, merely not skipped.
--
-- Every helper here is at file scope and takes what it needs as arguments,
-- capturing no per-call state. UpdateButtonCooldown runs ~160x per pass, and
-- defining these per call allocated three closures (plus one per pcall) each
-- time -- measured at ~58% of all addon garbage in a 30s raid trace. Do not
-- move them back inside the function.
--
-- Loaded after SecretValues.lua and before core/GUI.lua.

local addonName, Wise = ...

local pcall = pcall

-- Body of the cache comparison, kept separate so cdTupleMatches can hand it to
-- pcall as a plain function reference with its arguments passed through. The old
-- form wrapped an inline closure over the locals, which allocated on every call;
-- pcall(f, a, b, ...) forwards arguments natively and allocates nothing.
local function cdCacheEquals(cache, newStart, newDur, reverse)
	return cache.start == newStart and cache.duration == newDur and cache.reverse == reverse
end

-- Compare the cached swipe tuple without ever letting a secret number escape.
-- The values may be "secret numbers" in combat (WoW 11.1+) which throw on any
-- comparison, so the whole check is wrapped: a throw means "not matched", which
-- forces a re-write — always safe, just not skipped.
local function cdTupleMatches(cache, newStart, newDur, reverse)
	if not cache then
		return false
	end
	local ok, matched = pcall(cdCacheEquals, cache, newStart, newDur, reverse)
	return ok and matched
end

-- Record the applied tuple on the Cooldown frame, reusing the existing cache
-- table instead of replacing it. A cache MISS is the common case for a ticking
-- cooldown (the values genuinely change), so allocating a fresh 4-field table
-- per write produced steady garbage. The table is private to the frame and only
-- ever read back by cdTupleMatches, so overwriting in place is safe -- but every
-- field must be written each time, or a stale one would survive into the next
-- comparison and could wrongly report a match.
local function storeCDCache(cdFrame, newStart, newDur, reverse, source)
	local cache = cdFrame._wiseLastCD
	if not cache then
		cache = {}
		cdFrame._wiseLastCD = cache
	end
	cache.start = newStart
	cache.duration = newDur
	cache.reverse = reverse
	cache.source = source
end

local function applyCD(cdFrame, newStart, newDur, reverse, source)
	if not cdFrame then
		return
	end
	if cdTupleMatches(cdFrame._wiseLastCD, newStart, newDur, reverse) then
		return
	end
	if cdFrame.SetReverse then
		cdFrame:SetReverse(reverse == true)
	end
	cdFrame:SetCooldown(newStart, newDur)
	storeCDCache(cdFrame, newStart, newDur, reverse, source)
end

local function applyCDFromDuration(cdFrame, durObj, numStart, numDur, reverse)
	if not cdFrame then
		return
	end
	if cdTupleMatches(cdFrame._wiseLastCD, numStart, numDur, reverse) then
		return
	end
	if cdFrame.SetReverse then
		cdFrame:SetReverse(reverse == true)
	end
	cdFrame:SetCooldownFromDurationObject(durObj, true)
	-- Store the raw values; next comparison will pcall too.
	storeCDCache(cdFrame, numStart, numDur, reverse, "durObj")
end

local function clearCD(cdFrame)
	if not cdFrame then
		return
	end
	if cdTupleMatches(cdFrame._wiseLastCD, 0, 0, false) then
		return
	end
	cdFrame:SetCooldown(0, 0)
	storeCDCache(cdFrame, 0, 0, false, "clear")
end

-- Published for core/GUI.lua, which binds these as upvalues.
local CD = Wise.CooldownUtil or {}
Wise.CooldownUtil = CD
CD.storeCDCache = storeCDCache
CD.applyCD = applyCD
CD.applyCDFromDuration = applyCDFromDuration
CD.clearCD = clearCD
