--[[============================================================================
  QuestEcho — Emberveil (Unreal Azeroth, WoW 1.12.1) port
  -----------------------------------------------------------------------------
  From-scratch port of the QuestEcho addon for the Emberveil client.

  Design notes (why this looks different from the original):
    * The Emberveil client implements a vanilla-1.12-shaped Lua/UI surface but
      with its own quirks: no UnitGUID, no StaticPopup, limited FrameXML globals,
      and the community (KoQuest, PostalEV, ComboWatch, ...) ports all addons
      as plain single-file Lua with no Ace/XML dependencies. This port follows
      that proven pattern.
    * Every API call below is either confirmed present in the client binary
      (Azeroth-Win64-Shipping.exe) or wrapped in pcall so a missing function
      degrades gracefully instead of killing the addon.
    * The data module (QuestEchoData) is bundled as Data\ and also
      loads standalone if the client picks it up: DataModules:Register() is
      duplicate-safe, so whichever copy runs first wins, the other is ignored.

  Commands: /qe help
============================================================================]]

local _G = getfenv(0)

-- Public global kept for data-module compatibility (same contract as original)
QuestEcho = setmetatable({ _G = _G }, { __index = _G })

local type, tonumber, tostring = type, tonumber, tostring
local pairs, ipairs, next, select = pairs, ipairs, next, select

-- Vanilla clients alias string.format to the bare global `format`, and the
-- data module (Module.lua) relies on that global. Ensure it exists even if
-- this client does not define it; if the client already has it, this is a no-op.
if _G.format == nil then
    _G.format = string.format
end
local format = _G.format

local pcall, error, assert = pcall, error, assert

-- =============================================================================
-- Version / environment detection
-- =============================================================================
local okBuild, _, _, _, interfaceVersion = pcall(GetBuildInfo)
QuestEcho.Interface = tonumber(interfaceVersion) or 11200

-- =============================================================================
-- Enums (same values as the original addon)
-- =============================================================================
QuestEcho.Enums =
{
    SoundEvent =
    {
        QuestAccept    = 1,
        QuestProgress  = 2,
        QuestComplete  = 3,
        QuestGreeting  = 4,
        Gossip         = 5,
    },
    GossipFrequency =
    {
        Always          = 1,
        OncePerQuestNPC = 2,
        OncePerNPC      = 3,
        Never           = 4,
    },
    GUID =
    {
        Player     = 2,
        Item       = 3,
        Creature   = 8,
        Vehicle    = 9,
        GameObject = 11,
    },
}

local Enums = QuestEcho.Enums

function Enums.SoundEvent:IsQuestEvent(event)
    return event == self.QuestAccept or event == self.QuestProgress or event == self.QuestComplete
end

function Enums.SoundEvent:IsGossipEvent(event)
    return event == self.Gossip or event == self.QuestGreeting
end

function Enums.GUID:IsCreature(t)
    return t == self.Creature or t == self.Vehicle
end

function Enums.GUID:CanHaveID(t)
    return t == self.Creature or t == self.Vehicle or t == self.GameObject
end

-- =============================================================================
-- Addon database (SavedVariables: QuestEchoDB)
-- =============================================================================
QuestEcho.Addon = {}
local Addon = QuestEcho.Addon

local DEFAULTS =
{
    profile =
    {
        Delay = 0.3,            -- seconds to wait after the dialog opens
        GossipFrequency = 1,    -- Enums.GossipFrequency.Always
        ShowUI = true,          -- show the small status bar
        Debug = false,
        -- Seconds to keep the volume muted after a line is removed before
        -- restoring the player's sound settings. Short (0.5) = fast restore,
        -- the removed line's tail may keep playing for that long. "full"
        -- waits until the removed line would have ended (cleanest, slowest).
        StopWait = 0.5,
    },
    char =
    {
        IsPaused = false,
        PlayedNPC = {},         -- persisted once-per-NPC gossip memory
    },
}

function Addon:GetDefaults()
    local copy = {}
    for section, fields in pairs(DEFAULTS) do
        copy[section] = {}
        for k, v in pairs(fields) do
            if type(v) ~= "table" then
                copy[section][k] = v
            else
                copy[section][k] = {}
                for kk, vv in pairs(v) do
                    copy[section][k][kk] = vv
                end
            end
        end
    end
    return copy
end

function Addon:MergeDB(loaded, defaults)
    loaded = loaded or {}
    for section, fields in pairs(defaults) do
        if type(loaded[section]) ~= "table" then
            loaded[section] = fields
        else
            for k, v in pairs(fields) do
                if loaded[section][k] == nil then
                    loaded[section][k] = v
                end
            end
        end
    end
    return loaded
end

local defaults = Addon:GetDefaults()
QuestEchoDB = QuestEchoDB or {}
Addon.db = Addon:MergeDB(QuestEchoDB, defaults)

-- session-only state (not saved)
QuestEcho.session = { PlayedSession = {} }

-- =============================================================================
-- Chat helpers
-- =============================================================================
local function Print(msg)
    local frame = DEFAULT_CHAT_FRAME
    if frame and frame.AddMessage then
        pcall(frame.AddMessage, frame, msg)
    end
end

QuestEcho.Debug = {}
local Debug = QuestEcho.Debug

function Debug:Print(...)
    if Addon.db.profile.Debug then
        Print(format("|cff33ffcc[QuestEcho]|r %s", format(...)))
    end
end

-- =============================================================================
-- Utils
-- =============================================================================
QuestEcho.Utils = {}
local Utils = QuestEcho.Utils

--- Name of the NPC/object currently being talked to. This client only
--- supports the vanilla "npc" unit token ("questnpc" is not available).
function Utils:GetNPCName()
    local ok, name = pcall(UnitName, "npc")
    return ok and name or nil
end

--- This client has no UnitGUID; fall back to name-based lookups only.
function Utils:GetNPCGUID()
    return nil
end

function Utils:IsNPCObjectOrItem()
    local ok, exists = pcall(UnitExists, "npc")
    return not (ok and exists)
end

function Utils:IsNPCPlayer()
    local ok, isPlayer = pcall(UnitIsPlayer, "npc")
    return ok and isPlayer or false
end

--- Whether the game's sound options would allow playback.
--- Emberveil does not keep the vanilla Sound_Enable* cvars in sync with the
--- actual master audio, so they cannot be trusted to block playback. We always
--- attempt playback and only report the raw cvar values for /qe status.
function Utils:IsSoundEnabled()
    return true
end

--- Raw sound cvar values, for diagnostics (/qe status).
function Utils:GetSoundCvarInfo()
    local function read(name)
        local ok, value = pcall(GetCVar, name)
        if ok then
            return tostring(value)
        end
        return "?"
    end
    return read("Sound_EnableAllSound"), read("Sound_EnableSFX")
end

--- Sound files cannot be started-and-stopped on this client, so we trust
--- PrepareSound's length-table lookup instead of probing playback.
function Utils:TestSound(soundData)
    return true
end

-- Sound CVars that actually silence this client's PlaySoundFile output.
-- Diagnostics (/qe diag) show this client only reads the bare names
-- "MasterVolume" and "SoundVolume" (they hold the player's real volumes).
-- The WoW-standard "Sound_MasterVolume" etc. always read back "0" here, so
-- they are never muted or restored — touching them is pointless and their
-- "0" baseline would drag restore to silence.
Utils.SOUND_CVARS = { "MasterVolume", "SoundVolume" }
Utils.baselineSound = nil
-- True while we have muted the CVars. While muted, capturing the baseline
-- would record 0s and permanently poison restores, so capture is skipped.
Utils.isMuted = false

--- Capture the player's real sound CVar values once, so muting can restore
--- exactly what was there before (not hardcoded defaults). Skipped while we
--- are muted (would capture 0) unless a baseline is already cached.
function Utils:GetBaselineSoundSettings()
    if self.baselineSound then
        return self.baselineSound
    end
    if self.isMuted then
        return nil
    end
    local base = {}
    for _, name in ipairs(self.SOUND_CVARS) do
        local ok, v = pcall(GetCVar, name)
        if ok and v ~= nil and v ~= "" then
            base[name] = tostring(v)
        end
    end
    self.baselineSound = base
    return base
end

--- Called every frame until the baseline is captured. The first seconds after
--- load are skipped: at startup this client has not applied the player's
--- sound settings yet, so an early capture would record 0s and every restore
--- would drag the volume to minimum. Muted states are skipped for the same
--- reason. If a capture still sees every volume at 0 (slow startup), it waits
--- one second and tries again before giving up.
function Utils:MaybeCaptureBaseline()
    if self.baselineSound then
        return
    end
    if self.isMuted then
        return
    end
    if GetTime() < 3 then
        return
    end
    if self._nextCaptureAt and GetTime() < self._nextCaptureAt then
        return
    end
    local base = {}
    for _, name in ipairs(self.SOUND_CVARS) do
        local ok, v = pcall(GetCVar, name)
        if ok and v ~= nil and v ~= "" then
            base[name] = tostring(v)
        end
    end
    local allZero = true
    for _, name in ipairs(self.SOUND_CVARS) do
        local nv = tonumber(base[name])
        if nv and nv > 0.01 then
            allZero = false
            break
        end
    end
    if allZero and not self._zeroRetryDone then
        self._zeroRetryDone = true
        self._nextCaptureAt = GetTime() + 1
        return
    end
    self.baselineSound = base
end

--- Restore the sound CVars to their captured baseline. If we still have no
--- baseline (first ever restore happened while muted), bring the volume back
--- to 1 instead of leaving everything silenced.
function Utils:RestoreSoundSettings()
    local base = self:GetBaselineSoundSettings()
    self.isMuted = false
    if not base then
        for _, name in ipairs(self.SOUND_CVARS) do
            pcall(SetCVar, name, 1)
        end
        return
    end
    for _, name in ipairs(self.SOUND_CVARS) do
        local v = base[name]
        if v ~= nil then
            pcall(SetCVar, name, v)
        else
            pcall(SetCVar, name, 1)
        end
    end
end

--- Silence every sound CVar (stops / ducks whatever is currently playing).
function Utils:MuteSound()
    self.isMuted = true
    for _, name in ipairs(self.SOUND_CVARS) do
        pcall(SetCVar, name, 0)
    end
end

function Utils:PlaySound(soundData)
    if not soundData.filePath then
        return false
    end
    -- bring the volume back before our file starts (a previous stop or the
    -- gossip mute may have muted everything)
    self:RestoreSoundSettings()
    local ok = pcall(PlaySoundFile, soundData.filePath)
    Debug:Print("play %s -> %s", tostring(soundData.fileName or "?"), tostring(ok))
    return ok
end

--- Best-effort stop: this client cannot interrupt a sound file, so we mute
--- every sound CVar; the queue keeps them muted until the line would have
--- ended (SoundQueue:ScheduleMuteRestore), then restores the baseline.
function Utils:StopSound(soundData)
    self:MuteSound()
    soundData.handle = nil
end

function Utils:ColorizeText(text, color)
    return color .. text .. "|r"
end

--- Does the NPC currently being talked to offer quests?
function Utils:NpcHasQuests()
    local ok, nActive, nAvailable = pcall(GetGossipActiveQuests)
    if not ok then
        return false
    end
    return (tonumber(nActive) or 0) > 0 or (tonumber(nAvailable) or 0) > 0
end

-- =============================================================================
-- Fuzzy search (ported from the original addon)
-- =============================================================================
local function jaccardSimilarity(a, b)
    local tokens_a, tokens_b = {}, {}
    for token in string.gmatch(a, "%S+") do tokens_a[token] = true end
    for token in string.gmatch(b, "%S+") do tokens_b[token] = true end

    local intersection, union = 0, 0
    for token in pairs(tokens_a) do
        union = union + 1
        if tokens_b[token] then
            intersection = intersection + 1
        end
    end
    for token in pairs(tokens_b) do
        if not tokens_a[token] then
            union = union + 1
        end
    end

    if union == 0 then
        return 0
    end
    return intersection / union
end

function QuestEcho.FuzzySearchBestKeys(query, tableVar)
    local best_result = nil
    local max_similarity = -1

    for entry, value in pairs(tableVar) do
        local similarity = jaccardSimilarity(query, entry)
        -- deterministic ties: prefer the longest (most specific) key
        if similarity > max_similarity
            or (similarity == max_similarity and best_result and #entry > #best_result.text) then
            max_similarity = similarity
            best_result =
            {
                value = value,
                text = entry,
                similarity = similarity,
            }
        end
    end

    return best_result
end

-- =============================================================================
-- DataModules: detects, loads and queries QuestEcho data modules
-- =============================================================================
QuestEcho.DataModules =
{
    presentModules = {},
    presentModulesOrdered = {},
    registeredModules = {},
    registeredModulesOrdered = {},
    availableModules =
    {
        {
            AddonName = "QuestEchoData",
            Title = "QuestEcho Data - Emberveil",
            ContentVersion = "0.1",
            RelevantAboveVersion = 0,
            URL = "https://emberveil.org/wiki/addons",
        },
    },
}

local DataModules = QuestEcho.DataModules

local function SortModules(a, b)
    a = a.METADATA or a
    b = b.METADATA or b
    if (a.ModulePriority or 0) ~= (b.ModulePriority or 0) then
        return (a.ModulePriority or 0) > (b.ModulePriority or 0)
    end
    return a.AddonName < b.AddonName
end

--- Enumerate every addon that carries the X-QuestEcho-DataModule-Version
--- metadata, so Register() can later validate/attach metadata.
function DataModules:EnumerateAddons()
    local ok, numAddons = pcall(GetNumAddOns)
    if not ok then
        return
    end

    self.presentModules = {}
    self.presentModulesOrdered = {}

    for i = 1, numAddons do
        local okMeta, moduleVersion = pcall(GetAddOnMetadata, i, "X-QuestEcho-DataModule-Version")
        moduleVersion = okMeta and tonumber(moduleVersion)
        if moduleVersion then
            local name = (pcall(GetAddOnInfo, i) and select(1, GetAddOnInfo(i))) or tostring(i)
            local loadOnDemand = pcall(IsAddOnLoadOnDemand, name) and select(1, IsAddOnLoadOnDemand(name)) or false
            local okPriority, priority = pcall(GetAddOnMetadata, name, "X-QuestEcho-DataModule-Priority")
            local okVersion, contentVersion = pcall(GetAddOnMetadata, name, "Version")
            local okTitle, title = pcall(GetAddOnMetadata, name, "Title")
            local module =
            {
                AddonName = name,
                LoadOnDemand = loadOnDemand,
                ModuleVersion = moduleVersion,
                ModulePriority = okPriority and tonumber(priority) or 0,
                ContentVersion = okVersion and contentVersion or nil,
                Title = (okTitle and title) or name,
                Maps = {},
            }
            self.presentModules[name] = module
            table.insert(self.presentModulesOrdered, module)
        end
    end

    table.sort(self.presentModulesOrdered, SortModules)
end

function DataModules:HasRegisteredModules()
    return next(self.registeredModules) ~= nil
end

function DataModules:GetModule(name)
    return self.registeredModules[name]
end

function DataModules:GetModules()
    return ipairs(self.registeredModulesOrdered)
end

--- Register a data module. Duplicate-safe: if the same module is registered
--- again (e.g. the standalone pack loaded after the bundled Data\ copy), the
--- new module table replaces the old one so fresh data wins.
function DataModules:Register(name, module)
    if self.registeredModules[name] then
        for i, m in ipairs(self.registeredModulesOrdered) do
            if m == self.registeredModules[name] then
                self.registeredModulesOrdered[i] = module
                break
            end
        end
        self.registeredModules[name] = module
        return
    end

    local metadata = self.presentModules[name]
    if not metadata then
        self:EnumerateAddons()
        metadata = self.presentModules[name]
    end
    if not metadata then
        -- Fallback metadata so bundled modules still work if enumeration ran
        -- before the addon list was ready.
        metadata =
        {
            AddonName = name,
            LoadOnDemand = false,
            ModuleVersion = 1,
            ModulePriority = 0,
            ContentVersion = nil,
            Title = name,
            Maps = {},
        }
        self.presentModules[name] = metadata
        table.insert(self.presentModulesOrdered, metadata)
    end

    module.METADATA = metadata
    self.registeredModules[name] = module
    table.insert(self.registeredModulesOrdered, module)
    table.sort(self.registeredModulesOrdered, SortModules)
end

local function replaceDoubleQuotes(text)
    return string.gsub(text or "", '"', "'")
end

local function getFirstNWords(text, n)
    local firstNWords = {}
    local count = 0
    for word in string.gmatch(text or "", "%S+") do
        count = count + 1
        table.insert(firstNWords, word)
        if count >= n then
            break
        end
    end
    return table.concat(firstNWords, " ")
end

local function getLastNWords(text, n)
    local lastNWords = {}
    local count = 0
    for word in string.gmatch(text or "", "%S+") do
        count = count + 1
        table.insert(lastNWords, word)
    end
    local startIndex = math.max(1, count - n + 1)
    return table.concat(lastNWords, " ", startIndex, count)
end

--- Resolve the hash of the best-matching gossip/quest-greeting line for the
--- NPC the player is talking to. GUID-less client: name-based lookups only.
function DataModules:GetNPCGossipTextHash(soundData)
    local lookupTable = soundData.unitIsObjectOrItem and "GossipLookupByObjectName" or "GossipLookupByNPCName"
    local npc = replaceDoubleQuotes(soundData.name)
    local text = soundData.text or ""
    local text_entries = {}

    for _, module in self:GetModules() do
        local data = module[lookupTable]
        if data then
            local npc_gossip_table = data[npc]
            if npc_gossip_table then
                for gossipText, hash in pairs(npc_gossip_table) do
                    text_entries[gossipText] = text_entries[gossipText] or hash
                end
            end
        end
    end

    if not next(text_entries) then
        return nil
    end

    -- exact match wins immediately (deterministic, and the common case)
    if text_entries[text] then
        return text_entries[text]
    end

    local best_result = QuestEcho.FuzzySearchBestKeys(text, text_entries)
    return best_result and best_result.value or nil
end

--- Resolve a quest ID from the quest title / NPC name / quest text.
--- @param source "accept"|"progress"|"complete"
function DataModules:GetQuestID(source, title, npcName, text)
    local cleanedTitle = replaceDoubleQuotes(title)
    local cleanedNPCName = replaceDoubleQuotes(npcName)
    local cleanedText = replaceDoubleQuotes(getFirstNWords(text, 15)) ..
        " " .. replaceDoubleQuotes(getLastNWords(text, 15))
    local text_entries = {}

    for _, module in self:GetModules() do
        local data = module.QuestIDLookup
        if data then
            local sourceLookup = data[source]
            if sourceLookup then
                local titleLookup = sourceLookup[cleanedTitle]
                if titleLookup then
                    if type(titleLookup) == "number" then
                        return titleLookup
                    else
                        local npcLookup = titleLookup[cleanedNPCName]
                        if npcLookup then
                            if type(npcLookup) == "number" then
                                return npcLookup
                            else
                                for questText, ID in pairs(npcLookup) do
                                    text_entries[questText] = text_entries[questText] or ID
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if not next(text_entries) then
        return nil
    end
    local best_result = QuestEcho.FuzzySearchBestKeys(cleanedText, text_entries)
    return best_result and best_result.value or nil
end

--- Quest-giver name for quests started from an item/object (no "npc" unit).
function DataModules:GetQuestGiverName(questID)
    for _, module in self:GetModules() do
        local npcData = module.NPCIDLookupByQuestID
        if npcData and npcData[questID] then
            local npcNameData = module.NPCNameLookupByNPCID
            local name = npcNameData and npcNameData[npcData[questID]]
            if name then
                return name
            end
        end
        local objectData = module.ObjectIDLookupByQuestID
        if objectData and objectData[questID] then
            local objectNameData = module.ObjectNameLookupByObjectID
            local name = objectNameData and objectNameData[objectData[questID]]
            if name then
                return name
            end
        end
    end
end

--- Gender-prefixed filename variant (male/female voices).
function DataModules:AddPlayerGenderToFilename(fileName)
    local ok, gender = pcall(UnitSex, "player")
    if not ok then
        return fileName
    end
    if gender == 2 then
        return "m-" .. fileName
    elseif gender == 3 then
        return "f-" .. fileName
    end
    return fileName
end

local function getFileNameForEvent(event, soundData)
    if event == Enums.SoundEvent.QuestAccept then
        return format("%d-%s", soundData.questID, "accept")
    elseif event == Enums.SoundEvent.QuestProgress then
        return format("%d-%s", soundData.questID, "progress")
    elseif event == Enums.SoundEvent.QuestComplete then
        return format("%d-%s", soundData.questID, "complete")
    elseif event == Enums.SoundEvent.QuestGreeting or event == Enums.SoundEvent.Gossip then
        return DataModules:GetNPCGossipTextHash(soundData)
    end
end

--- Fill in fileName / filePath / length / module for a sound, if any data
--- module knows this voice line.
function DataModules:PrepareSound(soundData)
    soundData.fileName = getFileNameForEvent(soundData.event, soundData)
    if not soundData.fileName then
        return false
    end

    for _, module in self:GetModules() do
        local data = module.SoundLengthLookupByFileName
        if data then
            local genderedFileName = DataModules:AddPlayerGenderToFilename(soundData.fileName)
            local length = data[genderedFileName]
            if length then
                soundData.fileName = genderedFileName
            else
                length = data[soundData.fileName]
            end
            if length then
                -- Emberveil resolves sound paths relative to the executable
                -- directory (Binaries\Win64), so we climb two levels up to the
                -- game root with forward slashes. The audio engine plays ogg
                -- (vorbis); mp3 files are silently ignored.
                soundData.filePath = format("../../Interface/AddOns/%s/%s", module.METADATA.AddonName,
                    (module.GetSoundPath and module:GetSoundPath(soundData.fileName, soundData.event)) or
                    soundData.fileName)
                soundData.length = length
                soundData.module = module
                return true
            end
        end
    end

    return false
end

-- =============================================================================
-- SoundQueueUI (declared early: SoundQueue methods reference it)
-- =============================================================================
QuestEcho.SoundQueueUI = {}
local SoundQueueUI = QuestEcho.SoundQueueUI

-- =============================================================================
-- SoundQueue: FIFO voice line queue driven by an OnUpdate frame
-- =============================================================================
QuestEcho.SoundQueue =
{
    soundIdCounter = 0,
    sounds = {},        -- queued (not yet started)
    current = nil,      -- currently playing
    nextSoundAt = nil,  -- GetTime() deadline for the current sound
    pendingNextAt = nil, -- GetTime() deadline before the next line starts
}

local SoundQueue = QuestEcho.SoundQueue

function SoundQueue:GetQueueSize()
    return #self.sounds
end

function SoundQueue:IsEmpty()
    return self.current == nil and #self.sounds == 0
end

function SoundQueue:IsPlaying()
    return self.current ~= nil
end

--- @param soundData table fields: event, name, title?, text?, questID?, delay?
function SoundQueue:AddSoundToQueue(soundData)
    if not DataModules:PrepareSound(soundData) then
        Debug:Print("no voice line for: %s", tostring(soundData.title or soundData.name or ""))
        return false
    end

    if not Utils:IsSoundEnabled() then
        Debug:Print("sound is turned off in the game options")
        return false
    end

    -- don't queue the same line twice
    for _, queuedSound in ipairs(self.sounds) do
        if queuedSound.fileName == soundData.fileName then
            return false
        end
    end
    if self.current and self.current.fileName == soundData.fileName then
        return false
    end

    -- gossip lines are suppressed while a quest voice line is queued/playing
    local questSoundExists = self.current and self.current.questID ~= nil
    if not questSoundExists then
        for _, queuedSound in ipairs(self.sounds) do
            if queuedSound.questID ~= nil then
                questSoundExists = true
                break
            end
        end
    end
    if soundData.questID == nil and questSoundExists then
        Debug:Print("gossip suppressed: quest voice line in queue")
        return false
    end

    self.soundIdCounter = self.soundIdCounter + 1
    soundData.id = self.soundIdCounter

    table.insert(self.sounds, soundData)

    if self.current == nil and not Addon.db.char.IsPaused then
        self:PlayNextSound()
    end

    SoundQueueUI:Update()
    return true
end

--- Play a line with priority (used when the quest-reward window opens):
--- cut whatever is playing (e.g. a gossip line) and queued gossip lines, and
--- start this line immediately.
function SoundQueue:PlayPriority(soundData)
    -- resolve filePath/length exactly like AddSoundToQueue does
    if not DataModules:PrepareSound(soundData) then
        return false
    end
    if self.gossipPending then
        self.gossipPending = nil
        self.gossipRestoreAt = nil
    end
    if self.current then
        Utils:StopSound(self.current)
        self.current = nil
        self.nextSoundAt = nil
    end
    self.muteRestoreAt = nil
    -- drop queued gossip lines (the chat context just switched away)
    local kept = {}
    for _, s in ipairs(self.sounds) do
        if s.questID ~= nil then
            table.insert(kept, s)
        end
    end
    self.sounds = kept
    self.soundIdCounter = self.soundIdCounter + 1
    soundData.id = self.soundIdCounter
    table.insert(self.sounds, 1, soundData)
    self:PlayNextSound()
end

function SoundQueue:PlayNextSound()
    local soundData = self.sounds[1]
    if not soundData then
        -- queue is empty: refresh the UI so the "playing" row disappears
        SoundQueueUI:Update()
        return
    end
    table.remove(self.sounds, 1)
    self.current = soundData
    self.muteRestoreAt = nil
    soundData.startedAt = GetTime()

    if Enums.SoundEvent:IsGossipEvent(soundData.event) then
        -- Cut the NPC's own dialogue voice so it doesn't play over ours.
        -- Mute every sound CVar now; OnUpdate restores the baseline and
        -- starts the file on the next tick so the mute lands first.
        Utils:MuteSound()
        self.gossipPending = soundData
        self.gossipRestoreAt = GetTime() + 0.15
        SoundQueueUI:Update()
        return
    end

    Utils:PlaySound(soundData)
    self.nextSoundAt = GetTime() + (soundData.delay or 0) + (soundData.length or 0) + 0.5
    Debug:Print("playing: %s (%.1fs)", tostring(soundData.fileName), soundData.length or 0)
    SoundQueueUI:Update()
end

--- After stopping the current line, keep the mute on until the line would
--- have ended (length-based), so the removed file cannot resume when the
--- volume comes back. Unknown length falls back to a short window.
--- Addon.db.profile.StopWait: a number (default 0.5) restores the volume
--- after that many seconds (the removed line's tail may keep playing);
--- "full" waits for the line to end.
function SoundQueue:ScheduleMuteRestore(length, startedAt)
    local wait = Addon.db.profile.StopWait
    local restoreAt
    if wait == "full" then
        restoreAt = (startedAt or GetTime()) + (length or 0) + 0.3
    else
        restoreAt = GetTime() + (tonumber(wait) or 1)
    end
    if restoreAt <= GetTime() then
        restoreAt = GetTime() + 1.5
    end
    self.muteRestoreAt = restoreAt
end

--- Called every frame; advances the queue when the current line finishes.
function SoundQueue:OnUpdate()
    -- a stopped line's mute window is over: restore the player's sound
    -- settings. If a new line already started (PlaySound restores the volume
    -- itself), just clear the marker so it can never wedge the mute on.
    if self.muteRestoreAt and GetTime() >= self.muteRestoreAt then
        self.muteRestoreAt = nil
        if not self.current and not self.gossipPending then
            Utils:RestoreSoundSettings()
        end
    end
    -- gossip pending: the mute window is over, restore and start the line
    -- (or drop it if paused — but never leave everything muted)
    if self.gossipPending and GetTime() >= (self.gossipRestoreAt or 0) then
        local soundData = self.gossipPending
        self.gossipPending = nil
        self.gossipRestoreAt = nil
        if not Addon.db.char.IsPaused then
            Utils:PlaySound(soundData)
            self.nextSoundAt = GetTime() + (soundData.delay or 0) + (soundData.length or 0) + 0.5
            Debug:Print("playing: %s (%.1fs)", tostring(soundData.fileName), soundData.length or 0)
        else
            Utils:RestoreSoundSettings()
            self.current = nil
            self.nextSoundAt = nil
        end
        SoundQueueUI:Update()
        return
    end
    if Addon.db.char.IsPaused then
        return
    end
    -- a removed line's mute window is over: start the next line
    if self.pendingNextAt and GetTime() >= self.pendingNextAt then
        self.pendingNextAt = nil
        if not self.current and self.sounds[1] then
            self:PlayNextSound()
            SoundQueueUI:Update()
        end
    end
    if not self.current or not self.nextSoundAt then
        return
    end
    if GetTime() >= self.nextSoundAt then
        self.current = nil
        self.nextSoundAt = nil
        self:PlayNextSound()
        -- refresh even when nothing is left, so the playing row clears
        SoundQueueUI:Update()
    end
end

function SoundQueue:PauseQueue()
    if Addon.db.char.IsPaused then
        return
    end
    Addon.db.char.IsPaused = true
    if self.current then
        Utils:StopSound(self.current)
    end
    SoundQueueUI:Update()
end

function SoundQueue:ResumeQueue()
    if not Addon.db.char.IsPaused then
        return
    end
    Addon.db.char.IsPaused = false
    -- This client cannot resume mid-file; restart the current line.
    if self.current then
        Utils:PlaySound(self.current)
        self.nextSoundAt = GetTime() + (self.current.delay or 0) + (self.current.length or 0) + 0.5
    end
    SoundQueueUI:Update()
end

function SoundQueue:TogglePauseQueue()
    if Addon.db.char.IsPaused then
        self:ResumeQueue()
    else
        self:PauseQueue()
    end
end

function SoundQueue:RemoveAllSoundsFromQueue()
    self.sounds = {}
    self.pendingNextAt = nil
    if self.gossipPending then
        self.gossipPending = nil
        self.gossipRestoreAt = nil
    end
    if self.current then
        Utils:StopSound(self.current)
        local length = self.current.length
        local startedAt = self.current.startedAt
        self.current = nil
        self.nextSoundAt = nil
        -- keep the mute on until the stopped line would have ended
        self:ScheduleMuteRestore(length, startedAt)
    end
    SoundQueueUI:Update()
end

--- Remove one line by its id: the current line stops, a queued line drops out.
-- How long to keep everything muted after a line is removed before the next
-- line starts. The client applies CVar changes on its own frame, so an
-- immediate restore in the same frame would never mute (and the removed
-- sound would keep playing under the next one).
local SOUND_SWITCH_BUFFER = 0.25

function SoundQueue:RemoveSound(id)
    if self.current and self.current.id == id then
        Utils:StopSound(self.current)
        local length = self.current.length
        local startedAt = self.current.startedAt
        self.current = nil
        self.nextSoundAt = nil
        if self.gossipPending then
            self.gossipPending = nil
            self.gossipRestoreAt = nil
        end
        -- keep the mute until the stopped line would have ended, then restore
        -- the player's sound settings (fallback if the queue empties first)
        self:ScheduleMuteRestore(length, startedAt)
        if not Addon.db.char.IsPaused and self.sounds[1] then
            -- let the mute take effect before the next line starts
            self.pendingNextAt = GetTime() + SOUND_SWITCH_BUFFER
        end
    else
        for i, sound in ipairs(self.sounds) do
            if sound.id == id then
                table.remove(self.sounds, i)
                break
            end
        end
    end
    SoundQueueUI:Update()
end

-- =============================================================================
-- SoundQueueUI: small draggable status bar with a live queue list
-- =============================================================================
local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

-- Classic WoW panel look: opaque dark fill + thin gold border, drawn from
-- solid-color textures (icon/backdrop texture files are not guaranteed to
-- exist in this client's pak).
local PANEL_BG = { 0.035, 0.035, 0.05, 0.97 }
local PANEL_BORDER = { 0.78, 0.62, 0.36, 1 }
local BUTTON_BG = { 0.09, 0.09, 0.12, 0.97 }
local BUTTON_BORDER = { 0.50, 0.42, 0.28, 1 }

local function EdgeTexture(frame, x1, y1, x2, y2, color)
    local tex = frame:CreateTexture(nil, "BORDER")
    tex:SetTexture(color[1], color[2], color[3], color[4] or 1)
    tex:SetPoint("TOPLEFT", frame, "TOPLEFT", x1, -y1)
    tex:SetPoint("BOTTOMRIGHT", frame, "TOPLEFT", x2, -y2)
    return tex
end

--- Opaque panel backdrop for a fixed-size frame (settings panel).
local function ApplyClassicBackdrop(frame, width, height)
    local fill = frame:CreateTexture(nil, "BACKGROUND")
    fill:SetTexture(PANEL_BG[1], PANEL_BG[2], PANEL_BG[3], PANEL_BG[4])
    fill:SetAllPoints()
    EdgeTexture(frame, 0, 0, width, 2, PANEL_BORDER)
    EdgeTexture(frame, 0, height - 2, width, height, PANEL_BORDER)
    EdgeTexture(frame, 0, 0, 2, height, PANEL_BORDER)
    EdgeTexture(frame, width - 2, 0, width, height, PANEL_BORDER)
end

--- Opaque panel backdrop whose border follows a resizing frame (status bar).
local function ApplyClassicBackdropResizable(frame)
    local fill = frame:CreateTexture(nil, "BACKGROUND")
    fill:SetTexture(PANEL_BG[1], PANEL_BG[2], PANEL_BG[3], PANEL_BG[4])
    fill:SetAllPoints()
    local top = frame:CreateTexture(nil, "BORDER")
    top:SetTexture(PANEL_BORDER[1], PANEL_BORDER[2], PANEL_BORDER[3], PANEL_BORDER[4])
    top:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    top:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, -2)
    local bottom = frame:CreateTexture(nil, "BORDER")
    bottom:SetTexture(PANEL_BORDER[1], PANEL_BORDER[2], PANEL_BORDER[3], PANEL_BORDER[4])
    bottom:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, 2)
    bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    local left = frame:CreateTexture(nil, "BORDER")
    left:SetTexture(PANEL_BORDER[1], PANEL_BORDER[2], PANEL_BORDER[3], PANEL_BORDER[4])
    left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", 2, 0)
    local right = frame:CreateTexture(nil, "BORDER")
    right:SetTexture(PANEL_BORDER[1], PANEL_BORDER[2], PANEL_BORDER[3], PANEL_BORDER[4])
    right:SetPoint("TOPLEFT", frame, "TOPRIGHT", -2, 0)
    right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
end

--- Small dark button face with a thin border.
local function MakeButtonBackdrop(button, w, h)
    local fill = button:CreateTexture(nil, "BACKGROUND")
    fill:SetTexture(BUTTON_BG[1], BUTTON_BG[2], BUTTON_BG[3], BUTTON_BG[4])
    fill:SetAllPoints()
    button._fill = fill
    EdgeTexture(button, 0, 0, w, 1, BUTTON_BORDER)
    EdgeTexture(button, 0, h - 1, w, h, BUTTON_BORDER)
    EdgeTexture(button, 0, 0, 1, h, BUTTON_BORDER)
    EdgeTexture(button, w - 1, 0, w, h, BUTTON_BORDER)
end

--- Classic WoW hover + press feedback for our buttons. Hover shows a gold
--- highlight (the client's Button auto-shows the HIGHLIGHT texture on mouse
--- over); while the mouse is held, the backdrop fill flashes gold. Every
--- call is wrapped in pcall so clients without a given feature keep the
--- static look.
local function AddButtonFeedback(button, withHover)
    if not button then
        return
    end
    if withHover ~= false then
        local okHL, hl = pcall(button.CreateTexture, button, nil, "HIGHLIGHT")
        if okHL and hl then
            pcall(hl.SetTexture, hl, 1.00, 0.82, 0.30, 0.28)
            pcall(hl.SetAllPoints, hl)
            pcall(button.SetHighlightTexture, button, hl)
        end
    end
    local fill = button._fill
    if fill then
        local okDown = pcall(button.SetScript, button, "OnMouseDown", function()
            pcall(fill.SetTexture, fill, 1.00, 0.82, 0.30, 0.45)
        end)
        if okDown then
            pcall(button.SetScript, button, "OnMouseUp", function()
                pcall(fill.SetTexture, fill, BUTTON_BG[1], BUTTON_BG[2], BUTTON_BG[3], BUTTON_BG[4])
            end)
        end
    end
end

local function ColorForEvent(event)
    if Enums.SoundEvent:IsQuestEvent(event) then
        return "|cff69ccf0"
    elseif event == Enums.SoundEvent.QuestGreeting then
        return "|cffa335ee"
    end
    return "|cff7fff7f" -- gossip
end

local function FormatStatus()
    local current = SoundQueue.current
    local queued = #SoundQueue.sounds

    local text
    if Addon.db.char.IsPaused then
        text = "|cffffcc00[QuestEcho paused]|r"
    elseif current then
        local label = current.title or current.name or current.fileName or "?"
        text = format("%s%s|r", ColorForEvent(current.event), label)
        if queued > 0 then
            text = text .. format("  |cffcccccc(+%d)|r", queued)
        end
    elseif queued > 0 then
        text = format("|cffcccccc[QuestEcho %d queued...]|r", queued)
    else
        text = "|cff33ffcc[QuestEcho ready]|r"
    end
    return text
end

local QUEUE_ROW_HEIGHT = 18
local QUEUE_MAX_ROWS = 12

function SoundQueueUI:Create()
    if self.frame then
        return
    end

    local frame = CreateFrame("Frame", "QuestEchoStatusFrame", UIParent)
    frame:SetWidth(320)
    frame:SetHeight(24)
    -- 96px above the screen bottom clears the experience bar (Unreal-rendered);
    -- the bar grows upward when the queue is shown and stays draggable.
    frame:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 96)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    ApplyClassicBackdropResizable(frame)

    -- Manual Shift-drag: RegisterForDrag/StartMoving is unreliable on this
    -- client, so we track the cursor ourselves with OnMouseDown/OnUpdate/
    -- OnMouseUp and re-anchor the bar every frame while dragging.
    frame:SetScript("OnMouseDown", function()
        local okShift, shift = pcall(IsShiftKeyDown)
        if okShift and not shift then
            return
        end
        local okX, x, y = pcall(GetCursorPosition)
        local okL, left = pcall(frame.GetLeft, frame)
        local okB, bottom = pcall(frame.GetBottom, frame)
        if not okX or not x or not y or not okL or not left or not okB or not bottom then
            return
        end
        frame.dragging = true
        frame.dragDX = left - x
        frame.dragDY = bottom - y
    end)
    frame:SetScript("OnUpdate", function()
        if not frame.dragging then
            return
        end
        local okX, x, y = pcall(GetCursorPosition)
        if not okX or not x or not y then
            return
        end
        local nx, ny = x + frame.dragDX, y + frame.dragDY
        local okW, w = pcall(UIParent.GetWidth, UIParent)
        local okH, h = pcall(UIParent.GetHeight, UIParent)
        if okW and w and nx + frame:GetWidth() > w then
            nx = w - frame:GetWidth()
        end
        if okH and h and ny + frame:GetHeight() > h then
            ny = h - frame:GetHeight()
        end
        if nx < 0 then nx = 0 end
        if ny < 0 then ny = 0 end
        frame:ClearAllPoints()
        frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", nx, ny)
    end)
    frame:SetScript("OnMouseUp", function()
        frame.dragging = false
    end)

    local status = frame:CreateFontString("QuestEchoStatusText", "OVERLAY", "GameFontWhite")
    -- TOPLEFT anchor: the frame grows downward when the queue list expands,
    -- and a center anchor would slide the status line into the rows.
    status:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -5)
    status:SetWidth(210)
    status:SetHeight(16)
    pcall(status.SetJustifyH, status, "LEFT")
    pcall(status.SetFont, status, FONT, 12)

    local clearButton = CreateFrame("Button", "QuestEchoClearButton", frame)
    clearButton:SetWidth(20)
    clearButton:SetHeight(20)
    clearButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    clearButton:SetScript("OnClick", function()
        SoundQueue:RemoveAllSoundsFromQueue()
    end)
    MakeButtonBackdrop(clearButton, 20, 20)
    AddButtonFeedback(clearButton)
    local clearText = clearButton:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    clearText:SetPoint("CENTER")
    clearText:SetText("X")
    pcall(clearText.SetFont, clearText, FONT, 12)

    local pauseButton = CreateFrame("Button", "QuestEchoPauseButton", frame)
    pauseButton:SetWidth(20)
    pauseButton:SetHeight(20)
    pauseButton:SetPoint("TOPRIGHT", clearButton, "TOPLEFT", -2, 0)
    pauseButton:SetScript("OnClick", function()
        SoundQueue:TogglePauseQueue()
    end)
    MakeButtonBackdrop(pauseButton, 20, 20)
    AddButtonFeedback(pauseButton)
    local pauseText = pauseButton:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    pauseText:SetPoint("CENTER")
    pauseText:SetText("II")
    pcall(pauseText.SetFont, pauseText, FONT, 12)

    local settingsButton = CreateFrame("Button", "QuestEchoSettingsButton", frame)
    settingsButton:SetWidth(20)
    settingsButton:SetHeight(20)
    settingsButton:SetPoint("TOPRIGHT", pauseButton, "TOPLEFT", -2, 0)
    settingsButton:SetScript("OnClick", function()
        -- QuestEcho.OptionsUI instead of the OptionsUI upvalue: that local is
        -- declared later in this file, so a direct reference here would be a
        -- (nil) global.
        QuestEcho.OptionsUI:Toggle()
    end)
    MakeButtonBackdrop(settingsButton, 20, 20)
    -- small gear glyph drawn from solid rectangles (this client's pak has no
    -- WoW-style Interface texture paths, so texture files cannot be used)
    local gearGold = { 1.00, 0.82, 0.31 }
    local function GearRect(tex, left, right, top, bottom)
        tex:SetTexture(gearGold[1], gearGold[2], gearGold[3], 1)
        tex:SetPoint("TOPLEFT", settingsButton, "TOPLEFT", left, -top)
        tex:SetPoint("BOTTOMRIGHT", settingsButton, "TOPLEFT", right, -bottom)
    end
    local teethN = settingsButton:CreateTexture(nil, "OVERLAY")
    GearRect(teethN, 5, 15, 0, 3)
    local teethS = settingsButton:CreateTexture(nil, "OVERLAY")
    GearRect(teethS, 5, 15, 17, 20)
    local teethW = settingsButton:CreateTexture(nil, "OVERLAY")
    GearRect(teethW, 0, 3, 5, 15)
    local teethE = settingsButton:CreateTexture(nil, "OVERLAY")
    GearRect(teethE, 17, 20, 5, 15)
    local spokeN = settingsButton:CreateTexture(nil, "OVERLAY")
    GearRect(spokeN, 9, 11, 3, 8)
    local spokeS = settingsButton:CreateTexture(nil, "OVERLAY")
    GearRect(spokeS, 9, 11, 12, 17)
    local spokeW = settingsButton:CreateTexture(nil, "OVERLAY")
    GearRect(spokeW, 3, 8, 9, 11)
    local spokeE = settingsButton:CreateTexture(nil, "OVERLAY")
    GearRect(spokeE, 12, 17, 9, 11)
    local hub = settingsButton:CreateTexture(nil, "OVERLAY")
    GearRect(hub, 8, 12, 8, 12)
    local settingsHL = settingsButton:CreateTexture(nil, "HIGHLIGHT")
    settingsHL:SetTexture(1.00, 0.82, 0.30, 0.25)
    settingsHL:SetAllPoints()
    pcall(settingsButton.SetHighlightTexture, settingsButton, settingsHL)
    AddButtonFeedback(settingsButton, false) -- already has a hover highlight

    -- Queue list rows (one per line; current line first). Reused across
    -- updates so we never leak frames.
    self.rows = {}
    for i = 1, QUEUE_MAX_ROWS do
        local row = CreateFrame("Frame", nil, frame)
        row:SetWidth(316)
        row:SetHeight(QUEUE_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -24 - (i - 1) * QUEUE_ROW_HEIGHT)

        local rowBg = row:CreateTexture(nil, "BACKGROUND")
        rowBg:SetTexture(0, 0, 0, 0.25)
        rowBg:SetAllPoints()

        local xButton = CreateFrame("Button", nil, row)
        xButton:SetWidth(14)
        xButton:SetHeight(14)
        xButton:SetPoint("LEFT", row, "LEFT", 2, 0)
        xButton:SetScript("OnClick", function()
            if row.soundId then
                SoundQueue:RemoveSound(row.soundId)
            end
        end)
        MakeButtonBackdrop(xButton, 14, 14)
        AddButtonFeedback(xButton)
        local xText = xButton:CreateFontString(nil, "OVERLAY", "GameFontWhite")
        xText:SetPoint("CENTER")
        xText:SetText("X")
        pcall(xText.SetFont, xText, FONT, 9)

        local label = row:CreateFontString(nil, "OVERLAY", "GameFontWhite")
        label:SetPoint("LEFT", xButton, "RIGHT", 4, 0)
        label:SetHeight(14)
        pcall(label.SetJustifyH, label, "LEFT")
        pcall(label.SetFont, label, FONT, 11)

        row.xButton = xButton
        row.label = label
        row.rowBg = rowBg
        row.soundId = nil
        row:Hide()
        table.insert(self.rows, row)
    end

    self.frame = frame
    self.status = status

    if Addon.db.profile.ShowUI then
        frame:Show()
    else
        frame:Hide()
    end
    self:Update()
end

function SoundQueueUI:Update()
    if not self.frame then
        return
    end
    if not Addon.db.profile.ShowUI then
        self.frame:Hide()
        return
    end
    self.frame:Show()
    if self.status then
        self.status:SetText(FormatStatus())
    end
    self:RebuildRows()
end

--- Fill the queue rows with the current line (first) and every queued line.
function SoundQueueUI:RebuildRows()
    local frame = self.frame
    local items = {}
    if SoundQueue.current then
        table.insert(items, { sound = SoundQueue.current, playing = true })
    end
    for _, sound in ipairs(SoundQueue.sounds) do
        table.insert(items, { sound = sound, playing = false })
    end

    local shown = math.min(#items, #self.rows)
    local paused = Addon.db.char.IsPaused
    for i = 1, #self.rows do
        local row = self.rows[i]
        local entry = items[i]
        if not entry then
            row:Hide()
            row.soundId = nil
        else
            row:Show()
            row.soundId = entry.sound.id
            row.xButton:Show()
            local sound = entry.sound
            local labelText = sound.title or sound.name or sound.fileName or "?"
            if entry.playing then
                local state = paused and "(paused)" or "(playing)"
                row.label:SetText(format("|cffffd24a>|r %s%s|r  |cffcccccc%s|r",
                    ColorForEvent(sound.event), labelText, state))
                row.rowBg:SetTexture(1.00, 0.82, 0.31, 0.12)
            else
                row.label:SetText(format("%s%s|r", ColorForEvent(sound.event), labelText))
                row.rowBg:SetTexture(0, 0, 0, 0.25)
            end
        end
    end

    frame:SetHeight(24 + shown * QUEUE_ROW_HEIGHT)
end


function SoundQueueUI:Toggle()
    Addon.db.profile.ShowUI = not Addon.db.profile.ShowUI
    self:Update()
end

-- =============================================================================
-- QuestLogUI: quest replay window. The Emberveil client's own quest log UI is
-- not Lua-hookable (no QuestLogFrame), so this window lists the player's
-- current quests via the quest log data API and adds accept/complete play
-- buttons — same feature the original addon put into the quest log itself.
-- =============================================================================
QuestEcho.QuestLogUI = {}
local QuestLogUI = QuestEcho.QuestLogUI

local QUESTLOG_VISIBLE_ROWS = 14
local QUESTLOG_ROW_HEIGHT = 20

local function FindQuestIDByTitle(title)
    local cleanedTitle = replaceDoubleQuotes(title)
    for _, module in DataModules:GetModules() do
        local data = module.QuestIDLookup
        if data then
            for _, source in ipairs({ "accept", "complete" }) do
                local sourceLookup = data[source]
                if sourceLookup then
                    local titleLookup = sourceLookup[cleanedTitle]
                    if titleLookup then
                        if type(titleLookup) == "number" then
                            return titleLookup
                        else
                            -- Deterministic pick: lowest id wins regardless of
                            -- table iteration order.
                            local best = nil
                            for _, v in pairs(titleLookup) do
                                if type(v) == "number" then
                                    if not best or v < best then
                                        best = v
                                    end
                                end
                            end
                            if best then
                                return best
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function HasQuestVoice(questID, eventType)
    local fileName = format("%d-%s", questID, eventType)
    for _, module in DataModules:GetModules() do
        local data = module.SoundLengthLookupByFileName
        if data and (data[fileName] or data["m-" .. fileName] or data["f-" .. fileName]) then
            return true
        end
    end
    return false
end

function QuestLogUI:CollectQuests()
    local quests = {}
    local ok, num = pcall(GetNumQuestLogEntries)
    if not ok then
        return quests
    end
    for i = 1, num do
        local okTitle, title, _, _, isHeader = pcall(GetQuestLogTitle, i)
        if okTitle and title and title ~= "" and not isHeader then
            local questID = FindQuestIDByTitle(title)
            local giver = questID and DataModules:GetQuestGiverName(questID) or nil
            table.insert(quests,
            {
                index = i,
                title = title,
                giver = giver,
                questID = questID,
                hasAccept = questID and HasQuestVoice(questID, "accept") or false,
                hasComplete = questID and HasQuestVoice(questID, "complete") or false,
            })
        end
    end
    return quests
end

function QuestLogUI:Create()
    if self.frame then
        return
    end

    local frame = CreateFrame("Frame", "QuestEchoQuestLogFrame", UIParent)
    frame:SetWidth(460)
    frame:SetHeight(60 + QUESTLOG_VISIBLE_ROWS * QUESTLOG_ROW_HEIGHT + 26)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function()
        frame:StartMoving()
    end)
    frame:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
    end)
    frame:SetScript("OnMouseWheel", function(delta)
        frame.scrollOffset = math.max(0, (frame.scrollOffset or 0) - (delta or 0))
        QuestLogUI:Update()
    end)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -8)
    title:SetText("QuestEcho — Quest Replay")
    pcall(title.SetFont, title, FONT, 13)

    local closeButton = CreateFrame("Button", nil, frame)
    closeButton:SetWidth(20)
    closeButton:SetHeight(20)
    closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    closeButton:SetScript("OnClick", function()
        QuestLogUI:Toggle()
    end)
    AddButtonFeedback(closeButton)
    local closeText = closeButton:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    closeText:SetPoint("CENTER")
    closeText:SetText("X")
    pcall(closeText.SetFont, closeText, FONT, 11)

    local refreshButton = CreateFrame("Button", nil, frame)
    refreshButton:SetWidth(20)
    refreshButton:SetHeight(20)
    refreshButton:SetPoint("RIGHT", closeButton, "LEFT", -4, 0)
    refreshButton:SetScript("OnClick", function()
        QuestLogUI:Update(true)
    end)
    AddButtonFeedback(refreshButton)
    local refreshText = refreshButton:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    refreshText:SetPoint("CENTER")
    refreshText:SetText("R")
    pcall(refreshText.SetFont, refreshText, FONT, 11)

    local hQuest = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hQuest:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -32)
    hQuest:SetText("Quest")
    pcall(hQuest.SetFont, hQuest, FONT, 10)

    local hPlay = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hPlay:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -94, -32)
    hPlay:SetText("accept | complete")
    pcall(hPlay.SetFont, hPlay, FONT, 10)

    self.rows = {}
    for i = 1, QUESTLOG_VISIBLE_ROWS do
        local row = CreateFrame("Frame", nil, frame)
        row:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -52 - (i - 1) * QUESTLOG_ROW_HEIGHT)
        row:SetWidth(444)
        row:SetHeight(QUESTLOG_ROW_HEIGHT)

        local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("LEFT", row, "LEFT", 2, 0)
        label:SetWidth(250)
        label:SetHeight(16)
        pcall(label.SetFont, label, FONT, 10)

        local acceptButton = CreateFrame("Button", nil, row)
        acceptButton:SetWidth(84)
        acceptButton:SetHeight(16)
        acceptButton:SetPoint("RIGHT", row, "RIGHT", -94, 0)
        local acceptText = acceptButton:CreateFontString(nil, "OVERLAY", "GameFontWhite")
        acceptText:SetPoint("CENTER")
        acceptText:SetText("accept")
        pcall(acceptText.SetFont, acceptText, FONT, 10)

        local completeButton = CreateFrame("Button", nil, row)
        completeButton:SetWidth(84)
        completeButton:SetHeight(16)
        completeButton:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        local completeText = completeButton:CreateFontString(nil, "OVERLAY", "GameFontWhite")
        completeText:SetPoint("CENTER")
        completeText:SetText("complete")
        pcall(completeText.SetFont, completeText, FONT, 10)

        acceptButton:SetScript("OnClick", function()
            QuestLogUI:PlayQuest(row.questID, "accept", row.title)
        end)
        AddButtonFeedback(acceptButton)
        completeButton:SetScript("OnClick", function()
            QuestLogUI:PlayQuest(row.questID, "complete", row.title)
        end)
        AddButtonFeedback(completeButton)

        row.label = label
        row.acceptButton = acceptButton
        row.completeButton = completeButton
        self.rows[i] = row
    end

    self.frame = frame
    self:Update(true)
end

function QuestLogUI:PlayQuest(questID, eventType, questTitle)
    if not questID then
        return
    end
    -- No voice line: nothing to do (the row button is disabled already; this
    -- guards the play path on clients where a stray click can hang).
    if not HasQuestVoice(questID, eventType) then
        return
    end
    local event = eventType == "complete" and Enums.SoundEvent.QuestComplete or Enums.SoundEvent.QuestAccept
    SoundQueue:AddSoundToQueue(
    {
        event = event,
        name = DataModules:GetQuestGiverName(questID),
        title = questTitle,
        text = "",
        questID = questID,
        delay = Addon.db.profile.Delay,
    })
end

function QuestLogUI:Update(forceReload)
    if not self.frame then
        return
    end
    if forceReload or not self.quests then
        self.quests = self:CollectQuests()
    end
    local quests = self.quests
    local offset = math.max(0, math.min(self.frame.scrollOffset or 0, math.max(0, #quests - QUESTLOG_VISIBLE_ROWS)))
    self.frame.scrollOffset = offset

    for i = 1, QUESTLOG_VISIBLE_ROWS do
        local row = self.rows[i]
        local quest = quests[offset + i]
        if quest then
            local labelText = quest.title
            if quest.giver then
                labelText = format("%s — %s", quest.title, quest.giver)
            end
            row.label:SetText(labelText)
            row.acceptButton:Show()
            if quest.hasAccept then
                row.acceptButton:Enable()
                row.acceptButton:SetAlpha(1)
            else
                row.acceptButton:Disable()
                row.acceptButton:SetAlpha(0.25)
            end
            row.completeButton:Show()
            if quest.hasComplete then
                row.completeButton:Enable()
                row.completeButton:SetAlpha(1)
            else
                row.completeButton:Disable()
                row.completeButton:SetAlpha(0.25)
            end
            row.questID = quest.questID
            row.title = quest.title
        else
            row.label:SetText("")
            row.acceptButton:Hide()
            row.completeButton:Hide()
            row.questID = nil
            row.title = nil
        end
    end

    local empty = #quests == 0
    local withVoice = 0
    for _, q in ipairs(quests) do
        if q.hasAccept or q.hasComplete then
            withVoice = withVoice + 1
        end
    end
    local summary = format("Quest log: %d current, %d with voice lines", #quests, withVoice)
    if not self.summary then
        self.summary = self.frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        self.summary:SetPoint("BOTTOM", self.frame, "BOTTOM", 0, 6)
        pcall(self.summary.SetFont, self.summary, FONT, 10)
    end
    self.summary:SetText(summary)
    if empty and not self.emptyNote then
        self.emptyNote = self.frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        self.emptyNote:SetPoint("TOP", self.frame, "TOP", 0, -80)
        self.emptyNote:SetText("No current quests with voice lines found.")
        pcall(self.emptyNote.SetFont, self.emptyNote, FONT, 10)
    elseif self.emptyNote then
        if empty then
            self.emptyNote:Show()
        else
            self.emptyNote:Hide()
        end
    end
end

function QuestLogUI:Toggle()
    if not self.frame then
        local ok, err = pcall(self.Create, self)
        if not ok then
            Print(format("|cffff3333[QuestEcho]|r quest window failed to open: %s", tostring(err)))
            return
        end
    end
    if self.frame:IsShown() then
        self.frame:Hide()
    else
        self:Update(true)
        self.frame:Show()
    end
end

-- =============================================================================
-- OptionsUI: settings panel (/qe settings). Plain Lua frames, no Ace.
-- =============================================================================
QuestEcho.OptionsUI = {}
local OptionsUI = QuestEcho.OptionsUI

local GOSSIP_BUTTONS = {}
local GOSSIP_ORDER =
{
    Enums.GossipFrequency.Always,
    Enums.GossipFrequency.OncePerQuestNPC,
    Enums.GossipFrequency.OncePerNPC,
    Enums.GossipFrequency.Never,
}
local GOSSIP_NAMES =
{
    [Enums.GossipFrequency.Always] = "always",
    [Enums.GossipFrequency.OncePerQuestNPC] = "oncequest",
    [Enums.GossipFrequency.OncePerNPC] = "once",
    [Enums.GossipFrequency.Never] = "never",
}

--- Queue the built-in test voice line (quest 5). Returns (ok, fileName).
-- =============================================================================
-- Quest log integration (defensive attach)
-- =============================================================================
-- If the client exposes the vanilla-style quest log frames at runtime
-- (QuestLogScrollFrame / QuestLogDetailScrollChildFrame / QuestLogDescriptionTitle
-- etc.), we attach "Voice accept" / "Voice complete" play buttons to the quest
-- log's detail pane, like the original addon did. On clients that render the
-- quest log with the engine instead, these globals do not exist and the attach
-- silently skips (no errors, no spam).
QuestEcho.QuestLogHook = {}
local QuestLogHook = QuestEcho.QuestLogHook

function QuestLogHook:CanAttach()
    return type(QuestLogScrollFrame) == "table"
        or type(QuestLogDetailScrollChildFrame) == "table"
        or type(QuestLogQuestTitle) == "table"
end

function QuestLogHook:Attach()
    if self.attached or not self:CanAttach() then
        return self.attached
    end

    local parent = QuestLogDetailScrollChildFrame
        or (type(QuestLogScrollFrame) == "table" and QuestLogScrollFrame)
        or nil
    if not parent then
        return nil
    end

    local okCreate = pcall(function()
        -- One replay button, placed to the right of the quest title fontstring.
        -- Falls back to the detail pane top-right when the title object is
        -- absent or cannot be anchored to. The complete voice plays
        -- automatically on quest completion, so no complete button here.
        local titleRegion = type(QuestLogQuestTitle) == "table" and QuestLogQuestTitle
            or (type(QuestInfoTitleHeader) == "table" and QuestInfoTitleHeader)
            or nil

        self.acceptButton = CreateFrame("Button", "QuestEchoQuestLogPlay", parent)
        self.acceptButton:SetWidth(38)
        self.acceptButton:SetHeight(18)
        -- same classic look as the status bar / settings buttons
        MakeButtonBackdrop(self.acceptButton, 38, 18)
        local voiceText = self.acceptButton:CreateFontString(nil, "OVERLAY", "GameFontWhite")
        voiceText:SetPoint("CENTER")
        voiceText:SetText("Echo")
        pcall(voiceText.SetFont, voiceText, FONT, 11)
        self.acceptButton:SetScript("OnClick", function()
            local ok, err = pcall(QuestLogHook.PlaySelected, QuestLogHook, "accept")
            if not ok then
                Print(format("|cffff3333[QuestEcho]|r play error: %s", tostring(err)))
            end
        end)
        AddButtonFeedback(self.acceptButton)

        self.parent = parent
        self.titleRegion = titleRegion
        self.anchoredToTitle = false
        if titleRegion then
            local okAnchor = pcall(self.acceptButton.SetPoint, self.acceptButton, "LEFT", titleRegion, "RIGHT", 8, 0)
            if okAnchor then
                self.anchoredToTitle = true
            end
        end
        if not self.anchoredToTitle then
            pcall(self.acceptButton.SetPoint, self.acceptButton, "TOPRIGHT", parent, "TOPRIGHT", -12, -10)
        end
    end)
    if not okCreate then
        return nil
    end

    self.attached = true
    -- Refresh whenever the quest log pane becomes visible. This client may
    -- not fire QUEST_LOG_UPDATE on the first open (data is also not ready
    -- at Attach time), so without this the button stays disabled until a
    -- quest selection change.
    pcall(function()
        if type(parent.SetScript) == "function" then
            if type(parent.HookScript) == "function" then
                parent:HookScript("OnShow", function()
                    QuestLogHook:Update()
                end)
            else
                local oldShow = nil
                if type(parent.GetScript) == "function" then
                    oldShow = parent:GetScript("OnShow")
                end
                parent:SetScript("OnShow", function(...)
                    if oldShow then
                        pcall(oldShow, parent, ...)
                    end
                    QuestLogHook:Update()
                end)
            end
        end
    end)
    if self.anchoredToTitle then
        Debug:Print("quest log button anchored right of the quest title")
    else
        Debug:Print("quest log button anchored to the pane top-right (no usable title object)")
    end
    self:Update()
    return true
end

function QuestLogHook:SelectedQuestID()
    local okSel, selection = pcall(GetQuestLogSelection)
    if not okSel or not selection then
        return nil, nil
    end
    local okTitle, title = pcall(GetQuestLogTitle, selection)
    if not okTitle or not title or title == "" then
        return nil, nil
    end
    local questID = FindQuestIDByTitle(title)
    return questID, title
end

function QuestLogHook:PlaySelected(eventType)
    local okSel, questID, title = pcall(function()
        return self:SelectedQuestID()
    end)
    if not okSel or not questID then
        Print("|cffff3333[QuestEcho]|r no voice line match for the selected quest: " .. tostring(title or "?"))
        return
    end
    -- Belt and braces: the button should already be disabled without a voice
    -- line, but never let a click reach the play path on this client.
    if not HasQuestVoice(questID, eventType) then
        Print(format("|cffff3333[QuestEcho]|r no %s voice line file for: |cffffffff%s|r",
            eventType, tostring(title)))
        return
    end
    local event = eventType == "complete" and Enums.SoundEvent.QuestComplete or Enums.SoundEvent.QuestAccept
    local soundData =
    {
        event = event,
        name = DataModules:GetQuestGiverName(questID),
        title = title,
        questID = questID,
        delay = Addon.db.profile.Delay,
    }
    if not SoundQueue:AddSoundToQueue(soundData) then
        Print(format("|cffff3333[QuestEcho]|r no %s voice line file for: |cffffffff%s|r",
            eventType, tostring(title)))
    end
end

-- Some clients stretch the quest title fontstring to the full pane width,
-- which would push the button off the right edge; pull it back inside.
function QuestLogHook:ClampInPane()
    if not self.attached or not self.acceptButton or not self.parent then
        return
    end
    local btn = self.acceptButton
    local par = self.parent
    if not (btn.GetRight and btn.GetLeft and par.GetRight) then
        return
    end
    local ok1, right = pcall(btn.GetRight, btn)
    local ok3, pRight = pcall(par.GetRight, par)
    if not (ok1 and ok3 and right and pRight) then
        return
    end
    if right > pRight - 4 then
        pcall(btn.ClearAllPoints, btn)
        pcall(btn.SetPoint, btn, "TOPRIGHT", par, "TOPRIGHT", -12, -10)
        pcall(btn.SetWidth, btn, 38)
    end
end

function QuestLogHook:Update()
    if not self.attached then
        return
    end
    self:ClampInPane()
    local questID, title = self:SelectedQuestID()
    if not questID then
        self.acceptButton:Disable()
        return
    end
    if HasQuestVoice(questID, "accept") then
        self.acceptButton:Enable()
        self.acceptButton:SetAlpha(1)
    else
        -- No voice line for this quest: keep the button visible but inert.
        -- (Clicking it on this client can hang the game, so never let it
        -- through to the play path.)
        self.acceptButton:Disable()
        self.acceptButton:SetAlpha(0.25)
    end
end

-- Keep the buttons in sync whenever the quest log data or selection changes.
function QuestLogHook:RegisterRefresh()
    if self.refreshed then
        return
    end
    self.refreshed = true
    pcall(function()
        local onEvent = RegisterEvent
        onEvent("QUEST_LOG_UPDATE")
    end)
    -- Wrap the selection click handler if the client exposes one, mirroring
    -- what KoQuest does, so a quest selection refresh also updates our buttons.
    pcall(function()
        if type(QuestLogTitleButton_OnClick) == "function" then
            local old = QuestLogTitleButton_OnClick
            QuestLogTitleButton_OnClick = function(self, button)
                old(self, button)
                QuestLogHook:Update()
            end
        end
    end)
end

function QuestLogHook:TryEnable()
    if self:Attach() then
        self:RegisterRefresh()
        Debug:Print("quest log integration attached")
    else
        Debug:Print("quest log frames not present in this client — voice buttons are in /qe questlog instead")
    end
end

-- =============================================================================

-- =============================================================================
-- Runtime probe (/qe probe)
-- =============================================================================
local function ProbeRuntime()
    local function exists(name)
        local ok, value = pcall(function()
            return _G[name]
        end)
        return ok and value ~= nil
    end

    Print("|cff33ffcc[QuestEcho]|r -- probe --")
    Print(format("data module: |cffffffff%s|r",
        DataModules:GetModule("QuestEchoData") and "loaded" or "NOT LOADED"))

    local function probeList(title, names)
        local parts = {}
        for _, name in ipairs(names) do
            local v = exists(name)
            table.insert(parts, format("%s%s", v and "|cff33ff33" or "|cffff3333", name))
        end
        Print(format("%s: %s|r", title, table.concat(parts, " ")))
    end

    probeList("quest log frames", {
        "QuestLogScrollFrame", "QuestLogTitle1", "QuestLogDetailScrollChildFrame",
        "QuestLogDescriptionTitle", "QuestLogQuestTitle", "QuestLogListScrollFrame",
        "QuestLogTitleButton_OnClick", "QuestLog_Update", "QuestLog_SetSelection",
        "QuestLogPopupFrame", "ToggleQuestLog", "FauxScrollFrame_GetOffset",
    })
    probeList("client data api", {
        "GetQuestLogSelection", "GetNumQuestLogEntries", "GetQuestLogTitle",
        "GetQuestLogRewardMoney", "GetQuestLogQuestText", "GetQuestLogLeaderBoard",
    })
    probeList("addons", { "KoQuest", "KoQuestCompat", "KoDatabase", "AllBags" })

    if type(KoQuest) == "table" and type(KoQuest.questlog) == "table" then
        local n = 0
        for _ in pairs(KoQuest.questlog) do n = n + 1 end
        Print(format("KoQuest.questlog entries: |cffffffff%d|r", n))
    end

    -- Quest log data read-back: does the data API work and do titles match?
    local okNum, num = pcall(GetNumQuestLogEntries)
    if okNum and num then
        Print(format("GetNumQuestLogEntries: |cffffffff%d|r", num))
        local matched, listed = 0, 0
        for i = 1, num do
            local okTitle, title, _, _, isHeader = pcall(GetQuestLogTitle, i)
            if okTitle and title and title ~= "" then
                if not isHeader then
                    listed = listed + 1
                    if FindQuestIDByTitle(title) then
                        matched = matched + 1
                    end
                end
                if i <= 3 then
                    Print(format("  entry %d: %s%s", i, tostring(title), isHeader and " [header]" or ""))
                end
            end
        end
        Print(format("titles read: %d, matched to voice line data: |cffffffff%d|r", listed, matched))
    else
        Print("|cffff3333GetNumQuestLogEntries failed — quest log data api unavailable|r")
    end

    -- Sound probe: resolve a real file and attempt playback.
    local testData =
    {
        event = Enums.SoundEvent.QuestAccept,
        name = "Jitters",
        title = "Jitters' Growling Gut",
        questID = 5,
        delay = 0,
    }
    local okPrepare = pcall(DataModules.PrepareSound, DataModules, testData)
    Print(format("prepare quest 5 accept: %s, path: |cffffffff%s|r",
        okPrepare and "ok" or "FAILED", tostring(testData.filePath or "?")))
    if okPrepare and testData.filePath then
        local okPlay = pcall(PlaySoundFile, testData.filePath)
        Print(format("PlaySoundFile(\"%s\") -> |cffffffff%s|r",
            tostring(testData.filePath), okPlay and "accepted" or "FAILED"))
        Print("if you just heard the voice, everything works; if not, check the file exists at that path and the client master volume")
    end
    Print("|cff33ffcc[QuestEcho]|r -- probe done --")
end

-- =============================================================================
-- Sound path probe (/qe soundprobe)
-- =============================================================================
-- The Emberveil client is Unreal-based and its PlaySoundFile path resolution
-- is unknown (it may resolve relative to the game root, the executable
-- directory, or not accept addon paths at all). This plays the same short
-- file (quest 5 complete, ~2s) once per path variant with pauses in between;
-- the user listens and reports which variant(s) are audible.
local function RunSoundProbe()
    -- The client's audio engine is Unreal-based (SoundWave assets, ogg
    -- support). MP3 files silently fail; the probe tests ogg/wav loose-file
    -- playback and the PlayRadio URL channel.
    local base = "QuestEchoData/generated/sounds/quests/5-complete"
    local variants =
    {
        { name = "ogg game-root fwdslash", fn = "PlaySoundFile", path = "Interface/AddOns/" .. base .. ".ogg" },
        { name = "ogg game-root backslash", fn = "PlaySoundFile", path = "Interface\\AddOns\\QuestEchoData\\generated\\sounds\\quests\\5-complete.ogg" },
        { name = "wav game-root fwdslash", fn = "PlaySoundFile", path = "Interface/AddOns/" .. base .. ".wav" },
        { name = "ogg exe-dir up2", fn = "PlaySoundFile", path = "../../Interface/AddOns/" .. base .. ".ogg" },
        { name = "radio file:// abs", fn = "PlayRadio", path = "file:///C:/Leysure/Unreal%205%20WOW/Azeroth/Binaries/Win64/Games/Emberveil/live/Azeroth/Interface/AddOns/" .. base .. ".ogg" },
        { name = "radio file:// rel", fn = "PlayRadio", path = "file://Interface/AddOns/" .. base .. ".ogg" },
    }
    local probeFrame = CreateFrame("Frame")
    probeFrame:Show()
    local index = 0
    Print("|cff33ffcc[QuestEcho]|r -- sound probe: 6 plays, ~5s apart --")
    probeFrame:SetScript("OnUpdate", function()
        if GetTime() < (probeFrame.nextAt or 0) then
            return
        end
        index = index + 1
        if index > #variants then
            probeFrame:SetScript("OnUpdate", nil)
            probeFrame:Hide()
            Print("|cff33ffcc[QuestEcho]|r -- sound probe done: which numbers did you hear? --")
            return
        end
        local v = variants[index]
        local results = {}
        local fn = v.fn == "PlayRadio" and PlayRadio or PlaySoundFile
        local ok, r1, r2 = pcall(fn, v.path)
        table.insert(results, format("pcall=%s", tostring(ok)))
        if ok then
            table.insert(results, format("ret1=%s", tostring(r1)))
            if r2 ~= nil then
                table.insert(results, format("ret2=%s", tostring(r2)))
            end
        end
        Print(format("[%d/6] %s (%s): %s", index, v.name, v.fn, table.concat(results, ", ")))
        Print(format("  path: |cffffffff%s|r", v.path))
        probeFrame.nextAt = GetTime() + 5
    end)
    probeFrame.nextAt = 0
end

local function PlayTestVoice()
    local soundData =
    {
        event = Enums.SoundEvent.QuestAccept,
        name = "Jitters",
        title = "Jitters' Growling Gut",
        questID = 5,
        delay = Addon.db.profile.Delay,
    }
    local ok = SoundQueue:AddSoundToQueue(soundData)
    return ok, ok and soundData.fileName or nil
end

local function MakeTextButton(parent, text, width, onClick)
    local button = CreateFrame("Button", nil, parent)
    button:SetWidth(width)
    button:SetHeight(18)
    button:SetScript("OnClick", onClick)
    MakeButtonBackdrop(button, width, 18)
    AddButtonFeedback(button)
    local label = button:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    label:SetPoint("CENTER")
    label:SetText(text)
    pcall(label.SetFont, label, FONT, 11)
    button.label = label
    return button
end

local function RefreshOptionsUI()
    if not OptionsUI.frame then
        return
    end
    local profile = Addon.db.profile
    OptionsUI.delayLabel:SetText(format("Delay before lines: %.1f s", profile.Delay))
    OptionsUI.statusLabel:SetText(format("Status bar: %s", profile.ShowUI and "shown" or "hidden"))
    OptionsUI.debugLabel:SetText(format("Debug messages: %s", profile.Debug and "on" or "off"))
    for _, entry in ipairs(GOSSIP_BUTTONS) do
        local active = profile.GossipFrequency == entry.value
        entry.button.label:SetText(active and (format("|cff33ffcc%s|r", entry.name)) or entry.name)
    end
end

function OptionsUI:Create()
    if self.frame then
        return
    end

    local frame = CreateFrame("Frame", "QuestEchoOptionsFrame", UIParent)
    frame:SetWidth(320)
    frame:SetHeight(230)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    ApplyClassicBackdrop(frame, 320, 230)
    -- Manual Shift-drag, same as the status bar (StartMoving is unreliable
    -- on this client).
    frame:SetScript("OnMouseDown", function()
        local okShift, shift = pcall(IsShiftKeyDown)
        if okShift and not shift then
            return
        end
        local okX, x, y = pcall(GetCursorPosition)
        local okL, left = pcall(frame.GetLeft, frame)
        local okB, bottom = pcall(frame.GetBottom, frame)
        if not okX or not x or not y or not okL or not left or not okB or not bottom then
            return
        end
        frame.dragging = true
        frame.dragDX = left - x
        frame.dragDY = bottom - y
    end)
    frame:SetScript("OnUpdate", function()
        if not frame.dragging then
            return
        end
        local okX, x, y = pcall(GetCursorPosition)
        if not okX or not x or not y then
            return
        end
        local nx, ny = x + frame.dragDX, y + frame.dragDY
        local okW, w = pcall(UIParent.GetWidth, UIParent)
        local okH, h = pcall(UIParent.GetHeight, UIParent)
        if okW and w and nx + frame:GetWidth() > w then
            nx = w - frame:GetWidth()
        end
        if okH and h and ny + frame:GetHeight() > h then
            ny = h - frame:GetHeight()
        end
        if nx < 0 then nx = 0 end
        if ny < 0 then ny = 0 end
        frame:ClearAllPoints()
        frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", nx, ny)
    end)
    frame:SetScript("OnMouseUp", function()
        frame.dragging = false
    end)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -8)
    title:SetText("QuestEcho Settings")
    pcall(title.SetFont, title, FONT, 13)

    local closeButton = MakeTextButton(frame, "X", 20, function()
        OptionsUI:Toggle()
    end)
    closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

    local gossipTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    gossipTitle:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -36)
    gossipTitle:SetText("Gossip frequency")
    pcall(gossipTitle.SetFont, gossipTitle, FONT, 11)

    for i, value in ipairs(GOSSIP_ORDER) do
        local name = GOSSIP_NAMES[value]
        local button = MakeTextButton(frame, name, 70, function()
            Addon.db.profile.GossipFrequency = value
            RefreshOptionsUI()
        end)
        button:SetPoint("TOPLEFT", frame, "TOPLEFT", 12 + (i - 1) * 76, -54)
        table.insert(GOSSIP_BUTTONS, { button = button, name = name, value = value })
    end

    local delayLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    delayLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -84)
    pcall(delayLabel.SetFont, delayLabel, FONT, 11)

    local minusButton = MakeTextButton(frame, "-", 24, function()
        Addon.db.profile.Delay = math.max(0, Addon.db.profile.Delay - 0.1)
        RefreshOptionsUI()
    end)
    minusButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 230, -80)

    local plusButton = MakeTextButton(frame, "+", 24, function()
        Addon.db.profile.Delay = math.min(10, Addon.db.profile.Delay + 0.1)
        RefreshOptionsUI()
    end)
    plusButton:SetPoint("LEFT", minusButton, "RIGHT", 2, 0)

    local statusLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statusLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -110)
    pcall(statusLabel.SetFont, statusLabel, FONT, 11)

    local statusButton = MakeTextButton(frame, "toggle", 70, function()
        SoundQueueUI:Toggle()
        RefreshOptionsUI()
    end)
    statusButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 230, -106)

    local debugLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    debugLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -136)
    pcall(debugLabel.SetFont, debugLabel, FONT, 11)

    local debugButton = MakeTextButton(frame, "toggle", 70, function()
        Addon.db.profile.Debug = not Addon.db.profile.Debug
        RefreshOptionsUI()
    end)
    debugButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 230, -132)

    local testButton = MakeTextButton(frame, "Test voice", 100, function()
        PlayTestVoice()
    end)
    testButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 8)

    local clearButton = MakeTextButton(frame, "Clear queue", 100, function()
        SoundQueue:RemoveAllSoundsFromQueue()
    end)
    clearButton:SetPoint("LEFT", testButton, "RIGHT", 6, 0)

    local closeAllButton = MakeTextButton(frame, "Close", 60, function()
        OptionsUI:Toggle()
    end)
    closeAllButton:SetPoint("RIGHT", frame, "BOTTOMRIGHT", -10, 8)

    self.frame = frame
    self.delayLabel = delayLabel
    self.statusLabel = statusLabel
    self.debugLabel = debugLabel
    RefreshOptionsUI()
end

function OptionsUI:Toggle()
    if not self.frame then
        local ok, err = pcall(self.Create, self)
        if not ok then
            Print(format("|cffff3333[QuestEcho]|r settings window failed to open: %s", tostring(err)))
            return
        end
    end
    if self.frame:IsShown() then
        self.frame:Hide()
    else
        RefreshOptionsUI()
        self.frame:Show()
    end
end

-- =============================================================================
-- Core event handling
-- =============================================================================
local welcomed = false
local function Welcome()
    if welcomed then
        return
    end
    if not DataModules:GetModule("QuestEchoData") then
        return
    end
    welcomed = true
    Debug:Print("data module registered: QuestEchoData")
end

local coreFrame = CreateFrame("Frame", "QuestEchoCoreFrame")

local registeredEvents = {}
local function RegisterEvent(name)
    if registeredEvents[name] then
        return true
    end
    local ok = pcall(coreFrame.RegisterEvent, coreFrame, name)
    if ok then
        registeredEvents[name] = true
        Debug:Print("registered event %s", name)
    else
        Debug:Print("event not available on this client: %s", name)
    end
    return ok
end

-- =============================================================================
-- Quest / gossip voice line triggers
-- =============================================================================
-- Quest-accept watcher state (table created early so OnQuestDetail can mark
-- titles it has already queued, preventing double plays from the poll).
QuestEcho.QuestAcceptWatcher = {}

local function OnQuestDetail()
    local name = Utils:GetNPCName()
    local okTitle, title = pcall(GetTitleText)
    local okText, text = pcall(GetQuestText)
    title = okTitle and title or nil
    text = okText and text or nil
    if not title or title == "" then
        return
    end

    local questID = DataModules:GetQuestID("accept", title, name, text)
    if not questID then
        Debug:Print("no quest ID match for accept: %s (%s)", tostring(title), tostring(name or "?"))
        return
    end
    if not name then
        name = DataModules:GetQuestGiverName(questID)
    end

    SoundQueue:AddSoundToQueue(
    {
        event = Enums.SoundEvent.QuestAccept,
        name = name,
        title = title,
        text = text,
        questID = questID,
        delay = Addon.db.profile.Delay,
    })
    local watcher = QuestEcho.QuestAcceptWatcher
    if watcher and watcher.known then
        watcher.known[title] = true
    end
end

local function OnQuestComplete()
    local name = Utils:GetNPCName()
    local okTitle, title = pcall(GetTitleText)
    local okText, text = pcall(GetRewardText)
    title = okTitle and title or nil
    text = okText and text or nil
    if not title or title == "" then
        return
    end

    local questID = DataModules:GetQuestID("complete", title, name, text)
    if not questID then
        Debug:Print("no quest ID match for complete: %s (%s)", tostring(title), tostring(name or "?"))
        return
    end
    if not name then
        name = DataModules:GetQuestGiverName(questID)
    end

    SoundQueue:AddSoundToQueue(
    {
        event = Enums.SoundEvent.QuestComplete,
        name = name,
        title = title,
        text = text,
        questID = questID,
        delay = Addon.db.profile.Delay,
    })
end

local function OnQuestProgress()
    -- The vanilla data pack has no "-progress" lines; kept for parity.
    local name = Utils:GetNPCName()
    local okTitle, title = pcall(GetTitleText)
    local okText, text = pcall(GetProgressText)
    title = okTitle and title or nil
    text = okText and text or nil
    if not title or title == "" then
        return
    end

    local questID = DataModules:GetQuestID("progress", title, name, text)
    if not questID then
        return
    end

    SoundQueue:AddSoundToQueue(
    {
        event = Enums.SoundEvent.QuestProgress,
        name = name,
        title = title,
        text = text,
        questID = questID,
        delay = Addon.db.profile.Delay,
    })
end

local function ShouldPlayGossip(name)
    local frequency = Addon.db.profile.GossipFrequency
    if frequency == Enums.GossipFrequency.Never then
        return false
    end
    if not name or name == "" then
        return false
    end

    if frequency == Enums.GossipFrequency.OncePerNPC then
        if Addon.db.char.PlayedNPC[name] then
            return false
        end
        Addon.db.char.PlayedNPC[name] = true
        return true
    elseif frequency == Enums.GossipFrequency.OncePerQuestNPC then
        local key = "q:" .. name
        if QuestEcho.session.PlayedSession[key] then
            return false
        end
        QuestEcho.session.PlayedSession[key] = true
        return true
    end

    return true -- Always
end

-- =============================================================================
-- Gossip watcher (fallback trigger)
-- This client may not fire GOSSIP_SHOW / QUEST_GREETING (the gossip window can
-- be engine-rendered), so we poll a cheap signal every 0.4s: an open gossip
-- shows gossip text while the "npc" unit is valid. The event handlers stay for
-- clients that do fire them; the openKey signature guard prevents double plays
-- from both paths.
-- =============================================================================
QuestEcho.GossipWatcher = {}
local GossipWatcher = QuestEcho.GossipWatcher
GossipWatcher.openKey = nil
GossipWatcher.nextCheck = nil
local GOSSIP_POLL_INTERVAL = 0.4

local function OnQuestGreeting()
    local name = Utils:GetNPCName()
    local ok, text = pcall(GetGreetingText)
    text = ok and text or nil
    if not text or text == "" then
        return
    end
    if GossipWatcher.openKey == (name or "") .. "|greet|" .. text then
        return
    end
    GossipWatcher.openKey = (name or "") .. "|greet|" .. text

    SoundQueue:AddSoundToQueue(
    {
        event = Enums.SoundEvent.QuestGreeting,
        name = name,
        text = text,
        delay = Addon.db.profile.Delay,
    })
end

local function OnGossipShow()
    local name = Utils:GetNPCName()
    local ok, text = pcall(GetGossipText)
    text = ok and text or nil
    if not text or text == "" then
        return
    end
    if GossipWatcher.openKey == (name or "") .. "|" .. text then
        return
    end
    GossipWatcher.openKey = (name or "") .. "|" .. text
    if not ShouldPlayGossip(name) then
        Debug:Print("gossip skipped (frequency setting)")
        return
    end

    SoundQueue:AddSoundToQueue(
    {
        event = Enums.SoundEvent.Gossip,
        name = name,
        text = text,
        delay = Addon.db.profile.Delay,
    })
end

function GossipWatcher:OnUpdate()
    local okT, t = pcall(GetTime)
    if not okT or not t then
        return
    end
    if self.nextCheck and t < self.nextCheck then
        return
    end
    self.nextCheck = t + GOSSIP_POLL_INTERVAL

    local okName, name = pcall(UnitName, "npc")
    local okText, text = pcall(GetGossipText)
    local isOpen = okName and name and name ~= "" and okText and text and text ~= ""
    if not isOpen then
        self.openKey = nil
        return
    end
    OnGossipShow()
end

-- =============================================================================
-- Quest-accept watcher (fallback trigger)
-- QUEST_DETAIL may not fire on this client, so poll the quest log for newly
-- appeared quest titles and play their accept voice line once. The first poll
-- only primes the known set (existing quests do not replay). Titles already
-- queued by OnQuestDetail are marked and skipped.
-- =============================================================================
local QuestAcceptWatcher = QuestEcho.QuestAcceptWatcher
QuestAcceptWatcher.known = nil
QuestAcceptWatcher.nextCheck = nil
local QUEST_POLL_INTERVAL = 0.5

local function CurrentQuestTitles()
    local titles = {}
    local okNum, num = pcall(GetNumQuestLogEntries)
    if not okNum or not num or num < 1 then
        return titles
    end
    for i = 1, num do
        local okT, title = pcall(GetQuestLogTitle, i)
        if okT and title and title ~= "" then
            titles[title] = true
        end
    end
    return titles
end

-- Quest-complete watcher: the client does not pass real event names to
-- OnEvent (event is always nil) and GetQuestReward() with no argument only
-- returns a usage string, so neither can drive completion detection.
--
-- Verified signals (from live diagnostics): GetRewardText only updates when
-- the quest-reward (turn-in) window opens — the detail window keeps the
-- previous value (0 -> 478, 478 -> 97 were both the reward window appearing).
-- So a change in reward-text length while a quest title is showing = the
-- turn-in window just opened: play the complete line immediately. The quest
-- log shrinking (turn-in finished) is kept as a fallback, deduped so the
-- same quest never plays twice.
QuestEcho.QuestCompleteWatcher = {}
local QuestCompleteWatcher = QuestEcho.QuestCompleteWatcher
QuestCompleteWatcher.nextCheck = nil
QuestCompleteWatcher.lastRtLen = nil

function QuestCompleteWatcher:OnUpdate()
    local okT, t = pcall(GetTime)
    if not okT or not t then
        return
    end
    if self.nextCheck and t < self.nextCheck then
        return
    end
    self.nextCheck = t + QUEST_POLL_INTERVAL

    local okTitle, title = pcall(GetTitleText)
    local hasTitle = okTitle and title and title ~= ""
    local okRT, rewardText = pcall(GetRewardText)
    local rtlen = (okRT and rewardText and #rewardText) or 0

    -- The reward (turn-in) window just opened: reward text appeared/changed
    -- while a quest title is showing. This is the only complete trigger —
    -- clicking Complete must not replay it.
    if hasTitle and rtlen > 0 and rtlen ~= self.lastRtLen then
        self.lastRtLen = rtlen
        local questID = FindQuestIDByTitle(title)
        if questID and HasQuestVoice(questID, "complete") then
            Debug:Print("complete detected via reward window: %s", tostring(title))
            SoundQueue:PlayPriority(
            {
                event = Enums.SoundEvent.QuestComplete,
                name = DataModules:GetQuestGiverName(questID),
                title = title,
                questID = questID,
                delay = Addon.db.profile.Delay,
            })
        end
    end
    if not hasTitle then
        -- Left the quest window: arm the detector again for the next window.
        self.lastRtLen = nil
    end
end

function QuestAcceptWatcher:OnUpdate()
    local okT, t = pcall(GetTime)
    if not okT or not t then
        return
    end
    if self.nextCheck and t < self.nextCheck then
        return
    end
    self.nextCheck = t + QUEST_POLL_INTERVAL

    local current = CurrentQuestTitles()
    local known = self.known
    if not known then
        self.known = current
        return
    end
    for title in pairs(current) do
        if not known[title] then
            local questID = FindQuestIDByTitle(title)
            if questID and HasQuestVoice(questID, "accept") then
                SoundQueue:AddSoundToQueue(
                {
                    event = Enums.SoundEvent.QuestAccept,
                    name = DataModules:GetQuestGiverName(questID),
                    title = title,
                    questID = questID,
                    delay = Addon.db.profile.Delay,
                })
            end
        end
    end
    self.known = current
end

local function OnEvent(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == "QuestEcho" or addonName == nil then
            -- Re-sync saved variables if they arrived after our initial merge.
            QuestEchoDB = QuestEchoDB or {}
            Addon.db = Addon:MergeDB(QuestEchoDB, defaults)
            -- capture the player's sound settings once the client has applied
            -- them (delayed so startup volume 0s can never become the baseline)
            Utils:MaybeCaptureBaseline()
            SoundQueueUI:Update()
            -- All bundled data files have loaded by now, so announce.
            Welcome()
        end
    elseif event == "QUEST_DETAIL" then
        OnQuestDetail()
    elseif event == "QUEST_PROGRESS" then
        OnQuestProgress()
    elseif event == "QUEST_COMPLETE" then
        OnQuestComplete()
    elseif event == "QUEST_GREETING" then
        OnQuestGreeting()
    elseif event == "GOSSIP_SHOW" then
        OnGossipShow()
    elseif event == "QUEST_LOG_UPDATE" then
        QuestLogUI:Update()
        QuestLogHook:Update()
    end
end

coreFrame:SetScript("OnEvent", OnEvent)


pcall(Welcome)
-- loaded the standalone data pack before us).



-- =============================================================================
-- timer driver
local timerFrame = CreateFrame("Frame")
timerFrame:SetScript("OnUpdate", function()
    Utils:MaybeCaptureBaseline()
    SoundQueue:OnUpdate()
    GossipWatcher:OnUpdate()
    QuestAcceptWatcher:OnUpdate()
    QuestCompleteWatcher:OnUpdate()
end)

-- =============================================================================
-- Slash commands
-- =============================================================================
local GOSSIP_NAMES =
{
    [Enums.GossipFrequency.Always] = "always",
    [Enums.GossipFrequency.OncePerQuestNPC] = "oncequest",
    [Enums.GossipFrequency.OncePerNPC] = "once",
    [Enums.GossipFrequency.Never] = "never",
}

local function Help()
    Print("|cff33ffccQuestEcho (Emberveil)|r 1.5.0 — voice lines for quests and gossip")
    Print("|cff33ffcc/qe|r — this help")
    Print("|cff33ffcc/qe pause|r — pause/resume the voice line queue")
    Print("|cff33ffcc/qe clear|r — clear the queue and stop the current line")
    Print("|cff33ffcc/qe gossip|r — show gossip frequency")
    Print("|cff33ffcc/qe gossip always|r / |cff33ffcconce|r / |cff33ffcconcequest|r / |cff33ffccnever|r — set gossip frequency")
    Print("|cff33ffcc/qe delay <sec>|r — delay before a voice line starts (default 0.3)")
    Print("|cff33ffcc/qe stopwait full|<sec>|r — how long to keep volume muted after removing a line (default 0.5)")
    Print("|cff33ffcc/qe ui|r — toggle the status bar")
    Print("|cff33ffcc/qe debug|r — toggle debug messages")
    Print("|cff33ffcc/qe questlog|r — open the quest replay window")
    Print("|cff33ffcc/qe settings|r — open the settings panel")
    Print("|cff33ffcc/qe test|r — play a test voice line")
    Print("|cff33ffcc/qe status|r — show queue state")
    Print("|cff33ffcc/qe diag|r — dump sound cvar/baseline/api diagnostics")
    Print("|cff33ffcc/qe probe|r — dump runtime quest-log/sound diagnostics")
    Print("|cff33ffcc/qe soundprobe|r — play one file via 5 path variants (which do you hear?)")
end

local function HandleSlashCommand(input)
    input = string.lower(string.gsub(input or "", "^%s*(.-)%s*$", "%1"))
    local command, arg = input:match("^(%S*)%s*(.-)$")
    arg = string.gsub(arg or "", "^%s*(.-)%s*$", "%1")

    if command == "" or command == "help" then
        Help()
    elseif command == "pause" or command == "p" then
        SoundQueue:TogglePauseQueue()
        Print(format("|cff33ffcc[QuestEcho]|r %s", Addon.db.char.IsPaused and "paused" or "resumed"))
    elseif command == "clear" or command == "c" then
        SoundQueue:RemoveAllSoundsFromQueue()
        Print("|cff33ffcc[QuestEcho]|r queue cleared")
    elseif command == "gossip" or command == "g" then
        if arg == "" then
            Print(format("|cff33ffcc[QuestEcho]|r gossip frequency: |cffffffff%s|r",
                GOSSIP_NAMES[Addon.db.profile.GossipFrequency] or "?"))
        elseif arg == "always" then
            Addon.db.profile.GossipFrequency = Enums.GossipFrequency.Always
            Print("|cff33ffcc[QuestEcho]|r gossip: always")
        elseif arg == "once" then
            Addon.db.profile.GossipFrequency = Enums.GossipFrequency.OncePerNPC
            Print("|cff33ffcc[QuestEcho]|r gossip: once per NPC (per character)")
        elseif arg == "oncequest" or arg == "onceperquest" then
            Addon.db.profile.GossipFrequency = Enums.GossipFrequency.OncePerQuestNPC
            Print("|cff33ffcc[QuestEcho]|r gossip: once per quest NPC (per session)")
        elseif arg == "never" then
            Addon.db.profile.GossipFrequency = Enums.GossipFrequency.Never
            Print("|cff33ffcc[QuestEcho]|r gossip: never")
        else
            Print("|cffff3333[QuestEcho]|r unknown gossip setting: " .. tostring(arg))
        end
    elseif command == "delay" then
        local delay = tonumber(arg)
        if delay and delay >= 0 and delay <= 10 then
            Addon.db.profile.Delay = delay
            Print(format("|cff33ffcc[QuestEcho]|r delay set to %.1fs", delay))
        else
            Print(format("|cff33ffcc[QuestEcho]|r current delay: %.1fs", Addon.db.profile.Delay))
        end
    elseif command == "ui" then
        SoundQueueUI:Toggle()
    elseif command == "probe" then
        ProbeRuntime()
    elseif command == "soundprobe" then
        RunSoundProbe()
    elseif command == "questlog" or command == "ql" then
        QuestLogUI:Toggle()
    elseif command == "settings" or command == "options" or command == "opt" then
        OptionsUI:Toggle()
    elseif command == "stopwait" then
        if arg == "" then
            Print(format("|cff33ffcc[QuestEcho]|r stop restore wait: |cffffffff%s|r (full = wait for the removed line to end)", tostring(Addon.db.profile.StopWait)))
        elseif arg == "full" then
            Addon.db.profile.StopWait = "full"
            Print("|cff33ffcc[QuestEcho]|r stop restore wait: full (wait for the removed line to end)")
        else
            local wait = tonumber(arg)
            if wait and wait >= 0 and wait <= 30 then
                Addon.db.profile.StopWait = wait
                Print(format("|cff33ffcc[QuestEcho]|r stop restore wait: %.1fs (the removed line's tail may keep playing)", wait))
            else
                Print("|cffff3333[QuestEcho]|r usage: /qe stopwait full | <seconds 0-30>")
            end
        end
    elseif command == "debug" then
        Addon.db.profile.Debug = not Addon.db.profile.Debug
        Print(format("|cff33ffcc[QuestEcho]|r debug %s", Addon.db.profile.Debug and "on" or "off"))
    elseif command == "test" then
        if not DataModules:GetModule("QuestEchoData") then
            Print("|cffff3333[QuestEcho]|r test failed: data module not loaded — type |cff33ffcc/qe status|r")
        elseif not Utils:IsSoundEnabled() then
            Print("|cffff3333[QuestEcho]|r test failed: sound is disabled in the game options")
        else
            local ok, fileName = PlayTestVoice()
            if ok then
                Print(format("|cff33ffcc[QuestEcho]|r test voice line queued (%s)", tostring(fileName)))
            else
                Print("|cffff3333[QuestEcho]|r test failed: no voice line file for quest 5 in the data pack")
            end
        end
    elseif command == "diag" then
        Print("|cff33ffcc[QuestEcho]|r -- diag --")
        local cvars = Utils.SOUND_CVARS
        for i = 1, #cvars do
            local name = cvars[i]
            local base = Utils.baselineSound and Utils.baselineSound[name] or "nil"
            local ok, cur = pcall(GetCVar, name)
            Print(format("  %s: base=%s now=%s", name, tostring(base), tostring(ok and cur or "?")))
        end
        Print(format("  isMuted: %s", tostring(Utils.isMuted)))
        Print(format("  StopSound=%s MuteSoundFile=%s UnmuteSoundFile=%s",
            tostring(type(StopSound)), tostring(type(MuteSoundFile)), tostring(type(UnmuteSoundFile))))
        local dataMod = DataModules:GetModule("QuestEchoData")
        if dataMod and dataMod.SoundLengthLookupByFileName then
            local snd = next(dataMod.SoundLengthLookupByFileName)
            if snd then
                local path = "Interface\\AddOns\\QuestEchoData\\generated\\sounds\\gossip\\" .. snd .. ".ogg"
                local ok, handle = pcall(PlaySoundFile, path, "Master")
                Print(format("  PlaySoundFile -> ok=%s handle=%s (%s)", tostring(ok), tostring(handle), tostring(snd)))
            end
        end
        Print("|cff33ffcc[QuestEcho]|r -- diag done --")
    elseif command == "play" then
        local qid = tonumber(arg)
        if not qid then
            Print("|cffff3333[QuestEcho]|r usage: /qe play <questID> (plays the accept voice line directly)")
        else
            local sd = { event = Enums.SoundEvent.QuestAccept, questID = qid, title = "quest " .. qid, delay = 0 }
            if DataModules:PrepareSound(sd) then
                local okPlay = Utils:PlaySound(sd)
                Print(format("|cff33ffcc[QuestEcho]|r played %s (%s) -> %s", tostring(sd.fileName), tostring(sd.filePath), tostring(okPlay)))
            else
                Print(format("|cffff3333[QuestEcho]|r no voice line for quest %d", qid))
            end
        end
    elseif command == "diagquest" then
        Print("|cff33ffcc[QuestEcho]|r -- diagquest --")
        local okSel, selection = pcall(GetQuestLogSelection)
        Print(format("  1) GetQuestLogSelection -> ok=%s val=%s", tostring(okSel), tostring(selection)))
        if okSel and selection then
            local okTitle, title = pcall(GetQuestLogTitle, selection)
            Print(format("  2) GetQuestLogTitle(%s) -> ok=%s title=%s", tostring(selection), tostring(okTitle), tostring(title)))
            if okTitle and title and title ~= "" then
                local questID = FindQuestIDByTitle(title)
                Print(format("  3) FindQuestIDByTitle -> %s", tostring(questID)))
                if questID then
                    Print(format("  4) HasQuestVoice(accept) -> %s", tostring(HasQuestVoice(questID, "accept"))))
                    local sd = { event = Enums.SoundEvent.QuestAccept, questID = questID, title = title }
                    local okPrep = DataModules:PrepareSound(sd)
                    if okPrep then
                        Print(format("  5) PrepareSound -> %s / %s / %.2fs", tostring(sd.fileName), tostring(sd.filePath), sd.length or 0))
                        local okPlay = Utils:PlaySound(sd)
                        Print(format("  6) PlaySoundFile -> %s", tostring(okPlay)))
                    else
                        Print("  5) PrepareSound -> false (no voice line)")
                    end
                end
            end
        end
        Print("|cff33ffcc[QuestEcho]|r -- diagquest done --")
    elseif command == "status" or command == "s" then
        local current = SoundQueue.current
        local queued = #SoundQueue.sounds
        Print(format("|cff33ffcc[QuestEcho]|r queue: %d queued%s |cffcccccc(%s)|r",
            queued,
            current and format(", playing: |cffffffff%s|r", tostring(current.fileName)) or ", idle",
            Addon.db.char.IsPaused and "paused" or "running"))
        Print(format("|cff33ffcc[QuestEcho]|r data module: |cffffffff%s|r",
            DataModules:GetModule("QuestEchoData") and "loaded" or "NOT LOADED"))
        local soundAll, soundSfx = Utils:GetSoundCvarInfo()
        Print(format("|cff33ffcc[QuestEcho]|r sound: |cffffffff%s|r (Sound_EnableAllSound=%s, Sound_EnableSFX=%s)",
            Utils:IsSoundEnabled() and "enabled" or "disabled", soundAll, soundSfx))
    else
        Print("|cffff3333[QuestEcho]|r unknown command: " .. tostring(command) .. " — type |cff33ffcc/qe|r for help")
    end
end

SLASH_QUESTECHO1, SLASH_QUESTECHO2 = "/qe", "/questecho"
SlashCmdList["QUESTECHO"] = HandleSlashCommand

-- =============================================================================
-- Startup
-- =============================================================================
-- Enumerate present data modules before anything can register against us.
pcall(DataModules.EnumerateAddons, DataModules)

-- Register events (missing events are skipped safely).
RegisterEvent("ADDON_LOADED")
RegisterEvent("QUEST_DETAIL")
RegisterEvent("QUEST_PROGRESS")
RegisterEvent("QUEST_COMPLETE")
RegisterEvent("QUEST_GREETING")
RegisterEvent("GOSSIP_SHOW")
RegisterEvent("QUEST_LOG_UPDATE")

-- Create the status bar.
pcall(SoundQueueUI.Create, SoundQueueUI)

-- Try to attach voice buttons into the client's quest log (skips silently
-- when the client renders the quest log with the engine instead).
pcall(QuestLogHook.TryEnable, QuestLogHook)

-- Announce if everything was already in place at load time (e.g. the client
-- loaded the standalone data pack before us).
pcall(Welcome)
