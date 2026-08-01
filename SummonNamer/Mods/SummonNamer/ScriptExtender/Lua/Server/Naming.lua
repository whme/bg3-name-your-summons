local Util     = Ext.Require("Shared/Util.lua")
local Channels = Ext.Require("Shared/Channels.lua")

local Naming = {}

--- Set to "Loca" only if CustomName turns out not to drive the UI on your
--- game/SE build. See Naming.Diagnose() and the README.
Naming.Strategy = "CustomName"

---@param ref string|EntityHandle
---@return EntityHandle|nil
local function resolve(ref)
    if ref == nil then return nil end
    local e = (type(ref) == "string") and Ext.Entity.Get(ref) or ref
    if e == nil or not e:IsAlive() then return nil end
    return e
end

---------------------------------------------------------------------------
-- Reading the current name
---------------------------------------------------------------------------

---@param ref string|EntityHandle
---@return string
function Naming.GetCurrentName(ref)
    local e = resolve(ref)
    if not e then return "" end

    if e.CustomName and e.CustomName.Name and e.CustomName.Name ~= "" then
        return e.CustomName.Name
    end

    local dn = e.DisplayName
    if dn and dn.NameKey and dn.NameKey.Handle and dn.NameKey.Handle.Handle then
        local ok, text = pcall(Ext.Loca.GetTranslatedString, dn.NameKey.Handle.Handle)
        if ok and type(text) == "string" then return text end
    end

    return ""
end

---------------------------------------------------------------------------
-- Strategy 1 (default): the CustomName component
--
-- This is per-entity, which is exactly what we want. Contrast with the
-- localisation-handle approach below, which is shared by every entity
-- spawned from the same root template.
---------------------------------------------------------------------------

---@param e EntityHandle
---@param name string
---@return boolean
local function applyCustomName(e, name)
    if e.CustomName == nil then
        local ok, err = pcall(function() e:CreateComponent("CustomName") end)
        if not ok then
            Util.Warn("CreateComponent('CustomName') failed: " .. tostring(err))
            return false
        end
    end
    if e.CustomName == nil then return false end

    local ok, err = pcall(function()
        e.CustomName.Name = name
        e:Replicate("CustomName")
    end)
    if not ok then
        Util.Warn("Writing CustomName failed: " .. tostring(err))
        return false
    end
    return true
end

---------------------------------------------------------------------------
-- Strategy 2 (fallback): give the entity its OWN localisation handle
--
-- Do NOT just overwrite the existing NameKey handle in place. Every wolf
-- summoned from the same template shares that handle, so renaming one would
-- rename all of them, in this save and in every future one, until the game
-- restarts. Instead we mint a fresh handle per entity and point NameKey at it.
---------------------------------------------------------------------------

local locaCounter = 0

---@param e EntityHandle
---@param name string
---@return boolean
local function applyLoca(e, name)
    local dn = e.DisplayName
    if not (dn and dn.NameKey and dn.NameKey.Handle) then return false end

    locaCounter = locaCounter + 1
    local handle = string.format("hSUMMONNAMER%08x%06x", Ext.Timer.ClockEpoch() % 0xFFFFFFFF, locaCounter)

    local ok, err = pcall(function()
        Ext.Loca.UpdateTranslatedString(handle, name)
        dn.NameKey.Handle.Handle = handle
        e:Replicate("DisplayName")
    end)
    if not ok then
        Util.Warn("Loca fallback failed: " .. tostring(err))
        return false
    end

    -- Clients keep their own loca table; tell them about the new string.
    Channels.SetLoca:Broadcast({ Handle = handle, Text = name })
    return true
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------

---@param ref string|EntityHandle
---@param name string
---@return boolean
function Naming.Apply(ref, name)
    local e = resolve(ref)
    if not e then return false end

    name = Util.Sanitise(name)
    if name == "" then return false end

    if Naming.Strategy == "Loca" then
        return applyLoca(e, name)
    end

    if applyCustomName(e, name) then return true end

    Util.Warn("CustomName strategy failed, falling back to loca handles.")
    return applyLoca(e, name)
end

--- Applies the name a moment after the entity settles. Summons are still
--- being assembled on the tick they enter the level, and an immediate write
--- can be clobbered by the engine.
---@param guid string
---@param name string
---@param delayMs integer|nil
function Naming.ApplyDeferred(guid, name, delayMs)
    Ext.Timer.WaitFor(delayMs or 250, function()
        if not Naming.Apply(guid, name) then
            Util.Warn("Could not apply name '" .. tostring(name) .. "' to " .. tostring(guid))
        end
    end)
end

--- Prints what the game actually thinks the name is, so you can confirm on
--- your own build which strategy works. Run  !sn_diag  in the SE console
--- with a summon selected.
---@param ref string|EntityHandle
function Naming.Diagnose(ref)
    local e = resolve(ref)
    if not e then Util.Log("Diagnose: no such entity") return end

    Util.Log("---- SummonNamer diagnosis ----")
    Util.Log("Has CustomName component :", e.CustomName ~= nil)
    if e.CustomName then
        Util.Log("CustomName.Name          :", tostring(e.CustomName.Name))
    end
    if e.DisplayName and e.DisplayName.NameKey and e.DisplayName.NameKey.Handle then
        local h = e.DisplayName.NameKey.Handle.Handle
        Util.Log("DisplayName.NameKey      :", tostring(h))
        Util.Log("Resolved loca string     :", tostring(Ext.Loca.GetTranslatedString(h)))
    end
    if e.OriginalTemplate then
        Util.Log("OriginalTemplate         :", tostring(e.OriginalTemplate.OriginalTemplate))
    end
    if e.Uuid then
        local uuid = tostring(e.Uuid.EntityUuid)
        Util.Log("Uuid                     :", uuid)
        Util.Log("Is summon (Osiris)       :", tostring(Osi.IsSummon(uuid)))
        Util.Log("Owner (Osiris)           :", tostring(Osi.CharacterGetOwner(uuid)))
    end
    Util.Log("-------------------------------")
end

return Naming
