import re

with open("core/GUI.lua", "r") as f:
    content = f.read()

# Also adjust PositionNestedChild for lists
# Find PositionNestedChild definition

new_pos_code = """
function Wise:PositionNestedChild(childFrame, childName, parentName)
    local parentFrame = Wise.frames and Wise.frames[parentName]
    if not parentFrame then return end

    -- Find which parent button is the interface action pointing to this child
    local parentBtn = nil
    if parentFrame.buttons then
        for _, btn in ipairs(parentFrame.buttons) do
            if btn:IsShown() and btn:GetAttribute("isa_interface_target") == childName then
                parentBtn = btn
                break
            end
        end
    end

    -- Fallback to parent frame center if no specific button found
    local anchorFrame = parentBtn or parentFrame

    -- Resolve open direction from the action's nesting options
    local direction = "auto"
    if parentBtn then
        direction = parentBtn:GetAttribute("isa_open_direction") or "auto"
    end
    direction = Wise:ResolveOpenDirection(anchorFrame, direction)

    -- Get the anchor frame's center in screen coordinates
    local cx, cy = anchorFrame:GetCenter()
    if not cx or not cy then return end

    local uiScale = UIParent:GetScale()
    local frameScale = childFrame:GetScale()
    local correctedX = cx / frameScale
    local correctedY = cy / frameScale

    -- Offset based on direction (use parent icon size as spacing)
    local spacingX = (parentBtn and parentBtn:GetWidth() or 50) + 10
    local spacingY = (parentBtn and parentBtn:GetHeight() or 50) + 10

    -- In a list layout, width might be much larger (150+), so handle X offset carefully
    if parentBtn and parentBtn.textLabel and parentBtn.textLabel:IsShown() then
        -- This is likely a list item. The actual clickable width is the whole row,
        -- but visually we might want to offset relative to the icon or the whole row.
        spacingX = parentBtn:GetWidth() + 10
    end

    if direction == "up" then
        correctedY = correctedY + spacingY / frameScale
    elseif direction == "down" then
        correctedY = correctedY - spacingY / frameScale
    elseif direction == "right" then
        correctedX = correctedX + spacingX / frameScale
    elseif direction == "left" then
        correctedX = correctedX - spacingX / frameScale
    end
    -- "center" keeps the same position

    -- Move the proxy anchor (safe even in combat)
    if childFrame.Anchor then
        childFrame.Anchor:ClearAllPoints()
        childFrame.Anchor:SetPoint("CENTER", UIParent, "BOTTOMLEFT", correctedX, correctedY)
    end

    -- Also move the secure frame directly (only safe out of combat)
    if not InCombatLockdown() then
        childFrame:ClearAllPoints()
        childFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", correctedX, correctedY)
    end
end
"""

# Now replace the existing PositionNestedChild function
start_marker = "function Wise:PositionNestedChild("
end_marker = "function Wise:StartNestedCloseOnLeave("

start_idx = content.find(start_marker)
end_idx = content.find(end_marker)

if start_idx != -1 and end_idx != -1:
    content = content[:start_idx] + new_pos_code + "\n" + content[end_idx:]

    with open("core/GUI.lua", "w") as f:
        f.write(content)
else:
    print("Could not find markers")
