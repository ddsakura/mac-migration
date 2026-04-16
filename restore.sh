#!/bin/bash
# ============================================================
# restore.sh — 新機器還原 script
# 用法: bash restore.sh [--migration-dir /path/to/mac-migration]
# ============================================================

set -e

# ── 參數處理 ───────────────────────────────────────────────
MIGRATION_DIR="$(pwd)/mac-migration"
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --migration-dir) MIGRATION_DIR="$2"; shift ;;
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

step() {
  echo ""
  echo -e "${CYAN}── $1 ─────────────────────────────────────${NC}"
}

confirm() {
  read -p "  $1 [Y/n] " -n 1 -r
  echo ""
  [[ $REPLY =~ ^[Nn]$ ]] && return 1 || return 0
}

restore_dotfile() {
  local src="$DOTFILES_DIR/$1"
  local dest="$HOME/$1"
  if [ -f "$src" ]; then
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
  echo "  bash setup.sh --migration-dir /path/to/mac-migration"
  exit 1
fi

info "使用 migration 資料夾: $MIGRATION_DIR"

# ════════════════════════════════════════════
# 1. Xcode Command Line Tools
# ════════════════════════════════════════════
step "1. Xcode Command Line Tools"
if xcode-select -p &>/dev/null; then
  success "已安裝: $(xcode-select -p)"
else
  info "安裝 Xcode Command Line Tools..."
  xcode-select --install
  echo ""
  warn "請在彈出視窗點擊「安裝」，完成後按 Enter 繼續"
  read -r
fi

# ════════════════════════════════════════════
# 2. Homebrew
# ════════════════════════════════════════════
step "2. Homebrew"
if command -v brew &>/dev/null; then
  success "Homebrew 已安裝"
  info "更新 Homebrew..."
  brew update
else
  info "安裝 Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Apple Silicon 設定 PATH
  if [ -f "/opt/homebrew/bin/brew" ]; then
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
    eval "$(/opt/homebrew/bin/brew shellenv)"
    success "Apple Silicon: 已設定 Homebrew PATH"
  fi
fi

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
    brew bundle install --file="$MIGRATION_DIR/Brewfile" --no-lock || \
      warn "部分套件安裝失敗（通常是版本或授權問題，可手動補裝）"
    success "Brewfile 安裝完成"
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

  # GitHub CLI config
  if [ -d "$DOTFILES_DIR/gh" ]; then
    mkdir -p "$HOME/.config"
    cp -r "$DOTFILES_DIR/gh" "$HOME/.config/gh"
    success "還原: GitHub CLI 設定"
  fi

  # 套用 .zshrc
  if [ -f "$HOME/.zshrc" ]; then
    source "$HOME/.zshrc" 2>/dev/null || true
  fi
else
  warn "找不到 dotfiles 備份，跳過"
fi

# ════════════════════════════════════════════
# 4. SSH 設定
# ════════════════════════════════════════════
step "4. SSH 設定"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# config 檔
if [ -f "$SSH_DIR/config" ]; then
  cp "$SSH_DIR/config" "$HOME/.ssh/config"
  chmod 644 "$HOME/.ssh/config"
  success "還原: SSH config"
fi

# Private keys（如果有備份）
KEY_COUNT=$(find "$SSH_DIR" -name "id_*" ! -name "*.pub" 2>/dev/null | wc -l | tr -d ' ')
if [ "$KEY_COUNT" -gt 0 ]; then
  if confirm "找到 $KEY_COUNT 個 SSH private key，是否還原？"; then
    cp "$SSH_DIR"/id_* "$HOME/.ssh/" 2>/dev/null
    chmod 600 "$HOME/.ssh"/id_* 2>/dev/null || true
    success "SSH keys 已還原"
  fi
else
  warn "未找到 SSH private key 備份"
  echo ""
  if confirm "  要現在產生新的 SSH key 嗎？"; then
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

# ════════════════════════════════════════════
# 5. mackup restore
# ════════════════════════════════════════════
step "5. mackup restore（App 設定）"

MACKUP_CFG="$MIGRATION_DIR/mackup.cfg"

if [ ! -f "$MACKUP_CFG" ]; then
  warn "找不到 $MACKUP_CFG，跳過 mackup restore"
  info "若需要，請手動建立設定後執行："
  echo "  mackup --config-file <path/to/mackup.cfg> restore"
else
  if ! command -v mackup &>/dev/null; then
    info "安裝 mackup..."
    brew install mackup
  fi
  warn "此步驟需要 mackup 的 storage 已同步完成（iCloud / Dropbox / Google Drive / 自訂路徑）"
  if confirm "確認 storage 已同步，執行 mackup restore？"; then
    mackup --config-file "$MACKUP_CFG" restore
    success "mackup restore 完成"
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

if confirm "套用 macOS defaults？"; then

  # ── Dock ──
  defaults write com.apple.dock "autohide"        -bool "true"
  defaults write com.apple.dock "show-recents"    -bool "false"
  defaults write com.apple.dock "tilesize"        -int  "48"
  defaults write com.apple.dock "mineffect"       -string "scale"
  killall Dock
  success "Dock 設定已套用"

  # ── Finder ──
  defaults write com.apple.finder "ShowPathbar"       -bool "true"
  defaults write com.apple.finder "ShowStatusBar"     -bool "true"
  defaults write com.apple.finder "FXPreferredViewStyle" -string "Nlsv"  # list view
  defaults write com.apple.finder "AppleShowAllFiles" -bool "true"
  defaults write com.apple.finder "_FXShowPosixPathInTitle" -bool "true"
  defaults write com.apple.finder "FXDefaultSearchScope" -string "SCcf"  # 搜尋目前資料夾
  killall Finder
  success "Finder 設定已套用"

  # ── 截圖 ──
  defaults write com.apple.screencapture "location"        -string "$HOME/Desktop"
  defaults write com.apple.screencapture "type"            -string "png"
  defaults write com.apple.screencapture "disable-shadow"  -bool "true"
  success "截圖設定已套用"

  # ── 鍵盤 ──
  defaults write NSGlobalDomain "KeyRepeat"           -int "2"
  defaults write NSGlobalDomain "InitialKeyRepeat"    -int "15"
  defaults write NSGlobalDomain "ApplePressAndHoldEnabled" -bool "false"
  success "鍵盤設定已套用"

  # ── 觸控板 ──
  defaults write com.apple.AppleMultitouchTrackpad "Clicking" -bool "true"
  defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad "Clicking" -bool "true"
  success "觸控板設定已套用（Tap to Click）"

  # ── 其他 ──
  defaults write NSGlobalDomain "NSDocumentSaveNewDocumentsToCloud" -bool "false"  # 預設存本機
  defaults write com.apple.TextEdit "RichText" -bool "false"  # TextEdit 預設純文字
  success "其他設定已套用"

  warn "部分設定需要登出或重新開機才會生效"
fi

# ════════════════════════════════════════════
# 7. 開發工具（nvm / Node）
# ════════════════════════════════════════════
step "7. 開發工具"

# nvm
if [ ! -d "$HOME/.nvm" ]; then
  if confirm "安裝 nvm？"; then
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/HEAD/install.sh | bash
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
    success "nvm 已安裝"

    # 從 versions.txt 提示安裝的 Node 版本
    if [ -f "$MIGRATION_DIR/versions.txt" ]; then
      NODE_VER=$(grep "^Node:" "$MIGRATION_DIR/versions.txt" | awk '{print $2}' | tr -d 'v')
      if [ -n "$NODE_VER" ]; then
        info "舊機器 Node 版本: v$NODE_VER"
        if confirm "安裝 Node v$NODE_VER？"; then
          nvm install "$NODE_VER"
          nvm use "$NODE_VER"
          success "Node v$NODE_VER 已安裝"
        fi
      fi
    fi

    if confirm "安裝 Node LTS？"; then
      nvm install --lts
      success "Node LTS 已安裝"
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
echo "  ✅ 自動化部分已完成"
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
