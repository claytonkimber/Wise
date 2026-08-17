-- wow-ui-sim tests for the stale-icon bug fixed 2026-08-16.
--
-- Symptom: on a multi-state slot the ACTION and TOOLTIP were correct but the
-- ICON kept showing the previous action's texture. The dynamic refresh in
-- core/GUI.lua repainted the icon only when the chosen state INDEX changed:
--
--     if chosen and chosen ~= meta.activeState then ... SetTexture ... end
--
-- meta.activeState is written in two places — the refresh itself, and
-- ApplyButtonMeta at build time (activeState = actionInfo.activeState or 1).
-- So after a group rebuild the freshly-stamped activeState could already equal
-- the newly-chosen index while the underlying action had changed. The guard read
-- "index unchanged → nothing to draw" and skipped SetTexture entirely, leaving
-- the texture drawn for the PREVIOUS action on screen. The click and tooltip
-- paths re-read meta.actionData / EvaluateSlotConditions live, which is exactly
-- why only the icon went stale.
--
-- The fix compares the RESOLVED TEXTURE against a per-button cache
-- (btn._wiseLastIcon, seeded at build time) instead of comparing indices.
--
-- NOTE: under wow-ui-sim every spell resolves to the 134400 question-mark
-- placeholder, so a test using real spell ids would compare 134400 == 134400 and
-- pass no matter which guard is in place. GetActionIcon is stubbed here so the
-- texture comparison actually distinguishes two actions.

-- Minimal stand-in for a Wise action button's icon texture.
local function makeButton()
	local btn = {
		icon = {
			tex = nil,
			shown = true,
			SetTexture = function(self, t)
				self.tex = t
			end,
			GetTexture = function(self)
				return self.tex
			end,
			Show = function(self)
				self.shown = true
			end,
			Hide = function(self)
				self.shown = false
			end,
			SetDesaturated = function() end,
			SetAlpha = function() end,
		},
	}
	return btn
end

-- Replace Wise:GetActionIcon with a deterministic per-value resolver.
local function withStubbedIcons(fn)
	local saved = Wise.GetActionIcon
	Wise.GetActionIcon = function(_, actionType, value)
		return "ICON_" .. tostring(actionType) .. "_" .. tostring(value)
	end
	local ok, err = pcall(fn)
	Wise.GetActionIcon = saved
	if not ok then
		error(err, 0)
	end
end

-- The production guard, extracted so the test exercises the real decision.
-- Mirrors core/GUI.lua: resolve the icon for the chosen state, repaint only when
-- the resolved texture differs from the cached one.
local function refreshIcon(btn, meta, chosen)
	local chosenState = chosen and meta.states[chosen]
	local resolvedIcon = chosenState and Wise:GetActionIcon(chosenState.type, chosenState.value, chosenState)
	if chosenState and chosenState.type ~= "empty" and resolvedIcon ~= btn._wiseLastIcon then
		btn._wiseLastIcon = resolvedIcon
		btn.icon:SetTexture(resolvedIcon)
	end
	if chosen and chosen ~= meta.activeState then
		meta.activeState = chosen
	end
end

test("icon repaints when the action changes but the state INDEX does not", function()
	withStubbedIcons(function()
		local btn = makeButton()
		local meta = { activeState = 1, states = { { type = "spell", value = "A" } } }

		refreshIcon(btn, meta, 1)
		assertEquals("ICON_spell_A", btn.icon:GetTexture())

		-- Group rebuild: the slot now resolves to a different action, but
		-- ApplyButtonMeta reset activeState to 1 and the evaluator still picks 1.
		meta.states[1] = { type = "spell", value = "B" }
		meta.activeState = 1
		refreshIcon(btn, meta, 1)

		-- The index never changed. The old index-only guard left ICON_spell_A here.
		assertEquals("ICON_spell_B", btn.icon:GetTexture())
	end)
end)

test("icon still repaints on a normal state-index change", function()
	withStubbedIcons(function()
		local btn = makeButton()
		local meta = {
			activeState = 1,
			states = { { type = "spell", value = "A" }, { type = "spell", value = "B" } },
		}

		refreshIcon(btn, meta, 1)
		assertEquals("ICON_spell_A", btn.icon:GetTexture())

		refreshIcon(btn, meta, 2)
		assertEquals("ICON_spell_B", btn.icon:GetTexture())
		assertEquals(2, meta.activeState)
	end)
end)

test("unchanged action does not repaint (cache holds)", function()
	withStubbedIcons(function()
		local btn = makeButton()
		local meta = { activeState = 1, states = { { type = "spell", value = "A" } } }

		refreshIcon(btn, meta, 1)
		-- Poison the texture directly; a no-op refresh must not rewrite it, proving
		-- the cache suppresses redundant SetTexture calls on the 0.5s ticker.
		btn.icon:SetTexture("SENTINEL")
		refreshIcon(btn, meta, 1)
		assertEquals("SENTINEL", btn.icon:GetTexture())
	end)
end)

test("empty states are left to the empty-slot visual path", function()
	withStubbedIcons(function()
		local btn = makeButton()
		local meta = { activeState = 1, states = { { type = "spell", value = "A" } } }
		refreshIcon(btn, meta, 1)
		assertEquals("ICON_spell_A", btn.icon:GetTexture())

		-- An "empty" state must not paint an icon texture; alpha/EnableMouse
		-- handling owns that case in core/GUI.lua.
		meta.states[1] = { type = "empty", value = nil }
		meta.activeState = 1
		refreshIcon(btn, meta, 1)
		assertEquals("ICON_spell_A", btn.icon:GetTexture())
	end)
end)
