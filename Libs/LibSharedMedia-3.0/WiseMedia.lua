--[[
Wise SharedMedia Fonts
Additional fonts registered with LibSharedMedia-3.0
]]

local LSM = LibStub("LibSharedMedia-3.0", true)
if not LSM then return end

-- These are paths to fonts that may exist depending on user's system/addons
-- The fonts will only show if they actually exist

-- Default WoW Fonts with alternative names
LSM:Register("font", "Friz Quadrata", [[Fonts\FRIZQT__.TTF]])
LSM:Register("font", "Arial Narrow", [[Fonts\ARIALN.TTF]])
LSM:Register("font", "Morpheus", [[Fonts\MORPHEUS.TTF]])
LSM:Register("font", "Skurri", [[Fonts\SKURRI.TTF]])
LSM:Register("font", "2002", [[Fonts\2002.TTF]])
LSM:Register("font", "2002 Bold", [[Fonts\2002B.TTF]])

-- These may exist in the game files
LSM:Register("font", "Friz Quadrata CYR", [[Fonts\FRIZQT___CYR.TTF]])
