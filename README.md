# mac-migrate

用 shell script 在換 Mac 時備份舊機器、還原到新機器。
請將 `backup.sh`、`restore.sh`、`encrypt-backup.sh` 與共用的 `migration-common.sh` 放在一起（建議直接 clone 專案）。

## 流程

```
舊機器                          新機器
  │                               │
  ├─ bash backup.sh               │
  │   └─ 產生 mac-migration/      │
  │                               │
  └─ 傳送 mac-migration/ ────────►├─ bash restore.sh
     （AirDrop / 外接碟 / iCloud）     └─ 自動安裝還原
```

## 使用方式

### 舊機器：匯出

在任意目錄執行，會在該目錄下建立 `mac-migration/`：

```bash
bash backup.sh
```

若已有 `mac-migration/`，會先改名為 `mac-migration-YYYYMMDD-HHMMSS/`，
再建立全新的備份資料夾，避免上次的檔案（包含 SSH keys）殘留。
名稱若已存在會加上 `-1`、`-2` 等序號。舊備份不會自動刪除，請自行清理；
完成時會顯示新舊備份路徑。時間戳使用本機時間。

### 可選：密碼加密備份

使用 macOS 內建工具建立 AES-256 加密 `.dmg`，新舊 Mac 都不需額外安裝 App。

`backup.sh` 完成後會詢問是否加密，預設不加密。請將
`encrypt-backup.sh` 與 `backup.sh` 放在同一目錄。
也可以直接加密已經產生的備份，不必重新備份：

```bash
bash encrypt-backup.sh /path/to/mac-migration
```

此指令只接受名稱為 `mac-migration`、且包含 `dotfiles/`、`ssh/`、`defaults/` 的資料夾。
若要加密舊的 `mac-migration-YYYYMMDD-HHMMSS/`，請先將它移至另一個目錄，
並改名為 `mac-migration`，避免與目前備份衝突。

會在備份資料夾旁產生 `mac-migration-YYYYMMDD-HHMMSS.dmg`，
遇到同名檔案會加序號。映像檔為壓縮唯讀格式，內容與檔名需解鎖後才能讀取。
請在互動式終端機輸入非空密碼；密碼不會顯示，也不會存入命令列、環境變數或設定檔。
請自行妥善保存密碼，遺失後無法透過這些 script 復原。

建立後會要求再次輸入密碼，解密並檢查映像檔完整性。
只有驗證成功才會詢問是否刪除本次明文資料夾，預設保留。
加密或驗證失敗會保留明文，清除本次未完成的暫存映像檔並回傳失敗。

`backup.sh` 的結束狀態碼：`0` 表示完成所選步驟（也可能選擇不加密）；
`1` 表示備份階段失敗；`2` 表示明文備份已完成，但選擇的加密步驟失敗。
遇到 `2` 可直接重跑 `encrypt-backup.sh`，不必重新備份。
單獨執行 `encrypt-backup.sh` 時，加密或驗證失敗仍回傳 `1`。

較早的 `mac-migration-*/` 備份不會自動加密或刪除；保留的明文仍需妥善保管。
刪除是一般檔案刪除，不保證安全抹除磁碟內容。
映像檔只包含 `mac-migration/` 的內容，不包含外部的 Mackup storage。

在新 Mac 雙擊 `.dmg`，輸入密碼後會掛載名為 `mac-migration` 的磁碟。
備份內容（`dotfiles/`、`ssh/` 等）就在磁碟根目錄，可直接還原：

```bash
bash restore.sh --dry-run --migration-dir /Volumes/mac-migration
bash restore.sh --migration-dir /Volumes/mac-migration
```

若同名磁碟已存在，macOS 可能使用不同掛載路徑，請以 Finder 顯示的實際路徑為準。
也可以先把磁碟內容複製到本機的 `mac-migration/` 再還原。
完成後在 Finder 退出磁碟；`restore.sh` 接受掛載後的資料夾，不直接接受 `.dmg`。

### 新機器：安裝還原

將 `mac-migration/` 資料夾傳到新機器，放在同一個目錄下執行：

```bash
bash restore.sh
```

或指定資料夾路徑：

```bash
bash restore.sh --migration-dir /path/to/mac-migration
```

先檢查會做哪些事、但不實際安裝或覆蓋檔案：

```bash
bash restore.sh --dry-run --migration-dir /path/to/mac-migration
```

## 備份內容

| 項目 | 說明 |
|---|---|
| `Brewfile` | 所有 Homebrew packages / casks / taps |
| `dotfiles/` | `.zshrc` / `.gitconfig` / `.npmrc` 等 shell & 工具設定 |
| `dotfiles/.config/` | 整個 `~/.config/`，含 Starship、GitHub CLI、其他工具的設定與隱藏檔 |
| `mackup.cfg` | mackup storage 設定（供 `--config-file` 使用） |
| `developer/` | AI 工具與編輯器使用者資料（詳見下方範圍） |
| `extensions/` | VS Code 系列預設 profile 的擴充套件 ID 與版本清單 |
| `ssh/` | 預設 config / known_hosts；選擇完整備份時包含整個 `~/.ssh/` |
| `defaults/` | 可匯入的 macOS／App 偏好 plist |
| `versions.txt` | 各開發工具版本號紀錄 |

## 還原內容

| 步驟 | 說明 |
|---|---|
| Xcode Command Line Tools | 自動安裝 |
| Homebrew | 自動安裝，並從 Brewfile 還原所有套件 |
| dotfiles | 自動複製回 `~/` |
| `.config` | 合併還原至 `~/.config/`；覆蓋同名檔案，保留新機器其他檔案，亦相容舊版僅備份 gh 的格式 |
| AI／編輯器資料 | 確認後還原完整副本，既有資料改名為 `.before-restore-*` 保留 |
| 編輯器擴充套件 | CLI 可用時，確認後依 ID／版本重新安裝 |
| SSH config & keys | 完整備份可確認後合併還原；仍相容舊版 `id_*` 格式與產生新 key 的流程 |
| macOS defaults | 確認後匯入備份中的偏好，不再套用寫死的預設值 |
| nvm / Node | 安裝 nvm，提示安裝舊機器相同版本 |
| mackup restore | 還原 app 設定（需 storage 同步完成） |

## AI 工具與編輯器範圍

只備份存在的路徑，未安裝的工具會跳過。備份與還原使用同一份路徑清單：

| 類別 | 內容／路徑 |
|---|---|
| Codex | `~/.codex/`，或 `CODEX_HOME` 指定的位置：設定、skills、plugins、sessions 等本機資料 |
| Claude Code | `~/.claude/`（可用 `CLAUDE_CONFIG_DIR` 指定）、`~/.claude.json` |
| 共用 agents／skills | `~/.agents/` |
| 桌面 AI App | `~/Library/Application Support/` 下的 `Codex`、`com.openai.codex`、`Claude`、`com.openai.chat`（若存在）；另匯出對應偏好 domain |
| VS Code／Insiders／Cursor／Windsurf | 各自 `Application Support` 的 `User/`，包含 settings、keybindings、snippets、profiles 和本機狀態；另存 VS Code／Cursor 的 `argv.json` |
| JetBrains | `~/Library/Application Support/JetBrains/` |
| Vim／Emacs | 原有 `.vimrc`，加上 `.vim/`、`.gvimrc`、`.ideavimrc`、`.emacs`、`.emacs.d/`；Neovim 設定已由 `.config/` 涵蓋 |

`CODEX_HOME`／`CLAUDE_CONFIG_DIR` 請使用絕對路徑；新機器還原時，以新機器上的環境變數或預設路徑為準。
目錄內部的符號連結保留為連結，外部目標不會自動收集；socket／device 等執行期物件不備份。
使用者資料目錄中的歷史、plugins 與快取也可能包含在內，因此備份可能較大。

**備份及還原前，請先關閉相關 AI App、CLI 與編輯器。** 正在寫入的資料庫無法保證一致性。
還原時先準備副本，再把目的地原資料改名保留，以免舊資料庫的 WAL 等殘留檔案混進備份。
`.before-restore-*` 是未加密的舊資料，請在確認完成後自行管理；失敗時保留的備份同樣需要妥善保管。

這些本機檔案不等於雲端聊天備份，也不包含 Keychain、App sandbox 的完整容器或專案目錄。
登入狀態不保證可跨機搬移；仍可能需要重新登入。專案內的 `.claude/`、`AGENTS.md`、`.env` 等需另行備份。
編輯器 CLI 不可用時會提示並保留擴充套件清單；特定舊版本若下架，可能需手動改裝新版。

## SSH 與偏好設定還原

還原流程的確認問題請輸入 `y`／`yes` 再按 Enter 才會執行；直接 Enter、`n` 或輸入結束皆視為否。
Dry-run 仍預覽所有確認為「是」的分支，不執行變更。

- 選擇完整 SSH 備份後，包含自訂名稱的金鑰、`config.d/`、`authorized_keys`、公鑰及隱藏檔。
  還原後目錄權限為 `700`、一般檔案為 `600`，不追蹤符號連結修改外部權限。
  新機器原有、不與備份同名的 SSH 檔案會保留。
- 拒絕完整 SSH 還原時，仍還原 `config`／`known_hosts` 並明確提示略過私鑰及其他檔案；與舊版備份行為一致。
- 拒絕完整備份時只保存 `config` 與 `known_hosts`，不自動猜測哪些額外檔案可安全帶走。
  `Include`／`IdentityFile` 若指向 `~/.ssh/` 以外（或外部符號連結目標），需另外備份。
- 偏好包含 Dock、Finder、截圖、Terminal、Safari、TextEdit、全域鍵盤設定、觸控板、iTerm2 及上述 AI App domain。
  匯入會取代該 domain 的偏好，未備份的 domain 不變更。只有成功匯入 Dock／Finder 後才重啟它們。
  若單一 domain 匯入失敗（例如權限不足），會提示並繼續其他還原項目，不重啟該 domain 的 App；失敗項目需之後重試。
- 舊 `defaults/*.txt` 若可解析為 plist，也可匯入；無法解析或損壞的檔案會提示並跳過，不會套用預設值替代。
  舊帳號的絕對路徑（例如截圖位置）與機器特定設定不會自動改寫，換機後可能需調整。
- `.curlrc`、`.wgetrc` 現在會與其他 dotfiles 一起還原。Shell 設定只複製，不在 Bash 還原程序中執行；請另開終端機載入。

## 注意事項

- **`.config` 範圍**：整個 `~/.config/` 都會備份，沒有排除 Token、快取或其他資料，建議使用加密 DMG。內部符號連結保留為連結，不會額外收集外部目標；根目錄 `~/.config` 若是符號連結，則備份其目錄內容。自訂 `XDG_CONFIG_HOME`／`STARSHIP_CONFIG` 指向此目錄以外的設定不會自動收集。
- **SSH private keys**：`backup.sh` 會詢問是否備份，備份後請妥善保管，不建議放 iCloud
- **Dry-run**：`restore.sh --dry-run` 只會列出將執行的動作，不會安裝套件、複製檔案、寫入 defaults、產生 SSH key 或重啟 Dock/Finder
- **macOS defaults**：套用前需要 Terminal 有完整磁碟存取權限（系統設定 → 隱私權與安全性）
- **mackup**：執行 restore 前需確認 storage 已同步。storage 設定備份於 `mac-migration/mackup.cfg`，restore.sh 會自動以 `--config-file` 傳入，支援 iCloud、Dropbox、Google Drive、或自訂路徑（`file_system`）
- **VS Code `code` 指令**：安裝後需手動註冊 shell command 才能在終端機使用 `code`。開啟 Command Palette → 執行「Shell Command: Install 'code' command in PATH」。詳見 [官方說明](https://code.visualstudio.com/docs/setup/mac#_launch-vs-code-from-the-command-line)
- `mac-migration/` 資料夾包含敏感資訊，不應上傳到任何雲端或公開服務
