if not QuestEcho or not QuestEcho.DataModules then return end

QuestEchoData = {}

function QuestEchoData:GetSoundPath(fileName, event)
    setfenv(1, QuestEcho)
    if Enums.SoundEvent:IsQuestEvent(event) then
        return format([[generated/sounds/quests/%s.ogg]], fileName)
    elseif Enums.SoundEvent:IsGossipEvent(event) then
        return format([[generated/sounds/gossip/%s.ogg]], fileName)
    end
end

QuestEcho.DataModules:Register("QuestEchoData", QuestEchoData)
