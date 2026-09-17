#!/bin/bash
# shellcheck disable=SC2034
# 陣列由載入此檔的 backup.sh / restore.sh 使用。
# 共用路徑清單：備份與還原共用，避免只備份卻漏還原。
# 此檔需與 backup.sh / restore.sh 放在一起。
DEVELOPER_IDS=(
  codex claude-code claude-state agent-skills
  codex-desktop codex-desktop-support claude-desktop chatgpt-desktop
  vscode vscode-insiders cursor windsurf jetbrains
  vim gvimrc ideavimrc emacs emacs-config vscode-argv cursor-argv
)
DEVELOPER_PATHS=(
  "${CODEX_HOME:-$HOME/.codex}" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$HOME/.claude.json" "$HOME/.agents"
  "$HOME/Library/Application Support/Codex" "$HOME/Library/Application Support/com.openai.codex"
  "$HOME/Library/Application Support/Claude" "$HOME/Library/Application Support/com.openai.chat"
  "$HOME/Library/Application Support/Code/User" "$HOME/Library/Application Support/Code - Insiders/User"
  "$HOME/Library/Application Support/Cursor/User" "$HOME/Library/Application Support/Windsurf/User"
  "$HOME/Library/Application Support/JetBrains"
  "$HOME/.vim" "$HOME/.gvimrc" "$HOME/.ideavimrc" "$HOME/.emacs" "$HOME/.emacs.d"
  "$HOME/.vscode/argv.json" "$HOME/.cursor/argv.json"
)
EDITOR_COMMANDS=(code code-insiders cursor windsurf)
DEFAULTS_DOMAINS=(
  com.apple.dock com.apple.finder com.apple.screencapture com.apple.Terminal
  com.apple.Safari com.apple.TextEdit NSGlobalDomain
  com.apple.AppleMultitouchTrackpad com.apple.driver.AppleBluetoothMultitouch.trackpad
  com.googlecode.iterm2 com.openai.codex com.openai.chat com.anthropic.claudefordesktop
)

# 合併目錄；保留內部符號連結與權限，但不複製 socket/device 等執行期物件。
copy_tree() {
  mkdir -p "$2"
  local source_real dest_real
  source_real="$(cd "$1" && pwd -P)"
  dest_real="$(cd "$2" && pwd -P)"
  case "$dest_real/" in
    "$source_real/"*) echo "拒絕將目錄複製到其自身內部: $1 -> $2" >&2; return 1 ;;
  esac
  rsync -rlpt -- "$1/" "$2/"
}

# 資料庫與其 WAL 必須成套還原，不能混入目的地殘留檔案。
# 先準備完整副本，再將既有資料改名保留；不刪除原資料。
restore_snapshot() (
  set -e
  src="$1"
  dest="$2"
  case "$dest" in /*) ;; *) echo "還原路徑需為絕對路徑: $dest" >&2; exit 1 ;; esac
  case "$(basename "$dest")" in
    /|.|..) echo "拒絕將使用者資料還原到根目錄或相對目錄本身" >&2; exit 1 ;;
  esac
  mkdir -p "$(dirname "$dest")"
  dest="$(cd "$(dirname "$dest")" && pwd -P)/$(basename "$dest")"
  if [ "$dest" = / ] || [ "$dest" = "$(cd "$HOME" && pwd -P)" ] ||
      [ "$(basename "$dest")" = . ] || [ "$(basename "$dest")" = .. ]; then
    echo "拒絕將使用者資料還原到根目錄或家目錄本身" >&2
    exit 1
  fi
  stage="$(mktemp -d "$(dirname "$dest")/.mac-migrate-restore.XXXXXX")"
  trap 'rm -rf -- "$stage"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [ -d "$src" ]; then
    copy_tree "$src" "$stage/data"
  else
    cp -p "$src" "$stage/data"
  fi
  previous=""
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    base="$dest.before-restore-$(date +%Y%m%d-%H%M%S)"
    previous="$base"
    suffix=1
    while [ -e "$previous" ] || [ -L "$previous" ]; do
      previous="$base-$suffix"
      suffix=$((suffix + 1))
    done
    mv "$dest" "$previous"
  fi
  if ! mv "$stage/data" "$dest"; then
    [ -z "$previous" ] || mv "$previous" "$dest"
    exit 1
  fi
  [ -z "$previous" ] || printf '原資料已保留: %s\n' "$previous"
)
