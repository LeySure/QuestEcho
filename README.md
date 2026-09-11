# QuestEcho

![](screenshots/QuestEcho.png)
Voice add‑on for Emberveil WoW 1.12.1 client.  

Plays audio voice lines when you accept / complete quests and interact with NPC gossip.   

Adds an **Echo** button inside quest log, playback queue status bar, settings panel and replay window.   

![](https://github.com/LeySure/QuestEcho/blob/main/screenshots/quest%20echo%20button.png)

![](https://github.com/LeySure/QuestEcho/blob/main/screenshots/status%20bar%20and%20settings.png)

Chat command: `/qe`
> ⚠️ This addon **requires language‑specific audio data pack**. Core addon alone has no sound.
## Downloads
- Main Addon: [QuestEcho‑1.5.2.zip](https://github.com/LeySure/QuestEcho/releases/download/1.5.2/QuestEcho-1.5.2.zip)
- Audio Data Packs:
  - enUS: [QuestEchoData-enUS.zip](https://github.com/LeySure/QuestEcho/releases/download/1.5.2/QuestEchoData-enUS.zip) — extract to folder **`QuestEchoData`**
  - zhCN: [QuestEchoData-zhCN.zip](https://github.com/LeySure/QuestEcho/releases/download/1.5.2/QuestEchoData-zhCN.zip) — extract to folder **`QuestEchoData-zhCN`**
  - ruRU: (coming soon)
## Installation
1. Extract `QuestEcho` into `Interface/AddOns`
2. Extract the audio data pack(s) alongside QuestEcho in `Interface/AddOns`:
   - English client → folder name **`QuestEchoData`**
   - Chinese client → folder name **`QuestEchoData-zhCN`**
3. Restart your WoW client.
### Both packs can coexist
The English pack and the Chinese pack can be installed **at the same time** — they use different folder names (`QuestEchoData` / `QuestEchoData-zhCN`) and do not overwrite each other. The addon automatically picks the audio matching your client language: English clients read from `QuestEchoData`, Chinese (zhCN) clients read from `QuestEchoData-zhCN`. You can switch the game language without touching the addon folders.
## Features
‑ Auto‑play voice for quest accept / complete
‑ NPC gossip voice playback
‑ In‑quest‑log Echo replay button
‑ Play queue status bar, pause / clear / remove single audio item
‑ Configurable settings panel via `/qe settings`
‑ Replay window for reviewing quest voice lines
‑ Chinese client support: UI and voice matching localized for zhCN
## Commands
/qe          Show help
/qe settings Open settings panel
/qe questlog Open replay window
/qe status   Show current queue status
## Notes
‑ Each language data pack is separate large‑size archive (~1.2GB).
‑ Keep only the pack(s) matching your client language; the addon ignores packs of other languages.
‑ If button is greyed‑out: no available voice for this quest.
## 中文说明
QuestEcho 是 Emberveil（1.12.1）语音插件。接取、完成任务以及NPC对话时播放对应语音。
任务日志会显示Echo按钮，附带播放队列状态栏与设置面板。聊天指令 `/qe`。
> ⚠️ 本体插件**不包含语音**，必须安装对应语言数据包才有声音。
### 下载
- 主插件：[QuestEcho‑1.5.2.zip](https://github.com/LeySure/QuestEcho/releases/download/1.5.2/QuestEcho-1.5.2.zip)
- 英文数据包：[QuestEchoData-enUS.zip](https://github.com/LeySure/QuestEcho/releases/download/1.5.2/QuestEchoData-enUS.zip) — 解压后文件夹名 **`QuestEchoData`**
- 中文数据包：[QuestEchoData-zhCN.zip](https://github.com/LeySure/QuestEcho/releases/download/1.5.2/QuestEchoData-zhCN.zip) — 解压后文件夹名 **`QuestEchoData-zhCN`**
### 安装
1. 将 `QuestEcho` 解压到 `Interface/AddOns`
2. 将语言数据包解压到同一目录 `Interface/AddOns`：
   - 英文客户端 → 文件夹名 **`QuestEchoData`**
   - 中文客户端 → 文件夹名 **`QuestEchoData-zhCN`**
3. 重启游戏。
### 两个数据包可以共存
英文包和中文包**可以同时安装**——它们使用不同的文件夹名（`QuestEchoData` / `QuestEchoData-zhCN`），互不覆盖。插件会根据客户端语言自动选择对应音频：英文客户端读取 `QuestEchoData`，中文（zhCN）客户端读取 `QuestEchoData-zhCN`。切换游戏语言时无需改动插件目录。
### 说明
- 每个语言数据包为独立的大体积压缩包（约1.2GB）。
- 只保留与客户端语言匹配的包即可，插件会自动忽略其他语言的包。
- Echo按钮灰色表示该任务没有对应语音。
