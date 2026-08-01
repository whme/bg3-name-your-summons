local Util     = Ext.Require("Shared/Util.lua")
local Channels = Ext.Require("Shared/Channels.lua")
local Store    = Ext.Require("Server/Store.lua")
local Naming   = Ext.Require("Server/Naming.lua")

local Watcher = {}

-- Keys we have already asked about this session, so a player who dismissed the
-- prompt is not nagged every single time they re-cast the spell.
local askedThisSession = {}

-- Summons we are currently waiting on a name for: key -> summon uuid
local pending = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

---@param guid string
---@return boolean
local function isSummon(guid)
    local ok, result = pcall(Osi.IsSummon, guid)
    return ok and result == 1
end

--- Only bother the player about summons that belong to their own party.
---@param ownerUuid string
---@return boolean
local function ownerIsPlayer(ownerUuid)
    local ok, result = pcall(Osi.IsPartyMember, ownerUuid, 1)
    return ok and result == 1
end

---------------------------------------------------------------------------
-- Core
---------------------------------------------------------------------------

---@param summonGuid string
---@param rootTemplate string
function Watcher.HandleSummon(summonGuid, rootTemplate)
    if not Osi.Exists(summonGuid) or Osi.Exists(summonGuid) == 0 then return end

    local ownerRaw = Osi.CharacterGetOwner(summonGuid)
    if not ownerRaw or ownerRaw == "" then
        -- Owner is not wired up yet on some summon paths; try once more shortly.
        return
    end

    local ownerUuid = Util.ToUuid(ownerRaw)
    local key = Util.MakeKey(ownerUuid, rootTemplate)

    local saved = Store.Get(key)
    if saved then
        Naming.ApplyDeferred(summonGuid, saved)
        return
    end

    local settings = Store.Settings()
    if not settings.PromptOnSummon then return end
    if askedThisSession[key] then return end
    if not ownerIsPlayer(ownerUuid) then return end

    askedThisSession[key] = true
    pending[key] = Util.ToUuid(summonGuid)

    -- Give the summon a moment to finish spawning so the default name we show
    -- in the prompt is the real one.
    Ext.Timer.WaitFor(400, function()
        Channels.AskName:SendToClient({
            Key         = key,
            SummonUuid  = Util.ToUuid(summonGuid),
            OwnerUuid   = ownerUuid,
            DefaultName = Naming.GetCurrentName(summonGuid),
            Template    = rootTemplate,
        }, ownerRaw)
    end)
end

---------------------------------------------------------------------------
-- Osiris hook
--
-- There is no "summon created" Osiris event in BG3. EnteredLevel fires for
-- every object that spawns into a level, and it conveniently hands us the
-- root template, which is the stable half of our storage key.
---------------------------------------------------------------------------

function Watcher.Register()
    Ext.Osiris.RegisterListener("EnteredLevel", 3, "after", function(objectGuid, rootTemplate, _level)
        if not isSummon(objectGuid) then return end
        -- Defer: on the tick a summon enters the level its owner link and
        -- display name are not reliably populated yet.
        Ext.Timer.WaitFor(100, function()
            Watcher.HandleSummon(objectGuid, rootTemplate)
        end)
    end)
end

---------------------------------------------------------------------------
-- Re-apply names to summons that are already alive (e.g. after loading a save)
---------------------------------------------------------------------------

function Watcher.ReapplyExisting()
    if not Store.Settings().ApplyToExisting then return end

    local players = Osi.DB_Players:Get(nil)
    if not players then return end

    for _, row in pairs(players) do
        local playerUuid = Util.ToUuid(row[1])
        local ok, entity = pcall(Ext.Entity.Get, row[1])
        if ok and entity and entity.SummonContainer then
            for _, summonHandle in pairs(entity.SummonContainer.Characters or {}) do
                local sOk, summon = pcall(function() return summonHandle end)
                if sOk and summon and summon.Uuid and summon.OriginalTemplate then
                    local key = Util.MakeKey(playerUuid, summon.OriginalTemplate.OriginalTemplate)
                    local saved = Store.Get(key)
                    if saved then
                        Naming.Apply(summon, saved)
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Net handlers
---------------------------------------------------------------------------

function Watcher.RegisterNet()
    Channels.SubmitName:SetHandler(function(data, _user)
        if type(data) ~= "table" or type(data.Key) ~= "string" then return end

        local name = Util.Sanitise(data.Name)
        if name == "" then
            pending[data.Key] = nil
            return
        end

        Store.Set(data.Key, name)

        local target = data.SummonUuid or pending[data.Key]
        if target then
            Naming.Apply(target, name)
        end
        pending[data.Key] = nil
        Util.Log(("Saved name '%s' for key %s"):format(name, data.Key))
    end)

    Channels.ListNames:SetRequestHandler(function(_data, _user)
        local out = {}
        for key, name in pairs(Store.All()) do
            table.insert(out, { Key = key, Name = name })
        end
        table.sort(out, function(a, b) return a.Name:lower() < b.Name:lower() end)
        return { Entries = out }
    end)

    Channels.ForgetName:SetHandler(function(data, _user)
        if type(data) ~= "table" or type(data.Key) ~= "string" then return end
        Store.Forget(data.Key)
        askedThisSession[data.Key] = nil
        Util.Log("Forgot saved name for key " .. data.Key)
    end)
end

---------------------------------------------------------------------------
-- Console commands (server context)
---------------------------------------------------------------------------

function Watcher.RegisterConsole()
    Ext.RegisterConsoleCommand("sn_diag", function()
        local host = Osi.GetHostCharacter()
        local entity = Ext.Entity.Get(host)
        if entity and entity.SummonContainer then
            local any = false
            for _, summon in pairs(entity.SummonContainer.Characters or {}) do
                any = true
                Naming.Diagnose(summon)
            end
            if any then return end
        end
        Util.Log("No summons found on the host character; diagnosing the host instead.")
        Naming.Diagnose(host)
    end)

    Ext.RegisterConsoleCommand("sn_list", function()
        local n = 0
        for key, name in pairs(Store.All()) do
            Util.Log(("  %-70s -> %s"):format(key, name))
            n = n + 1
        end
        Util.Log(("%d saved name(s)."):format(n))
    end)

    Ext.RegisterConsoleCommand("sn_clear", function()
        for key in pairs(Store.All()) do Store.Forget(key) end
        askedThisSession = {}
        Util.Log("Cleared all saved summon names.")
    end)
end

return Watcher
