QuestEcho — Emberveil port (v1.5.1)
==========================================

IMPORTANT — sound files
  The Emberveil client's audio engine does not play mp3 (it is Unreal-based,
  SoundWave/ogg). The 9555 voice lines are converted to .ogg (vorbis,
  44.1 kHz mono) in QuestEchoData\generated\sounds\; the original
  mp3s were deleted after conversion (they are not used). Paths are resolved
  relative to the executable directory, so playback uses
  ../../Interface/AddOns/... with forward slashes. Verified live in-game:
  /qe soundprobe variant "ogg exe-dir up2" is audible.

This is a from-scratch rewrite for the Emberveil client
(Unreal Azeroth, WoW 1.12.1). The classic WoW addon it is based on
cannot run on this client as-is.

Why a rewrite instead of the original files?
  The Emberveil client implements a vanilla-shaped Lua/UI surface with its own
  quirks (no UnitGUID, no StaticPopup, no hookable quest-log UI). The original
  addon depends on Ace3 + XML templates + APIs this client does not provide,
  so it cannot run as-is. This port follows the same pattern used by the other
  verified Emberveil addons (KoQuest, AllBags): plain Lua, no Ace, only APIs
  confirmed present in the client binary. Data is loaded straight from the
  .toc (no XML dependency).

What works
  - Quest accept voice lines (QUEST_DETAIL when the client fires it; plus a
    0.5s poll that auto-plays the accept voice the first time a new quest
    appears in the quest log - the first poll only primes existing quests)
  - Quest complete / turn-in voice lines (QUEST_COMPLETE)
  - NPC gossip voice lines (GOSSIP_SHOW) and quest greetings (QUEST_GREETING)
  - Gender-correct voice files (male/female variants from the data pack)
  - Sound queue: lines play one after another; gossip is skipped while a quest
    line is playing; duplicates are ignored
  - Quest replay window (/qe questlog): lists your current quests (title +
    quest giver) with accept/complete play buttons and a count summary. This
    is the play-button interface for quest voice lines on this client.
  - Quest-log integration: if the client exposes the vanilla quest-log frames
    at runtime, a "Play task voice" button is attached to the right of the
    quest title in the quest log detail pane (no setup needed). The complete
    voice plays automatically when the quest is turned in. Clients that render
    the quest log with the engine have no such frames, and the attach is
    skipped silently.
  - Gossip trigger: if the client does not fire GOSSIP_SHOW / QUEST_GREETING
    (engine-rendered gossip window), a poll every 0.4s detects an open gossip
    via UnitName("npc") + GetGossipText() and plays the matching line; the
    event handlers remain for clients that do fire them, deduped by signature.
  - Runtime diagnostics (/qe probe): dumps which quest-log globals and data
    APIs exist in this client, reads back your current quest log, and plays a
    real test file with the resolved path — useful when reporting issues.
  - Sound path probe (/qe soundprobe): plays the same short voice line once per
    path/format variant (ogg/wav loose files, PlayRadio file:// URLs) and
    reports each result, to find out how this client resolves sound paths
    when nothing is audible. The client's audio engine is Unreal-based and
    supports ogg; its mp3 playback is unproven, so the probe includes
    converted ogg/wav test files.
  - Settings panel (/qe settings): gossip frequency, line delay, status bar,
    debug, test/clear buttons
  - Status bar at the bottom of the screen (classic opaque panel with a gold
    border): gear (settings) / pause / clear buttons; it expands into a live
    queue list where every line (playing or queued) has its own X to remove
    just that line. Hold Shift and drag to move it (position is remembered)
  - Settings panel (/qe settings) uses the same opaque classic-WoW look; hold
    Shift and drag its title area to move it
  - Data module QuestEchoData is bundled as Data\ and also works
    if the standalone pack loads by itself

Why there are no buttons inside the client's quest log
  The Emberveil client renders its quest log (L) with the Unreal engine, not
  with Lua frames. Verified against the client files: the shipped FrameXML
  (in the game pak) contains only chat/unitframe/minimap-style UIs, and
  neither the pak nor the executable contains QuestLogFrame, QuestLogTitle1,
  QuestLog_Update or any quest-log UI globals (only the quest log DATA
  functions exist: GetQuestLogTitle, GetNumQuestLogEntries, ...). Lua addons
  therefore cannot place buttons inside that window. If the client ever ships
  a Lua quest log, the built-in quest-log integration attaches the voice
  buttons automatically; /qe probe shows which world you are in.
  The Show/Hide/Clean/Reset and Translate buttons you see in the client's
  quest log are rendered by the client itself, not by quest addons.

Commands (/qe)
  /qe               help
  /qe pause         pause / resume the queue
  /qe clear         clear the queue and stop the current line
  /qe gossip        show current gossip frequency
  /qe gossip always|once|oncequest|never
  /qe delay <sec>   delay before a voice line starts (default 0.3)
  /qe ui            toggle the status bar
  /qe questlog      open the quest replay window (ql works too)
  /qe settings      open the settings panel (options / opt work too)
  /qe debug         toggle debug messages
  /qe test          play a test voice line (quest 5) with precise diagnostics
  /qe status        show queue + data module + sound state

Troubleshooting
  - "/qe test failed: data module not loaded" -> the Data\ tables did not
    register; check /qe status and reload UI. The .toc loads the data files
    directly, so a missing file in Data\generated\ is the usual cause.
  - /qe status prints the raw Sound_EnableAllSound / Sound_EnableSFX cvar
    values for reference. The client does not keep these cvars in sync with
    the real master audio, so playback is never blocked by them.
  - If a window command appears to do nothing, /qe status still works; the
    panel will now print the actual error in chat instead of failing
    silently. Known client quirk: Frame:SetSize and Frame:SetShown do not
    exist on Emberveil — the port uses SetWidth/SetHeight and Show/Hide.
  - Quest replay window shows "No current quests with voice lines found." ->
    the data pack only covers English quest titles; localized quest titles do
    not match, and quests without a voice pack have no buttons.

Updating the voice pack
  The mp3 files live in the QuestEchoData addon
  (generated\sounds\quests\ and generated\sounds\gossip\). To update the pack,
  replace that addon's files. The lookup tables used by this addon are copied
  in Data\ — refresh them from QuestEchoData\generated\ whenever the
  pack is updated (or simply let the standalone pack load: it re-registers and
  takes priority automatically).

Notes / limitations of the client
  - No UnitGUID: voice lookups are name-based only (same as vanilla 1.12).
  - No Lua-hookable quest log UI: replay buttons live in our own window
    (/qe questlog) instead of the client's quest log.
  - GOSSIP_SHOW / QUEST_GREETING / QUEST_LOG_UPDATE are registered
    defensively; if the client does not fire them, gossip lines will not
    trigger (quest lines still will).
  - Pause mutes the master sound channel as a best effort; the client cannot
    interrupt a playing file mid-way.
