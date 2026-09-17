#!/bin/bash
# ============================================================
# backup.sh — 舊機器備份 script
# 用法: bash backup.sh
# 輸出: ./mac-migration/ 資料夾（在執行目錄下），可直接傳到新機器
# ============================================================

set -e
# 備份階段的未處理錯誤統一回傳 1，保留 2 給「備份完成、加密失敗」。
trap 'exit 1' ERR
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/migration-common.sh"

MIGRATION_DIR="$(pwd)/mac-migration"
DOTFILES_DIR="$MIGRATION_DIR/dotfiles"
DEFAULTS_DIR="$MIGRATION_DIR/defaults"
SSH_DIR="$MIGRATION_DIR/ssh"

# ── 顏色輸出 ──────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
skip()    { echo -e "${YELLOW}[SKIP]${NC}  $1"; }

archive_previous_backup() {
  local archive_base archive_dir suffix=1
  if [ -L "$MIGRATION_DIR" ] || { [ -e "$MIGRATION_DIR" ] && [ ! -d "$MIGRATION_DIR" ]; }; then
    warn "備份路徑不是一般資料夾，請先移開: $MIGRATION_DIR"
    exit 1
  fi
  if [ -d "$MIGRATION_DIR" ]; then
    archive_base="${MIGRATION_DIR}-$(date +%Y%m%d-%H%M%S)"
    archive_dir="$archive_base"
    # 同一秒重跑時加上序號，避免覆蓋或移入既有備份。
    while [ -e "$archive_dir" ] || [ -L "$archive_dir" ]; do
      archive_dir="${archive_base}-${suffix}"
      suffix=$((suffix + 1))
    done
    mv "$MIGRATION_DIR" "$archive_dir"
    PREVIOUS_BACKUP_DIR="$archive_dir"
    success "已保留前次備份: $PREVIOUS_BACKUP_DIR"
  fi
}

copy_if_exists() {
  local src="$1"
  local dest="$2"
  if [ -f "$src" ] || [ -d "$src" ]; then
    # 取代前次備份，避免 cp 將目錄塞進既有的同名目錄。
    rm -rf -- "$dest"
    cp -r "$src" "$dest"
    success "已備份: $src"
  else
    skip "不存在: $src"
  fi
}

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║        Mac Migration — 舊機器匯出         ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# Fail before rotating the previous backup or creating new output.
select_ai_data backup "$MIGRATION_DIR"
select_ai_preferences backup "$MIGRATION_DIR"
check_ai_processes "${AI_SELECTED_IDS[@]}" "${AI_PREFERENCE_IDS[@]}"
PREFLIGHT_SOURCES=("${DEVELOPER_PATHS[@]}" "$HOME/.config" "$HOME/.ssh" "$HOME/.mackup.cfg")
for name in .zshrc .zprofile .zshenv .bashrc .bash_profile .aliases .gitconfig .gitignore_global .gitignore .vimrc .editorconfig .curlrc .wgetrc .npmrc; do
  PREFLIGHT_SOURCES+=("$HOME/$name")
done
integrity backup-preflight "$MIGRATION_DIR" "${PREFLIGHT_SOURCES[@]}"

# ── 建立目錄結構 ───────────────────────────────────────────
PREVIOUS_BACKUP_DIR=""
archive_previous_backup
info "建立 migration 目錄..."
mkdir -p "$DOTFILES_DIR" "$DEFAULTS_DIR" "$SSH_DIR"
printf 'mac-migration-v1\n' > "$MIGRATION_DIR/backup-format"

# ════════════════════════════════════════════
# 1. Homebrew
# ════════════════════════════════════════════
echo ""
echo "── 1. Homebrew ─────────────────────────────"
if command -v brew &>/dev/null; then
  info "匯出 Brewfile..."
  brew bundle dump --file="$MIGRATION_DIR/Brewfile" --force
  success "Brewfile 已匯出（$(grep -c '' "$MIGRATION_DIR/Brewfile") 行）"
else
  warn "Homebrew 未安裝，跳過"
fi

# ════════════════════════════════════════════
# 2. dotfiles
# ════════════════════════════════════════════
echo ""
echo "── 2. dotfiles ─────────────────────────────"
# Shell
copy_if_exists "$HOME/.zshrc"           "$DOTFILES_DIR/.zshrc"
copy_if_exists "$HOME/.zprofile"        "$DOTFILES_DIR/.zprofile"
copy_if_exists "$HOME/.zshenv"          "$DOTFILES_DIR/.zshenv"
copy_if_exists "$HOME/.bashrc"          "$DOTFILES_DIR/.bashrc"
copy_if_exists "$HOME/.bash_profile"    "$DOTFILES_DIR/.bash_profile"
copy_if_exists "$HOME/.aliases"         "$DOTFILES_DIR/.aliases"

# Git
copy_if_exists "$HOME/.gitconfig"           "$DOTFILES_DIR/.gitconfig"
copy_if_exists "$HOME/.gitignore_global"    "$DOTFILES_DIR/.gitignore_global"
copy_if_exists "$HOME/.gitignore"           "$DOTFILES_DIR/.gitignore"

# Editor
copy_if_exists "$HOME/.vimrc"           "$DOTFILES_DIR/.vimrc"
copy_if_exists "$HOME/.editorconfig"    "$DOTFILES_DIR/.editorconfig"

# Misc tools
copy_if_exists "$HOME/.curlrc"          "$DOTFILES_DIR/.curlrc"
copy_if_exists "$HOME/.wgetrc"          "$DOTFILES_DIR/.wgetrc"
copy_if_exists "$HOME/.npmrc"           "$DOTFILES_DIR/.npmrc"

# 整個 .config（含隱藏檔）；/. 也可讀取以 symlink 指向的根目錄。
if [ -d "$HOME/.config" ]; then
  mkdir -p "$DOTFILES_DIR/.config"
  cp -R "$HOME/.config/." "$DOTFILES_DIR/.config/"
  success "已備份: $HOME/.config"
else
  skip "不存在: $HOME/.config"
fi

# Mackup
copy_if_exists "$HOME/.mackup.cfg"      "$MIGRATION_DIR/mackup.cfg"

# AI 工具與編輯器：整份使用者資料，包含設定、skills 與本機紀錄。
echo ""
echo "── AI 工具與編輯器 ─────────────────────────"
warn "請先關閉 AI App、CLI 與編輯器，再備份；執行中的資料庫無法保證一致性。"
mkdir -p "$MIGRATION_DIR/developer" "$MIGRATION_DIR/extensions"
for index in "${!DEVELOPER_IDS[@]}"; do
  src="${DEVELOPER_PATHS[$index]}"
  dest="$MIGRATION_DIR/developer/${DEVELOPER_IDS[$index]}"
  if [ -d "$src" ]; then
    copy_tree "$src" "$dest"
    success "已備份: $src"
  elif [ -f "$src" ]; then
    cp -p "$src" "$dest"
    success "已備份: $src"
  fi
done
for editor in "${EDITOR_COMMANDS[@]}"; do
  if command -v "$editor" >/dev/null 2>&1; then
    list="$MIGRATION_DIR/extensions/$editor.txt"
    if "$editor" --list-extensions --show-versions > "$list.tmp"; then
      mv "$list.tmp" "$list"
    else
      rm -f "$list.tmp"
      warn "無法匯出 $editor 擴充套件清單"
    fi
  fi
done

# 完整 SSH 為 opt-in，避免將不明名稱的私鑰在使用者拒絕時一併帶走。
echo ""
echo "── 3. SSH ──────────────────────────────────"
copy_if_exists "$HOME/.ssh/config" "$SSH_DIR/config"
copy_if_exists "$HOME/.ssh/known_hosts" "$SSH_DIR/known_hosts"
IFS= read -r -p "  是否完整備份 ~/.ssh（含所有名稱的私鑰、Include 子目錄）？[y/N] " REPLY || REPLY=""
echo ""
if [[ $REPLY =~ ^[Yy]$ ]] && [ -d "$HOME/.ssh" ]; then
  copy_tree "$HOME/.ssh" "$SSH_DIR"
  printf 'full-v1\n' > "$MIGRATION_DIR/ssh-format"
  success "已完整備份 ~/.ssh（不含 socket；符號連結外部目標需另備份）"
else
  skip "只備份 SSH config 與 known_hosts；未收集私鑰或額外 Include 檔案"
fi

# 可還原的 plist；不再只保存 defaults read 的人類閱讀輸出。
echo ""
echo "── 4. macOS defaults ───────────────────────"
for domain in "${DEFAULTS_DOMAINS[@]}"; do
  filename="${domain//./_}"
  target="$DEFAULTS_DIR/$filename.plist"
  if defaults export "$domain" - > "$target.tmp" 2>/dev/null &&
      plutil -lint "$target.tmp" >/dev/null 2>&1; then
    mv "$target.tmp" "$target"
    success "匯出: $domain"
  else
    rm -f "$target.tmp"
    warn "無法匯出: ${domain}（不存在或無讀取權限）"
  fi
done

# ════════════════════════════════════════════
# 5. 開發工具版本紀錄
# ════════════════════════════════════════════
echo ""
echo "── 5. 開發工具版本 ──────────────────────────"
VERSIONS_FILE="$MIGRATION_DIR/versions.txt"
echo "# 開發工具版本紀錄 — $(date)" > "$VERSIONS_FILE"
echo "" >> "$VERSIONS_FILE"

record_version() {
  local label="$1"
  local cmd="$2"
  local version
  if version=$(eval "$cmd" 2>/dev/null); then
    echo "$label: $version" >> "$VERSIONS_FILE"
    success "$label: $version"
  else
    skip "$label: 未安裝"
  fi
}

record_version "macOS"        "sw_vers -productVersion"
record_version "Xcode"        "xcodebuild -version | head -1"
record_version "Node"         "node --version"
record_version "npm"          "npm --version"
record_version "Ruby"         "ruby --version"
record_version "Python3"      "python3 --version"
record_version "Java"         "java --version 2>&1 | head -1"
record_version "Go"           "go version"
record_version "Rust"         "rustc --version"
record_version "Swift"        "swift --version 2>&1 | head -1"

# nvm 清單
if [ -f "$HOME/.nvm/nvm.sh" ]; then
  source "$HOME/.nvm/nvm.sh" 2>/dev/null
  echo "" >> "$VERSIONS_FILE"
  echo "# nvm 已安裝版本:" >> "$VERSIONS_FILE"
  nvm ls --no-colors 2>/dev/null \
    | grep -E '^\s*-?>?\s*v[0-9]' \
    | sed 's/.*\(v[0-9][^ ]*\).*/\1/' \
    | sed 's/^/  /' \
    >> "$VERSIONS_FILE"
  success "nvm 版本清單已記錄"
fi

info "匯出已安裝 App 清單（名稱、版本、路徑）..."
if list_installed_apps /Applications "$HOME/Applications" > "$MIGRATION_DIR/installed-apps.txt"; then
  success "App 清單已匯出: $MIGRATION_DIR/installed-apps.txt（供新機重新安裝參考）"
else
  warn "App 清單匯出不完整或失敗；其餘備份與校驗會繼續。"
  printf '# WARNING: App inventory incomplete or unavailable; do not treat as a complete list.\n' >> "$MIGRATION_DIR/installed-apps.txt"
fi

# Detect applications reopened during the copy; unfinished v1 backups lack a manifest.
check_ai_processes "${AI_SELECTED_IDS[@]}" "${AI_PREFERENCE_IDS[@]}"
integrity create "$MIGRATION_DIR"
integrity verify "$MIGRATION_DIR"

# ════════════════════════════════════════════
# 完成
# ════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║              匯出完成！                   ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  匯出路徑: $MIGRATION_DIR"
if [ -n "$PREVIOUS_BACKUP_DIR" ]; then
  echo "  前次備份: $PREVIOUS_BACKUP_DIR（保留供自行清理）"
fi
echo ""
echo "  下一步："
echo "  1. 執行 mackup backup 備份 app 設定："
echo "     mackup --config-file $MIGRATION_DIR/mackup.cfg backup"
echo "  2. 等待 storage 同步完成（iCloud / Dropbox / 自訂路徑）"
echo "  3. 將 $MIGRATION_DIR 傳到新機器"
echo "     （AirDrop / iCloud Drive / 外接碟）"
echo ""

read -r -p "是否將本次備份加密打包成 .dmg？[y/N] " ENCRYPT_BACKUP || ENCRYPT_BACKUP=""
if [[ "$ENCRYPT_BACKUP" =~ ^[Yy]$ ]]; then
  if ! bash "$SCRIPT_DIR/encrypt-backup.sh" "$MIGRATION_DIR"; then
    warn "備份已完成，但加密未完成（狀態碼 2）；請妥善保管明文備份: $MIGRATION_DIR"
    exit 2
  fi
fi
