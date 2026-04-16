#!/bin/bash
# ============================================================
# backup.sh — 舊機器備份 script
# 用法: bash backup.sh
# 輸出: ./mac-migration/ 資料夾（在執行目錄下），可直接傳到新機器
# ============================================================

set -e

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

copy_if_exists() {
  local src="$1"
  local dest="$2"
  if [ -f "$src" ] || [ -d "$src" ]; then
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

# ── 建立目錄結構 ───────────────────────────────────────────
info "建立 migration 目錄..."
mkdir -p "$DOTFILES_DIR" "$DEFAULTS_DIR" "$SSH_DIR"

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
copy_if_exists "$HOME/.config/gh"       "$DOTFILES_DIR/gh"

# ════════════════════════════════════════════
# 3. SSH config（不含 private key）
# ════════════════════════════════════════════
echo ""
echo "── 3. SSH config ───────────────────────────"
copy_if_exists "$HOME/.ssh/config"  "$SSH_DIR/config"

# 是否要備份 private key（問使用者）
echo ""
read -p "  是否備份 SSH private keys？(建議放加密外接碟，不建議 iCloud) [y/N] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
  warn "即將備份 SSH private keys，請確保 migration 資料夾安全存放"
  if [ -d "$HOME/.ssh" ]; then
    cp "$HOME/.ssh"/id_* "$SSH_DIR/" 2>/dev/null && success "SSH keys 已備份" || skip "找不到 SSH keys"
  fi
else
  skip "略過 SSH private keys（建議在新機器重新產生）"
fi

# ════════════════════════════════════════════
# 4. macOS defaults 匯出
# ════════════════════════════════════════════
echo ""
echo "── 4. macOS defaults ───────────────────────"

DOMAINS=(
  "com.apple.dock"
  "com.apple.finder"
  "com.apple.screencapture"
  "com.apple.terminal"
  "com.apple.Safari"
  "com.apple.TextEdit"
  "NSGlobalDomain"
)

for domain in "${DOMAINS[@]}"; do
  filename=$(echo "$domain" | tr '.' '_')
  defaults read "$domain" > "$DEFAULTS_DIR/${filename}.txt" 2>/dev/null \
    && success "匯出: $domain" \
    || warn "無法讀取: $domain"
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

# ════════════════════════════════════════════
# 完成
# ════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║              匯出完成！                   ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  匯出路徑: $MIGRATION_DIR"
echo ""
echo "  下一步："
echo "  1. 執行 'mackup backup' 備份 app 設定"
echo "  2. 等待 iCloud 同步完成"
echo "  3. 將 $MIGRATION_DIR 傳到新機器"
echo "     （AirDrop / iCloud Drive / 外接碟）"
echo ""
