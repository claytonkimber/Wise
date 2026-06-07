require("mock_wow_api")

local function run_baseline()
    local items = {}
    local configID = C_ClassTalents.GetActiveConfigID()
    if configID then
        local configInfo = C_Traits.GetConfigInfo(configID)
        if configInfo then
            for _, treeID in ipairs(configInfo.treeIDs) do
                local nodes = C_Traits.GetTreeNodes(treeID)
                for _, nodeID in ipairs(nodes) do
                    local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
                    if nodeInfo and nodeInfo.entryIDs then
                        -- Iterate all entries in this node
                        for _, entryID in ipairs(nodeInfo.entryIDs) do
                            local entryInfo = C_Traits.GetEntryInfo(configID, entryID)
                            if entryInfo and entryInfo.definitionID then
                                local defInfo = C_Traits.GetDefinitionInfo(entryInfo.definitionID)
                                if defInfo and defInfo.spellID then
                                    local spellInfo = C_Spell.GetSpellInfo(defInfo.spellID)
                                    if spellInfo then
                                        -- Deduplicate by spellID
                                        local exists = false
                                        for _, item in ipairs(items) do
                                            if item.spellID == spellInfo.spellID then
                                                exists = true
                                                break
                                            end
                                        end
                                        if not exists then
                                            table.insert(items, {
                                                spellID = spellInfo.spellID,
                                                name = spellInfo.name,
                                                icon = spellInfo.iconID
                                            })
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(items, function(a, b) return a.name < b.name end)
    return items
end

local function run_optimized()
    local items = {}
    local seen = {}
    local defCache = {}

    local configID = C_ClassTalents.GetActiveConfigID()
    if configID then
        local configInfo = C_Traits.GetConfigInfo(configID)
        if configInfo then
            for _, treeID in ipairs(configInfo.treeIDs) do
                local nodes = C_Traits.GetTreeNodes(treeID)
                for _, nodeID in ipairs(nodes) do
                    local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
                    if nodeInfo and nodeInfo.entryIDs then
                        -- Iterate all entries in this node
                        for _, entryID in ipairs(nodeInfo.entryIDs) do
                            local entryInfo = C_Traits.GetEntryInfo(configID, entryID)
                            if entryInfo and entryInfo.definitionID then
                                local defID = entryInfo.definitionID
                                local defInfo = defCache[defID]
                                if not defInfo then
                                    defInfo = C_Traits.GetDefinitionInfo(defID)
                                    defCache[defID] = defInfo
                                end

                                if defInfo and defInfo.spellID then
                                    local spellID = defInfo.spellID
                                    if not seen[spellID] then
                                        seen[spellID] = true
                                        local spellInfo = C_Spell.GetSpellInfo(spellID)
                                        if spellInfo then
                                            table.insert(items, {
                                                spellID = spellInfo.spellID,
                                                name = spellInfo.name,
                                                icon = spellInfo.iconID
                                            })
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(items, function(a, b) return a.name < b.name end)
    return items
end

local start = os.clock()
for i=1, 1000 do run_baseline() end
print("Baseline:", os.clock() - start)

local start2 = os.clock()
for i=1, 1000 do run_optimized() end
print("Optimized:", os.clock() - start2)
