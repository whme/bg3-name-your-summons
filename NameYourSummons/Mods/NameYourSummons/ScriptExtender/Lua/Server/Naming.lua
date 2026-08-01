local Util     = Ext.Require("Shared/Util.lua")
local Channels = Ext.Require("Shared/Channels.lua")
local Writer   = Ext.Require("Shared/NameWriter.lua")

local Naming = {}

---------------------------------------------------------------------------
-- Reading the current name
---------------------------------------------------------------------------

---@param ref string|EntityHandle
---@return string
function Naming.GetCurrentName(ref)
    local e = Writer.Resolve(ref)
    if not e then return "" end

    if e.CustomName and e.CustomName.Name and e.CustomName.Name ~= "" then
        return e.CustomName.Name
    end

    local dn = e.DisplayName
    if dn and dn.NameKey and dn.NameKey.Handle and dn.NameKey.Handle.Handle then
        local ok, text = pcall(Ext.Loca.GetTranslatedString, dn.NameKey.Handle.Handle)
        if ok and type(text) == "string" and text ~= "" then return text end
    end

    return ""
end

---------------------------------------------------------------------------
-- Applying a name
---------------------------------------------------------------------------

---@param ref string|EntityHandle
---@param name string
---@return boolean success, string|nil err
function Naming.Apply(ref, name)
    local e = Writer.Resolve(ref)
    if not e then return false, "entity not found" end

    name = Util.Sanitise(name)
    if name == "" then return false, "empty name" end

    local handle = Util.LocaHandleFor(name)

    -- Must come first: an unregistered handle renders as nothing at all.
    if not Writer.RegisterLoca(handle, name) then
        return false, "could not register localisation handle"
    end

    local ok, err = Writer.SetDisplayName(e, handle, true)
    if not ok then return false, err end

    -- Remote peers have their own localisation table and have not seen this handle.
    pcall(function() Channels.ApplyName:Broadcast({ Handle = handle, Text = name }) end)

    local uuid = e.Uuid and tostring(e.Uuid.EntityUuid) or tostring(ref)
    Util.Log(("Named %s '%s'"):format(uuid, name))
    return true
end

--- Applies the name a moment after the entity settles. Summons are still being
--- assembled on the tick they enter the level, and an immediate write can be
--- clobbered by the engine.
---@param guid string
---@param name string
---@param delayMs integer|nil
function Naming.ApplyDeferred(guid, name, delayMs)
    Ext.Timer.WaitFor(delayMs or 250, function()
        local ok, err = Naming.Apply(guid, name)
        if not ok then
            Util.Warn(("Could not name %s '%s': %s"):format(tostring(guid), tostring(name), tostring(err)))
        end
    end)
end

--- Re-registers every saved name's handle. Runtime localisation entries do not
--- survive a restart, so this runs on session load before any name is re-applied.
---@param names table<string,string>  key -> name
function Naming.SeedLoca(names)
    local seeded = {}
    local n = 0
    for _, name in pairs(names) do
        local handle = Util.LocaHandleFor(name)
        if not seeded[handle] then
            seeded[handle] = name
            Writer.RegisterLoca(handle, name)
            n = n + 1
        end
    end
    if n > 0 then
        pcall(function() Channels.SeedLoca:Broadcast({ Entries = seeded }) end)
        Util.Log(("Registered %d localisation handle(s) for saved names."):format(n))
    end
end

---------------------------------------------------------------------------
-- Diagnostics
---------------------------------------------------------------------------

---@param ref string|EntityHandle
function Naming.Diagnose(ref)
    local e = Writer.Resolve(ref)
    if not e then Util.Log("Diagnose: no such entity") return end

    Util.Log("---- NameYourSummons diagnosis ----")

    local uuid
    if e.Uuid then
        uuid = tostring(e.Uuid.EntityUuid)
        Util.Log("Uuid                     :", uuid)
    end

    if e.DisplayName and e.DisplayName.NameKey and e.DisplayName.NameKey.Handle then
        local h = e.DisplayName.NameKey.Handle.Handle
        Util.Log("DisplayName.NameKey      :", tostring(h),
                 "(version " .. tostring(e.DisplayName.NameKey.Handle.Version) .. ")")
        Util.Log("  resolves to            :", tostring(Ext.Loca.GetTranslatedString(h)))
    end

    if e.CustomName then
        Util.Log("CustomName.Name          :", tostring(e.CustomName.Name))
    end

    if e.OriginalTemplate then
        Util.Log("OriginalTemplate         :", tostring(e.OriginalTemplate.OriginalTemplate))
    end
    if uuid then
        Util.Log("Is summon (Osiris)       :", tostring(Osi.IsSummon(uuid)))
        Util.Log("Owner (Osiris)           :", tostring(Osi.CharacterGetOwner(uuid)))
    end

    Util.Log("-------------------------------")
end

--- Every summon the host currently has out.
---@return EntityHandle[]
function Naming.HostSummons()
    local out = {}
    local ok, host = pcall(Osi.GetHostCharacter)
    if not ok or not host then return out end

    local entityOk, entity = pcall(Ext.Entity.Get, host)
    if not entityOk or not entity or not entity.SummonContainer then return out end

    for _, summon in pairs(entity.SummonContainer.Characters or {}) do
        if type(summon) ~= "string" and type(summon) ~= "number" then
            table.insert(out, summon)
        end
    end
    return out
end

return Naming
