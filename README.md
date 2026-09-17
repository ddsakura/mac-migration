# mac-migrate

備份 Mac 的開發環境、設定與指定 App 本機資料，供換機或原機清除重裝後還原。

**目前不備份 `~/Downloads`、`~/Programming` 或整個家目錄。** 這些資料需另外複製到外部儲存。

## 取得專案

在 Terminal 執行：

```bash
git clone https://github.com/ddsakura/mac-migration.git mac-migrate
cd mac-migrate
```

以下指令均在專案目錄執行，另有說明的除外。若系統提示安裝 Command Line Tools，先完成安裝再重試。
新機或重裝後也先執行上述指令，取得還原程式。

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

### 備份：換機或清除重裝前

先關閉相關 AI App、CLI 與編輯器，再從 Terminal 執行：

```bash
bash backup.sh
```

備份會寫入**執行指令當下目錄**的 `mac-migration/`。依上述步驟操作時，位於專案目錄內。
若要直接備份到外接硬碟，先切換到備份目的地，再用完整路徑執行 script：

```bash
# 將兩個範例路徑改成自己的路徑
cd "/Volumes/你的外接硬碟/備份目錄"
bash "/你的專案路徑/mac-migrate/backup.sh"
```

目的地資料夾需先建立，且不能位於本次備份的來源目錄內。

若已有 `mac-migration/`，會先改名為 `mac-migration-YYYYMMDD-HHMMSS/`，
再建立全新的備份資料夾，避免上次的檔案（包含 SSH keys）殘留。
名稱若已存在會加上 `-1`、`-2` 等序號。舊備份不會自動刪除，請自行清理；
完成時會顯示新舊備份路徑。時間戳使用本機時間。

### 可選：密碼加密備份

使用 macOS 內建工具建立 AES-256 加密 `.dmg`，新舊 Mac 都不需額外安裝 App。

`backup.sh` 完成後會詢問是否加密，預設不加密。
也可以在專案目錄執行以下指令，加密既有備份：

```bash
bash encrypt-backup.sh /path/to/mac-migration
```

此指令只接受名稱為 `mac-migration`、且包含 `dotfiles/`、`ssh/`、`defaults/` 的資料夾。
若要加密舊的 `mac-migration-YYYYMMDD-HHMMSS/`，請先將它移至另一個目錄，
並改名為 `mac-migration`，避免與目前備份衝突。

會在備份資料夾旁產生 `mac-migration-YYYYMMDD-HHMMSS.dmg`，
遇到同名檔案會加序號。映像檔為 APFS（區分大小寫）的壓縮唯讀格式，需 macOS 10.13 或更新版本；內容與檔名需解鎖後才能讀取。
APFS 保留 Unicode 檔名形式，避免 HFS+ 正規化檔名後與完整性清單不符。
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

### 還原：新機或重裝後

先 clone 本專案，接上備份硬碟；若使用 DMG，先雙擊並輸入密碼掛載。
保持相關 AI App、CLI 與編輯器關閉，在專案目錄先預覽，再執行還原：

```bash
# /path/to/mac-migration 請改成備份資料夾或 DMG 掛載路徑
bash restore.sh --dry-run --migration-dir /path/to/mac-migration
bash restore.sh --migration-dir /path/to/mac-migration
```

`--dry-run` 會校驗備份並預覽操作，不會安裝或覆寫資料。
若備份就在目前目錄的 `mac-migration/`，可省略 `--migration-dir`。
還原後開啟備份中的 `installed-apps.txt`，逐項補裝 App Store 或手動下載的 App。

### 原機清除重裝前

- 將本專案產生的備份、另外保存的 Downloads 與 Programming 放到外部儲存；不要只留在原機。
- Programming 請保留隱藏檔、`.git`、`.env`、未提交及未追蹤檔案。Git push 不涵蓋這些全部資料。
- 從外部副本執行[完整性驗證](#完整性驗證與舊備份)；加密 DMG 先確認密碼可用。此校驗只涵蓋本專案備份，另存的 Downloads／Programming 需另外確認。
- 備份可讀且重要資料齊全後再清除原機。Dry-run 是預檢，不是完整還原演練。

## 備份內容

下表左欄是產生的 `mac-migration/` 內的位置，不是原機上的來源目錄。
`dotfiles/` 是 script 建立的分類資料夾，**不會掃描或備份家目錄下所有隱藏檔**。

| 備份內位置 | 備份來源／內容 |
|---|---|
| `Brewfile` | 所有 Homebrew packages / casks / taps |
| `dotfiles/` | 家目錄中指定的 14 個設定檔，以及整個 `~/.config/`；完整清單見下方 |
| `extra-settings/` | 額外 Shell 設定、服務憑證、雲端工具、GPG、Docker 設定及自訂腳本，完整清單見下方 |
| `mackup.cfg` | mackup storage 設定（供 `--config-file` 使用） |
| `developer/` | AI 工具與編輯器使用者資料（詳見下方範圍） |
| `extensions/` | VS Code 系列預設 profile 的擴充套件 ID 與版本清單 |
| `ssh/` | 預設 config / known_hosts；選擇完整備份時包含整個 `~/.ssh/` |
| `defaults/` | 可匯入的 macOS／App 偏好 plist |
| `versions.txt` | 各開發工具版本號紀錄 |
| `installed-apps.txt` | `/Applications` 與 `~/Applications` 的 App 名稱、版本、路徑，供新機重新安裝參考 |
| `backup-format` / `manifest.json` | v1 格式標記、完整相對路徑清單與 SHA-256／符號連結校驗資訊 |

`dotfiles/` 收集以下來源，來源不存在就略過：

| 來源（相對於 `~/`） | 備份內位置 |
|---|---|
| `.zshrc`、`.zprofile`、`.zshenv`、`.bashrc`、`.bash_profile`、`.aliases` | `dotfiles/` 下的同名檔案 |
| `.gitconfig`、`.gitignore_global`、`.gitignore` | `dotfiles/` 下的同名檔案 |
| `.vimrc`、`.editorconfig` | `dotfiles/` 下的同名檔案 |
| `.curlrc`、`.wgetrc`、`.npmrc` | `dotfiles/` 下的同名檔案 |
| `.config/` 的全部內容，含隱藏檔、Starship、GitHub CLI 與其他工具設定 | `dotfiles/.config/` |

其他家目錄隱藏檔不會因為是 dotfile 就自動備份。
`.ssh/`、`.codex/` 等另依各自的備份規則處理，見上表及下方範圍說明。

`extra-settings/` 使用以下固定清單，存在就備份，不存在就略過：

| 來源（相對於 `~/`） | 備份內位置（相對於 `extra-settings/`） |
|---|---|
| `.profile`、`.zlogin`、`.zlogout` | `profile`、`zlogin`、`zlogout` |
| `.netrc`、`.pypirc` | `netrc`、`pypirc` |
| `.aws/`、`.azure/`、`.kube/`、`.gnupg/` | `aws/`、`azure/`、`kube/`、`gnupg/` |
| `.docker/config.json`、`.docker/contexts/` | `docker-config`、`docker-contexts/` |
| `bin/`、`.local/bin/` | `bin/`、`local-bin/` |

這些項目可能包含密碼、Token 與 GPG 私鑰，會自動納入備份與完整性清單，建議使用加密 DMG。
目錄包含隱藏檔與快取，但排除 socket／device 等執行期物件；備份前請停止相關工具的寫入。
內部符號連結只保存連結，不收集外部目標；來源根節點若是符號連結，會提示略過，需另備份目標。
不整包備份 `.local/share/`，不包含 Docker 容器／images／volumes，亦不收集設定引用的外部憑證或腳本。
自訂環境變數指向其他位置的工具資料未自動收集；Docker credential helper 所使用的 Keychain 也不在範圍內。
還原時逐項詢問，接受後整份替換，現有資料另存 `.before-restore-*`；不合併目錄，也不跨項目回復。
舊備份沒有這些項目時直接略過。還原不會執行 Shell 設定或腳本，也不保證服務登入仍有效。
單一額外項目複製失敗時，會繼續其他項目、後續備份與校驗，並將失敗 ID 寫入
`extra-settings-failed.txt`（也納入校驗）。最後回傳狀態碼 `1`，不顯示完成或進入加密詢問；
請修正錯誤後重新備份，再清除原機。部分副本保留供檢查，但還原會略過失敗清單中的項目，
避免用不完整資料取代現有設定。校驗通過只表示已保存的內容一致，不表示所有來源都備份成功。

`installed-apps.txt` 也涵蓋上述位置中手動下載安裝的 `.app`，包含 Utilities 等子資料夾，
但不列出 App bundle 內附的 helper apps、不追蹤一般資料夾符號連結，也不掃描 `/System/Applications` 或其他位置。
讀不到版本時記為 `unknown`；特殊字元使用 Bash `%q` 跳脫，避免檔名換行破壞清單。
這不是純文字 TSV：試算表匯入時仍會看到跳脫字元，例如空白前的反斜線。
掃描或暫存建立失敗時會提示，清單會標記不完整，保留已取得項目；其餘備份與校驗仍會繼續。
清單會一起納入 SHA-256 校驗與選用的加密 DMG。新機可開啟清單逐項核對，
從 App Store 或原廠重新安裝；清單不包含 App 本體、授權或安裝來源，也不會自動安裝。

## 還原內容

| 步驟 | 說明 |
|---|---|
| Xcode Command Line Tools | 自動安裝 |
| Homebrew | 自動安裝，並從 Brewfile 還原所有套件 |
| dotfiles | 自動複製回 `~/` |
| 額外設定與自訂腳本 | 逐項確認後完整還原，保留原資料；來源清單見 `extra-settings/` 說明 |
| `.config` | 合併還原至 `~/.config/`；覆蓋同名檔案，保留新機器其他檔案，亦相容舊版僅備份 gh 的格式 |
| AI 資料 | 預先校驗所有副本，批次替換；失敗反向回復，成功時仍保留 `.before-restore-*` 原資料 |
| 編輯器資料 | 延續逐一目錄的完整副本還原與 `.before-restore-*` 保護，不納入 AI 交易 |
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
| Codex 本機文件／工作資料 | `~/Documents/Codex/`，存在時整份備份與還原 |
| 桌面 AI App | `~/Library/Application Support/` 下的 `Codex`、`com.openai.codex`、`Claude`、`com.openai.chat`（若存在）；另匯出對應偏好 domain |
| VS Code／Insiders／Cursor／Windsurf | 各自 `Application Support` 的 `User/`，包含 settings、keybindings、snippets、profiles 和本機狀態；另存 VS Code／Cursor 的 `argv.json` |
| JetBrains | `~/Library/Application Support/JetBrains/` |
| Vim／Emacs | 原有 `.vimrc`，加上 `.vim/`、`.gvimrc`、`.ideavimrc`、`.emacs`、`.emacs.d/`；Neovim 設定已由 `.config/` 涵蓋 |

`CODEX_HOME`／`CLAUDE_CONFIG_DIR` 請使用絕對路徑；新機器還原時，以新機器上的環境變數或預設路徑為準。
目錄內部的符號連結保留為連結，外部目標不會自動收集；socket／device 等執行期物件不備份。
使用者資料目錄中的歷史、plugins 與快取也可能包含在內，因此備份可能較大。

**備份及還原前，請先關閉相關 AI App、CLI 與編輯器，並在整個流程中保持關閉。**
備份開始前及結束複製後，會對存在的 AI 資料檢查對應程序；還原時則在任何寫入前，
以及 AI 副本準備完成、正式替換前，再次檢查。相關 AI 偏好 domain 也會在匯入前檢查。
不會自動關閉、終止或重啟 AI App。編輯器目前仍需使用者自行關閉。

| 資料群組 | `pgrep -x` 精確程序名稱 |
|---|---|
| Codex、Documents/Codex、Codex 桌面資料 | `Codex`、`codex` |
| Claude Code／Claude 桌面資料 | `Claude`、`claude` |
| 共用 `.agents` | 上述 Codex 與 Claude 名稱 |
| ChatGPT 桌面資料 | `ChatGPT` |

桌面名稱對應 macOS App 的 executable 名稱；Claude CLI 使用 `claude`。
不使用 `pgrep -f` 或廣泛字串匹配。只有 `pgrep` 回傳 `1`（找不到程序）才繼續；
回傳 `0`、檢查工具不存在或其他錯誤都中止，並顯示原因。
這是時間點檢查，不是鎖住 App 的機制；重新命名的 executable 或其他寫入程式不在偵測範圍。
若正在 Codex／Claude 裡操作，請改到外部終端機，在關閉相關 App／CLI 後執行實際備份。

Codex 本機資料、Claude Code、桌面 App 的設定／資料，**不等於 ChatGPT 或 Claude 雲端聊天匯出**。
本流程不包含 Keychain、App sandbox 的完整容器、`~/Downloads`、`~/Programming` 或其他外部專案。
`~/Documents/Codex` 本身包含的檔案會備份；其中連向外部專案的符號連結只保存連結，不追蹤目標。
專案內的 `.claude/`、`AGENTS.md`、`.env` 等需另行備份。
登入狀態及跨 App／CLI 版本相容性不保證，仍可能需要重新登入或手動調整。
使用者名稱或專案位置改變後，資料內的絕對路徑及符號連結可能需要手動修正。
編輯器 CLI 不可用時會提示並保留擴充套件清單；特定舊版本若下架，可能需手動改裝新版。

## 完整性驗證與舊備份

備份使用資料夾格式，可選擇封裝為加密 DMG：

- 開始建立時寫入 `backup-format`（`mac-migration-v1`）。完成後才寫入 `manifest.json`。
  有版本標記但沒有清單的中斷備份會被拒絕，不會當成可還原的舊備份。
- 清單版本為 `1`，記錄每個相對路徑及物件類型；普通檔案使用 SHA-256，符號連結記錄連結目標。
  隱藏檔與空目錄也涵蓋；路徑／連結目標以 Base64 編碼原始 bytes，支援空白、中文、換行與反斜線檔名。
  不追蹤連結外部內容，不包含清單自身，避免循環校驗。
- 還原前重算整份備份清單。缺檔、內容變更、額外檔案、連結目標變更、損壞清單或未知版本，
  都會在 Homebrew、dotfiles 或 AI 目的地尚未改動前中止。必要的資料根節點不接受符號連結。
- **SHA-256 用來偵測搬移損壞／意外變更，不提供來源認證**；不能防止攻擊者同時改寫資料及清單。
  請只還原可信來源，也不要在完成後自行修改備份內容。
- 完全沒有版本標記與清單的舊主流程備份仍可還原，但會明確顯示「未驗證檔案完整性」。
  不支援直接匯入其他工具產生的 ZIP／tar.gz。

可先執行唯讀檢查：

```bash
/usr/bin/perl migration-integrity.pl verify /path/to/mac-migration
bash restore.sh --dry-run --migration-dir /path/to/mac-migration
```

`--dry-run` 同樣會執行校驗、路徑及程序檢查，但不建立暫存副本、不改動目的地。
掛載唯讀 DMG 後也能驗證。`hdiutil verify` 繼續檢查加密映像檔是否可解密且完整；
`manifest.json` 檢查搬移後的檔案／連結，兩者各自保留用途。

## AI 批次還原與救援

AI 資料是否還原會在主流程寫入前詢問。接受後先準備所有存在的 AI 項目，
並逐一比對來源與副本的檔案 SHA-256、目錄及連結目標。
預備位置為 `${TMPDIR:-/tmp}/mac-migrate-ai.XXXXXX/`；輸出、暫存或目的地與來源重疊時會拒絕。
同一批目的地也不能重疊（例如 `CODEX_HOME` 與 `CLAUDE_CONFIG_DIR` 指向同一目錄），
且不能是家目錄本身、其祖先或符號連結根節點。

正式替換前再次確認程序已關閉，才依序把原資料移至相鄰的 `.before-restore-時間戳`，再放入完整副本。
AI 批次在 Homebrew 等步驟之前完成，避免把整個 macOS 遷移流程納入交易：

- **全部成功**：保留每份 `.before-restore-*` 原資料並顯示位置，清除本批次暫存。
- **任何一步失敗**：依反向順序移開已放入的副本並放回原資料；原本不存在的目的地恢復為不存在，
  本批次新建的空父目錄也會移除。回復成功後仍以失敗狀態結束，不繼續遷移。
- **回復也失敗**：不刪除救援目錄，列出目的地、原資料與暫存位置。
  `journal.txt` 記錄路徑及原本是否存在（Bash `%q` 路徑表示法）；`staged/` 保存尚未放入的副本，
  `rescue/` 保存回復時移開的副本，原資料仍在顯示的 `.before-restore-*` 位置或已放回目的地。
  請保持 App 關閉，先複製這些位置到安全處，再依日誌人工確認和放回原資料。

此保護只涵蓋本批 AI 資料。編輯器保留原有單目錄保護；Homebrew、SSH、系統偏好與整個遷移流程不回復。
一般錯誤及可捕捉的 INT／TERM／HUP 會觸發回復；斷電、SIGKILL、檔案系統損壞不保證自動復原。
不要同時執行多個還原，也不要在過程中修改來源／目的地。
`.before-restore-*`、暫存與救援資料皆未加密，請確認完成後自行妥善管理。

執行環境為 macOS 內建 Bash 3.2、`pgrep`、`rsync`、`hdiutil` 與 `/usr/bin/perl` 的核心模組
（Digest::SHA、JSON::PP、MIME::Base64 等）；不需為這些新功能安裝 Python 或第三方套件。
測試使用 Python 標準函式庫：`python3 -m unittest discover -s tests -v`，所有資料均為隔離假 HOME／暫存資料。

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
- `mac-migration/` 包含敏感資訊，不要公開分享；若透過雲端搬移，請使用加密 DMG。
