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

-- =============================================================================
-- Localization (zhCN / enUS)
-- =============================================================================
local okLocale, LOCALE = pcall(GetLocale)
if not okLocale then
    LOCALE = "enUS"
end
local function L(en, zh)
    if LOCALE == "zhCN" then
        return zh or en
    end
    return en
end

--- Voice files that hang the client's ogg decoder (no static signature found:
--- identical encoding/structure/decode in ffmpeg, libvorbis and stb_vorbis, only
--- the in-game PlaySoundFile hangs). These are shipped as .wav in the data pack
--- and prepared via the override below; the ogg originals are removed.
--- Value = actual file name on disk (with extension); the lookup key is the
--- logical file name from the length table.
QuestEcho.WavOverride =
{
    ["6d671d26f71829b3cfdafaf53866d6f0"] = "6d671d26.wav",
    ["0016d0ff7c43ada7e4f367d5b24e9b81"] = "0016d0ff7c43ada7e4f367d5b24e9b81.wav",
    ["012cba0ea4f7f602188cc6eee3493caa"] = "012cba0ea4f7f602188cc6eee3493caa.wav",
    ["0183522424d4cfa55625a193ad8eb384"] = "0183522424d4cfa55625a193ad8eb384.wav",
    ["01ed61117dd6f345c1893b55ba7c3e87"] = "01ed61117dd6f345c1893b55ba7c3e87.wav",
    ["036da6474362e31b5c5b8714997221d3"] = "036da6474362e31b5c5b8714997221d3.wav",
    ["053c0fa7412311c64d1afb7f93c896c5"] = "053c0fa7412311c64d1afb7f93c896c5.wav",
    ["055387f3f8f3d85f77a3586504bdb666"] = "055387f3f8f3d85f77a3586504bdb666.wav",
    ["058360cd0cfb26d7fc00ef22bcb6d9f7"] = "058360cd0cfb26d7fc00ef22bcb6d9f7.wav",
    ["0815aba74c3a70d73e32cc5365b4babf"] = "0815aba74c3a70d73e32cc5365b4babf.wav",
    ["09a9c4ad934397dc02876bda84bad0ff"] = "09a9c4ad934397dc02876bda84bad0ff.wav",
    ["0b31ddefd183ea40f98d3eae3fd516ca"] = "0b31ddefd183ea40f98d3eae3fd516ca.wav",
    ["0c6e66b796bf9729d8e0c65c441711d3"] = "0c6e66b796bf9729d8e0c65c441711d3.wav",
    ["0fb161fe21a8ff5f560e714f38fb0b44"] = "0fb161fe21a8ff5f560e714f38fb0b44.wav",
    ["0ff75e91e3efa274b411fe43479cec98"] = "0ff75e91e3efa274b411fe43479cec98.wav",
    ["10d29ce6d81dc4cf54ce10f28a538a8b"] = "10d29ce6d81dc4cf54ce10f28a538a8b.wav",
    ["1210fdab329f2bfebdcf1f7d836de9da"] = "1210fdab329f2bfebdcf1f7d836de9da.wav",
    ["1308cc62e8033d85625722f0011e1e98"] = "1308cc62e8033d85625722f0011e1e98.wav",
    ["136e146f620b6e7197755a682b68ce84"] = "136e146f620b6e7197755a682b68ce84.wav",
    ["13a767725c325fa51d467e80639b5c7b"] = "13a767725c325fa51d467e80639b5c7b.wav",
    ["147f7781bcfc14024f4c4c8fae38a676"] = "147f7781bcfc14024f4c4c8fae38a676.wav",
    ["17112182a94dae91af72cf8bb58dde4b"] = "17112182a94dae91af72cf8bb58dde4b.wav",
    ["172651bdd26f58b06745eb92d746a013"] = "172651bdd26f58b06745eb92d746a013.wav",
    ["18b7641805b9860312823c6781f21372"] = "18b7641805b9860312823c6781f21372.wav",
    ["19094708788f5fed06d218ff02fd6667"] = "19094708788f5fed06d218ff02fd6667.wav",
    ["19d7a62aa644748c5d13eaad7341a221"] = "19d7a62aa644748c5d13eaad7341a221.wav",
    ["1b37830fe8480ed6bd57b3d834cd2310"] = "1b37830fe8480ed6bd57b3d834cd2310.wav",
    ["1d00acba5fef6b2efb8c4454e9935541"] = "1d00acba5fef6b2efb8c4454e9935541.wav",
    ["1d3cd34903e040de6b0c73c1aa2fb0df"] = "1d3cd34903e040de6b0c73c1aa2fb0df.wav",
    ["1ea4f7d4103e7f106c8b166cdb5e3649"] = "1ea4f7d4103e7f106c8b166cdb5e3649.wav",
    ["20e50f7907859f3c67714458b3ebf738"] = "20e50f7907859f3c67714458b3ebf738.wav",
    ["2494fd01fbbcaa3067f0f6bde8276ef1"] = "2494fd01fbbcaa3067f0f6bde8276ef1.wav",
    ["24f8a464cacbadb24bac1f53d8aa22dd"] = "24f8a464cacbadb24bac1f53d8aa22dd.wav",
    ["258744fe85450f544093d5fd17856341"] = "258744fe85450f544093d5fd17856341.wav",
    ["274e65db536d36aab805a57c6a0b4076"] = "274e65db536d36aab805a57c6a0b4076.wav",
    ["29ab1815cf6aff3f41bd5f69c7535753"] = "29ab1815cf6aff3f41bd5f69c7535753.wav",
    ["2a934c9aeb08dec90a0d0e7b99a9e8d0"] = "2a934c9aeb08dec90a0d0e7b99a9e8d0.wav",
    ["2ab19e8f4975368b71069106f4f9e703"] = "2ab19e8f4975368b71069106f4f9e703.wav",
    ["2c1d9480e123f8e1e386e141a695f2a7"] = "2c1d9480e123f8e1e386e141a695f2a7.wav",
    ["2c6cd31df344e81e13802e0526bd4f82"] = "2c6cd31df344e81e13802e0526bd4f82.wav",
    ["2cf644ba2f510e7a4b8706d23090659a"] = "2cf644ba2f510e7a4b8706d23090659a.wav",
    ["2e65eb1fa48fb06278bb020f60a84d34"] = "2e65eb1fa48fb06278bb020f60a84d34.wav",
    ["2e8e186a35fdbdc4167c9a2d1cbd23c8"] = "2e8e186a35fdbdc4167c9a2d1cbd23c8.wav",
    ["302142138778affead2a13087925b7b1"] = "302142138778affead2a13087925b7b1.wav",
    ["3108806b44f37624987d36cafc8de658"] = "3108806b44f37624987d36cafc8de658.wav",
    ["311c5f6a0a1dddef0371a0c113bb62ab"] = "311c5f6a0a1dddef0371a0c113bb62ab.wav",
    ["32a5626d8140ad954652c141442fc86c"] = "32a5626d8140ad954652c141442fc86c.wav",
    ["334b73436ddc4b1bda745af5eb1e4f32"] = "334b73436ddc4b1bda745af5eb1e4f32.wav",
    ["338674bfb1edb2117c563bae8305e5f2"] = "338674bfb1edb2117c563bae8305e5f2.wav",
    ["33e9252b9e79f5d50346fb17553ee92a"] = "33e9252b9e79f5d50346fb17553ee92a.wav",
    ["3a497353f8cb102ec4debd8d8adc446a"] = "3a497353f8cb102ec4debd8d8adc446a.wav",
    ["3afbafbdc7a6269b97c1bd93f678955c"] = "3afbafbdc7a6269b97c1bd93f678955c.wav",
    ["3c96e38d8275bcb879a7e7eb43dca519"] = "3c96e38d8275bcb879a7e7eb43dca519.wav",
    ["3ccc9d3982a4f8dde9b5653bc0c2e796"] = "3ccc9d3982a4f8dde9b5653bc0c2e796.wav",
    ["3def2f3bfaf2254698c9601afcf6a534"] = "3def2f3bfaf2254698c9601afcf6a534.wav",
    ["3f6b8f110896d04e7a6ad663cef0e70d"] = "3f6b8f110896d04e7a6ad663cef0e70d.wav",
    ["3fd9a5ca3019eefa0d287e45aeacd7da"] = "3fd9a5ca3019eefa0d287e45aeacd7da.wav",
    ["42589616848b8292a7b00119aa63bd29"] = "42589616848b8292a7b00119aa63bd29.wav",
    ["42747362bb8e6d2164d7e79747248058"] = "42747362bb8e6d2164d7e79747248058.wav",
    ["44b04e19a4aa4b719b00c378a9acd900"] = "44b04e19a4aa4b719b00c378a9acd900.wav",
    ["46bd22a73f998050e4834380890f65e5"] = "46bd22a73f998050e4834380890f65e5.wav",
    ["4c1b626c145d8077c5aa2db55852dcfa"] = "4c1b626c145d8077c5aa2db55852dcfa.wav",
    ["4cf39f0b48e67e4fb4e5d3538ae49f07"] = "4cf39f0b48e67e4fb4e5d3538ae49f07.wav",
    ["4fb69760c9da7ebb077cf4bab2e8b3c9"] = "4fb69760c9da7ebb077cf4bab2e8b3c9.wav",
    ["5011b7376cf9fbdf9a91842132fba2e6"] = "5011b7376cf9fbdf9a91842132fba2e6.wav",
    ["50d79c7aeabf3cffea9b701bf10738f2"] = "50d79c7aeabf3cffea9b701bf10738f2.wav",
    ["5521f2e5d2e37d7012ea87b75badcb01"] = "5521f2e5d2e37d7012ea87b75badcb01.wav",
    ["554b8726d09d342022c5c7eaf5a9818e"] = "554b8726d09d342022c5c7eaf5a9818e.wav",
    ["565e6a177495db01dd95ca40d2cdce06"] = "565e6a177495db01dd95ca40d2cdce06.wav",
    ["5776ad2ab96a8574ffb8006cc2353824"] = "5776ad2ab96a8574ffb8006cc2353824.wav",
    ["577b34a2009f6599e2e71e1f5ebe9a56"] = "577b34a2009f6599e2e71e1f5ebe9a56.wav",
    ["580054d04eb523be430e4750bc42907f"] = "580054d04eb523be430e4750bc42907f.wav",
    ["59639744f57566c294774d64cbef1436"] = "59639744f57566c294774d64cbef1436.wav",
    ["5a6a13f324242e75a6382d99c516cc94"] = "5a6a13f324242e75a6382d99c516cc94.wav",
    ["5aaf2f083eef745315ab1a2dc692fcb0"] = "5aaf2f083eef745315ab1a2dc692fcb0.wav",
    ["5b3a63364d822c6bd2559d96ec4d9317"] = "5b3a63364d822c6bd2559d96ec4d9317.wav",
    ["5b5b66a181411dac0931427a9ff18c6c"] = "5b5b66a181411dac0931427a9ff18c6c.wav",
    ["5bb22872b7638f5085ca2059018cc5ff"] = "5bb22872b7638f5085ca2059018cc5ff.wav",
    ["5e0b696d989d9f556038cd140846f661"] = "5e0b696d989d9f556038cd140846f661.wav",
    ["5e32b11a014d38435309852c50df4593"] = "5e32b11a014d38435309852c50df4593.wav",
    ["5f903d5d4508abe7b82460c9b5fcf80e"] = "5f903d5d4508abe7b82460c9b5fcf80e.wav",
    ["60e14cbaa8435b4075f83aeb3e80dcff"] = "60e14cbaa8435b4075f83aeb3e80dcff.wav",
    ["6169b63082c1481ee1b292a6bd277450"] = "6169b63082c1481ee1b292a6bd277450.wav",
    ["63954ad79a181f4bdebcb1e87ea78d14"] = "63954ad79a181f4bdebcb1e87ea78d14.wav",
    ["63da9bd89a3205deec3a0d71f3209f77"] = "63da9bd89a3205deec3a0d71f3209f77.wav",
    ["6427b5ad172185229fdf52a2a91052ea"] = "6427b5ad172185229fdf52a2a91052ea.wav",
    ["65ed32ee792501359c944e9da3ef350e"] = "65ed32ee792501359c944e9da3ef350e.wav",
    ["6628421bf475ed47d8d51a305f80ce4b"] = "6628421bf475ed47d8d51a305f80ce4b.wav",
    ["695bffa496e17bf3ace18949095a965e"] = "695bffa496e17bf3ace18949095a965e.wav",
    ["6a4b81d7d70a940c7734d52c5bd021ed"] = "6a4b81d7d70a940c7734d52c5bd021ed.wav",
    ["6adb3f498e428354df52f9e4254cab21"] = "6adb3f498e428354df52f9e4254cab21.wav",
    ["6b44a3e2d494f59d83f14e5c3fd90e85"] = "6b44a3e2d494f59d83f14e5c3fd90e85.wav",
    ["6ca0e5f286f5115ccba86010cc9d19a7"] = "6ca0e5f286f5115ccba86010cc9d19a7.wav",
    ["6d05441079c12f5737a4ae0732070946"] = "6d05441079c12f5737a4ae0732070946.wav",
    ["6d0616990747b3cf281cc9641375724d"] = "6d0616990747b3cf281cc9641375724d.wav",
    ["6e24adae0babfe7f1e128960d09c55af"] = "6e24adae0babfe7f1e128960d09c55af.wav",
    ["6f240a341cad715c1ce2f4322f7f0c15"] = "6f240a341cad715c1ce2f4322f7f0c15.wav",
    ["6f3dc341f1c868637188480b03d81828"] = "6f3dc341f1c868637188480b03d81828.wav",
    ["70cedd46427b60803ef6cb69ad0be4cb"] = "70cedd46427b60803ef6cb69ad0be4cb.wav",
    ["712130efaf95afb9ccb5f2a5c069c0fc"] = "712130efaf95afb9ccb5f2a5c069c0fc.wav",
    ["71b3c8878ca9d907574fab21af50df1a"] = "71b3c8878ca9d907574fab21af50df1a.wav",
    ["72d9e590ddf6bf219b208c8b157ddb5c"] = "72d9e590ddf6bf219b208c8b157ddb5c.wav",
    ["788e53903ca8bd09c088bd1d27efa397"] = "788e53903ca8bd09c088bd1d27efa397.wav",
    ["7eddf733901dbca29a5a21752dd1ceb4"] = "7eddf733901dbca29a5a21752dd1ceb4.wav",
    ["7f40e2c7a99505ba4995ee282dfc6836"] = "7f40e2c7a99505ba4995ee282dfc6836.wav",
    ["807f545aa510396b39fd74ed72c9abcb"] = "807f545aa510396b39fd74ed72c9abcb.wav",
    ["818428d85cc2451411dffed3878e6204"] = "818428d85cc2451411dffed3878e6204.wav",
    ["832d7cd84aaed062179a1a03bf687405"] = "832d7cd84aaed062179a1a03bf687405.wav",
    ["8515a7c8dc5b8746fab062eb6c4b7545"] = "8515a7c8dc5b8746fab062eb6c4b7545.wav",
    ["8651024fca6f7bd42a0336d52e7d69fc"] = "8651024fca6f7bd42a0336d52e7d69fc.wav",
    ["87e8317d1f6872386f47da8545ea8768"] = "87e8317d1f6872386f47da8545ea8768.wav",
    ["8bcc27057464ad8295116b381b58f4c4"] = "8bcc27057464ad8295116b381b58f4c4.wav",
    ["8bf5bc359aff1ea9c01dd2c255fe0603"] = "8bf5bc359aff1ea9c01dd2c255fe0603.wav",
    ["8d1a9653ec0ac81cbb827f31a1138bda"] = "8d1a9653ec0ac81cbb827f31a1138bda.wav",
    ["8d77629139cb2841d86e8e3ea861bc05"] = "8d77629139cb2841d86e8e3ea861bc05.wav",
    ["8dd5ae8dd52efbfbadf578cc9ba63982"] = "8dd5ae8dd52efbfbadf578cc9ba63982.wav",
    ["908c0040569523d5a3f6346f2a16f4ba"] = "908c0040569523d5a3f6346f2a16f4ba.wav",
    ["9160ee289a277af5bf427091078afc51"] = "9160ee289a277af5bf427091078afc51.wav",
    ["925eb79c2a5840bebb65045e96e8b3a9"] = "925eb79c2a5840bebb65045e96e8b3a9.wav",
    ["930e45368ed7dcac8e799df8fa5bc730"] = "930e45368ed7dcac8e799df8fa5bc730.wav",
    ["93b9b434b02f7bb9a2588ae09d531eae"] = "93b9b434b02f7bb9a2588ae09d531eae.wav",
    ["93cc04c8b8e24496ad60223e82204b3c"] = "93cc04c8b8e24496ad60223e82204b3c.wav",
    ["94e2524c35344ffbb05e9b1869c245f6"] = "94e2524c35344ffbb05e9b1869c245f6.wav",
    ["96d48bb506899c3338f1cadfcbe2c66a"] = "96d48bb506899c3338f1cadfcbe2c66a.wav",
    ["972de67fb04e5abac98c6158c6b5bcc6"] = "972de67fb04e5abac98c6158c6b5bcc6.wav",
    ["9802c328fee5a83bc01704102bf807c7"] = "9802c328fee5a83bc01704102bf807c7.wav",
    ["9894fe017afd5c82d452ec8f283f45f3"] = "9894fe017afd5c82d452ec8f283f45f3.wav",
    ["99f6365eca208317d557bba2b924e015"] = "99f6365eca208317d557bba2b924e015.wav",
    ["9b934f8faed0473a27a58466b2ffe393"] = "9b934f8faed0473a27a58466b2ffe393.wav",
    ["9e23396b9ad89ebcda67974afc38ea06"] = "9e23396b9ad89ebcda67974afc38ea06.wav",
    ["a18afdc5e96e5c4132424bf6058f6568"] = "a18afdc5e96e5c4132424bf6058f6568.wav",
    ["a25fe9ad1bdfb172b3a2dd3d0ef51db1"] = "a25fe9ad1bdfb172b3a2dd3d0ef51db1.wav",
    ["a28ef0400b8b68493cc0c0bec5e96f56"] = "a28ef0400b8b68493cc0c0bec5e96f56.wav",
    ["a5bb9bf7601a2bba6b4270f85bdd04f4"] = "a5bb9bf7601a2bba6b4270f85bdd04f4.wav",
    ["a7ed0b69c3f96a8b2db61ded1d58a42b"] = "a7ed0b69c3f96a8b2db61ded1d58a42b.wav",
    ["a82acbf9cc59e1d9b14eec0cc0cef377"] = "a82acbf9cc59e1d9b14eec0cc0cef377.wav",
    ["a98ca602e3662a391ca9f0807a798926"] = "a98ca602e3662a391ca9f0807a798926.wav",
    ["ab4fb84e95b89dcfe001b8f105e6210b"] = "ab4fb84e95b89dcfe001b8f105e6210b.wav",
    ["ac0ba2a4466278a2ed6ceac133133a36"] = "ac0ba2a4466278a2ed6ceac133133a36.wav",
    ["b1a4bc076a7a69d393730100ba28a6d7"] = "b1a4bc076a7a69d393730100ba28a6d7.wav",
    ["b27d8d76ceedb566e8ec960533bf3a52"] = "b27d8d76ceedb566e8ec960533bf3a52.wav",
    ["b34aad75e8e14753d5e47ece1a2eba61"] = "b34aad75e8e14753d5e47ece1a2eba61.wav",
    ["b4db7422b050ec4c88d959b16d7d2d02"] = "b4db7422b050ec4c88d959b16d7d2d02.wav",
    ["b4e38865182ec7942e86379c3c9fcdf9"] = "b4e38865182ec7942e86379c3c9fcdf9.wav",
    ["b660919fd15bb4acba5ab26eedc550ac"] = "b660919fd15bb4acba5ab26eedc550ac.wav",
    ["ba5ad36a7112e765204a7bd3ede7c783"] = "ba5ad36a7112e765204a7bd3ede7c783.wav",
    ["bb1f573853925f0a6e40c79130754165"] = "bb1f573853925f0a6e40c79130754165.wav",
    ["bb2e2ac84fdaea93b4cb5f24ace4d539"] = "bb2e2ac84fdaea93b4cb5f24ace4d539.wav",
    ["bb63ff9d75c7726f1d06e21fe2021b8b"] = "bb63ff9d75c7726f1d06e21fe2021b8b.wav",
    ["bb867ac15a6374047fe55ff21e0b3596"] = "bb867ac15a6374047fe55ff21e0b3596.wav",
    ["bc68f87f28d14f99d8f8ff4c267ffea2"] = "bc68f87f28d14f99d8f8ff4c267ffea2.wav",
    ["bce8743c8a0bd63dc3920724e764d1fa"] = "bce8743c8a0bd63dc3920724e764d1fa.wav",
    ["bd7be540acfdb0455e58364636e73dda"] = "bd7be540acfdb0455e58364636e73dda.wav",
    ["bdfe4126b453f140f54062473872a072"] = "bdfe4126b453f140f54062473872a072.wav",
    ["be509dfb481fe127dfd82ad17e93b19e"] = "be509dfb481fe127dfd82ad17e93b19e.wav",
    ["bf6b174b1213cc9fc8478d3b5f2b4971"] = "bf6b174b1213cc9fc8478d3b5f2b4971.wav",
    ["c3684d8296958c5935a2740fa7611b74"] = "c3684d8296958c5935a2740fa7611b74.wav",
    ["c507517029d417a2e6d13173fcac6bfe"] = "c507517029d417a2e6d13173fcac6bfe.wav",
    ["c7d0d5f0497c7bbd94f17ecb262de67c"] = "c7d0d5f0497c7bbd94f17ecb262de67c.wav",
    ["c7e8ad876846de0a672a9b4dd6150d20"] = "c7e8ad876846de0a672a9b4dd6150d20.wav",
    ["c8b7cc29723f78c9a33d40dd94b43a31"] = "c8b7cc29723f78c9a33d40dd94b43a31.wav",
    ["ca5ae8d63433bb1a991ae3a7d4a633fc"] = "ca5ae8d63433bb1a991ae3a7d4a633fc.wav",
    ["ca7d18cf048257b8138d41171774e437"] = "ca7d18cf048257b8138d41171774e437.wav",
    ["ce85977b0f1b155023ca49641a927acd"] = "ce85977b0f1b155023ca49641a927acd.wav",
    ["cf38911600ac02c04cb72aafa6596e66"] = "cf38911600ac02c04cb72aafa6596e66.wav",
    ["d02d422dcd7131e686d6532177696d9a"] = "d02d422dcd7131e686d6532177696d9a.wav",
    ["d0ef52056e69de8890c17a16c8e0a5ac"] = "d0ef52056e69de8890c17a16c8e0a5ac.wav",
    ["d34171a9fbd911b8f1bf818f71cc3f32"] = "d34171a9fbd911b8f1bf818f71cc3f32.wav",
    ["d3820c153c571b0cfaad41a0a05ec90b"] = "d3820c153c571b0cfaad41a0a05ec90b.wav",
    ["d607877befae4fc8560330345158b290"] = "d607877befae4fc8560330345158b290.wav",
    ["d8e60ce5ca29731c4ca9356a1d489a59"] = "d8e60ce5ca29731c4ca9356a1d489a59.wav",
    ["db0fd82a2e87168de7f37ba74147a476"] = "db0fd82a2e87168de7f37ba74147a476.wav",
    ["db570f1f51f6fd3b1a42e5953bafd049"] = "db570f1f51f6fd3b1a42e5953bafd049.wav",
    ["dcf21ea6bba24a55d9157c1f031d42ef"] = "dcf21ea6bba24a55d9157c1f031d42ef.wav",
    ["de96efe8437890d30d0aff9e01f5f7cb"] = "de96efe8437890d30d0aff9e01f5f7cb.wav",
    ["e0280ea403de38a99d9f00704dc83cf8"] = "e0280ea403de38a99d9f00704dc83cf8.wav",
    ["e2581a659044cdbda9365b2fd7a22202"] = "e2581a659044cdbda9365b2fd7a22202.wav",
    ["e3a348a35882a9d1e3d9c86ff56b6bbe"] = "e3a348a35882a9d1e3d9c86ff56b6bbe.wav",
    ["e3a9bceac350c8d4521ba30052baa2de"] = "e3a9bceac350c8d4521ba30052baa2de.wav",
    ["e6aaf0a5e40d69ade99a9420f809af6e"] = "e6aaf0a5e40d69ade99a9420f809af6e.wav",
    ["e762061ba8bf75781dc6a8a400d88e13"] = "e762061ba8bf75781dc6a8a400d88e13.wav",
    ["e7b869503b0c9fc3c78fef1e53facf50"] = "e7b869503b0c9fc3c78fef1e53facf50.wav",
    ["ee11d419f725f323959cf1466840e61b"] = "ee11d419f725f323959cf1466840e61b.wav",
    ["ee80e28a58b1049bafc0e9b980b7a239"] = "ee80e28a58b1049bafc0e9b980b7a239.wav",
    ["ef38b09c14f46b5a8dcf5d782c630fd6"] = "ef38b09c14f46b5a8dcf5d782c630fd6.wav",
    ["efa6e9ddc589d11d0aeee639e21deb43"] = "efa6e9ddc589d11d0aeee639e21deb43.wav",
    ["f-1ad4fc3d07a7873ab9512c5aa3f5ce4f"] = "f-1ad4fc3d07a7873ab9512c5aa3f5ce4f.wav",
    ["f-386f37176e6f7b06d34487928a573d23"] = "f-386f37176e6f7b06d34487928a573d23.wav",
    ["f-4ef02a6cde5565b37e151274512c0641"] = "f-4ef02a6cde5565b37e151274512c0641.wav",
    ["f-6a6954aa23ff423b51b954fe09b144a8"] = "f-6a6954aa23ff423b51b954fe09b144a8.wav",
    ["f-6d836253374e7258f1d26abac7475d18"] = "f-6d836253374e7258f1d26abac7475d18.wav",
    ["f-ac0a0b581e16d91b9d2a09b564f6d6c3"] = "f-ac0a0b581e16d91b9d2a09b564f6d6c3.wav",
    ["f-c25da7aea73e13a714910fc2805f839f"] = "f-c25da7aea73e13a714910fc2805f839f.wav",
    ["f05de425d7bd02752037b8477cf01b53"] = "f05de425d7bd02752037b8477cf01b53.wav",
    ["f0c3fcd8e5d2ce42560cdd3636e4af9e"] = "f0c3fcd8e5d2ce42560cdd3636e4af9e.wav",
    ["f1bba8b8fe977e9469a2a2d8535cd5bc"] = "f1bba8b8fe977e9469a2a2d8535cd5bc.wav",
    ["f252a63ef02f49f36892505401561fee"] = "f252a63ef02f49f36892505401561fee.wav",
    ["f479d49557864313202d2081a17b0dc5"] = "f479d49557864313202d2081a17b0dc5.wav",
    ["f4d8e423146d1060237e65e944828604"] = "f4d8e423146d1060237e65e944828604.wav",
    ["f54d2505d254f8e348f3bd182ed879e7"] = "f54d2505d254f8e348f3bd182ed879e7.wav",
    ["f62abc611ce83aa205cd0e2b5918cc10"] = "f62abc611ce83aa205cd0e2b5918cc10.wav",
    ["f6c0c1ea475d9aa33d7c2f43bb8f2ba6"] = "f6c0c1ea475d9aa33d7c2f43bb8f2ba6.wav",
    ["f721840f336ebbf959238b5f76ad37ab"] = "f721840f336ebbf959238b5f76ad37ab.wav",
    ["f9ef4e04eea4de713fc61313fd8a4c8e"] = "f9ef4e04eea4de713fc61313fd8a4c8e.wav",
    ["fa856e726cbf60331453148913410f70"] = "fa856e726cbf60331453148913410f70.wav",
    ["fb677ed28551b5faa6955044aacc539b"] = "fb677ed28551b5faa6955044aacc539b.wav",
    ["fc64c85b44749257ced7e34a940a1c64"] = "fc64c85b44749257ced7e34a940a1c64.wav",
    ["fcb888f0ece4f405f7b532de65cab6d0"] = "fcb888f0ece4f405f7b532de65cab6d0.wav",
    ["fd10ddbf850f23ec3e5ca81dbb183556"] = "fd10ddbf850f23ec3e5ca81dbb183556.wav",
    ["fd6c52e798e64559f12964acfc65a412"] = "fd6c52e798e64559f12964acfc65a412.wav",
    ["fdaab9e2b8a9ef75ee889a83109b9758"] = "fdaab9e2b8a9ef75ee889a83109b9758.wav",
    ["ffcf7d3fc05ebc9a1303d2c59a697fcc"] = "ffcf7d3fc05ebc9a1303d2c59a697fcc.wav",
    ["m-501c83ee292da27782fae1e60bf7c3f3"] = "m-501c83ee292da27782fae1e60bf7c3f3.wav",
    ["m-5906a29765d2173d53b9ab776005d62b"] = "m-5906a29765d2173d53b9ab776005d62b.wav",
    ["m-719242cbbf2aa59d701d86713c8c3252"] = "m-719242cbbf2aa59d701d86713c8c3252.wav",
    ["m-8b3c666dc6e4c0c98f9d6747a2aea0f8"] = "m-8b3c666dc6e4c0c98f9d6747a2aea0f8.wav",
    ["m-8b65201c7f8e4fca254e87dde37a2d5b"] = "m-8b65201c7f8e4fca254e87dde37a2d5b.wav",
    ["m-f3c8a5a8b088f61349bd467d2e1e02b1"] = "m-f3c8a5a8b088f61349bd467d2e1e02b1.wav",
    -- quests
    ["1008-complete"] = "1008-complete.wav",
    ["1019-complete"] = "1019-complete.wav",
    ["1022-complete"] = "1022-complete.wav",
    ["1023-accept"] = "1023-accept.wav",
    ["1038-accept"] = "1038-accept.wav",
    ["1069-complete"] = "1069-complete.wav",
    ["1076-complete"] = "1076-complete.wav",
    ["1078-accept"] = "1078-accept.wav",
    ["1107-complete"] = "1107-complete.wav",
    ["1115-complete"] = "1115-complete.wav",
    ["1121-accept"] = "1121-accept.wav",
    ["11219-accept"] = "11219-accept.wav",
    ["1136-accept"] = "1136-accept.wav",
    ["1140-accept"] = "1140-accept.wav",
    ["1151-complete"] = "1151-complete.wav",
    ["116-complete"] = "116-complete.wav",
    ["1164-complete"] = "1164-complete.wav",
    ["1167-accept"] = "1167-accept.wav",
    ["1176-complete"] = "1176-complete.wav",
    ["1180-accept"] = "1180-accept.wav",
    ["119-accept"] = "119-accept.wav",
    ["1192-complete"] = "1192-complete.wav",
    ["1248-accept"] = "1248-accept.wav",
    ["1249-accept"] = "1249-accept.wav",
    ["1250-complete"] = "1250-complete.wav",
    ["1258-complete"] = "1258-complete.wav",
    ["126-complete"] = "126-complete.wav",
    ["1260-accept"] = "1260-accept.wav",
    ["1266-complete"] = "1266-complete.wav",
    ["1275-complete"] = "1275-complete.wav",
    ["128-accept"] = "128-accept.wav",
    ["1287-complete"] = "1287-complete.wav",
    ["1324-complete"] = "1324-complete.wav",
    ["133-accept"] = "133-accept.wav",
    ["1382-accept"] = "1382-accept.wav",
    ["1387-complete"] = "1387-complete.wav",
    ["1439-accept"] = "1439-accept.wav",
    ["144-accept"] = "144-accept.wav",
    ["1454-accept"] = "1454-accept.wav",
    ["1468-accept"] = "1468-accept.wav",
    ["1515-accept"] = "1515-accept.wav",
    ["1518-complete"] = "1518-complete.wav",
    ["1525-accept"] = "1525-accept.wav",
    ["1534-accept"] = "1534-accept.wav",
    ["1535-complete"] = "1535-complete.wav",
    ["1599-accept"] = "1599-accept.wav",
    ["166-accept"] = "166-accept.wav",
    ["1667-complete"] = "1667-complete.wav",
    ["168-accept"] = "168-accept.wav",
    ["1681-accept"] = "1681-accept.wav",
    ["1681-complete"] = "1681-complete.wav",
    ["1683-accept"] = "1683-accept.wav",
    ["1691-complete"] = "1691-complete.wav",
    ["1719-accept"] = "1719-accept.wav",
    ["172-accept"] = "172-accept.wav",
    ["176-complete"] = "176-complete.wav",
    ["1781-accept"] = "1781-accept.wav",
    ["180-complete"] = "180-complete.wav",
    ["1806-accept"] = "1806-accept.wav",
    ["181-accept"] = "181-accept.wav",
    ["1841-accept"] = "1841-accept.wav",
    ["1882-accept"] = "1882-accept.wav",
    ["1883-complete"] = "1883-complete.wav",
    ["190-accept"] = "190-accept.wav",
    ["197-accept"] = "197-accept.wav",
    ["20-complete"] = "20-complete.wav",
    ["2041-accept"] = "2041-accept.wav",
    ["2078-accept"] = "2078-accept.wav",
    ["2078-complete"] = "2078-complete.wav",
    ["210-complete"] = "210-complete.wav",
    ["2158-complete"] = "2158-complete.wav",
    ["22-accept"] = "22-accept.wav",
    ["2200-accept"] = "2200-accept.wav",
    ["2201-accept"] = "2201-accept.wav",
    ["2201-complete"] = "2201-complete.wav",
    ["2206-accept"] = "2206-accept.wav",
    ["222-accept"] = "222-accept.wav",
    ["2259-accept"] = "2259-accept.wav",
    ["2279-complete"] = "2279-complete.wav",
    ["2300-accept"] = "2300-accept.wav",
    ["2300-complete"] = "2300-complete.wav",
    ["231-accept"] = "231-accept.wav",
    ["2318-accept"] = "2318-accept.wav",
    ["2342-accept"] = "2342-accept.wav",
    ["2359-complete"] = "2359-complete.wav",
    ["236-accept"] = "236-accept.wav",
    ["2361-complete"] = "2361-complete.wav",
    ["2438-complete"] = "2438-complete.wav",
    ["2460-complete"] = "2460-complete.wav",
    ["2479-complete"] = "2479-complete.wav",
    ["2480-complete"] = "2480-complete.wav",
    ["2605-complete"] = "2605-complete.wav",
    ["261-accept"] = "261-accept.wav",
    ["2745-complete"] = "2745-complete.wav",
    ["2746-complete"] = "2746-complete.wav",
    ["2750-complete"] = "2750-complete.wav",
    ["2755-complete"] = "2755-complete.wav",
    ["2845-accept"] = "2845-accept.wav",
    ["2848-complete"] = "2848-complete.wav",
    ["2856-accept"] = "2856-accept.wav",
    ["288-complete"] = "288-complete.wav",
    ["2922-accept"] = "2922-accept.wav",
    ["2963-accept"] = "2963-accept.wav",
    ["297-complete"] = "297-complete.wav",
    ["2970-accept"] = "2970-accept.wav",
    ["2974-accept"] = "2974-accept.wav",
    ["3083-complete"] = "3083-complete.wav",
    ["3091-accept"] = "3091-accept.wav",
    ["3094-accept"] = "3094-accept.wav",
    ["3099-accept"] = "3099-accept.wav",
    ["3100-complete"] = "3100-complete.wav",
    ["3103-accept"] = "3103-accept.wav",
    ["3120-accept"] = "3120-accept.wav",
    ["3121-complete"] = "3121-complete.wav",
    ["3130-accept"] = "3130-accept.wav",
    ["3182-complete"] = "3182-complete.wav",
    ["320-accept"] = "320-accept.wav",
    ["322-complete"] = "322-complete.wav",
    ["3370-accept"] = "3370-accept.wav",
    ["34-accept"] = "34-accept.wav",
    ["3454-accept"] = "3454-accept.wav",
    ["3461-complete"] = "3461-complete.wav",
    ["348-complete"] = "348-complete.wav",
    ["3506-complete"] = "3506-complete.wav",
    ["3517-complete"] = "3517-complete.wav",
    ["353-complete"] = "353-complete.wav",
    ["3562-accept"] = "3562-accept.wav",
    ["357-complete"] = "357-complete.wav",
    ["3629-complete"] = "3629-complete.wav",
    ["3763-complete"] = "3763-complete.wav",
    ["3765-accept"] = "3765-accept.wav",
    ["381-complete"] = "381-complete.wav",
    ["3823-complete"] = "3823-complete.wav",
    ["383-accept"] = "383-accept.wav",
    ["3845-complete"] = "3845-complete.wav",
    ["3881-accept"] = "3881-accept.wav",
    ["3881-complete"] = "3881-complete.wav",
    ["389-accept"] = "389-accept.wav",
    ["3912-complete"] = "3912-complete.wav",
    ["3921-complete"] = "3921-complete.wav",
    ["398-complete"] = "398-complete.wav",
    ["4002-complete"] = "4002-complete.wav",
    ["4041-complete"] = "4041-complete.wav",
    ["4061-accept"] = "4061-accept.wav",
    ["4132-complete"] = "4132-complete.wav",
    ["4144-complete"] = "4144-complete.wav",
    ["416-complete"] = "416-complete.wav",
    ["417-complete"] = "417-complete.wav",
    ["4185-complete"] = "4185-complete.wav",
    ["4186-complete"] = "4186-complete.wav",
    ["420-accept"] = "420-accept.wav",
    ["420-complete"] = "420-complete.wav",
    ["4223-accept"] = "4223-accept.wav",
    ["426-complete"] = "426-complete.wav",
    ["4261-complete"] = "4261-complete.wav",
    ["4266-accept"] = "4266-accept.wav",
    ["4285-accept"] = "4285-accept.wav",
    ["4289-accept"] = "4289-accept.wav",
    ["4322-accept"] = "4322-accept.wav",
    ["438-accept"] = "438-accept.wav",
    ["4402-complete"] = "4402-complete.wav",
    ["443-complete"] = "443-complete.wav",
    ["4503-accept"] = "4503-accept.wav",
    ["4505-complete"] = "4505-complete.wav",
    ["454-complete"] = "454-complete.wav",
    ["456-accept"] = "456-accept.wav",
    ["456-complete"] = "456-complete.wav",
    ["464-complete"] = "464-complete.wav",
    ["468-accept"] = "468-accept.wav",
    ["472-complete"] = "472-complete.wav",
    ["4722-complete"] = "4722-complete.wav",
    ["4738-complete"] = "4738-complete.wav",
    ["4782-complete"] = "4782-complete.wav",
    ["4786-accept"] = "4786-accept.wav",
    ["480-complete"] = "480-complete.wav",
    ["4842-accept"] = "4842-accept.wav",
    ["486-complete"] = "486-complete.wav",
    ["4865-complete"] = "4865-complete.wav",
    ["487-complete"] = "487-complete.wav",
    ["4967-accept"] = "4967-accept.wav",
    ["4971-accept"] = "4971-accept.wav",
    ["4976-accept"] = "4976-accept.wav",
    ["4981-complete"] = "4981-complete.wav",
    ["4983-accept"] = "4983-accept.wav",
    ["4987-complete"] = "4987-complete.wav",
    ["5048-complete"] = "5048-complete.wav",
    ["5055-accept"] = "5055-accept.wav",
    ["5055-complete"] = "5055-complete.wav",
    ["5061-accept"] = "5061-accept.wav",
    ["5061-complete"] = "5061-complete.wav",
    ["5084-accept"] = "5084-accept.wav",
    ["5092-complete"] = "5092-complete.wav",
    ["5097-complete"] = "5097-complete.wav",
    ["51-accept"] = "51-accept.wav",
    ["5102-complete"] = "5102-complete.wav",
    ["512-complete"] = "512-complete.wav",
    ["513-complete"] = "513-complete.wav",
    ["5141-accept"] = "5141-accept.wav",
    ["5141-complete"] = "5141-complete.wav",
    ["52-complete"] = "52-complete.wav",
    ["5203-accept"] = "5203-accept.wav",
    ["5210-complete"] = "5210-complete.wav",
    ["5214-complete"] = "5214-complete.wav",
    ["5229-accept"] = "5229-accept.wav",
    ["5231-accept"] = "5231-accept.wav",
    ["525-accept"] = "525-accept.wav",
    ["525-complete"] = "525-complete.wav",
    ["5263-complete"] = "5263-complete.wav",
    ["5264-complete"] = "5264-complete.wav",
    ["53-accept"] = "53-accept.wav",
    ["5302-complete"] = "5302-complete.wav",
    ["5305-accept"] = "5305-accept.wav",
    ["5384-accept"] = "5384-accept.wav",
    ["5385-accept"] = "5385-accept.wav",
    ["541-accept"] = "541-accept.wav",
    ["542-accept"] = "542-accept.wav",
    ["5466-accept"] = "5466-accept.wav",
    ["5526-accept"] = "5526-accept.wav",
    ["5536-accept"] = "5536-accept.wav",
    ["554-complete"] = "554-complete.wav",
    ["56-accept"] = "56-accept.wav",
    ["56-complete"] = "56-complete.wav",
    ["560-accept"] = "560-accept.wav",
    ["5641-complete"] = "5641-complete.wav",
    ["5646-accept"] = "5646-accept.wav",
    ["565-complete"] = "565-complete.wav",
    ["5654-complete"] = "5654-complete.wav",
    ["5656-complete"] = "5656-complete.wav",
    ["5663-accept"] = "5663-accept.wav",
    ["57-complete"] = "57-complete.wav",
    ["571-complete"] = "571-complete.wav",
    ["572-complete"] = "572-complete.wav",
    ["5781-accept"] = "5781-accept.wav",
    ["58-complete"] = "58-complete.wav",
    ["580-accept"] = "580-accept.wav",
    ["580-complete"] = "580-complete.wav",
    ["5845-complete"] = "5845-complete.wav",
    ["59-accept"] = "59-accept.wav",
    ["5902-accept"] = "5902-accept.wav",
    ["5903-accept"] = "5903-accept.wav",
    ["5921-accept"] = "5921-accept.wav",
    ["5929-accept"] = "5929-accept.wav",
    ["5932-accept"] = "5932-accept.wav",
    ["599-accept"] = "599-accept.wav",
    ["60-complete"] = "60-complete.wav",
    ["6004-accept"] = "6004-accept.wav",
    ["602-complete"] = "602-complete.wav",
    ["6025-accept"] = "6025-accept.wav",
    ["6042-complete"] = "6042-complete.wav",
    ["6070-accept"] = "6070-accept.wav",
    ["6083-accept"] = "6083-accept.wav",
    ["6101-complete"] = "6101-complete.wav",
    ["6122-accept"] = "6122-accept.wav",
    ["6128-accept"] = "6128-accept.wav",
    ["6129-accept"] = "6129-accept.wav",
    ["6129-complete"] = "6129-complete.wav",
    ["6141-accept"] = "6141-accept.wav",
    ["6147-complete"] = "6147-complete.wav",
    ["6185-complete"] = "6185-complete.wav",
    ["62-complete"] = "62-complete.wav",
    ["621-complete"] = "621-complete.wav",
    ["628-accept"] = "628-accept.wav",
    ["6283-complete"] = "6283-complete.wav",
    ["633-accept"] = "633-accept.wav",
    ["6361-accept"] = "6361-accept.wav",
    ["6364-complete"] = "6364-complete.wav",
    ["6382-accept"] = "6382-accept.wav",
    ["6384-complete"] = "6384-complete.wav",
    ["6388-complete"] = "6388-complete.wav",
    ["64-accept"] = "64-accept.wav",
    ["6402-accept"] = "6402-accept.wav",
    ["6548-accept"] = "6548-accept.wav",
    ["6568-complete"] = "6568-complete.wav",
    ["657-accept"] = "657-accept.wav",
    ["659-complete"] = "659-complete.wav",
    ["6605-complete"] = "6605-complete.wav",
    ["661-complete"] = "661-complete.wav",
    ["662-accept"] = "662-accept.wav",
    ["6627-complete"] = "6627-complete.wav",
    ["6643-complete"] = "6643-complete.wav",
    ["678-complete"] = "678-complete.wav",
    ["68-complete"] = "68-complete.wav",
    ["681-accept"] = "681-accept.wav",
    ["6826-complete"] = "6826-complete.wav",
    ["6827-complete"] = "6827-complete.wav",
    ["6984-complete"] = "6984-complete.wav",
    ["7022-accept"] = "7022-accept.wav",
    ["7023-accept"] = "7023-accept.wav",
    ["7170-complete"] = "7170-complete.wav",
    ["7281-complete"] = "7281-complete.wav",
    ["729-accept"] = "729-accept.wav",
    ["729-complete"] = "729-complete.wav",
    ["731-complete"] = "731-complete.wav",
    ["733-accept"] = "733-accept.wav",
    ["7463-accept"] = "7463-accept.wav",
    ["7485-accept"] = "7485-accept.wav",
    ["7492-complete"] = "7492-complete.wav",
    ["7496-complete"] = "7496-complete.wav",
    ["7541-complete"] = "7541-complete.wav",
    ["758-accept"] = "758-accept.wav",
    ["7583-complete"] = "7583-complete.wav",
    ["7625-complete"] = "7625-complete.wav",
    ["7627-complete"] = "7627-complete.wav",
    ["7630-complete"] = "7630-complete.wav",
    ["7640-complete"] = "7640-complete.wav",
    ["7642-complete"] = "7642-complete.wav",
    ["7645-complete"] = "7645-complete.wav",
    ["7647-accept"] = "7647-accept.wav",
    ["7668-complete"] = "7668-complete.wav",
    ["7731-accept"] = "7731-accept.wav",
    ["7733-accept"] = "7733-accept.wav",
    ["7733-complete"] = "7733-complete.wav",
    ["7789-accept"] = "7789-accept.wav",
    ["7798-complete"] = "7798-complete.wav",
    ["7803-complete"] = "7803-complete.wav",
    ["7825-complete"] = "7825-complete.wav",
    ["7827-complete"] = "7827-complete.wav",
    ["7831-complete"] = "7831-complete.wav",
    ["786-accept"] = "786-accept.wav",
    ["7885-complete"] = "7885-complete.wav",
    ["7889-complete"] = "7889-complete.wav",
    ["789-complete"] = "789-complete.wav",
    ["790-progress"] = "790-progress.wav",
    ["7925-complete"] = "7925-complete.wav",
    ["794-progress"] = "794-progress.wav",
    ["806-complete"] = "806-complete.wav",
    ["808-complete"] = "808-complete.wav",
    ["815-complete"] = "815-complete.wav",
    ["8156-accept"] = "8156-accept.wav",
    ["8158-complete"] = "8158-complete.wav",
    ["8165-accept"] = "8165-accept.wav",
    ["8168-accept"] = "8168-accept.wav",
    ["818-complete"] = "818-complete.wav",
    ["8181-accept"] = "8181-accept.wav",
    ["8182-accept"] = "8182-accept.wav",
    ["8233-accept"] = "8233-accept.wav",
    ["8276-complete"] = "8276-complete.wav",
    ["8283-complete"] = "8283-complete.wav",
    ["8284-complete"] = "8284-complete.wav",
    ["8286-complete"] = "8286-complete.wav",
    ["8306-complete"] = "8306-complete.wav",
    ["8310-complete"] = "8310-complete.wav",
    ["8320-accept"] = "8320-accept.wav",
    ["833-complete"] = "833-complete.wav",
    ["8331-accept"] = "8331-accept.wav",
    ["8359-complete"] = "8359-complete.wav",
    ["8361-complete"] = "8361-complete.wav",
    ["8364-complete"] = "8364-complete.wav",
    ["8388-complete"] = "8388-complete.wav",
    ["8398-accept"] = "8398-accept.wav",
    ["8400-accept"] = "8400-accept.wav",
    ["8419-accept"] = "8419-accept.wav",
    ["8437-accept"] = "8437-accept.wav",
    ["8442-accept"] = "8442-accept.wav",
    ["8443-accept"] = "8443-accept.wav",
    ["845-accept"] = "845-accept.wav",
    ["849-accept"] = "849-accept.wav",
    ["8509-complete"] = "8509-complete.wav",
    ["8527-complete"] = "8527-complete.wav",
    ["853-complete"] = "853-complete.wav",
    ["8548-accept"] = "8548-accept.wav",
    ["8549-accept"] = "8549-accept.wav",
    ["8556-complete"] = "8556-complete.wav",
    ["8569-complete"] = "8569-complete.wav",
    ["8578-complete"] = "8578-complete.wav",
    ["8583-accept"] = "8583-accept.wav",
    ["8584-complete"] = "8584-complete.wav",
    ["8586-complete"] = "8586-complete.wav",
    ["86-complete"] = "86-complete.wav",
    ["860-accept"] = "860-accept.wav",
    ["8605-complete"] = "8605-complete.wav",
    ["8608-accept"] = "8608-accept.wav",
    ["8614-complete"] = "8614-complete.wav",
    ["8621-accept"] = "8621-accept.wav",
    ["8624-complete"] = "8624-complete.wav",
    ["8630-complete"] = "8630-complete.wav",
    ["8631-accept"] = "8631-accept.wav",
    ["8632-accept"] = "8632-accept.wav",
    ["8634-accept"] = "8634-accept.wav",
    ["8638-accept"] = "8638-accept.wav",
    ["865-accept"] = "865-accept.wav",
    ["8655-complete"] = "8655-complete.wav",
    ["8666-accept"] = "8666-accept.wav",
    ["8668-accept"] = "8668-accept.wav",
    ["8672-complete"] = "8672-complete.wav",
    ["8679-complete"] = "8679-complete.wav",
    ["8680-complete"] = "8680-complete.wav",
    ["869-accept"] = "869-accept.wav",
    ["8701-complete"] = "8701-complete.wav",
    ["8703-complete"] = "8703-complete.wav",
    ["8706-complete"] = "8706-complete.wav",
    ["8740-complete"] = "8740-complete.wav",
    ["8746-complete"] = "8746-complete.wav",
    ["8771-complete"] = "8771-complete.wav",
    ["8776-complete"] = "8776-complete.wav",
    ["8789-complete"] = "8789-complete.wav",
    ["8790-accept"] = "8790-accept.wav",
    ["8792-complete"] = "8792-complete.wav",
    ["880-accept"] = "880-accept.wav",
    ["8824-complete"] = "8824-complete.wav",
    ["8827-complete"] = "8827-complete.wav",
    ["8837-complete"] = "8837-complete.wav",
    ["8848-complete"] = "8848-complete.wav",
    ["887-complete"] = "887-complete.wav",
    ["8899-complete"] = "8899-complete.wav",
    ["8902-complete"] = "8902-complete.wav",
    ["8904-complete"] = "8904-complete.wav",
    ["8911-complete"] = "8911-complete.wav",
    ["8914-accept"] = "8914-accept.wav",
    ["8918-complete"] = "8918-complete.wav",
    ["8925-accept"] = "8925-accept.wav",
    ["8928-complete"] = "8928-complete.wav",
    ["8929-accept"] = "8929-accept.wav",
    ["8930-complete"] = "8930-complete.wav",
    ["8931-accept"] = "8931-accept.wav",
    ["8932-accept"] = "8932-accept.wav",
    ["8950-complete"] = "8950-complete.wav",
    ["8958-accept"] = "8958-accept.wav",
    ["8962-accept"] = "8962-accept.wav",
    ["8963-accept"] = "8963-accept.wav",
    ["8967-accept"] = "8967-accept.wav",
    ["8977-complete"] = "8977-complete.wav",
    ["8985-complete"] = "8985-complete.wav",
    ["8990-accept"] = "8990-accept.wav",
    ["8995-accept"] = "8995-accept.wav",
    ["8999-complete"] = "8999-complete.wav",
    ["9004-complete"] = "9004-complete.wav",
    ["9007-complete"] = "9007-complete.wav",
    ["9012-complete"] = "9012-complete.wav",
    ["9022-complete"] = "9022-complete.wav",
    ["9025-complete"] = "9025-complete.wav",
    ["9047-complete"] = "9047-complete.wav",
    ["9054-accept"] = "9054-accept.wav",
    ["9058-complete"] = "9058-complete.wav",
    ["9071-complete"] = "9071-complete.wav",
    ["9072-accept"] = "9072-accept.wav",
    ["9073-complete"] = "9073-complete.wav",
    ["9080-accept"] = "9080-accept.wav",
    ["9080-complete"] = "9080-complete.wav",
    ["9090-accept"] = "9090-accept.wav",
    ["9096-complete"] = "9096-complete.wav",
    ["9102-accept"] = "9102-accept.wav",
    ["9103-complete"] = "9103-complete.wav",
    ["9108-accept"] = "9108-accept.wav",
    ["9110-accept"] = "9110-accept.wav",
    ["9115-complete"] = "9115-complete.wav",
    ["9121-complete"] = "9121-complete.wav",
    ["9128-accept"] = "9128-accept.wav",
    ["916-accept"] = "916-accept.wav",
    ["9201-complete"] = "9201-complete.wav",
    ["9221-accept"] = "9221-accept.wav",
    ["9222-accept"] = "9222-accept.wav",
    ["9228-accept"] = "9228-accept.wav",
    ["9230-accept"] = "9230-accept.wav",
    ["9236-accept"] = "9236-accept.wav",
    ["9239-accept"] = "9239-accept.wav",
    ["9245-complete"] = "9245-complete.wav",
    ["9246-accept"] = "9246-accept.wav",
    ["9246-complete"] = "9246-complete.wav",
    ["9262-complete"] = "9262-complete.wav",
    ["928-accept"] = "928-accept.wav",
    ["928-complete"] = "928-complete.wav",
    ["9295-complete"] = "9295-complete.wav",
    ["93-accept"] = "93-accept.wav",
    ["934-complete"] = "934-complete.wav",
    ["9341-complete"] = "9341-complete.wav",
    ["935-complete"] = "935-complete.wav",
    ["9415-accept"] = "9415-accept.wav",
    ["9416-accept"] = "9416-accept.wav",
    ["9416-complete"] = "9416-complete.wav",
    ["962-accept"] = "962-accept.wav",
    ["969-complete"] = "969-complete.wav",
    ["970-accept"] = "970-accept.wav",
    ["972-complete"] = "972-complete.wav",
    ["977-complete"] = "977-complete.wav",
    ["978-complete"] = "978-complete.wav",
    ["979-complete"] = "979-complete.wav",
    ["985-accept"] = "985-accept.wav",
    ["994-complete"] = "994-complete.wav",
    ["f-1783-complete"] = "f-1783-complete.wav",
    ["f-2981-accept"] = "f-2981-accept.wav",
    ["f-4295-complete"] = "f-4295-complete.wav",
    ["f-463-accept"] = "f-463-accept.wav",
    ["f-5508-complete"] = "f-5508-complete.wav",
    ["f-7123-complete"] = "f-7123-complete.wav",
    ["f-7940-complete"] = "f-7940-complete.wav",
    ["f-8359-accept"] = "f-8359-accept.wav",
    ["f-8514-complete"] = "f-8514-complete.wav",
    ["f-8797-complete"] = "f-8797-complete.wav",
    ["f-8801-complete"] = "f-8801-complete.wav",
    ["f-8859-complete"] = "f-8859-complete.wav",
    ["m-1222-accept"] = "m-1222-accept.wav",
    ["m-1649-complete"] = "m-1649-complete.wav",
    ["m-1661-accept"] = "m-1661-accept.wav",
    ["m-196-complete"] = "m-196-complete.wav",
    ["m-337-complete"] = "m-337-complete.wav",
    ["m-400-complete"] = "m-400-complete.wav",
    ["m-7622-complete"] = "m-7622-complete.wav",
    ["m-7933-complete"] = "m-7933-complete.wav",
    ["m-7934-complete"] = "m-7934-complete.wav",
    ["m-7940-complete"] = "m-7940-complete.wav",
    ["m-8359-accept"] = "m-8359-accept.wav",
    ["m-8366-complete"] = "m-8366-complete.wav",
    ["m-8795-complete"] = "m-8795-complete.wav",
    ["m-8857-complete"] = "m-8857-complete.wav",
    ["m-9267-complete"] = "m-9267-complete.wav",
}

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
        -- QuestEcho's own voice volume multiplier, applied per file at play
        -- time. Independent of the game's MasterVolume/SoundVolume sliders:
        -- changing this only affects voice lines, not combat or other sounds.
        -- 1.0 = no change; range 0.25 - 3.0 in 0.25 steps.
        VoiceVolume = 1.0,
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

-- Deferred play state: a voice-volume-scaled line must wait one beat before
-- PlaySoundFile so the client (which applies CVar changes on its own frame)
-- actually plays at the scaled volume. Same reasoning as the gossip mute
-- window — scaling and starting the file in the same Lua frame never lands.
Utils.voiceDeferred = nil

function Utils:DeferPlay(soundData, delay)
    self:CancelDeferred()
    local f = CreateFrame("Frame")
    local start = GetTime()
    local svc = self
    f:SetScript("OnUpdate", function()
        if GetTime() - start < delay then
            return
        end
        f:SetScript("OnUpdate", nil)
        f:Hide()
        local pending = svc.voiceDeferred
        if pending and pending.soundData == soundData then
            svc.voiceDeferred = nil
        end
        local ok = pcall(PlaySoundFile, soundData.filePath)
        Debug:Print("play %s (deferred) -> %s path=%s vol=%s/%s", tostring(soundData.fileName or "?"), tostring(ok), tostring(soundData.filePath or "?"), tostring(GetCVar("MasterVolume")), tostring(GetCVar("SoundVolume")))
    end)
    self.voiceDeferred = { frame = f, soundData = soundData }
    f:Show()
end

function Utils:CancelDeferred()
    if self.voiceDeferred then
        local pending = self.voiceDeferred
        self.voiceDeferred = nil
        pcall(pending.frame.SetScript, pending.frame, "OnUpdate", nil)
        pcall(pending.frame.Hide, pending.frame)
    end
end

function Utils:PlaySound(soundData)
    if not soundData.filePath then
        return false
    end
    -- bring the volume back before our file starts (a previous stop or the
    -- gossip mute may have muted everything)
    self:RestoreSoundSettings()
    -- QuestEcho's own voice volume multiplier. This client's PlaySoundFile
    -- has no per-file volume argument (its 2nd arg is a channel name like
    -- "Master"), so the multiplier is applied by scaling the game's volume
    -- CVars for the duration of this file; the queue restores the baseline
    -- once the line ends (PlayNextSound / mute restore). VoiceVolume is
    -- independent of the game sliders (it never changes them permanently).
    local vol = Addon.db.profile.VoiceVolume or 1
    if vol and vol ~= 1 then
        local base = self:GetBaselineSoundSettings()
        for _, name in ipairs(self.SOUND_CVARS) do
            local bv = base and base[name] and tonumber(base[name]) or 1
            if bv and bv > 0 then
                -- No clamp to 1: if the player's game volume is already at
                -- the top, a >1 multiplier would otherwise never change
                -- anything. This client's CVars tolerate over-1 values; a
                -- client that clamps simply caps the effect at the top.
                local scaled = bv * vol
                pcall(SetCVar, name, scaled)
            end
        end
        -- The client applies CVar changes on its own frame, so a file started
        -- in the same frame would play at the old volume. Defer the actual
        -- PlaySoundFile until the scale has landed.
        soundData._deferred = 0.3
        self:DeferPlay(soundData, soundData._deferred)
        return true
    end
    soundData._deferred = nil
    local ok = pcall(PlaySoundFile, soundData.filePath)
    Debug:Print("play %s -> %s path=%s vol=%s/%s voice=%.2f", tostring(soundData.fileName or "?"), tostring(ok), tostring(soundData.filePath or "?"), tostring(GetCVar("MasterVolume")), tostring(GetCVar("SoundVolume")), vol or 1)
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
function DataModules:Register(name, module, addonNameOverride)
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
            AddonName = addonNameOverride or name,
            LoadOnDemand = false,
            ModuleVersion = 1,
            ModulePriority = 0,
            ContentVersion = nil,
            Title = name,
            Maps = {},
        }
        self.presentModules[name] = metadata
        table.insert(self.presentModulesOrdered, metadata)
    elseif addonNameOverride and metadata.AddonName ~= addonNameOverride then
        -- The data pack directory may differ from the registered module name
        -- (e.g. QuestEchoData-zhCN registers as QuestEchoData). The sound path
        -- is built from AddonName, so point it at the real directory.
        metadata.AddonName = addonNameOverride
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
                -- WAV override: a few ogg files hang the client's ogg decoder;
                -- the data pack ships those as .wav and we play them instead.
                local overrideName = QuestEcho.WavOverride[soundData.fileName] or
                    QuestEcho.WavOverride[soundData.fileName:gsub("_[mf]$", "")]
                if overrideName then
                    soundData.filePath = soundData.filePath:gsub("[^/\\]+$", overrideName)
                end
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

-- How long to keep everything muted after a line is removed before the next
-- line starts. The client applies CVar changes on its own frame, so an
-- immediate restore in the same frame would never mute (and the removed
-- sound would keep playing under the next one). The priority preempts
-- (PlayPriority / PlayPriorityKeep) use the same buffer: the mute needs a
-- beat to actually stop the old file before the new line starts, otherwise
-- both files play together.
local SOUND_SWITCH_BUFFER = 0.25

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
        self.gossipRestored = nil
        self.gossipRestoreAt = nil
    end
    -- a volume-deferred line must not start after it is pre-empted
    Utils:CancelDeferred()
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
    return true
end

--- Play a line with priority, but keep every line that was already playing or
--- queued: stop the current line and move it to the BACK of the queue (so it
--- resumes after the priority line), leave queued gossip alone, and start the
--- new line immediately. Used when the player opens a quest detail (accept)
--- window while other voices are playing — the quest the player is looking at
--- gets to go first, nothing is lost.
function SoundQueue:PlayPriorityKeep(soundData)
    -- resolve filePath/length exactly like AddSoundToQueue does
    if not DataModules:PrepareSound(soundData) then
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

    -- a line is currently playing: stop it and re-queue it at the back
    if self.current then
        local deferred = self.current
        local length = deferred.length
        local startedAt = deferred.startedAt
        -- a volume-deferred line must not start after it is pre-empted
        Utils:CancelDeferred()
        Utils:StopSound(deferred)
        self.current = nil
        self.nextSoundAt = nil
        if self.gossipPending then
            self.gossipPending = nil
            self.gossipRestored = nil
            self.gossipRestoreAt = nil
        end
        -- keep the mute on long enough that the client actually stops the old
        -- file (CVar changes apply on its own frame); an immediate restore
        -- would let the deferred line keep playing under the priority one.
        self:ScheduleMuteRestore(length, startedAt)
        table.insert(self.sounds, deferred)
        -- let the mute take effect before the priority line starts
        self.pendingNextAt = GetTime() + SOUND_SWITCH_BUFFER
    end

    -- insert the priority line at the front and start it immediately
    self.soundIdCounter = self.soundIdCounter + 1
    soundData.id = self.soundIdCounter
    table.insert(self.sounds, 1, soundData)
    -- If a previous line was playing we defer the start by SOUND_SWITCH_BUFFER
    -- (handled in OnUpdate via pendingNextAt); otherwise start right away.
    if not self.pendingNextAt then
        self:PlayNextSound()
    end
    SoundQueueUI:Update()
    return true
end

function SoundQueue:PlayNextSound()
    local soundData = self.sounds[1]
    if not soundData then
        -- queue is empty: bring the player's own volume settings back (a
        -- VoiceVolume scale may be active on the just-finished line) and
        -- refresh the UI so the "playing" row disappears
        Utils:RestoreSoundSettings()
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
        self.gossipRestored = nil
        self.gossipRestoreAt = GetTime() + 0.15
        SoundQueueUI:Update()
        return
    end

    Utils:PlaySound(soundData)
    self.nextSoundAt = GetTime() + (soundData.delay or 0) + (soundData.length or 0) + 0.5 + (soundData._deferred or 0)
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
        -- wav playback honors the mute CVars more than ogg does: restore the
        -- volume, then wait one more beat so the client's audio engine has
        -- actually left the muted state before the file starts.
        if not self.gossipRestored and soundData.filePath and soundData.filePath:find("%.wav$", 1) then
            self.gossipRestored = true
            Utils:RestoreSoundSettings()
            self.gossipRestoreAt = GetTime() + 0.3
            return
        end
        self.gossipPending = nil
        self.gossipRestored = nil
        self.gossipRestoreAt = nil
        if not Addon.db.char.IsPaused then
            Utils:PlaySound(soundData)
            self.nextSoundAt = GetTime() + (soundData.delay or 0) + (soundData.length or 0) + 0.5 + (soundData._deferred or 0)
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
    -- a volume-deferred line must not start after the pause
    Utils:CancelDeferred()
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
        self.current.startedAt = GetTime()
        self.nextSoundAt = GetTime() + (self.current.delay or 0) + (self.current.length or 0) + 0.5 + (self.current._deferred or 0)
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
    -- a volume-deferred line must not start after the queue is cleared
    Utils:CancelDeferred()
    if self.gossipPending then
        self.gossipPending = nil
        self.gossipRestored = nil
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
function SoundQueue:RemoveSound(id)
    if self.current and self.current.id == id then
        Utils:CancelDeferred()
        Utils:StopSound(self.current)
        local length = self.current.length
        local startedAt = self.current.startedAt
        self.current = nil
        self.nextSoundAt = nil
        if self.gossipPending then
            self.gossipPending = nil
            self.gossipRestored = nil
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

-- Vanilla WoW palette: near-black panels, bright-gold trim, blue-grey
-- UIPanelButton gradient face, yellow titles with black shadow. Every look
-- is drawn from solid-color textures because this client's pak has no
-- WoW-style Interface texture files. Values sampled from the client's own
-- quest-log chrome: enabled buttons are red with gold labels (like the
-- native Exit button), disabled buttons are grey (like Share Quest).
local UI_GOLD_BRIGHT  = { 0.863, 0.667, 0.361 }  -- hover gold, 220,170,92
local UI_GOLD_DARK    = { 0.420, 0.353, 0.180 }
local UI_GOLD_TEXT    = { 0.957, 0.745, 0.427 }  -- titles/icons, 244,190,109
local UI_FRAME_BORDER = { 0.780, 0.780, 0.780 }  -- window frame trim, silver
local UI_RED_TOP      = { 0.380, 0.031, 0.031 }  -- native Exit face
local UI_RED_MID      = { 0.353, 0.024, 0.024 }
local UI_RED_DARK     = { 0.298, 0.016, 0.016 }
local UI_RED_BOTTOM   = { 0.341, 0.024, 0.024 }
local UI_RED_BORDER   = { 0.184, 0.161, 0.149 }  -- dark red-black trim
local UI_RED_HILIGHT  = { 0.337, 0.337, 0.337 }  -- inner top highlight
local UI_GREY_TOP     = { 0.192, 0.192, 0.184 }  -- disabled Share Quest face
local UI_GREY_MID     = { 0.161, 0.161, 0.161 }
local UI_GREY_DARK    = { 0.133, 0.133, 0.133 }
local UI_GREY_BOTTOM  = { 0.180, 0.180, 0.180 }
local UI_GREY_BORDER  = { 0.184, 0.188, 0.169 }
local UI_GREY_HILIGHT = { 0.337, 0.337, 0.337 }
local UI_GREEN_TOP    = { 0.310, 0.878, 0.310 }
local UI_GREEN_MID    = { 0.220, 0.690, 0.220 }
local UI_GREEN_DARK   = { 0.160, 0.520, 0.160 }
local UI_GREEN_BOTTOM = { 0.059, 0.541, 0.059 }
local UI_PANEL_TOP    = { 0.051, 0.051, 0.059 }
local UI_PANEL_BOTTOM = { 0.020, 0.020, 0.020 }

--- Fill a frame with horizontal gradient bands (approximated with stacked
--- solid-color textures). stops: {{frac, r,g,b}, ...} top-to-bottom, the
--- fracs must sum to 1. Textures are collected on parent._gradTex so a
--- caller can re-tint the gradient later (SetButtonStyle).
local function GradientFill(parent, w, h, layer, stops)
    local acc = 0
    for _, stop in ipairs(stops) do
        local tex = parent:CreateTexture(nil, layer)
        tex:SetTexture(stop[2], stop[3], stop[4], 1)
        -- Anchor the band between two opposite corners of the parent:
        -- TOPLEFT at the parent's left edge and BOTTOMRIGHT at the parent's
        -- right edge (x = w), so the band spans the full parent width.
        tex:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -acc * h)
        tex:SetPoint("BOTTOMRIGHT", parent, "TOPLEFT", w, -(acc + stop[1]) * h)
        acc = acc + stop[1]
        if parent._gradTex then
            table.insert(parent._gradTex, tex)
        end
    end
end

local function ButtonPalette(style)
    if style == "red" then
        return UI_RED_TOP, UI_RED_MID, UI_RED_DARK, UI_RED_BOTTOM, UI_RED_BORDER, UI_RED_HILIGHT
    elseif style == "grey" then
        return UI_GREY_TOP, UI_GREY_MID, UI_GREY_DARK, UI_GREY_BOTTOM, UI_GREY_BORDER, UI_GREY_HILIGHT
    elseif style == "green" then
        return UI_GREEN_TOP, UI_GREEN_MID, UI_GREEN_DARK, UI_GREEN_BOTTOM, UI_GREY_BORDER, UI_GREEN_TOP
    elseif style == "gold" then
        -- selected state: red face with the bright gold trim + grey hilight
        return UI_RED_TOP, UI_RED_MID, UI_RED_DARK, UI_RED_BOTTOM, UI_GOLD_BRIGHT, UI_RED_HILIGHT
    end
    -- Default: enabled native buttons are red with gold labels (Exit style).
    return UI_RED_TOP, UI_RED_MID, UI_RED_DARK, UI_RED_BOTTOM, UI_RED_BORDER, UI_RED_HILIGHT
end

--- WoW UIPanelButton look: red/grey gradient face, dark outer trim with a
--- bright inner bevel (1px) and a 2px top highlight, like native buttons.
local function MakeWowButtonBackdrop(button, w, h, style)
    button._gradTex = {}
    local top, mid, dark, bottom, border, hilight = ButtonPalette(style)
    GradientFill(button, w, h, "BACKGROUND", {
        { 0.50, top[1], top[2], top[3] },
        { 0.15, mid[1], mid[2], mid[3] },
        { 0.15, dark[1], dark[2], dark[3] },
        { 0.20, bottom[1], bottom[2], bottom[3] },
    })
    button._gradColors = { top, mid, dark, bottom }
    button._gradBorder = border
    local b1 = EdgeTexture(button, 0, 0, w, 1, border)
    EdgeTexture(button, 0, h - 1, w, h, border)
    EdgeTexture(button, 0, 0, 1, h, border)
    EdgeTexture(button, w - 1, 0, w, h, border)
    button._gradBorderTex = b1
    -- native buttons keep the dark trim with a bright top band only (no
    -- silver rim around the whole button)
    EdgeTexture(button, 1, 1, w - 1, 3, hilight)
    -- chamfered corners: 2px dark notches, like the native UIPanelButton
    -- corner bevel (this client can only draw solid rectangles)
    local notch = { 0.02, 0.02, 0.02 }
    EdgeTexture(button, 0, 0, 2, 2, notch)
    EdgeTexture(button, w - 2, 0, w, 2, notch)
    EdgeTexture(button, 0, h - 2, 2, h, notch)
    EdgeTexture(button, w - 2, h - 2, w, h, notch)
    return button
end

--- Re-tint an existing UIPanelButton (settings panel uses this to show the
--- active gossip-frequency choice in green).
local function SetButtonStyle(button, style)
    local top, mid, dark, bottom, border = ButtonPalette(style)
    local texes = button._gradTex
    if texes then
        local targets = { top, mid, dark, bottom }
        for i, tex in ipairs(texes) do
            local t = targets[i] or bottom
            pcall(tex.SetTexture, tex, t[1], t[2], t[3], 1)
        end
    end
    if button._gradBorderTex then
        pcall(button._gradBorderTex.SetTexture, button._gradBorderTex, border[1], border[2], border[3], 1)
    end
    button._gradColors = { top, mid, dark, bottom }
    button._gradBorder = border
end

--- Opaque WoW-style panel backdrop for a fixed-size frame (settings panel):
--- near-black gradient fill, bright-gold outer trim, inner gold line and
--- corner studs.
local function ApplyClassicBackdrop(frame, width, height)
    GradientFill(frame, width, height, "BACKGROUND", {
        { 0.55, UI_PANEL_TOP[1], UI_PANEL_TOP[2], UI_PANEL_TOP[3] },
        { 0.45, UI_PANEL_BOTTOM[1], UI_PANEL_BOTTOM[2], UI_PANEL_BOTTOM[3] },
    })
    EdgeTexture(frame, 0, 0, width, 1, UI_FRAME_BORDER)
    EdgeTexture(frame, 0, height - 1, width, height, UI_FRAME_BORDER)
    EdgeTexture(frame, 0, 0, 1, height, UI_FRAME_BORDER)
    EdgeTexture(frame, width - 1, 0, width, height, UI_FRAME_BORDER)
    -- dark slot between the outer gold and the inner gold line
    EdgeTexture(frame, 1, 1, width - 1, 2, UI_PANEL_BOTTOM)
    EdgeTexture(frame, 1, height - 2, width - 1, height - 1, UI_PANEL_BOTTOM)
    EdgeTexture(frame, 1, 1, 2, height - 1, UI_PANEL_BOTTOM)
    EdgeTexture(frame, width - 2, 1, width - 1, height - 1, UI_PANEL_BOTTOM)
    EdgeTexture(frame, 2, 2, width - 2, 3, UI_GOLD_DARK)
    EdgeTexture(frame, 2, height - 3, width - 2, height - 2, UI_GOLD_DARK)
    EdgeTexture(frame, 2, 2, 3, height - 2, UI_GOLD_DARK)
    EdgeTexture(frame, width - 3, 2, width - 2, height - 2, UI_GOLD_DARK)
    -- corner studs removed: user wants the plain native look (outer gold
    -- border only, no corner ornaments)
end

--- WoW-style panel backdrop whose border follows a resizing frame (status
--- bar): near-black fill with a slightly lighter 24px top band, bright-gold
--- outer trim. NOTE: this client renders 1px lines badly when they are
--- anchored with two points (TOPLEFT+BOTTOMRIGHT/TOPRIGHT) — they get
--- stretched into big solid patches — so the border lines are single-point
--- anchored and their size is refreshed on frame resize via OnUpdate.
local function ApplyClassicBackdropResizable(frame)
    local fill = frame:CreateTexture(nil, "BACKGROUND")
    fill:SetTexture(UI_PANEL_BOTTOM[1], UI_PANEL_BOTTOM[2], UI_PANEL_BOTTOM[3], 1)
    fill:SetAllPoints()
    local band = frame:CreateTexture(nil, "BACKGROUND")
    band:SetTexture(UI_PANEL_TOP[1], UI_PANEL_TOP[2], UI_PANEL_TOP[3], 1)
    band:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    band:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, -24)
    local function EdgeLine(anchorPoint, w, h)
        local tex = frame:CreateTexture(nil, "BORDER")
        tex:SetTexture(UI_FRAME_BORDER[1], UI_FRAME_BORDER[2], UI_FRAME_BORDER[3], 1)
        tex:SetPoint(anchorPoint, frame, anchorPoint, 0, 0)
        tex:SetWidth(w)
        tex:SetHeight(h)
        return tex
    end
    local topL = EdgeLine("TOPLEFT", 0, 1)
    local botL = EdgeLine("BOTTOMLEFT", 0, 1)
    local lefL = EdgeLine("TOPLEFT", 1, 0)
    local rigL = EdgeLine("TOPRIGHT", 1, 0)
    local lastW, lastH = -1, -1
    local prevOnUpdate = frame:GetScript("OnUpdate")
    frame:SetScript("OnUpdate", function(self, elapsed)
        local w = frame:GetWidth()
        local h = frame:GetHeight()
        if (w or 0) < 10 then
            w = 320
        end
        if (h or 0) < 10 then
            h = 40
        end
        if w ~= lastW or h ~= lastH then
            lastW, lastH = w, h
            topL:SetWidth(w)
            botL:SetWidth(w)
            lefL:SetHeight(h)
            rigL:SetHeight(h)
        end
        if prevOnUpdate then
            prevOnUpdate(self, elapsed)
        end
    end)
end

--- Small WoW UIPanelButton-style button face (blue-grey).
local function MakeButtonBackdrop(button, w, h)
    return MakeWowButtonBackdrop(button, w, h, "blue")
end

--- WoW hover + press feedback for our buttons. Vertex-colour modulation is
--- not honoured by this client, so the hover/press tint is applied by
--- re-SetTexture-ing the face gradient colours (SetTexture is reliable here).
--- Hover brightens the face and lights the border gold like native buttons;
--- press darkens the face.
local function AddButtonFeedback(button, withHover)
    if not button then
        return
    end
    local function TintFace(factor)
        local colors = button._gradColors
        local texes = button._gradTex
        if not colors or not texes then
            return
        end
        for i, tex in ipairs(texes) do
            local c = colors[i] or colors[#colors]
            pcall(tex.SetTexture, tex,
                math.min(c[1] * factor, 1),
                math.min(c[2] * factor, 1),
                math.min(c[3] * factor, 1), 1)
        end
    end
    local function TintBorder(r, g, b)
        if button._gradBorderTex then
            pcall(button._gradBorderTex.SetTexture, button._gradBorderTex, r, g, b, 1)
        end
    end
    local function ResetBorder()
        local b = button._gradBorder
        if b then
            TintBorder(b[1], b[2], b[3])
        end
    end
    local function Hover()
        TintFace(1.3)
        TintBorder(UI_GOLD_BRIGHT[1], UI_GOLD_BRIGHT[2], UI_GOLD_BRIGHT[3])
    end
    local function Press()
        TintFace(0.7)
        ResetBorder()
    end
    local function Normal()
        TintFace(button._pressedFlag and 0.6 or 1)
        ResetBorder()
    end
    if withHover ~= false then
        pcall(button.SetScript, button, "OnEnter", Hover)
        pcall(button.SetScript, button, "OnLeave", Normal)
    end
    pcall(button.SetScript, button, "OnMouseDown", Press)
    pcall(button.SetScript, button, "OnMouseUp", Normal)
end

--- AllBags-style stock button: tries the native UIPanelButtonTemplate first
--- (named frame — the client needs a name for the template to take), falls
--- back to the exact plain build AllBags uses (button SetFont/SetTextColor +
--- tooltip backdrop + square highlight). Text is set through the button, so
--- the template's own FontString draws it like the quest-log buttons.
local stockBtnSeq = 0
local function MakeStockButton(parent, text, width, onClick, height)
    local h = height or 18
    stockBtnSeq = stockBtnSeq + 1
    local name = "QuestEchoStockBtn" .. stockBtnSeq
    local ok, made = pcall(CreateFrame, "Button", name, parent, "UIPanelButtonTemplate")
    local button = ok and made or nil
    if not button then
        -- plain build, AllBags fallback
        button = CreateFrame("Button", name, parent)
        button:SetWidth(width)
        button:SetHeight(math.max(h, 17))
        pcall(button.SetFont, button, "Fonts\\FRIZQT__.TTF", 11)
        pcall(button.SetTextColor, button, 1, 0.82, 0)
        pcall(function()
            button:SetBackdrop({
                bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tileSize = 16, edgeSize = 10,
                insets   = { left = 2, right = 2, top = 2, bottom = 2 },
            })
            button:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
            button:SetBackdropBorderColor(0.45, 0.45, 0.45, 0.9)
        end)
        pcall(button.SetHighlightTexture, button, "Interface\\Buttons\\ButtonHilight-Square")
    else
        button:SetWidth(width)
        button:SetHeight(h)
    end
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end

--- Radio-style pressed state: darkens the button face like a pressed button.
--- Only affects the hand-drawn fallback (template buttons have their own
--- visuals); AddButtonFeedback's Normal() honours _pressedFlag so hover/leave
--- does not undo the pressed look.
local function SetButtonPressed(button, pressed)
    if not button then
        return
    end
    button._pressedFlag = pressed and true or nil
    local texes = button._gradTex
    local colors = button._gradColors
    if not texes or not colors then
        return
    end
    local factor = pressed and 0.6 or 1
    for i, tex in ipairs(texes) do
        local c = colors[i] or colors[#colors]
        pcall(tex.SetTexture, tex, math.min(c[1] * factor, 1), math.min(c[2] * factor, 1), math.min(c[3] * factor, 1), 1)
    end
end

local function MakeTextButton(parent, text, width, onClick, style)
    return MakeStockButton(parent, text, width, onClick, 18)
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
        text = format("|cffffcc00%s|r", L("[Paused]", "[已暂停]"))
    elseif current then
        local label = current.title or current.name or current.fileName or "?"
        text = format("%s%s|r", ColorForEvent(current.event), label)
        if queued > 0 then
            text = text .. format("  |cffcccccc(+%d)|r", queued)
        end
    elseif queued > 0 then
        text = format("|cffcccccc%s|r", format(L("%d queued...", "%d 排队中..."), queued))
    else
        text = format("|cff33ffcc%s|r", L("[Ready]", "[就绪]"))
    end
    return text
end

local QUEUE_ROW_HEIGHT = 18
local QUEUE_MAX_ROWS = 12

-- Apply the saved status bar position (clamped to the screen), or default to
-- 96px above the screen bottom (clears the experience bar; the bar grows
-- upward when the queue is shown). A bad saved position must never break the
-- caller. Also called again from the timer frame after the client injects the
-- SavedVariables global (which happens AFTER file-level Create on this client),
-- so the saved position is applied even when Create ran too early to see it.
function SoundQueueUI:ApplySavedPos()
    local frame = self.frame
    if not frame then
        return
    end
    local savedPos = Addon.db.profile.StatusBarPos
    if savedPos and type(savedPos[1]) == "number" and type(savedPos[2]) == "number" then
        local okW, w = pcall(UIParent.GetWidth, UIParent)
        local okH, h = pcall(UIParent.GetHeight, UIParent)
        local px, py = savedPos[1], savedPos[2]
        if okW and w and px + frame:GetWidth() > w then
            px = w - frame:GetWidth()
        end
        if okH and h and py + frame:GetHeight() > h then
            py = h - frame:GetHeight()
        end
        if px < 0 then px = 0 end
        if py < 0 then py = 0 end
        pcall(frame.SetPoint, frame, "BOTTOMLEFT", UIParent, "BOTTOMLEFT", px, py)
    else
        pcall(frame.SetPoint, frame, "BOTTOM", UIParent, "BOTTOM", 0, 96)
    end
end

function SoundQueueUI:Create()
    if self.frame then
        return
    end

    local frame = CreateFrame("Frame", "QuestEchoStatusFrame", UIParent)
    frame:SetWidth(320)
    frame:SetHeight(24)
    self.frame = frame
    self:ApplySavedPos()
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
        -- Persist every frame while dragging: OnMouseUp may never fire on this
        -- client if the cursor leaves the small frame before the button is
        -- released, so the position must be saved as the drag happens.
        Addon.db.profile.StatusBarPos = { nx, ny }
        -- Remember the exact anchor params so OnMouseUp can persist them in the
        -- same coordinate space (avoiding a GetLeft/GetBottom re-conversion).
        frame.lastDragX, frame.lastDragY = nx, ny
    end)
    frame:SetScript("OnMouseUp", function()
        if not frame.dragging then
            return
        end
        frame.dragging = false
        -- Persist the position so the bar stays where the player put it.
        if frame.lastDragX and frame.lastDragY then
            Addon.db.profile.StatusBarPos = { frame.lastDragX, frame.lastDragY }
        end
    end)

    local status = frame:CreateFontString("QuestEchoStatusText", "OVERLAY", "GameFontWhite")
    -- TOPLEFT anchor: the frame grows downward when the queue list expands,
    -- and a center anchor would slide the status line into the rows.
    status:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -5)
    status:SetWidth(210)
    status:SetHeight(16)
    pcall(status.SetJustifyH, status, "LEFT")
    pcall(status.SetFont, status, FONT, 12)
    -- WoW-style black text shadow under the status line.
    pcall(status.SetShadowColor, status, 0, 0, 0, 1)
    pcall(status.SetShadowOffset, status, 1, -1)

    local clearButton = MakeStockButton(frame, "X", 20, function()
        SoundQueue:RemoveAllSoundsFromQueue()
    end)
    clearButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

    local pauseButton = MakeStockButton(frame, "II", 20, function()
        SoundQueue:TogglePauseQueue()
    end)
    pauseButton:SetPoint("TOPRIGHT", clearButton, "TOPLEFT", -2, 0)

    local settingsButton = MakeStockButton(frame, L("Settings", "设置"), 52, function()
        local ok, err = pcall(function()
            QuestEcho.OptionsUI:Toggle()
        end)
        if not ok then
            Print("|cffff3333[QuestEcho]|r settings toggle error: " .. tostring(err))
        end
    end)
    settingsButton:SetPoint("TOPRIGHT", pauseButton, "TOPLEFT", -2, 0)

    -- Progress bar for the current voice line, in WoW health-bar style:
    -- near-black track, dark-gold trim, green gradient fill. The fill width
    -- is updated every frame by SoundQueueUI:UpdateProgress.
    local progBar = CreateFrame("Frame", "QuestEchoProgressBar", frame)
    progBar:SetWidth(304)
    progBar:SetHeight(6)
    progBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -27)
    local progBg = progBar:CreateTexture(nil, "BACKGROUND")
    progBg:SetTexture(0.02, 0.02, 0.02, 1)
    progBg:SetAllPoints()
    EdgeTexture(progBar, 0, 0, 304, 1, UI_GOLD_DARK)
    EdgeTexture(progBar, 0, 5, 304, 6, UI_GOLD_DARK)
    EdgeTexture(progBar, 0, 0, 1, 6, UI_GOLD_DARK)
    EdgeTexture(progBar, 303, 0, 304, 6, UI_GOLD_DARK)
    local progFillTop = progBar:CreateTexture(nil, "ARTWORK")
    progFillTop:SetTexture(UI_GREEN_TOP[1], UI_GREEN_TOP[2], UI_GREEN_TOP[3], 1)
    progFillTop:SetPoint("TOPLEFT", progBar, "TOPLEFT", 1, -1)
    progFillTop:SetHeight(2)
    progFillTop:SetWidth(0)
    local progFillBot = progBar:CreateTexture(nil, "ARTWORK")
    progFillBot:SetTexture(UI_GREEN_BOTTOM[1], UI_GREEN_BOTTOM[2], UI_GREEN_BOTTOM[3], 1)
    progFillBot:SetPoint("TOPLEFT", progBar, "TOPLEFT", 1, -3)
    progFillBot:SetPoint("BOTTOMLEFT", progBar, "BOTTOMLEFT", 1, 1)
    progFillBot:SetWidth(0)
    self.progBar = progBar
    self.progFillTop = progFillTop
    self.progFillBot = progFillBot

    -- Queue list rows (one per line; current line first). Reused across
    -- updates so we never leak frames.
    self.rows = {}
    for i = 1, QUEUE_MAX_ROWS do
        local row = CreateFrame("Frame", nil, frame)
        row:SetWidth(316)
        row:SetHeight(QUEUE_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -34 - (i - 1) * QUEUE_ROW_HEIGHT)

        -- row backdrop: near-black, playing rows get a gold-tinted face later
        -- (RebuildRows re-tints rowBg).
        local rowBg = row:CreateTexture(nil, "BACKGROUND")
        rowBg:SetTexture(0, 0, 0, 0.4)
        rowBg:SetAllPoints()
        -- thin inner trim so rows read as WoW list rows
        local rowTrim = row:CreateTexture(nil, "BORDER")
        rowTrim:SetTexture(UI_GOLD_DARK[1], UI_GOLD_DARK[2], UI_GOLD_DARK[3], 0.35)
        rowTrim:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        rowTrim:SetPoint("BOTTOMRIGHT", row, "TOPRIGHT", 0, -1)
        row.rowTrim = rowTrim

        local xButton = MakeStockButton(row, "X", 16, function()
            if row.soundId then
                SoundQueue:RemoveSound(row.soundId)
            end
        end, 16)
        xButton:SetPoint("LEFT", row, "LEFT", 2, 0)

        local label = row:CreateFontString(nil, "OVERLAY", "GameFontWhite")
        label:SetPoint("LEFT", xButton, "RIGHT", 4, 0)
        label:SetHeight(14)
        pcall(label.SetJustifyH, label, "LEFT")
        pcall(label.SetFont, label, FONT, 11)
        pcall(label.SetShadowColor, label, 0, 0, 0, 1)
        pcall(label.SetShadowOffset, label, 1, -1)

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
        -- WoW-style title: gold "QuestEcho" brand + the state text.
        self.status:SetText(format("|cffffd200%s|r %s", L("QuestEcho", "QuestEcho"), FormatStatus()))
    end
    self:RebuildRows()
    self:UpdateProgress()
end

--- Advance the progress bar for the current voice line (green WoW bar).
--- Called every frame from the main OnUpdate and after every queue change.
function SoundQueueUI:UpdateProgress()
    if not self.frame or not self.progFillTop then
        return
    end
    -- Freeze while paused (ResumeQueue restarts the line and re-arms startedAt).
    if Addon.db.char.IsPaused then
        return
    end
    local current = SoundQueue.current
    local pct = 0
    if current and current.startedAt and current.length and current.length > 0 then
        pct = (GetTime() - current.startedAt) / current.length
        pct = math.max(0, math.min(1, pct))
    end
    local okW, barW = pcall(self.progBar.GetWidth, self.progBar)
    local w = 0
    if okW and barW then
        w = math.floor((barW - 2) * pct)
    end
    if w < 0 then w = 0 end
    if self.progFillTop:GetWidth() ~= w then
        self.progFillTop:SetWidth(w)
        self.progFillBot:SetWidth(w)
    end
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
                local state = paused and L("(paused)", "(已暂停)") or L("(playing)", "(播放中)")
                row.label:SetText(format("|cffffd24a>|r %s%s|r  |cffcccccc%s|r",
                    ColorForEvent(sound.event), labelText, state))
                row.rowBg:SetTexture(UI_GOLD_TEXT[1], UI_GOLD_TEXT[2], UI_GOLD_TEXT[3], 0.14)
                if row.rowTrim then
                    row.rowTrim:SetTexture(UI_GOLD_TEXT[1], UI_GOLD_TEXT[2], UI_GOLD_TEXT[3], 0.6)
                end
            else
                row.label:SetText(format("%s%s|r", ColorForEvent(sound.event), labelText))
                row.rowBg:SetTexture(0, 0, 0, 0.4)
                if row.rowTrim then
                    row.rowTrim:SetTexture(UI_GOLD_DARK[1], UI_GOLD_DARK[2], UI_GOLD_DARK[3], 0.35)
                end
            end
        end
    end

    -- 24px title row + 6px progress bar + 4px gap + the queue rows.
    frame:SetHeight(34 + shown * QUEUE_ROW_HEIGHT)
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
    ApplyClassicBackdrop(frame, 460, 60 + QUESTLOG_VISIBLE_ROWS * QUESTLOG_ROW_HEIGHT + 26)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -8)
    title:SetText(L("QuestEcho — Quest Replay", "QuestEcho — 任务语音回放"))
    pcall(title.SetFont, title, FONT, 13)
    pcall(title.SetTextColor, title, UI_GOLD_TEXT[1], UI_GOLD_TEXT[2], UI_GOLD_TEXT[3])
    pcall(title.SetShadowColor, title, 0, 0, 0, 1)
    pcall(title.SetShadowOffset, title, 1, -1)

    local closeButton = MakeStockButton(frame, "X", 20, function()
        QuestLogUI:Toggle()
    end)
    closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

    local refreshButton = MakeStockButton(frame, "R", 20, function()
        QuestLogUI:Update(true)
    end)
    refreshButton:SetPoint("RIGHT", closeButton, "LEFT", -4, 0)

    local hQuest = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hQuest:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -32)
    hQuest:SetText(L("Quest", "任务"))
    pcall(hQuest.SetFont, hQuest, FONT, 10)

    local hPlay = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hPlay:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -94, -32)
    hPlay:SetText(L("accept | complete", "接取 | 完成"))
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

        local acceptButton = MakeStockButton(row, L("accept", "接取"), 84, function()
            QuestLogUI:PlayQuest(row.questID, "accept", row.title)
        end, 16)
        acceptButton:SetPoint("RIGHT", row, "RIGHT", -94, 0)

        local completeButton = MakeStockButton(row, L("complete", "完成"), 84, function()
            QuestLogUI:PlayQuest(row.questID, "complete", row.title)
        end, 16)
        completeButton:SetPoint("RIGHT", row, "RIGHT", -4, 0)

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
                if row.acceptButton.label then
                    pcall(row.acceptButton.label.SetTextColor, row.acceptButton.label, 1.0, 0.82, 0.05)
                end
            else
                row.acceptButton:Disable()
                row.acceptButton:SetAlpha(0.55)
                if row.acceptButton.label then
                    pcall(row.acceptButton.label.SetTextColor, row.acceptButton.label, 0.55, 0.55, 0.55)
                end
            end
            row.completeButton:Show()
            if quest.hasComplete then
                row.completeButton:Enable()
                row.completeButton:SetAlpha(1)
                if row.completeButton.label then
                    pcall(row.completeButton.label.SetTextColor, row.completeButton.label, 1.0, 0.82, 0.05)
                end
            else
                row.completeButton:Disable()
                row.completeButton:SetAlpha(0.55)
                if row.completeButton.label then
                    pcall(row.completeButton.label.SetTextColor, row.completeButton.label, 0.55, 0.55, 0.55)
                end
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
        self.emptyNote:SetText(L("No current quests with voice lines found.", "未找到有语音的当前任务。"))
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
    [Enums.GossipFrequency.Always] = L("always", "总是"),
    [Enums.GossipFrequency.OncePerQuestNPC] = L("oncequest", "每任务一次"),
    [Enums.GossipFrequency.OncePerNPC] = L("once", "每NPC一次"),
    [Enums.GossipFrequency.Never] = L("never", "从不"),
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

        self.acceptButton = MakeStockButton(parent, "Echo", 38, function()
            local ok, err = pcall(QuestLogHook.PlaySelected, QuestLogHook, "accept")
            if not ok then
                Print(format("|cffff3333[QuestEcho]|r %s", format(L("play error: %s", "播放错误：%s"), tostring(err))))
            end
        end, 18)
        self.voiceText = nil

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
        Print("|cffff3333[QuestEcho]|r " .. format(L("no voice line match for the selected quest: %s", "所选任务没有匹配的语音：%s"), tostring(title or "?")))
        return
    end
    -- Belt and braces: the button should already be disabled without a voice
    -- line, but never let a click reach the play path on this client.
    if not HasQuestVoice(questID, eventType) then
        Print(format("|cffff3333[QuestEcho]|r %s", format(L("no %s voice line file for: %s", "没有 %s 语音文件：%s"),
            eventType, tostring(title))))
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
        Print(format("|cffff3333[QuestEcho]|r %s", format(L("no %s voice line file for: %s", "没有 %s 语音文件：%s"),
            eventType, tostring(title))))
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
        -- enabled: red face with the gold label
        self.acceptButton:Enable()
        self.acceptButton:SetAlpha(1)
        if self.acceptButton.label then
            pcall(self.acceptButton.label.SetTextColor, self.acceptButton.label, 1.0, 0.82, 0.05)
        end
    else
        -- No voice line for this quest: grey disabled state, kept inert.
        -- (Clicking it on this client can hang the game, so never let it
        -- through to the play path.)
        self.acceptButton:Disable()
        self.acceptButton:SetAlpha(0.55)
        if self.acceptButton.label then
            pcall(self.acceptButton.label.SetTextColor, self.acceptButton.label, 0.55, 0.55, 0.55)
        end
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

--- /qe volprobe — plays the same voice line once per volume step (0.5x, 1x,
--- 2x) so the player can hear whether the VoiceVolume multiplier actually
--- changes the loudness on this client. Each play uses Utils:PlaySound so it
--- exercises exactly the code path used by real queue playback.
local function RunVoiceVolumeProbe()
    local sd = { event = Enums.SoundEvent.QuestAccept, name = "Jitters", title = "Jitters' Growling Gut", questID = 5, delay = 0 }
    if not DataModules:PrepareSound(sd) then
        Print("|cffff3333[QuestEcho]|r " .. L("volprobe failed: no voice line file for quest 5 in the data pack", "音量探测失败：数据包中没有任务 5 的语音文件"))
        return
    end
    local steps = { 0.5, 1, 2 }
    local old = Addon.db.profile.VoiceVolume or 1
    Print("|cff33ffcc[QuestEcho]|r " .. L("volprobe: playing at 0.5x, 1x, 2x — you should hear the loudness change", "音量探测：依次播放 0.5 倍、1 倍、2 倍——应当能听到音量变化"))
    local pf = CreateFrame("Frame")
    local idx = 1
    pf:SetScript("OnUpdate", function()
        if GetTime() < (pf.nextAt or 0) then
            return
        end
        local step = steps[idx]
        if not step then
            Addon.db.profile.VoiceVolume = old
            -- a scaled step may still be mid-play; restore the real game
            -- volume once it has had time to finish
            Utils:RestoreSoundSettings()
            pf:SetScript("OnUpdate", nil)
            Print("|cff33ffcc[QuestEcho]|r " .. L("volprobe done (volume restored)", "音量探测完成（音量已恢复）"))
            return
        end
        Addon.db.profile.VoiceVolume = step
        local okPlay = Utils:PlaySound(sd)
        Print(format("|cff33ffcc[QuestEcho]|r volprobe: %sx -> %s", tostring(step), tostring(okPlay)))
        idx = idx + 1
        pf.nextAt = GetTime() + (sd.length or 2) + 1.0
    end)
    pf.nextAt = 0
end

--- Stock WoW UIPanelButtonTemplate button: native red face with gold label,
local function RefreshOptionsUI()
    if not OptionsUI.frame then
        return
    end
    local profile = Addon.db.profile
    OptionsUI.delayLabel:SetText(format(L("Delay before lines: %.1f s", "播放前延迟：%.1f 秒"), profile.Delay))
    OptionsUI.statusLabel:SetText(format(L("Status bar: %s", "状态栏：%s"), profile.ShowUI and L("shown", "显示") or L("hidden", "隐藏")))
    OptionsUI.voiceLabel:SetText(format(L("Voice volume: %.2f x", "语音音量：%.2f 倍"), profile.VoiceVolume or 1))
    for _, entry in ipairs(GOSSIP_BUTTONS) do
        local active = profile.GossipFrequency == entry.value
        SetButtonPressed(entry.button, active)
        local label = entry.button.label
        if not label then
            local ok, fs = pcall(entry.button.GetFontString, entry.button)
            label = ok and fs or nil
        end
        if label then
            label:SetText(active and (format("|cffffee8c%s|r", entry.name)) or entry.name)
        end
    end
end

-- Apply the saved settings window position, or fall back to the centered
-- default. Called both from Create and again from the timer frame after the
-- client injects the SavedVariables global, so a saved position is applied
-- even when Create ran before the global was injected.
function OptionsUI:ApplySavedPos()
    local frame = self.frame
    if not frame then
        return
    end
    local savedPos = Addon.db.profile.OptionsPos
    if savedPos and type(savedPos[1]) == "number" and type(savedPos[2]) == "number" then
        local okW, w = pcall(UIParent.GetWidth, UIParent)
        local okH, h = pcall(UIParent.GetHeight, UIParent)
        local px, py = savedPos[1], savedPos[2]
        if okW and w and px + frame:GetWidth() > w then
            px = w - frame:GetWidth()
        end
        if okH and h and py + frame:GetHeight() > h then
            py = h - frame:GetHeight()
        end
        if px < 0 then px = 0 end
        if py < 0 then py = 0 end
        pcall(frame.SetPoint, frame, "BOTTOMLEFT", UIParent, "BOTTOMLEFT", px, py)
    else
        pcall(frame.SetPoint, frame, "CENTER", UIParent, "CENTER", 0, 120)
    end
end

function OptionsUI:Create()
    if self.frame then
        return
    end

    local frame = CreateFrame("Frame", "QuestEchoOptionsFrame", UIParent)
    frame:SetWidth(320)
    frame:SetHeight(188)
    self.frame = frame
    self:ApplySavedPos()
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    ApplyClassicBackdrop(frame, 320, 188)
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
        -- Persist every frame while dragging (OnMouseUp may never fire on this
        -- client if the cursor leaves the frame before the button is released).
        Addon.db.profile.OptionsPos = { nx, ny }
        frame.lastDragX, frame.lastDragY = nx, ny
    end)
    frame:SetScript("OnMouseUp", function()
        if not frame.dragging then
            return
        end
        frame.dragging = false
        if frame.lastDragX and frame.lastDragY then
            Addon.db.profile.OptionsPos = { frame.lastDragX, frame.lastDragY }
        end
    end)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontWhite")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -8)
    title:SetText(L("QuestEcho Settings", "QuestEcho 设置"))
    pcall(title.SetFont, title, FONT, 13)
    -- WoW panel title: gold with a black shadow.
    pcall(title.SetTextColor, title, UI_GOLD_TEXT[1], UI_GOLD_TEXT[2], UI_GOLD_TEXT[3])
    pcall(title.SetShadowColor, title, 0, 0, 0, 1)
    pcall(title.SetShadowOffset, title, 1, -1)

    local closeButton = MakeTextButton(frame, "X", 20, function()
        OptionsUI:Toggle()
    end, "red")
    closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

    local gossipTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    gossipTitle:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -36)
    gossipTitle:SetText(L("Gossip frequency", "闲聊语音频率"))
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

    local statusButton = MakeTextButton(frame, L("toggle", "切换"), 70, function()
        SoundQueueUI:Toggle()
        RefreshOptionsUI()
    end)
    statusButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 230, -106)

    local voiceLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    voiceLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -136)
    pcall(voiceLabel.SetFont, voiceLabel, FONT, 11)

    local voiceMinus = MakeTextButton(frame, "-", 24, function()
        Addon.db.profile.VoiceVolume = math.max(0.25, math.floor((Addon.db.profile.VoiceVolume - 0.25) / 0.25 + 0.5) * 0.25)
        RefreshOptionsUI()
    end)
    voiceMinus:SetPoint("TOPLEFT", frame, "TOPLEFT", 230, -132)

    local voicePlus = MakeTextButton(frame, "+", 24, function()
        Addon.db.profile.VoiceVolume = math.min(3, math.floor((Addon.db.profile.VoiceVolume + 0.25) / 0.25 + 0.5) * 0.25)
        RefreshOptionsUI()
    end)
    voicePlus:SetPoint("LEFT", voiceMinus, "RIGHT", 2, 0)

    local testButton = MakeTextButton(frame, L("Test voice", "测试语音"), 100, function()
        PlayTestVoice()
    end)
    testButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 8)

    local clearButton = MakeTextButton(frame, L("Clear queue", "清空队列"), 100, function()
        SoundQueue:RemoveAllSoundsFromQueue()
    end)
    clearButton:SetPoint("LEFT", testButton, "RIGHT", 6, 0)

    self.frame = frame
    self.delayLabel = delayLabel
    self.statusLabel = statusLabel
    self.voiceLabel = voiceLabel
    RefreshOptionsUI()
end

function OptionsUI:Toggle()
    if not self.frame then
        local ok, err = pcall(self.Create, self)
        if not ok then
            Print(format("|cffff3333[QuestEcho]|r settings window failed to open: %s", tostring(err)))
            return
        end
        -- First creation: show it right away. This client shows frames as
        -- soon as they are created, so checking IsShown() here would hide
        -- the freshly created panel (the "first click does nothing" bug).
        self:ApplySavedPos()
        RefreshOptionsUI()
        self.frame:Show()
        return
    end
    if self.frame:IsShown() then
        self.frame:Hide()
    else
        self:ApplySavedPos()
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

--- Play the accept line for the quest currently shown in the detail window.
--- @param usePriority boolean  true = cut whatever is playing and start now
--- (used when the detail window opens), false = normal queue append
--- (QUEST_DETAIL event path). Returns true only when a line was actually queued,
--- so callers can mark the title as voiced only on success.
local function OnQuestDetail(usePriority)
    local name = Utils:GetNPCName()
    local okTitle, title = pcall(GetTitleText)
    local okText, text = pcall(GetQuestText)
    title = okTitle and title or nil
    text = okText and text or nil
    if not title or title == "" then
        return false
    end

    local questID = DataModules:GetQuestID("accept", title, name, text)
    -- The detail window may expose the title but not the full body text, so
    -- fall back to the plain title match used by the log-based watcher.
    if not questID then
        questID = FindQuestIDByTitle(title)
    end
    if not questID then
        Debug:Print("no quest ID match for accept: %s (%s)", tostring(title), tostring(name or "?"))
        return false
    end
    if not HasQuestVoice(questID, "accept") then
        Debug:Print("no accept voice for quest %s (%s)", tostring(questID), tostring(title))
        return false
    end
    if not name then
        name = DataModules:GetQuestGiverName(questID)
    end

    local soundData =
    {
        event = Enums.SoundEvent.QuestAccept,
        name = name,
        title = title,
        text = text,
        questID = questID,
        delay = Addon.db.profile.Delay,
    }
    local ok
    if usePriority then
        ok = SoundQueue:PlayPriorityKeep(soundData)
    else
        ok = SoundQueue:AddSoundToQueue(soundData)
    end
    if ok then
        local watcher = QuestEcho.QuestAcceptWatcher
        if watcher and watcher.known then
            watcher.known[title] = true
        end
    end
    return ok
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
-- The turn-in (reward) window's native panel. GetTitleText on this client
-- keeps the last quest-giver title after the window closes, so a lingering
-- title cannot serve as the "window closed" signal — the panel's visibility
-- is the reliable one (same reason as QuestDetailWatcher).
QuestCompleteWatcher.REWARD_PANELS = { "QuestRewardScrollChildFrame", "QuestFrameRewardPanel" }

function QuestCompleteWatcher:OnUpdate()
    local okT, t = pcall(GetTime)
    if not okT or not t then
        return
    end
    if self.nextCheck and t < self.nextCheck then
        return
    end
    self.nextCheck = t + QUEST_POLL_INTERVAL

    -- Reward window open? At least one panel resolved, and one is shown.
    local rewardShown = false
    local panelResolved = false
    for _, name in ipairs(QuestCompleteWatcher.REWARD_PANELS) do
        local ok, panel = pcall(getglobal, name)
        if ok and panel and type(panel.IsShown) == "function" then
            panelResolved = true
            local okShown, shown = pcall(panel.IsShown, panel)
            if okShown and shown then
                rewardShown = true
                break
            end
        end
    end

    local okTitle, title = pcall(GetTitleText)
    local hasTitle = okTitle and title and title ~= ""
    local okRT, rewardText = pcall(GetRewardText)
    local rtlen = (okRT and rewardText and #rewardText) or 0

    -- Panels resolved: the reward window is open only while one is shown.
    -- When it closes, clear lastRtLen so the next turn-in (even of the same
    -- quest) re-arms the detector.
    if panelResolved then
        if not rewardShown then
            self.lastRtLen = nil
            return
        end
    elseif not hasTitle then
        -- No panel API: fall back to the title going empty as "closed".
        self.lastRtLen = nil
        return
    end

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

-- =============================================================================
-- Quest-detail watcher: play the accept voice as soon as the quest detail
-- (accept) window opens, instead of waiting for the quest to enter the log.
-- QUEST_DETAIL never fires on this client (OnEvent's event arg is always nil),
-- so poll the detail window itself.
--
-- Window detection: GetTitleText on this client is documented as the title
-- "last received from a quest-giver packet (detail, progress, or complete)"
-- and it does NOT clear when the detail window closes — so a non-empty title
-- cannot mean "the window is open". Re-using the title as a debounce would
-- permanently block re-voicing the same quest on a second open. Instead we
-- test the native detail panel's visibility (QuestDetailScrollChildFrame):
-- shown = the accept window is up, hidden = it is closed (or the reward
-- window took over). Only while shown do we read the title, and only a
-- title NOT in the quest log yet is an acceptable quest (a title already in
-- the log means the turn-in window is open, which QuestCompleteWatcher
-- owns). No session-level de-dupe: every time the accept window opens the
-- accept line plays again. OnQuestDetail marks the quest as known on
-- success, so the log-based watcher will not double-play after the quest is
-- accepted.
-- =============================================================================
QuestEcho.QuestDetailWatcher = {}
local QuestDetailWatcher = QuestEcho.QuestDetailWatcher
QuestDetailWatcher.nextCheck = nil
QuestDetailWatcher.lastTitle = nil
-- The panel name is Vanilla 1.12 FrameXML (QuestDetailScrollChildFrame is
-- inside the accept/detail panel). On a client where it is absent the watcher
-- degrades to the previous title-based behavior.
QuestDetailWatcher.DETAIL_PANELS = { "QuestDetailScrollChildFrame", "QuestFrameDetailPanel" }

-- "shown"  = an accept/detail panel is visible (the accept window is up)
-- "hidden" = at least one panel resolved but none is visible (window closed)
-- "unavailable" = no panel could be resolved at all (fall back to titles)
local function DetailPanelState()
    local resolved = false
    for _, name in ipairs(QuestDetailWatcher.DETAIL_PANELS) do
        local ok, panel = pcall(getglobal, name)
        if ok and panel and type(panel.IsShown) == "function" then
            resolved = true
            local okShown, shown = pcall(panel.IsShown, panel)
            if okShown and shown then
                return "shown"
            end
        end
    end
    if resolved then
        return "hidden"
    end
    return "unavailable"
end

function QuestDetailWatcher:OnUpdate()
    local okT, t = pcall(GetTime)
    if not okT or not t then
        return
    end
    if self.nextCheck and t < self.nextCheck then
        return
    end
    self.nextCheck = t + QUEST_POLL_INTERVAL

    local state = DetailPanelState()
    if state == "shown" then
        -- Accept window is up: read the title and voice it once per open
        -- (the lastTitle debounce only suppresses repeats while the SAME
        -- window stays open; closing the window clears it below).
        local okTitle, title = pcall(GetTitleText)
        local hasTitle = okTitle and title and title ~= ""
        if not hasTitle then
            -- panel shown but title not yet populated: keep waiting
            return
        end
        if self.lastTitle == title then
            return
        end
        self.lastTitle = title
        -- A title already in the quest log is the turn-in window, owned by
        -- QuestCompleteWatcher — not an acceptable quest.
        if CurrentQuestTitles()[title] then
            return
        end
        OnQuestDetail(true)
        return
    elseif state == "hidden" then
        -- Window closed (or the reward window swapped the panel in): clear
        -- the debounce so the same quest voices again on the next open.
        self.lastTitle = nil
        return
    end

    -- "unavailable": no native panel to test, so fall back to the old rule
    -- (title going empty = window closed, non-empty = open).
    local okTitle, title = pcall(GetTitleText)
    local hasTitle = okTitle and title and title ~= ""
    if not hasTitle then
        self.lastTitle = nil
        return
    end
    if self.lastTitle == title then
        return
    end
    self.lastTitle = title
    if CurrentQuestTitles()[title] then
        return
    end
    OnQuestDetail(true)
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
            -- OnQuestDetail marks the quest known on success, so accepting
            -- after the detail window already voiced it won't double-play.
            -- Only fall back here when the detail match failed (no voice
            -- found while the window was open).
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
    -- SavedVariables binding: on this client ADDON_LOADED has no probed
    -- record and the QuestEchoDB global may be injected AFTER our file-level
    -- init, so Addon.db would keep pointing at the table we built ourselves
    -- while the client serializes the (freshly injected) global on exit —
    -- every runtime write would be lost. Detect a client-injected global and
    -- merge it in once, then keep the global bound to our live table every
    -- frame so exit-save writes the table we actually use.
    if type(QuestEchoDB) == "table" and QuestEchoDB ~= Addon.db then
        Addon.db = Addon:MergeDB(QuestEchoDB, defaults)
        -- The status bar and settings frames may have been created before the
        -- client injected the SavedVariables global, so re-apply any saved
        -- positions now that Addon.db actually contains them.
        SoundQueueUI:ApplySavedPos()
        OptionsUI:ApplySavedPos()
    end
    QuestEchoDB = Addon.db
    Utils:MaybeCaptureBaseline()
    SoundQueue:OnUpdate()
    SoundQueueUI:UpdateProgress()
    GossipWatcher:OnUpdate()
    QuestDetailWatcher:OnUpdate()
    QuestAcceptWatcher:OnUpdate()
    QuestCompleteWatcher:OnUpdate()
end)

-- =============================================================================
-- Slash commands
-- =============================================================================
local GOSSIP_NAMES =
{
    [Enums.GossipFrequency.Always] = L("always", "总是"),
    [Enums.GossipFrequency.OncePerQuestNPC] = L("oncequest", "每任务一次"),
    [Enums.GossipFrequency.OncePerNPC] = L("once", "每NPC一次"),
    [Enums.GossipFrequency.Never] = L("never", "从不"),
}

local function Help()
    Print("|cff33ffccQuestEcho (Emberveil)|r 1.5.3 — " .. L("voice lines for quests and gossip", "任务与闲聊语音"))
    Print("|cff33ffcc/qe|r — " .. L("this help", "本帮助"))
    Print("|cff33ffcc/qe pause|r — " .. L("pause/resume the voice line queue", "暂停/恢复语音队列"))
    Print("|cff33ffcc/qe clear|r — " .. L("clear the queue and stop the current line", "清空队列并停止当前语音"))
    Print("|cff33ffcc/qe gossip|r — " .. L("show gossip frequency", "查看闲聊语音频率"))
    Print("|cff33ffcc/qe gossip always|r / |cff33ffcconce|r / |cff33ffcconcequest|r / |cff33ffccnever|r — " .. L("set gossip frequency", "设置闲聊语音频率"))
    Print("|cff33ffcc/qe delay <sec>|r — " .. L("delay before a voice line starts (default 0.3)", "语音播放前延迟（默认 0.3 秒）"))
    Print("|cff33ffcc/qe vol [0.25-3]|r — " .. L("QuestEcho voice volume multiplier (default 1.0, independent of game sound)", "QuestEcho 语音音量倍率（默认 1.0，独立于游戏音量）"))
    Print("|cff33ffcc/qe volprobe|r — " .. L("play one line at several volumes so you can confirm the multiplier works", "用不同音量播放同一句语音，用于确认倍率生效"))
    Print("|cff33ffcc/qe stopwait full|<sec>|r — " .. L("how long to keep volume muted after removing a line (default 0.5)", "移除语音后保持音量静音的时长（默认 0.5 秒）"))
    Print("|cff33ffcc/qe ui|r — " .. L("toggle the status bar", "开关状态栏"))
    Print("|cff33ffcc/qe debug|r — " .. L("toggle debug messages", "开关调试信息"))
    Print("|cff33ffcc/qe questlog|r — " .. L("open the quest replay window", "打开任务语音回放窗口"))
    Print("|cff33ffcc/qe settings|r — " .. L("open the settings panel", "打开设置面板"))
    Print("|cff33ffcc/qe test|r — " .. L("play a test voice line", "播放测试语音"))
    Print("|cff33ffcc/qe status|r — " .. L("show queue state", "显示队列状态"))
    Print("|cff33ffcc/qe locale|r — " .. L("show client locale and data module state", "显示客户端语言和数据模块状态"))
    Print("|cff33ffcc/qe diag|r — " .. L("dump sound cvar/baseline/api diagnostics", "输出音频设置/基准/接口诊断"))
    Print("|cff33ffcc/qe probe|r — " .. L("dump runtime quest-log/sound diagnostics", "输出任务日志/音频运行时诊断"))
    Print("|cff33ffcc/qe soundprobe|r — " .. L("play one file via 5 path variants (which do you hear?)", "用 5 种路径变体播放同一文件（你听到哪个？）"))
end

local function HandleSlashCommand(input)
    input = string.lower(string.gsub(input or "", "^%s*(.-)%s*$", "%1"))
    local command, arg = input:match("^(%S*)%s*(.-)$")
    arg = string.gsub(arg or "", "^%s*(.-)%s*$", "%1")

    if command == "" or command == "help" then
        Help()
    elseif command == "pause" or command == "p" then
        SoundQueue:TogglePauseQueue()
        Print(format("|cff33ffcc[QuestEcho]|r %s", Addon.db.char.IsPaused and L("paused", "已暂停") or L("resumed", "已恢复")))
    elseif command == "clear" or command == "c" then
        SoundQueue:RemoveAllSoundsFromQueue()
        Print(format("|cff33ffcc[QuestEcho]|r %s", L("queue cleared", "队列已清空")))
    elseif command == "gossip" or command == "g" then
        if arg == "" then
            Print(format("|cff33ffcc[QuestEcho]|r %s: |cffffffff%s|r",
                L("gossip frequency", "闲聊语音频率"),
                GOSSIP_NAMES[Addon.db.profile.GossipFrequency] or "?"))
        elseif arg == "always" then
            Addon.db.profile.GossipFrequency = Enums.GossipFrequency.Always
            Print(format("|cff33ffcc[QuestEcho]|r gossip: %s", L("always", "总是")))
        elseif arg == "once" then
            Addon.db.profile.GossipFrequency = Enums.GossipFrequency.OncePerNPC
            Print(format("|cff33ffcc[QuestEcho]|r gossip: %s", L("once per NPC (per character)", "每 NPC 一次（每角色）")))
        elseif arg == "oncequest" or arg == "onceperquest" then
            Addon.db.profile.GossipFrequency = Enums.GossipFrequency.OncePerQuestNPC
            Print(format("|cff33ffcc[QuestEcho]|r gossip: %s", L("once per quest NPC (per session)", "每任务 NPC 一次（每会话）")))
        elseif arg == "never" then
            Addon.db.profile.GossipFrequency = Enums.GossipFrequency.Never
            Print(format("|cff33ffcc[QuestEcho]|r gossip: %s", L("never", "从不")))
        else
            Print("|cffff3333[QuestEcho]|r " .. format(L("unknown gossip setting: %s", "未知的闲聊设置：%s"), tostring(arg)))
        end
    elseif command == "delay" then
        local delay = tonumber(arg)
        if delay and delay >= 0 and delay <= 10 then
            Addon.db.profile.Delay = delay
            Print(format("|cff33ffcc[QuestEcho]|r %s", format(L("delay set to %.1fs", "延迟已设为 %.1f 秒"), delay)))
        else
            Print(format("|cff33ffcc[QuestEcho]|r %s", format(L("current delay: %.1fs", "当前延迟：%.1f 秒"), Addon.db.profile.Delay)))
        end
    elseif command == "vol" then
        local v = tonumber(arg)
        if v and v >= 0.25 and v <= 3 then
            Addon.db.profile.VoiceVolume = v
            Print(format("|cff33ffcc[QuestEcho]|r %s", format(L("voice volume set to %.2f x", "语音音量已设为 %.2f 倍"), v)))
        else
            Print(format("|cff33ffcc[QuestEcho]|r %s: |cffffffff%.2f x|r", L("current voice volume", "当前语音音量"), Addon.db.profile.VoiceVolume or 1))
            Print("|cffff3333[QuestEcho]|r usage: /qe vol 0.25-3")
        end
    elseif command == "volprobe" then
        RunVoiceVolumeProbe()
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
            Print(format("|cff33ffcc[QuestEcho]|r %s: |cffffffff%s|r (%s)", 
                L("stop restore wait", "停止后音量恢复等待"),
                tostring(Addon.db.profile.StopWait),
                L("full = wait for the removed line to end", "full = 等待被移除的语音播完")))
        elseif arg == "full" then
            Addon.db.profile.StopWait = "full"
            Print(format("|cff33ffcc[QuestEcho]|r %s: full (%s)",
                L("stop restore wait", "停止后音量恢复等待"),
                L("wait for the removed line to end", "等待被移除的语音播完")))
        else
            local wait = tonumber(arg)
            if wait and wait >= 0 and wait <= 30 then
                Addon.db.profile.StopWait = wait
                Print(format("|cff33ffcc[QuestEcho]|r %s: %.1fs (%s)",
                    L("stop restore wait", "停止后音量恢复等待"),
                    wait,
                    L("the removed line's tail may keep playing", "被移除语音的尾部可能继续播放")))
            else
                Print("|cffff3333[QuestEcho]|r usage: /qe stopwait full | <seconds 0-30>")
            end
        end
    elseif command == "debug" then
        Addon.db.profile.Debug = not Addon.db.profile.Debug
        Print(format("|cff33ffcc[QuestEcho]|r debug %s", Addon.db.profile.Debug and L("on", "开") or L("off", "关")))
    elseif command == "test" then
        if not DataModules:GetModule("QuestEchoData") then
            Print("|cffff3333[QuestEcho]|r " .. L("test failed: data module not loaded — type /qe status", "测试失败：数据模块未加载 — 输入 /qe status"))
        elseif not Utils:IsSoundEnabled() then
            Print("|cffff3333[QuestEcho]|r " .. L("test failed: sound is disabled in the game options", "测试失败：游戏设置中声音已关闭"))
        else
            local ok, fileName = PlayTestVoice()
            if ok then
                Print(format("|cff33ffcc[QuestEcho]|r %s (%s)", L("test voice line queued", "测试语音已加入队列"), tostring(fileName)))
            else
                Print("|cffff3333[QuestEcho]|r " .. L("test failed: no voice line file for quest 5 in the data pack", "测试失败：数据包中没有任务 5 的语音文件"))
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
    elseif command == "uidiag" then
        -- UI renderer diagnostic: which construction tints gold?
        -- A = Frame + gradient, B = Button + gradient, D = Frame + flat,
        -- E = Button + flat. Screenshot and report which look gold.
        local parent = CreateFrame("Frame", nil, UIParent)
        parent:SetPoint("CENTER", 0, 200)
        parent:SetWidth(700)
        parent:SetHeight(140)
        parent:SetFrameStrata("DIALOG")
        local function MakeTest(typ, x, label, grad)
            local f
            if typ == "button" then
                f = CreateFrame("Button", nil, parent)
            else
                f = CreateFrame("Frame", nil, parent)
            end
            f:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -20)
            f:SetWidth(120)
            f:SetHeight(50)
            if grad then
                GradientFill(f, 120, 50, "BACKGROUND", {
                    { 0.50, UI_GREY_TOP[1], UI_GREY_TOP[2], UI_GREY_TOP[3] },
                    { 0.15, UI_GREY_MID[1], UI_GREY_MID[2], UI_GREY_MID[3] },
                    { 0.15, UI_GREY_DARK[1], UI_GREY_DARK[2], UI_GREY_DARK[3] },
                    { 0.20, UI_GREY_BOTTOM[1], UI_GREY_BOTTOM[2], UI_GREY_BOTTOM[3] },
                })
            else
                local fill = f:CreateTexture(nil, "BACKGROUND")
                fill:SetTexture(UI_GREY_TOP[1], UI_GREY_TOP[2], UI_GREY_TOP[3], 1)
                fill:SetAllPoints()
            end
            EdgeTexture(f, 0, 0, 120, 1, UI_GOLD_BRIGHT)
            EdgeTexture(f, 0, 49, 120, 50, UI_GOLD_BRIGHT)
            EdgeTexture(f, 0, 0, 1, 50, UI_GOLD_BRIGHT)
            EdgeTexture(f, 119, 0, 120, 50, UI_GOLD_BRIGHT)
            local hl = f:CreateTexture(nil, "BORDER")
            hl:SetTexture(UI_GREY_HILIGHT[1], UI_GREY_HILIGHT[2], UI_GREY_HILIGHT[3], 0.8)
            hl:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
            hl:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", -1, -2)
            local lab = parent:CreateFontString(nil, "OVERLAY", "GameFontWhite")
            lab:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 4)
            lab:SetText(label)
            lab:SetTextColor(1, 1, 1, 1)
            return f
        end
        MakeTest("frame", 20, "A Frame+grad", true)
        MakeTest("button", 160, "B Button+grad", true)
        MakeTest("frame", 300, "D Frame+flat", false)
        MakeTest("button", 440, "E Button+flat", false)
        Print("|cff33ffcc[QuestEcho]|r uidiag: 4 test panels at screen center (A/B/D/E). Screenshot them and tell me which look gold.")
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
    elseif command == "playfile" or command == "pf" then
        local sub, name = arg:match("^(%S+)%s+(%S+)$")
        if not sub or not name then
            Print("|cffff3333[QuestEcho]|r usage: /qe playfile <quests|gossip> <name[.ogg|.wav]> (plays the raw file directly, no queue)")
        else
            if not name:find("%.") then
                name = name .. ".ogg"
            end
            local p = format("../../Interface/AddOns/QuestEchoData/generated/sounds/%s/%s", sub, name)
            Print(format("|cff33ffcc[QuestEcho]|r playing: %s", p))
            local ok = pcall(PlaySoundFile, p)
            Print(format("|cff33ffcc[QuestEcho]|r PlaySoundFile -> %s", tostring(ok)))
        end
    elseif command == "wavtest" then
        -- diagnostic: is the mute->restore flow what kills wav playback?
        local function afterDelay(delay, fn)
            local f = CreateFrame("Frame")
            f.at = GetTime() + delay
            f:SetScript("OnUpdate", function()
                if GetTime() >= f.at then
                    f:SetScript("OnUpdate", nil)
                    fn()
                end
            end)
        end
        local p = "../../Interface/AddOns/QuestEchoData/generated/sounds/gossip/6d671d26f71829b3cfdafaf53866d6f0.wav"
        Print("|cff33ffcc[QuestEcho]|r -- wavtest A: direct play (should be audible) --")
        local okA = pcall(PlaySoundFile, p)
        Print(format("|cff33ffcc[QuestEcho]|r A -> %s", tostring(okA)))
        afterDelay(2.0, function()
            Print("|cff33ffcc[QuestEcho]|r -- wavtest B: mute -> restore -> play --")
            Utils:MuteSound()
            afterDelay(0.15, function()
                Utils:RestoreSoundSettings()
                local okB = pcall(PlaySoundFile, p)
                Print(format("|cff33ffcc[QuestEcho]|r B -> %s vol=%s/%s", tostring(okB), tostring(GetCVar("MasterVolume")), tostring(GetCVar("SoundVolume"))))
            end)
        end)
    elseif command == "selftest" or command == "st" then
        local filter, startArg, gapArg = arg:match("^(%S*)%s*(%d*)%s*(%d*)$")
        local files = (DataModules:GetModule("QuestEchoData") and QuestEchoData.SelftestFiles) or nil
        if not files then
            Print("|cffff3333[QuestEcho]|r selftest: QuestEchoData selftest list not found")
        else
            local list = {}
            for i = 1, #files do
                local e = files[i]
                if filter == "" or e.dir == filter then
                    table.insert(list, e)
                end
            end
            local startIdx = tonumber(startArg) or 1
            local gap = tonumber(gapArg) or 0.5
            if startIdx > #list then
                Print(format("|cffff3333[QuestEcho]|r selftest: start %d out of range (1..%d)", startIdx, #list))
            else
                Print(format("|cff33ffcc[QuestEcho]|r selftest: %s (%d files) from %d, one every %gs. Turn game volume to minimum first (decode still runs). If the game hangs, the last printed file is the culprit; restart and continue with the next index.", filter == "" and "all" or filter, #list, startIdx, gap))
                local sf = CreateFrame("Frame")
                sf.list = list
                sf.index = startIdx
                sf.gap = gap
                sf:SetScript("OnUpdate", function()
                    if GetTime() < (sf.nextAt or 0) then
                        return
                    end
                    local e = sf.list[sf.index]
                    if not e then
                        sf:SetScript("OnUpdate", nil)
                        Print("|cff33ffcc[QuestEcho]|r selftest done")
                        return
                    end
                    local p = format("../../Interface/AddOns/QuestEchoData/generated/sounds/%s/%s", e.dir, e.file)
                    Print(format("|cff33ffcc[QuestEcho]|r [%d/%d] %s/%s", sf.index, #sf.list, e.dir, e.file))
                    local ok = pcall(PlaySoundFile, p)
                    if not ok then
                        Print(format("|cffff3333[QuestEcho]|r   PlaySoundFile FAILED: %s", p))
                    end
                    sf.index = sf.index + 1
                    sf.nextAt = GetTime() + sf.gap
                end)
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
                        -- the file plays out of band (possibly volume-scaled);
                        -- bring the game volume back once it has finished
                        if okPlay and sd.length then
                            afterDelay(sd.length + 1.0, function()
                                Utils:RestoreSoundSettings()
                            end)
                        end
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
    elseif command == "locale" then
        local ok, locale = pcall(GetLocale)
        Print(format("|cff33ffcc[QuestEcho]|r GetLocale() -> ok=%s value=|cffffffff%s|r", tostring(ok), tostring(locale)))
        DataModules:EnumerateAddons()
        local present = {}
        for _, m in ipairs(DataModules.presentModulesOrdered) do
            table.insert(present, tostring(m.AddonName) .. " (prio " .. tostring(m.ModulePriority) .. ")")
        end
        Print(format("|cff33ffcc[QuestEcho]|r present modules: |cffffffff%s|r", #present > 0 and table.concat(present, ", ") or "none"))
        local registered = {}
        for name in pairs(DataModules.registeredModules) do
            table.insert(registered, tostring(name))
        end
        Print(format("|cff33ffcc[QuestEcho]|r registered modules: |cffffffff%s|r", #registered > 0 and table.concat(registered, ", ") or "none"))
        if QuestEchoData then
            Print(format("|cff33ffcc[QuestEcho]|r QuestEchoData table: |cffffffff%s|r (NPCNameLookupByNPCID=%s, GossipLookupByNPCName=%s, QuestIDLookup=%s)",
                tostring(type(QuestEchoData)),
                tostring(type(QuestEchoData.NPCNameLookupByNPCID)),
                tostring(type(QuestEchoData.GossipLookupByNPCName)),
                tostring(type(QuestEchoData.QuestIDLookup))))
        else
            Print("|cff33ffcc[QuestEcho]|r QuestEchoData table: |cffffffffnil|r")
        end
    else
        Print("|cffff3333[QuestEcho]|r " .. format(L("unknown command: %s — type /qe for help", "未知命令：%s — 输入 /qe 查看帮助"), tostring(command)))
    end
end

SLASH_QUESTECHO1, SLASH_QUESTECHO2 = "/qe", "/questecho"
SlashCmdList["QUESTECHO"] = HandleSlashCommand

-- =============================================================================
-- Startup
-- =============================================================================
-- Enumerate present data modules before anything can register against us.
pcall(DataModules.EnumerateAddons, DataModules)

-- Actively load the data pack matching the client locale. The data packs are
-- LoadOnDemand: without this call their Module.lua never runs (the old
-- VoiceOver addon loaded its data pack the same way). Locale-specific clients
-- get their own pack (zhCN / ruRU / esES), everyone else the base pack.
local DATA_PACK_BY_LOCALE =
{
    ["zhCN"] = "QuestEchoData-zhCN",
    ["ruRU"] = "QuestEchoData-ruRU",
    ["esES"] = "QuestEchoData-esES",
}
local function LoadLocaleDataPack()
    local ok, locale = pcall(GetLocale)
    local addonName = (ok and DATA_PACK_BY_LOCALE[locale]) or "QuestEchoData"
    local loaded, reason = pcall(LoadAddOn, addonName)
    if not loaded then
        -- Some clients expose the loader under a different name.
        local ok2, loaded2, reason2 = pcall(C_AddOns and C_AddOns.LoadAddOn, addonName)
        if not (ok2 and loaded2) then
            -- Fall back to requesting by metadata-flagged addons.
            for _, m in ipairs(DataModules.presentModulesOrdered) do
                if m.AddonName == addonName then
                    pcall(LoadAddOn, m.AddonName)
                    break
                end
            end
        end
    end
    -- Re-enumerate so the newly loaded pack appears in presentModules.
    pcall(DataModules.EnumerateAddons, DataModules)
end
pcall(LoadLocaleDataPack)

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
