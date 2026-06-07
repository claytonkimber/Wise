C_ClassTalents = {
    GetActiveConfigID = function() return 1 end
}

C_Traits = {
    GetConfigInfo = function(configID)
        return { treeIDs = { 1, 2 } }
    end,
    GetTreeNodes = function(treeID)
        local nodes = {}
        for i=1, 50 do table.insert(nodes, i) end
        return nodes
    end,
    GetNodeInfo = function(configID, nodeID)
        local entries = {}
        for i=1, 3 do table.insert(entries, nodeID * 10 + i) end
        return { entryIDs = entries }
    end,
    GetEntryInfo = function(configID, entryID)
        return { definitionID = entryID % 20 }
    end,
    GetDefinitionInfo = function(defID)
        return { spellID = defID * 100 }
    end
}

C_Spell = {
    GetSpellInfo = function(spellID)
        return { spellID = spellID, name = "Spell " .. spellID, iconID = 12345 }
    end
}
