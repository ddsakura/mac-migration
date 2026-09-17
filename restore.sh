#!/bin/bash
# ============================================================
# restore.sh — 新機器還原 script
# 用法: bash restore.sh [--dry-run] [--migration-dir /path/to/mac-migration]
# ============================================================

set -e
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/migration-common.sh"

# ── 參數處理 ───────────────────────────────────────────────
MIGRATION_DIR="$(pwd)/mac-migration"
DRY_RUN=false
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true ;;
    --migration-dir)
      if [ -z "${2:-}" ] || [[ "$2" == --* ]]; then
        echo "--migration-dir 需要指定資料夾路徑"
        echo "用法: bash restore.sh [--dry-run] [--migration-dir /path/to/mac-migration]"
        exit 1
      fi
      MIGRATION_DIR="$2"
      shift
      ;;
    *)
      echo "未知參數: $1"
      echo "用法: bash restore.sh [--dry-run] [--migration-dir /path/to/mac-migration]"
      exit 1
      ;;
  esac
  shift
done

DOTFILES_DIR="$MIGRATION_DIR/dotfiles"
SSH_DIR="$MIGRATION_DIR/ssh"

# ── 顏色輸出 ──────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERR]${NC}   $1"; }
skip()    { echo -e "${YELLOW}[SKIP]${NC}  $1"; }
dryrun()  { echo -e "${YELLOW}[DRY]${NC}   $1"; }

run_or_dry() {
  local desc="$1"
  shift
  if [ "$DRY_RUN" = true ]; then
    dryrun "$desc"
  else
    "$@"
  fi
}

ensure_homebrew_shellenv() {
  local shellenv_line='eval "$(/opt/homebrew/bin/brew shellenv)"'
  if [ -f /opt/homebrew/bin/brew ]; then
    if [ "$DRY_RUN" = true ]; then
      # 追蹤預覽中的設定，避免因未實際寫檔而重複預告加入。
      if [ "${DRY_SHELLENV_ADDED:-false}" != true ] &&
          ! grep -Fqx "$shellenv_line" "${DRY_ZPROFILE:-$HOME/.zprofile}" 2>/dev/null; then
        dryrun "會加入 Homebrew shellenv 到 $HOME/.zprofile"
        dryrun "會載入 Homebrew shellenv"
        DRY_SHELLENV_ADDED=true
      fi
    else
      if ! grep -Fqx "$shellenv_line" "$HOME/.zprofile" 2>/dev/null; then
        # 前置換行避免與沒有結尾換行的設定黏在一起。
        printf '\n%s\n' "$shellenv_line" >> "$HOME/.zprofile"
        success "Apple Silicon: 已設定 Homebrew PATH"
      fi
      eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
  fi
}

step() {
  echo ""
  echo -e "${CYAN}── $1 ─────────────────────────────────────${NC}"
}

confirm() {
  if [ "$DRY_RUN" = true ]; then
    # Dry-run previews the full "yes" path so users can see every possible
    # action this restore would perform. It does not model the "no" branches.
    dryrun "會詢問: $1"
    return 0
  fi
  local reply
  if ! IFS= read -r -p "  $1 [y/N] " reply; then
    return 1
  fi
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

restore_dotfile() {
  local src="$DOTFILES_DIR/$1"
  local dest="$HOME/$1"
  if [ -f "$src" ]; then
    if [ "$DRY_RUN" = true ]; then
      if [ "$1" = .zprofile ]; then
        DRY_ZPROFILE="$src"
        DRY_SHELLENV_ADDED=false
      fi
      if [ -e "$dest" ]; then
        dryrun "會覆蓋: $dest <= $src"
      else
        dryrun "會還原: $dest <= $src"
      fi
      return
    fi
    cp "$src" "$dest"
    success "還原: $1"
  else
    skip "找不到備份: $1"
  fi
}

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║        Mac Migration — 新機器安裝         ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── 確認 migration 資料夾存在 ─────────────────────────────
if [ ! -d "$MIGRATION_DIR" ]; then
  error "找不到 migration 資料夾: $MIGRATION_DIR"
  echo ""
  echo "  請先將舊機器的 mac-migration 資料夾放到執行目錄下："
  echo "  $MIGRATION_DIR"
  echo ""
  echo "  或指定路徑執行："
  echo "  bash restore.sh --migration-dir /path/to/mac-migration"
  exit 1
fi

info "使用 migration 資料夾: $MIGRATION_DIR"
if [ "$DRY_RUN" = true ]; then
  warn "Dry-run 模式：只顯示將執行的動作，不會安裝、複製、寫入或重啟系統服務"
fi

# Verify all data before Homebrew, dotfiles, or any destination can be changed.
integrity verify "$MIGRATION_DIR"
select_ai_data restore "$MIGRATION_DIR"
integrity structure "$MIGRATION_DIR" "${DEVELOPER_IDS[@]}"
select_ai_preferences restore "$MIGRATION_DIR"
check_ai_processes "${AI_PREFERENCE_IDS[@]}"
RESTORE_DEVELOPER=false
if [ -d "$MIGRATION_DIR/developer" ]; then
  warn "還原 AI 工具與編輯器前請先關閉相關 App / CLI；原資料會改名保留。"
  if confirm "還原 AI 工具與編輯器使用者資料？"; then
    RESTORE_DEVELOPER=true
    check_ai_processes "${AI_SELECTED_IDS[@]}"
    integrity destinations "$MIGRATION_DIR" "$HOME" "${AI_DESTINATIONS[@]}"
    if [ "$DRY_RUN" = true ]; then
      for index in "${AI_INDICES[@]}"; do
        dryrun "會還原完整資料（AI 批次、預備校驗與失敗回復）: ${DEVELOPER_PATHS[$index]}"
      done
    else
      restore_ai_batch "$MIGRATION_DIR"
    fi
  fi
fi

# ════════════════════════════════════════════
# 1. Xcode Command Line Tools
# ════════════════════════════════════════════
step "1. Xcode Command Line Tools"
if xcode-select -p &>/dev/null; then
  success "已安裝: $(xcode-select -p)"
else
  info "安裝 Xcode Command Line Tools..."
  run_or_dry "會執行: xcode-select --install" xcode-select --install
  if [ "$DRY_RUN" = true ]; then
    dryrun "會等待使用者完成安裝後按 Enter"
  else
    echo ""
    warn "請在彈出視窗點擊「安裝」，完成後按 Enter 繼續"
    read -r
  fi
fi

# ════════════════════════════════════════════
# 2. Homebrew
# ════════════════════════════════════════════
step "2. Homebrew"
if command -v brew &>/dev/null; then
  success "Homebrew 已安裝"
  info "更新 Homebrew..."
  run_or_dry "會執行: brew update" brew update
else
  info "安裝 Homebrew..."
  if [ "$DRY_RUN" = true ]; then
    dryrun "會下載並執行 Homebrew installer"
  else
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi

fi
ensure_homebrew_shellenv

# ── VS Code 檢查（Brewfile 內有 vscode extensions，需要先裝）──
if grep -q '^vscode ' "$MIGRATION_DIR/Brewfile" 2>/dev/null; then
  if ! command -v code &>/dev/null; then
    warn "Brewfile 含有 VS Code extensions，但偵測不到 'code' 指令"
    info "請先安裝 VS Code 再重新執行，或手動安裝 extensions"
  fi
fi

# ── 用 Brewfile 安裝套件 ──────────────────────────────────
if [ -f "$MIGRATION_DIR/Brewfile" ]; then
  info "找到 Brewfile（$(grep -c '' "$MIGRATION_DIR/Brewfile") 行），準備安裝..."
  if confirm "開始安裝 Brewfile 套件？（可能需要較長時間）"; then
    if [ "$DRY_RUN" = true ]; then
      dryrun "會執行: brew bundle install --file=\"$MIGRATION_DIR/Brewfile\" --no-lock"
    else
      brew bundle install --file="$MIGRATION_DIR/Brewfile" --no-lock || \
        warn "部分套件安裝失敗（通常是版本或授權問題，可手動補裝）"
      success "Brewfile 安裝完成"
    fi
  fi
else
  warn "找不到 Brewfile，跳過"
fi

# ════════════════════════════════════════════
# 3. dotfiles 還原
# ════════════════════════════════════════════
step "3. dotfiles 還原"
if [ -d "$DOTFILES_DIR" ]; then
  restore_dotfile ".zshrc"
  restore_dotfile ".zprofile"
  restore_dotfile ".zshenv"
  restore_dotfile ".bashrc"
  restore_dotfile ".bash_profile"
  restore_dotfile ".aliases"
  restore_dotfile ".gitconfig"
  restore_dotfile ".gitignore_global"
  restore_dotfile ".gitignore"
  restore_dotfile ".vimrc"
  restore_dotfile ".editorconfig"
  restore_dotfile ".npmrc"
  restore_dotfile ".curlrc"
  restore_dotfile ".wgetrc"

  # 新備份包含整個 .config；舊版僅有 gh 的備份仍可還原。
  CONFIG_SOURCE=""
  CONFIG_DEST="$HOME/.config"
  if [ -d "$DOTFILES_DIR/.config" ]; then
    CONFIG_SOURCE="$DOTFILES_DIR/.config"
  elif [ -d "$DOTFILES_DIR/gh" ]; then
    CONFIG_SOURCE="$DOTFILES_DIR/gh"
    CONFIG_DEST="$HOME/.config/gh"
  fi
  if [ -n "$CONFIG_SOURCE" ]; then
    if [ "$DRY_RUN" = true ]; then
      dryrun "會建立: $CONFIG_DEST"
      dryrun "會合併還原（覆蓋同名檔案、保留其他檔案）: $CONFIG_DEST <= $CONFIG_SOURCE"
    else
      mkdir -p "$CONFIG_DEST"
      cp -R "$CONFIG_SOURCE/." "$CONFIG_DEST/"
      success "還原: ${CONFIG_DEST}（合併並覆蓋同名檔案）"
    fi
  fi

  info "Shell 設定已複製；請另開終端機載入。"

else
  warn "找不到 dotfiles 備份，跳過"
fi

# 還原的 .zprofile 可能覆蓋步驟 2 的設定，需再確保一次。
ensure_homebrew_shellenv

restore_extra_settings "$MIGRATION_DIR"

# Editors keep their existing per-directory snapshot protection, outside the AI batch.
if [ "$RESTORE_DEVELOPER" = true ]; then
  for index in "${!DEVELOPER_IDS[@]}"; do
    is_ai_id "${DEVELOPER_IDS[$index]}" && continue
    src="$MIGRATION_DIR/developer/${DEVELOPER_IDS[$index]}"
    dest="${DEVELOPER_PATHS[$index]}"
    if [ -d "$src" ] || [ -f "$src" ]; then
      run_or_dry "會還原完整資料（既有資料另存 .before-restore-*）: $dest <= $src" restore_snapshot "$src" "$dest"
    fi
  done
fi
for editor in "${EDITOR_COMMANDS[@]}"; do
  list="$MIGRATION_DIR/extensions/$editor.txt"
  [ -s "$list" ] || continue
  if ! command -v "$editor" >/dev/null 2>&1; then
    warn "找不到 $editor CLI；請安裝並啟用 CLI 後重新執行以還原擴充套件。清單: $list"
    continue
  fi
  if confirm "依備份清單安裝 $editor 擴充套件？"; then
    while IFS= read -r extension || [ -n "$extension" ]; do
      [ -n "$extension" ] || continue
      if [[ ! "$extension" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*\.[A-Za-z0-9][A-Za-z0-9_.-]*(@[A-Za-z0-9][A-Za-z0-9_.+-]*)?$ ]]; then
        warn "略過格式不正確的擴充套件項目"
        continue
      fi
      run_or_dry "會安裝 $editor 擴充套件: $extension" "$editor" --install-extension "$extension" ||
        warn "擴充套件安裝失敗: $extension"
    done < "$list"
  fi
done

# ════════════════════════════════════════════
# 4. SSH 設定
# ════════════════════════════════════════════
step "4. SSH 設定"
run_or_dry "會建立: $HOME/.ssh" mkdir -p "$HOME/.ssh"
run_or_dry "會設定權限: chmod 700 $HOME/.ssh" chmod 700 "$HOME/.ssh"

restore_ssh_basics() {
  # 新舊格式共用的基本設定還原
  if [ -f "$SSH_DIR/config" ]; then
    if [ "$DRY_RUN" = true ]; then
      if [ -e "$HOME/.ssh/config" ]; then
        dryrun "會覆蓋: $HOME/.ssh/config <= $SSH_DIR/config"
      else
        dryrun "會還原: $HOME/.ssh/config <= $SSH_DIR/config"
      fi
      dryrun "會設定權限: chmod 644 $HOME/.ssh/config"
    else
      cp "$SSH_DIR/config" "$HOME/.ssh/config"
      chmod 644 "$HOME/.ssh/config"
      success "還原: SSH config"
    fi
  fi

  if [ -f "$SSH_DIR/known_hosts" ]; then
    run_or_dry "會還原 SSH known_hosts" cp "$SSH_DIR/known_hosts" "$HOME/.ssh/known_hosts"
  fi

}

if [ -f "$MIGRATION_DIR/ssh-format" ] && [ "$(cat "$MIGRATION_DIR/ssh-format")" = full-v1 ]; then
  if confirm "還原完整 SSH 目錄（含私鑰及設定，同名檔案會覆蓋）？"; then
    run_or_dry "會合併完整 SSH: $SSH_DIR -> $HOME/.ssh" copy_tree "$SSH_DIR" "$HOME/.ssh"
    if [ "$DRY_RUN" = true ]; then
      dryrun "會設定 SSH 目錄 700、一般檔案 600（不追蹤符號連結）"
    else
      find "$HOME/.ssh" -type d -exec chmod 700 {} +
      find "$HOME/.ssh" -type f -exec chmod 600 {} +
    fi
  else
    restore_ssh_basics
    skip "已略過完整 SSH 還原；只還原 config / known_hosts，未還原私鑰及其他 Include 檔案"
  fi
else
restore_ssh_basics

# Private keys（如果有備份）
KEY_COUNT=$(find "$SSH_DIR" -name "id_*" ! -name "*.pub" 2>/dev/null | wc -l | tr -d ' ')
if [ "$KEY_COUNT" -gt 0 ]; then
  if confirm "找到 $KEY_COUNT 個 SSH private key，是否還原？"; then
    if [ "$DRY_RUN" = true ]; then
      dryrun "會複製 SSH private keys: $SSH_DIR/id_* -> $HOME/.ssh/"
      dryrun "會設定權限: chmod 600 $HOME/.ssh/id_*"
    else
      cp "$SSH_DIR"/id_* "$HOME/.ssh/" 2>/dev/null
      chmod 600 "$HOME/.ssh"/id_* 2>/dev/null || true
      success "SSH keys 已還原"
    fi
  fi
else
  warn "未找到 SSH private key 備份"
  echo ""
  if confirm "  要現在產生新的 SSH key 嗎？"; then
    if [ "$DRY_RUN" = true ]; then
      dryrun "會詢問 email 並執行: ssh-keygen -t ed25519 -C <email> -f \"$HOME/.ssh/id_ed25519\""
      dryrun "會顯示新公鑰並等待使用者加入 GitHub / GitLab"
    else
      read -p "  輸入 email: " SSH_EMAIL
      ssh-keygen -t ed25519 -C "$SSH_EMAIL" -f "$HOME/.ssh/id_ed25519"
      success "新的 SSH key 已產生"
      echo ""
      info "公鑰內容（複製到 GitHub / GitLab）："
      echo ""
      cat "$HOME/.ssh/id_ed25519.pub"
      echo ""
      warn "請先把公鑰加到各服務後，再按 Enter 繼續"
      read -r
    fi
  fi
fi

fi

# ════════════════════════════════════════════
# 5. mackup restore
# ════════════════════════════════════════════
step "5. mackup restore（App 設定）"

MACKUP_CFG="$MIGRATION_DIR/mackup.cfg"

if [ ! -f "$MACKUP_CFG" ]; then
  warn "找不到 mackup 設定，跳過 mackup restore"
  echo "  $MACKUP_CFG"
  info "若需要，請手動建立設定後執行："
  echo "  mackup --config-file <path/to/mackup.cfg> restore"
else
  if ! command -v mackup &>/dev/null; then
    info "安裝 mackup..."
    run_or_dry "會執行: brew install mackup" brew install mackup
  fi
  warn "此步驟需要 mackup 的 storage 已同步完成（iCloud / Dropbox / Google Drive / 自訂路徑）"
  if confirm "確認 storage 已同步，執行 mackup restore？"; then
    run_or_dry "會執行: mackup --config-file \"$MACKUP_CFG\" restore" mackup --config-file "$MACKUP_CFG" restore
    [ "$DRY_RUN" = true ] || success "mackup restore 完成"
  else
    skip "略過 mackup restore（可之後手動執行）："
    echo "  mackup --config-file $MACKUP_CFG restore"
  fi
fi

# ════════════════════════════════════════════
# 6. macOS defaults
# ════════════════════════════════════════════
step "6. macOS defaults"
warn "套用 macOS 系統設定前，請確認 Terminal 已有完整磁碟存取權限"
echo "  系統設定 → 隱私權與安全性 → 完整磁碟存取權限 → 加入 Terminal"
echo ""

warn "會以備份取代對應偏好 domain；備份中的舊使用者絕對路徑可能需要手動調整。"
if confirm "從備份還原 macOS / App 偏好設定？"; then
  check_ai_processes "${AI_PREFERENCE_IDS[@]}"
  for domain in "${DEFAULTS_DOMAINS[@]}"; do
    filename="${domain//./_}"
    plist="$MIGRATION_DIR/defaults/$filename.plist"
    if [ ! -f "$plist" ]; then
      plist="$MIGRATION_DIR/defaults/$filename.txt"
      if [ "$domain" = com.apple.Terminal ] && [ ! -f "$plist" ]; then
        plist="$MIGRATION_DIR/defaults/com_apple_terminal.txt"
      fi
    fi
    [ -f "$plist" ] || continue
    if ! plutil -lint "$plist" >/dev/null 2>&1; then
      warn "略過無法解析的舊備份或損壞 plist: $plist"
      continue
    fi
    if [ "$DRY_RUN" = true ]; then
      dryrun "會從備份匯入偏好設定: $domain <= $plist"
    else
      if ! defaults import "$domain" "$plist"; then
        warn "匯入失敗，略過並繼續其他項目: ${domain}（請檢查權限或 domain 是否被鎖定）"
        continue
      fi
      case "$domain" in
        com.apple.dock) killall Dock 2>/dev/null || true ;;
        com.apple.finder) killall Finder 2>/dev/null || true ;;
      esac
      success "已匯入: $domain"
    fi
  done
  info "部分設定需重新開啟 App、登出或重新開機才會生效；未備份的 domain 不變更。"
fi

# ════════════════════════════════════════════
# 7. 開發工具（nvm / Node）
# ════════════════════════════════════════════
step "7. 開發工具"

# nvm
if [ ! -d "$HOME/.nvm" ]; then
  if confirm "安裝 nvm？"; then
    if [ "$DRY_RUN" = true ]; then
      dryrun "會下載並執行 nvm installer"
      dryrun "會載入 $HOME/.nvm/nvm.sh"
    else
      curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/HEAD/install.sh | bash
      export NVM_DIR="$HOME/.nvm"
      [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
      success "nvm 已安裝"
    fi

    # 從 versions.txt 提示安裝的 Node 版本
    if [ -f "$MIGRATION_DIR/versions.txt" ]; then
      NODE_VER=$(grep "^Node:" "$MIGRATION_DIR/versions.txt" | awk '{print $2}' | tr -d 'v')
      if [ -n "$NODE_VER" ]; then
        info "舊機器 Node 版本: v$NODE_VER"
        if confirm "安裝 Node v$NODE_VER？"; then
          if [ "$DRY_RUN" = true ]; then
            dryrun "會執行: nvm install \"$NODE_VER\""
            dryrun "會執行: nvm use \"$NODE_VER\""
          else
            nvm install "$NODE_VER"
            nvm use "$NODE_VER"
            success "Node v$NODE_VER 已安裝"
          fi
        fi
      fi
    fi

    if confirm "安裝 Node LTS？"; then
      if [ "$DRY_RUN" = true ]; then
        dryrun "會執行: nvm install --lts"
      else
        nvm install --lts
        success "Node LTS 已安裝"
      fi
    fi
  fi
else
  success "nvm 已安裝"
fi

# ════════════════════════════════════════════
# 完成：待辦清單
# ════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║           安裝完成！                      ║"
echo "╚══════════════════════════════════════════╝"
echo ""
if [ "$DRY_RUN" = true ]; then
  echo "  ✅ Dry-run 檢查完成，未改動此機器"
else
  echo "  ✅ 自動化部分已完成"
fi
echo ""
echo "  📋 以下需要手動處理："
echo ""
echo "  [ ] Xcode — App Store 安裝，設定 Signing Certificate"
echo "  [ ] Android Studio — 官網下載，設定 SDK / AVD / JDK"
echo "  [ ] 系統設定 → 隱私權 → 重新授權各 app 權限"
echo "  [ ] 系統設定 → 一般 → 開機項目 → 重新設定 Login Items"
echo "  [ ] Slack / Figma / 1Password 等 — 重新登入"
echo ""
echo "  📁 Migration 資料夾: $MIGRATION_DIR"
echo "  📄 舊機器版本資訊: $MIGRATION_DIR/versions.txt"
echo ""
