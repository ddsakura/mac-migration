#!/bin/bash
# shellcheck disable=SC2329
# Cleanup/rollback functions are reached via EXIT traps.
# Sourced by migration-common.sh. No path list lives here: AI_INDICES uses the shared table.
restore_ai_batch() (
  set -e
  local root="$1" work="" committed=false recovery_failed=false touched=false
  local index slot id src dest previous base suffix status j
  local stages=() destinations=() originals=() existed=() phases=() ids=() created_dirs=()

  rollback_ai() {
    local i phase target old moved failed=false
    for ((i=${#destinations[@]}-1; i>=0; i--)); do
      phase="${phases[$i]}"
      target="${destinations[$i]}"
      old="${originals[$i]}"
      case "$phase" in
        untouched) continue ;;
        saving)
          # The backup is a sibling, so normal saving uses a same-filesystem rename.
          # A rename may succeed just before a signal arrives. Inspect both paths.
          # If both remain (e.g. a partial copy), preserve both for manual recovery;
          # existence alone cannot prove the saved copy is complete.
          if [ -e "$old" ] || [ -L "$old" ]; then
            if [ -e "$target" ] || [ -L "$target" ]; then failed=true; continue; fi
            mv "$old" "$target" || failed=true
          elif [ ! -e "$target" ] && [ ! -L "$target" ]; then
            failed=true
          fi
          ;;
        installing|installed)
          if [ -e "$target" ] || [ -L "$target" ]; then
            moved="$work/rescue/${ids[$i]}"
            if ! mv "$target" "$moved"; then failed=true; continue; fi
          fi
          if [ "${existed[$i]}" = true ]; then
            if ! mv "$old" "$target"; then failed=true; fi
          fi
          ;;
      esac
    done
    for ((i=${#created_dirs[@]}-1; i>=0; i--)); do
      rmdir "${created_dirs[$i]}" || failed=true
    done
    [ "$failed" = false ]
  }

  finish_ai() {
    status=$?
    trap - EXIT INT TERM HUP
    if [ "$committed" != true ] && { [ "$touched" = true ] || [ "${#created_dirs[@]}" -gt 0 ]; }; then
      if rollback_ai; then
        printf 'AI 批次還原失敗；已反向回復本批次目的地。\n' >&2
      else
        recovery_failed=true
        printf 'AI 回復失敗；保留救援資料，請勿刪除下列位置：\n' >&2
        printf '  暫存與日誌: %q\n' "$work" >&2
        for j in "${!destinations[@]}"; do
          printf '  目的地: %q  原資料: %q  暫存: %q\n' \
            "${destinations[$j]}" "${originals[$j]}" "${stages[$j]}" >&2
        done
      fi
      [ "$status" -ne 0 ] || status=1
    fi
    if [ -n "$work" ] && [ "$recovery_failed" = false ]; then rm -rf -- "$work"; fi
    exit "$status"
  }
  trap finish_ai EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  [ "${#AI_INDICES[@]}" -gt 0 ] || exit 0
  integrity structure "$root" "${DEVELOPER_IDS[@]}"
  integrity destinations "$root" "$HOME" "${AI_DESTINATIONS[@]}"
  check_ai_processes "${AI_SELECTED_IDS[@]}"
  # TMPDIR may itself be a source/destination; reject before creating anything.
  local temp_parent="${TMPDIR:-/tmp}"
  integrity disjoint "$root" "$temp_parent/mac-migrate-ai.pending"
  for dest in "${AI_DESTINATIONS[@]}"; do
    integrity disjoint "$dest" "$temp_parent/mac-migrate-ai.pending"
  done
  work="$(mktemp -d "$temp_parent/mac-migrate-ai.XXXXXX")"
  mkdir "$work/staged" "$work/rescue"
  printf 'AI restore journal v1 (paths use Bash %%q escaping)\n' > "$work/journal.txt"

  # Prepare and verify every copy before any destination is replaced.
  for index in "${AI_INDICES[@]}"; do
    id="${DEVELOPER_IDS[$index]}"
    src="$root/developer/$id"
    dest="${DEVELOPER_PATHS[$index]}"
    slot=${#destinations[@]}
    ids+=("$id")
    stages+=("$work/staged/$id")
    destinations+=("$dest")
    originals+=("")
    existed+=(false)
    phases+=(untouched)
    if [ -d "$src" ]; then copy_tree "$src" "${stages[$slot]}"
    else cp -p "$src" "${stages[$slot]}"; fi
    integrity compare "$src" "${stages[$slot]}"
  done
  integrity verify "$root"
  integrity destinations "$root" "$HOME" "${destinations[@]}"
  check_ai_processes "${AI_SELECTED_IDS[@]}"

  for slot in "${!destinations[@]}"; do
    dest="${destinations[$slot]}"
    local parent missing=() n
    parent="$(dirname "$dest")"
    while [ ! -d "$parent" ]; do
      missing+=("$parent")
      parent="$(dirname "$parent")"
    done
    for ((n=${#missing[@]}-1; n>=0; n--)); do
      mkdir "${missing[$n]}"
      created_dirs+=("${missing[$n]}")
    done
    base="$dest.before-restore-$(date +%Y%m%d-%H%M%S)"
    previous="$base"
    suffix=1
    while [ -e "$previous" ] || [ -L "$previous" ]; do
      previous="$base-$suffix"; suffix=$((suffix + 1))
    done
    originals[slot]="$previous"
    if [ -e "$dest" ] || [ -L "$dest" ]; then existed[slot]=true; fi
    printf 'item %q destination %q original %q existed %s staged %q\n' \
      "${ids[$slot]}" "$dest" "$previous" "${existed[$slot]}" "${stages[$slot]}" >> "$work/journal.txt"
    if [ "${existed[$slot]}" = true ]; then
      phases[slot]=saving
      touched=true
      mv "$dest" "$previous"
    fi
    phases[slot]=installing
    touched=true
    mv "${stages[$slot]}" "$dest"
    phases[slot]=installed
    printf 'installed %q\n' "${ids[$slot]}" >> "$work/journal.txt"
  done
  committed=true
  for slot in "${!destinations[@]}"; do
    if [ "${existed[slot]}" = true ]; then
      printf '原 AI 資料已保留: %q\n' "${originals[slot]}"
    fi
  done
  printf 'AI 批次還原完成。\n'
)
