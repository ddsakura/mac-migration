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

### 新機器：安裝還原

將 `mac-migration/` 資料夾傳到新機器，放在同一個目錄下執行：

```bash
bash restore.sh
```

或指定資料夾路徑：

```bash
bash restore.sh --migration-dir /path/to/mac-migration
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

- **SSH private keys**：export.sh 會詢問是否備份，備份後請妥善保管，不建議放 iCloud
- **macOS defaults**：套用前需要 Terminal 有完整磁碟存取權限（系統設定 → 隱私權與安全性）
- **mackup**：執行 restore 前需確認 storage 已同步。storage 設定備份於 `mac-migration/mackup.cfg`，restore.sh 會自動以 `--config-file` 傳入，支援 iCloud、Dropbox、Google Drive、或自訂路徑（`file_system`）
- `mac-migration/` 資料夾包含敏感資訊，不應上傳到任何雲端或公開服務
