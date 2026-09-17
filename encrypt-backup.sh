#!/bin/bash
# 用法: bash encrypt-backup.sh [備份資料夾]
# 即使以 bash -x/-v 啟動，也不可記錄密碼。
set +x
set +v
set +a
set -e
umask 077

SOURCE_DIR="${1:-$(pwd)/mac-migration}"
if [ "$#" -gt 1 ] || [ -L "$SOURCE_DIR" ] || [ ! -d "$SOURCE_DIR" ]; then
  echo "用法: bash encrypt-backup.sh [備份資料夾]（必須是一般資料夾）" >&2
  exit 1
fi
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd -P)"
# 只接受專案產生的備份目錄，避免清理時誤刪任意目錄。
if [ "$(basename "$SOURCE_DIR")" != mac-migration ] ||
    [ ! -d "$SOURCE_DIR/dotfiles" ] || [ ! -d "$SOURCE_DIR/ssh" ] ||
    [ ! -d "$SOURCE_DIR/defaults" ]; then
  echo "請指定包含 dotfiles/、ssh/、defaults/ 的 mac-migration 資料夾。" >&2
  exit 1
fi
if [ ! -t 0 ]; then
  echo "請在互動式終端機執行，以安全輸入密碼。" >&2
  exit 1
fi

if ! command -v hdiutil >/dev/null 2>&1; then
  echo "需要 macOS 內建的 hdiutil；明文備份已保留: $SOURCE_DIR" >&2
  exit 1
fi

PARENT_DIR="$(dirname "$SOURCE_DIR")"
ARCHIVE_BASE="$PARENT_DIR/mac-migration-$(date +%Y%m%d-%H%M%S)"
ARCHIVE_PATH="$ARCHIVE_BASE.dmg"
suffix=1
while [ -e "$ARCHIVE_PATH" ] || [ -L "$ARCHIVE_PATH" ]; do
  ARCHIVE_PATH="$ARCHIVE_BASE-$suffix.dmg"
  suffix=$((suffix + 1))
done
# 先在私有暫存目錄建立，只有驗證成功才發布成正式備份。
WORK_DIR="$(mktemp -d "$PARENT_DIR/.mac-migration-encrypt.XXXXXX")"
cleanup() {
  unset BACKUP_PASSWORD VERIFY_PASSWORD
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
TEMP_ARCHIVE="$WORK_DIR/backup.dmg"

echo "建立 AES-256 加密 DMG；內容與檔名需解鎖後才能讀取。"
echo "密碼隱藏輸入，只透過標準輸入交給 macOS，不寫入命令列或設定檔。"
# unset 清除可能由父程序匯出的同名變數，避免密碼成為環境變數。
unset BACKUP_PASSWORD VERIFY_PASSWORD
IFS= read -r -s -p "設定備份密碼: " BACKUP_PASSWORD || exit 1
echo ""
if [ -z "$BACKUP_PASSWORD" ]; then
  echo "密碼不可為空；明文備份仍在: $SOURCE_DIR" >&2
  exit 1
fi
if ! printf '%s\0' "$BACKUP_PASSWORD" | hdiutil create "$TEMP_ARCHIVE" \
    -srcfolder "$SOURCE_DIR" -volname mac-migration -fs "Case-sensitive APFS" \
    -format UDZO -encryption AES-256 -stdinpass; then
  echo "加密失敗，明文備份已保留: $SOURCE_DIR" >&2
  exit 1
fi
unset BACKUP_PASSWORD

echo "請再次輸入密碼，解密並檢查映像檔完整性。"
IFS= read -r -s -p "驗證備份密碼: " VERIFY_PASSWORD || exit 1
echo ""
if [ -z "$VERIFY_PASSWORD" ] ||
    ! printf '%s\0' "$VERIFY_PASSWORD" | hdiutil verify "$TEMP_ARCHIVE" -stdinpass -nocache; then
  echo "解密驗證失敗；未保留映像檔，明文備份仍在: $SOURCE_DIR" >&2
  exit 1
fi
unset VERIFY_PASSWORD
# 不覆蓋既有檔案；使用移動以支援不提供硬連結的外接磁碟。
if ! mv -n "$TEMP_ARCHIVE" "$ARCHIVE_PATH" || [ -e "$TEMP_ARCHIVE" ]; then
  echo "無法儲存加密檔，明文備份已保留: $SOURCE_DIR" >&2
  exit 1
fi
echo "加密及解密驗證完成: $ARCHIVE_PATH"
echo "注意：同目錄下較早的備份不會被刪除或加密。"
read -r -p "刪除本次明文備份 $SOURCE_DIR？[y/N] " DELETE_PLAIN || DELETE_PLAIN=""
if [[ "$DELETE_PLAIN" =~ ^[Yy]$ ]]; then
  rm -rf -- "$SOURCE_DIR"
  echo "已刪除本次明文備份（一般刪除，不保證安全抹除）。"
else
  echo "明文備份已保留: $SOURCE_DIR"
fi
