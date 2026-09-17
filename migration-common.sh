#!/bin/bash
# shellcheck disable=SC2034
# 陣列由載入此檔的 backup.sh / restore.sh 使用。
# 共用路徑清單：備份與還原共用，避免只備份卻漏還原。
# 此檔需與 backup.sh / restore.sh 放在一起。
DEVELOPER_IDS=(
  codex claude-code claude-state agent-skills codex-documents
  codex-desktop codex-desktop-support claude-desktop chatgpt-desktop
  vscode vscode-insiders cursor windsurf jetbrains
  vim gvimrc ideavimrc emacs emacs-config vscode-argv cursor-argv
)
DEVELOPER_PATHS=(
  "${CODEX_HOME:-$HOME/.codex}" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$HOME/.claude.json" "$HOME/.agents" "$HOME/Documents/Codex"
  "$HOME/Library/Application Support/Codex" "$HOME/Library/Application Support/com.openai.codex"
  "$HOME/Library/Application Support/Claude" "$HOME/Library/Application Support/com.openai.chat"
  "$HOME/Library/Application Support/Code/User" "$HOME/Library/Application Support/Code - Insiders/User"
  "$HOME/Library/Application Support/Cursor/User" "$HOME/Library/Application Support/Windsurf/User"
  "$HOME/Library/Application Support/JetBrains"
  "$HOME/.vim" "$HOME/.gvimrc" "$HOME/.ideavimrc" "$HOME/.emacs" "$HOME/.emacs.d"
  "$HOME/.vscode/argv.json" "$HOME/.cursor/argv.json"
)
EDITOR_COMMANDS=(code code-insiders cursor windsurf)
# Explicit extra paths shared by backup and restore; no blanket ~/.local/share copy.
EXTRA_IDS=(profile zlogin zlogout netrc pypirc aws azure kube gnupg docker-config docker-contexts bin local-bin)
EXTRA_PATHS=(
  "$HOME/.profile" "$HOME/.zlogin" "$HOME/.zlogout" "$HOME/.netrc" "$HOME/.pypirc"
  "$HOME/.aws" "$HOME/.azure" "$HOME/.kube" "$HOME/.gnupg"
  "$HOME/.docker/config.json" "$HOME/.docker/contexts" "$HOME/bin" "$HOME/.local/bin"
)

backup_extra_settings() {
  local root="$1" index src dest status=0 failed
  for index in "${!EXTRA_IDS[@]}"; do
    src="${EXTRA_PATHS[$index]}"
    dest="$root/extra-settings/${EXTRA_IDS[$index]}"
    failed=false
    if [ -L "$src" ]; then
      printf '略過符號連結根路徑，請另備份外部目標: %s\n' "$src" >&2
    elif [ -d "$src" ]; then
      copy_tree "$src" "$dest" || failed=true
    elif [ -f "$src" ]; then
      mkdir -p "$root/extra-settings" && cp -p "$src" "$dest" || failed=true
    fi
    if [ "$failed" = true ]; then
      printf '備份不完整: %s（繼續其他項目）\n' "$src" >&2
      printf '%s\n' "${EXTRA_IDS[$index]}" >> "$root/extra-settings-failed.txt" || return 1
      status=1
    fi
  done
  return "$status"
}

restore_extra_settings() {
  local root="$1" index src dest
  for index in "${!EXTRA_IDS[@]}"; do
    src="$root/extra-settings/${EXTRA_IDS[$index]}"
    dest="${EXTRA_PATHS[$index]}"
    if [ -f "$root/extra-settings-failed.txt" ] &&
        grep -Fxq "${EXTRA_IDS[$index]}" "$root/extra-settings-failed.txt"; then
      printf '略過不完整的備份項目，請從原機重新備份: %s\n' "$dest" >&2
      continue
    fi
    if [ -e "$src" ] || [ -L "$src" ]; then
      if [ -L "$src" ]; then
        printf '拒絕還原符號連結資料根節點: %s\n' "$src" >&2
        return 1
      fi
      integrity destinations "$root" "$HOME" "$dest" || return 1
      if confirm "還原 $dest？（現有資料會另存，可能包含憑證或私鑰）"; then
        run_or_dry "會還原完整資料（原資料另存 .before-restore-*）: $dest <= $src" restore_snapshot "$src" "$dest"
      fi
    fi
  done
}
DEFAULTS_DOMAINS=(
  com.apple.dock com.apple.finder com.apple.screencapture com.apple.Terminal
  com.apple.Safari com.apple.TextEdit NSGlobalDomain
  com.apple.AppleMultitouchTrackpad com.apple.driver.AppleBluetoothMultitouch.trackpad
  com.googlecode.iterm2 com.openai.codex com.openai.chat com.anthropic.claudefordesktop
)

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTEGRITY_TOOL="$COMMON_DIR/migration-integrity.pl"
# Resolve before brew shellenv can change PATH; command stubs remain injectable in tests.
PGREP_BIN="$(command -v pgrep || true)"

integrity() { /usr/bin/perl "$INTEGRITY_TOOL" "$@"; }

# Read bundle metadata only; never launch an app. Arguments allow isolated fixtures.
list_installed_apps() (
  local root app name version plist paths scan_status=0
  printf '# Installed apps — reinstall reference only (no app binaries)\n'
  printf '# Tab-separated columns; values use Bash %%q escaping for special characters.\n'
  printf 'Name\tVersion\tPath\n'
  paths="$(mktemp "${TMPDIR:-/tmp}/mac-migrate-apps.XXXXXX")" || exit 1
  trap 'rm -f -- "$paths"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  for root in "$@"; do
    [ -d "$root" ] || continue
    # Prune bundles to omit embedded helper apps, but scan folders such as Utilities.
    if ! find -H "$root" -name '*.app' -prune -print0 > "$paths"; then
      printf '# WARNING: scan incomplete for %q\n' "$root"
      scan_status=1
    fi
    while IFS= read -r -d '' app; do
      [ -d "$app" ] || continue
      plist="$app/Contents/Info.plist"
      name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$plist" 2>/dev/null)" || name=""
      if [ -z "$name" ]; then
        name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$plist" 2>/dev/null)" || name=""
      fi
      [ -n "$name" ] || name="$(basename "$app" .app)"
      version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null)" || version=""
      if [ -z "$version" ]; then
        version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null)" || version=""
      fi
      [ -n "$version" ] || version=unknown
      printf '%q\t%q\t%q\n' "$name" "$version" "$app"
    done < "$paths"
  done
  return "$scan_status"
)

is_ai_id() {
  case "$1" in codex*|claude*|agent-skills|chatgpt-desktop) return 0 ;; *) return 1 ;; esac
}

select_ai_data() {
  local mode="$1" root="$2" index path
  AI_INDICES=()
  AI_SELECTED_IDS=()
  AI_DESTINATIONS=()
  for index in "${!DEVELOPER_IDS[@]}"; do
    is_ai_id "${DEVELOPER_IDS[$index]}" || continue
    if [ "$mode" = backup ]; then path="${DEVELOPER_PATHS[$index]}"
    else path="$root/developer/${DEVELOPER_IDS[$index]}"; fi
    if [ -d "$path" ] || [ -f "$path" ]; then
      AI_INDICES+=("$index")
      AI_SELECTED_IDS+=("${DEVELOPER_IDS[$index]}")
      AI_DESTINATIONS+=("${DEVELOPER_PATHS[$index]}")
    fi
  done
}

# Preferences are AI data too, even when the corresponding user-data directory is absent.
select_ai_preferences() {
  local mode="$1" root="$2" domain id path
  AI_PREFERENCE_IDS=()
  for domain in com.openai.codex com.openai.chat com.anthropic.claudefordesktop; do
    case "$domain" in
      com.openai.codex) id=codex-desktop ;;
      com.openai.chat) id=chatgpt-desktop ;;
      *) id=claude-desktop ;;
    esac
    if [ "$mode" = backup ]; then
      path="$HOME/Library/Preferences/$domain"
    else
      path="$root/defaults/${domain//./_}"
    fi
    if [ -f "$path.plist" ] || [ -f "$path.txt" ]; then AI_PREFERENCE_IDS+=("$id"); fi
  done
}

check_ai_processes() {
  local id name status checked=" "
  local names=()
  for id in "$@"; do
    case "$id" in
      codex*) names+=(Codex codex) ;;
      claude*) names+=(Claude claude) ;;
      agent-skills) names+=(Codex codex Claude claude) ;;
      chatgpt-desktop) names+=(ChatGPT) ;;
    esac
  done
  for name in "${names[@]}"; do
    case "$checked" in *" $name "*) continue ;; esac
    checked="$checked$name "
    if [ -z "$PGREP_BIN" ]; then
      printf '無法可靠檢查程序：找不到 pgrep；中止。\n' >&2
      return 1
    fi
    if "$PGREP_BIN" -x "$name" >/dev/null 2>&1; then
      printf '程序仍在執行: %s；請關閉後重試，未自動終止任何程序。\n' "$name" >&2
      return 1
    else
      status=$?
      if [ "$status" -ne 1 ]; then
        printf '無法可靠檢查程序: %s（pgrep 狀態 %s）；中止。\n' "$name" "$status" >&2
        return 1
      fi
    fi
  done
}

# 合併目錄；保留內部符號連結與權限，但不複製 socket/device 等執行期物件。
copy_tree() {
  integrity disjoint "$1" "$2" || return 1
  mkdir -p "$2" || return 1
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

source "$COMMON_DIR/migration-ai.sh"
