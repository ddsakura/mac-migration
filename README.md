# mac-migrate

兩支 shell script，讓你在換 Mac 時快速備份舊機器、還原到新機器。

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
| `mackup.cfg` | mackup storage 設定（供 `--config-file` 使用） |
| `ssh/config` | SSH host 設定（private key 選擇性備份） |
| `defaults/` | macOS 系統偏好設定（純文字，供參考） |
| `versions.txt` | 各開發工具版本號紀錄 |

## 還原內容

| 步驟 | 說明 |
|---|---|
| Xcode Command Line Tools | 自動安裝 |
| Homebrew | 自動安裝，並從 Brewfile 還原所有套件 |
| dotfiles | 自動複製回 `~/` |
| SSH config & keys | 自動還原，或產生新的 ed25519 key |
| macOS defaults | 套用 Dock / Finder / 鍵盤 / 觸控板等偏好設定 |
| nvm / Node | 安裝 nvm，提示安裝舊機器相同版本 |
| mackup restore | 還原 app 設定（需 storage 同步完成） |

## 注意事項

- **SSH private keys**：`backup.sh` 會詢問是否備份，備份後請妥善保管，不建議放 iCloud
- **Dry-run**：`restore.sh --dry-run` 只會列出將執行的動作，不會安裝套件、複製檔案、寫入 defaults、產生 SSH key 或重啟 Dock/Finder
- **macOS defaults**：套用前需要 Terminal 有完整磁碟存取權限（系統設定 → 隱私權與安全性）
- **mackup**：執行 restore 前需確認 storage 已同步。storage 設定備份於 `mac-migration/mackup.cfg`，restore.sh 會自動以 `--config-file` 傳入，支援 iCloud、Dropbox、Google Drive、或自訂路徑（`file_system`）
- **VS Code `code` 指令**：安裝後需手動註冊 shell command 才能在終端機使用 `code`。開啟 Command Palette → 執行「Shell Command: Install 'code' command in PATH」。詳見 [官方說明](https://code.visualstudio.com/docs/setup/mac#_launch-vs-code-from-the-command-line)
- `mac-migration/` 資料夾包含敏感資訊，不應上傳到任何雲端或公開服務
