local addonName, addon = ...
local LDB = LibStub("LibDataBroker-1.1")
local LDBIcon = LibStub("LibDBIcon-1.0")

-- Create the DataBroker object
local WiseLDB = LDB:NewDataObject("Wise", {
    type = "launcher",
    icon = "Interface\\AddOns\\Wise\\Media\\WiseIcon_64.png",  -- Explicit extension for PNG support
    
    OnClick = function(self, button)
        if button == "LeftButton" then
            if Wise.ToggleOptions then
                Wise:ToggleOptions()
            else
                print("Wise: Options not loaded yet.")
            end
        elseif button == "RightButton" then
            if Wise.ToggleEditMode then
                Wise:ToggleEditMode()
            end
        end
    end,
    
    OnTooltipShow = function(tooltip)
        tooltip:SetText("|cff00ccffWise|r")
        tooltip:AddLine("Ring Menu Addon", 1, 1, 1)
        tooltip:AddLine(" ")
        tooltip:AddLine("|cffaaaaaa<Left-Click>|r Open options", 0.2, 1, 0.2)
        tooltip:AddLine("|cffaaaaaa<Right-Click>|r Toggle Edit Mode", 0.2, 1, 0.2)
    end,
})

function addon:InitializeMinimap()
    -- Ensure persistence table exists
    -- WiseDB is global saved variable
    if not WiseDB then WiseDB = {} end
    if not WiseDB.settings then WiseDB.settings = {} end
    if not WiseDB.settings.minimap then WiseDB.settings.minimap = { hide = true } end
    
    -- Register the icon
    -- storage table is WiseDB.settings.minimap
    LDBIcon:Register("Wise", WiseLDB, WiseDB.settings.minimap)
end

function Wise:UpdateMinimapButton()
    if WiseDB.settings.minimap.hide then
        LDBIcon:Hide("Wise")
    else
        LDBIcon:Show("Wise")
    end
end
