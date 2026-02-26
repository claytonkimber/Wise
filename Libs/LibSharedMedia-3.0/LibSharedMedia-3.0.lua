--[[
Name: LibSharedMedia-3.0
Revision: $Revision: 133 $
Author: Elkano (elkano@gmx.de)
Inspired By: SurfaceLib by Haste/Otravi (trorat@gmail.com)
Website: https://www.curseforge.com/wow/addons/libsharedmedia-3-0
Description: Shared handling of media data (fonts, sounds, textures, ...) between addons.
Dependencies: LibStub, CallbackHandler-1.0
License: LGPL v2.1
]]

local MAJOR, MINOR = "LibSharedMedia-3.0", 8020003 -- 8.2.0 v3 / increase manually on changes
local lib = LibStub:NewLibrary(MAJOR, MINOR)

if not lib then return end

local _G = getfenv(0)

local pairs		= _G.pairs
local type		= _G.type

local band			= _G.bit.band

local table_sort	= _G.table.sort

local RESTRICTED_FILE_ACCESS = WOW_PROJECT_ID == WOW_PROJECT_MAINLINE -- starting with 8.2, some rules for file access have changed; classic still uses the old way

lib.MediaType = lib.MediaType or {}
local MediaType = lib.MediaType

lib.MediaTable = lib.MediaTable or {}
local MediaTable = lib.MediaTable

lib.DefaultMedia = lib.DefaultMedia or {}
local DefaultMedia = lib.DefaultMedia

lib.callbacks = lib.callbacks or LibStub("CallbackHandler-1.0"):New(lib)

local mediaTypeOrder = {}

local function rebuildMediaList(mediatype)
	local mtable = MediaTable[mediatype]
	if not mtable then return end
	local mediaList = {}
	for k in pairs(mtable) do
		mediaList[#mediaList + 1] = k
	end
	table_sort(mediaList)
	if not lib.MediaList then
		lib.MediaList = {}
	end
	lib.MediaList[mediatype] = mediaList
end

function lib:Register(mediatype, key, data, langmask)
	if type(mediatype) ~= "string" then
		error(MAJOR..":Register(mediatype, key, data, langmask) - mediatype must be string, got "..type(mediatype))
	end
	if type(key) ~= "string" then
		error(MAJOR..":Register(mediatype, key, data, langmask) - key must be string, got "..type(key))
	end
	mediatype = mediatype:lower()
	if not MediaTable[mediatype] then
		MediaTable[mediatype] = {}
		mediaTypeOrder[#mediaTypeOrder + 1] = mediatype
		table_sort(mediaTypeOrder)
	end
	local mtable = MediaTable[mediatype]
	if mtable[key] then return false end
	
	mtable[key] = data
	rebuildMediaList(mediatype)
	self.callbacks:Fire("LibSharedMedia_Registered", mediatype, key)
	return true
end

function lib:Fetch(mediatype, key, noDefault)
	local mtable = MediaTable[mediatype]
	local result = mtable and mtable[key]
	if not result then
		if not noDefault then
			result = mtable and mtable[DefaultMedia[mediatype]]
		end
	end
	return result
end

function lib:IsValid(mediatype, key)
	return MediaTable[mediatype] and (not key or MediaTable[mediatype][key]) and true or false
end

function lib:HashTable(mediatype)
	return MediaTable[mediatype]
end

function lib:List(mediatype)
	if not lib.MediaList then
		lib.MediaList = {}
	end
	if not lib.MediaList[mediatype] then
		rebuildMediaList(mediatype)
	end
	return lib.MediaList[mediatype]
end

function lib:GetGlobal(mediatype)
	return DefaultMedia[mediatype]
end

function lib:SetGlobal(mediatype, key)
	if not MediaTable[mediatype] then
		return false
	end
	DefaultMedia[mediatype] = MediaTable[mediatype][key] and key or nil
	return true
end

function lib:GetDefault(mediatype)
	return DefaultMedia[mediatype]
end

function lib:SetDefault(mediatype, key)
	if MediaTable[mediatype] and MediaTable[mediatype][key] then
		DefaultMedia[mediatype] = key
		return true
	end
	return false
end

-- Define the standard media types
MediaType.FONT          = "font"
MediaType.SOUND         = "sound"
MediaType.STATUSBAR     = "statusbar"
MediaType.BACKGROUND    = "background"
MediaType.BORDER        = "border"

-- Register default fonts
lib:Register(MediaType.FONT, "Friz Quadrata TT", [[Fonts\FRIZQT__.TTF]])
lib:Register(MediaType.FONT, "Arial Narrow", [[Fonts\ARIALN.TTF]])
lib:Register(MediaType.FONT, "Morpheus", [[Fonts\MORPHEUS.TTF]])
lib:Register(MediaType.FONT, "Skurri", [[Fonts\SKURRI.TTF]])
lib:Register(MediaType.FONT, "2002", [[Fonts\2002.TTF]])
lib:Register(MediaType.FONT, "2002 Bold", [[Fonts\2002B.TTF]])

-- Set default font
lib:SetDefault(MediaType.FONT, "Friz Quadrata TT")

-- Register default statusbar textures
lib:Register(MediaType.STATUSBAR, "Blizzard", [[Interface\TargetingFrame\UI-StatusBar]])
lib:Register(MediaType.STATUSBAR, "Blizzard Character Skills Bar", [[Interface\PaperDollInfoFrame\UI-Character-Skills-Bar]])
lib:Register(MediaType.STATUSBAR, "Blizzard Raid Bar", [[Interface\RaidFrame\Raid-Bar-Hp-Fill]])
lib:SetDefault(MediaType.STATUSBAR, "Blizzard")

-- Register default backgrounds
lib:Register(MediaType.BACKGROUND, "Blizzard Dialog Background", [[Interface\DialogFrame\UI-DialogBox-Background]])
lib:Register(MediaType.BACKGROUND, "Blizzard Dialog Background Dark", [[Interface\DialogFrame\UI-DialogBox-Background-Dark]])
lib:Register(MediaType.BACKGROUND, "Blizzard Dialog Background Gold", [[Interface\DialogFrame\UI-DialogBox-Gold-Background]])
lib:Register(MediaType.BACKGROUND, "Blizzard Low Health", [[Interface\FullScreenTextures\LowHealth]])
lib:Register(MediaType.BACKGROUND, "Blizzard Marble", [[Interface\FrameGeneral\UI-Background-Marble]])
lib:Register(MediaType.BACKGROUND, "Blizzard Out of Control", [[Interface\FullScreenTextures\OutOfControl]])
lib:Register(MediaType.BACKGROUND, "Blizzard Parchment", [[Interface\AchievementFrame\UI-Achievement-Parchment-Horizontal]])
lib:Register(MediaType.BACKGROUND, "Blizzard Parchment 2", [[Interface\AchievementFrame\UI-GuildAchievement-Parchment-Horizontal]])
lib:Register(MediaType.BACKGROUND, "Blizzard Rock", [[Interface\FrameGeneral\UI-Background-Rock]])
lib:Register(MediaType.BACKGROUND, "Blizzard Tabard Background", [[Interface\TabardFrame\TabardFrameBackground]])
lib:Register(MediaType.BACKGROUND, "Blizzard Tooltip", [[Interface\Tooltips\UI-Tooltip-Background]])
lib:Register(MediaType.BACKGROUND, "Solid", [[Interface\Buttons\WHITE8X8]])
lib:SetDefault(MediaType.BACKGROUND, "Blizzard Tooltip")

-- Register default borders
lib:Register(MediaType.BORDER, "Blizzard Dialog", [[Interface\DialogFrame\UI-DialogBox-Border]])
lib:Register(MediaType.BORDER, "Blizzard Dialog Gold", [[Interface\DialogFrame\UI-DialogBox-Gold-Border]])
lib:Register(MediaType.BORDER, "Blizzard Party", [[Interface\CHARACTERFRAME\UI-Party-Border]])
lib:Register(MediaType.BORDER, "Blizzard Achievement Wood", [[Interface\AchievementFrame\UI-Achievement-WoodBorder]])
lib:Register(MediaType.BORDER, "Blizzard Tooltip", [[Interface\Tooltips\UI-Tooltip-Border]])
lib:Register(MediaType.BORDER, "None", [[Interface\Buttons\WHITE8X8]])
lib:SetDefault(MediaType.BORDER, "Blizzard Tooltip")

-- Register default sounds (some examples)
lib:Register(MediaType.SOUND, "None", [[Interface\Quiet.ogg]])
