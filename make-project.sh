#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

if shopt -oq posix; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail

BASE_PROJECT_NAME="ProjMaker"
BASE_PROJECT_INFO_FILE=".base-project-info.json"
TEMPLATE_REPO="git@github.com:matechios/ProjMaker.git"
CURRENT_STEP=0
TOTAL_STEPS=6

progress() {
  local message="$1"

  CURRENT_STEP=$((CURRENT_STEP + 1))
  printf '[%02d/%02d] %s...\n' "$CURRENT_STEP" "$TOTAL_STEPS" "$message"
}

prompt_required() {
  local prompt="$1"
  local value=""

  while [[ -z "$value" ]]; do
    read -r -p "$prompt" value
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
  done

  printf '%s' "$value"
}

prompt_optional() {
  local prompt="$1"
  local value=""

  read -r -p "$prompt" value
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  printf '%s' "$value"
}

normalize_dropped_path() {
  local path="$1"

  path="${path#\'}"
  path="${path%\'}"
  path="${path#\"}"
  path="${path%\"}"
  PATH_INPUT="$path" perl -CS -e 'my $path = $ENV{"PATH_INPUT"}; $path =~ s/\\(.)/$1/g; print $path;'
}

expand_path() {
  local path="$1"

  path="$(normalize_dropped_path "$path")"

  case "$path" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${path#~/}" ;;
    *) printf '%s' "$path" ;;
  esac
}

replace_project_name_in_files() {
  local target_dir="$1"
  local new_project_name="$2"

  while IFS= read -r -d '' file; do
    if LC_ALL=C grep -Iq "$BASE_PROJECT_NAME" "$file"; then
      OLD_PROJECT_NAME="$BASE_PROJECT_NAME" NEW_PROJECT_NAME="$new_project_name" \
        perl -0pi -e 's/\Q$ENV{OLD_PROJECT_NAME}\E/$ENV{NEW_PROJECT_NAME}/g' "$file"
    fi
  done < <(find "$target_dir" -type f \
    -not -path '*/.git/*' \
    -not -path '*/Pods/*' \
    -not -path '*/build/*' \
    -not -path '*/DerivedData/*' \
    -not -path '*/scripts/make-project.sh' \
    -not -name "$BASE_PROJECT_INFO_FILE" \
    -print0)
}

rename_project_paths() {
  local target_dir="$1"
  local new_project_name="$2"

  while IFS= read -r -d '' path; do
    local dir
    local name
    local new_name

    dir="$(dirname "$path")"
    name="$(basename "$path")"
    new_name="${name//$BASE_PROJECT_NAME/$new_project_name}"

    if [[ "$name" != "$new_name" ]]; then
      mv "$path" "$dir/$new_name"
    fi
  done < <(find "$target_dir" -depth -name "*$BASE_PROJECT_NAME*" -print0)
}

clone_project_template() {
  local target_dir="$1"

  if ! command -v git >/dev/null 2>&1; then
    echo "Không tìm thấy git. Hãy cài git rồi chạy lại script."
    exit 1
  fi

  git clone --depth 1 "$TEMPLATE_REPO" "$target_dir"
  rm -rf \
    "$target_dir/.git" \
    "$target_dir/.claude" \
    "$target_dir/.github/workflows/command_archive.yml" \
    "$target_dir/Pods" \
    "$target_dir/Podfile.lock" \
    "$target_dir/DerivedData" \
    "$target_dir/build"
  find "$target_dir" \( -name '.DS_Store' -o -name '*.xcuserstate' \) -type f -delete
  find "$target_dir" -type d -name 'xcuserdata' -prune -exec rm -rf {} +
}

open_workspace() {
  local target_dir="$1"
  local new_project_name="$2"
  local workspace_path="$target_dir/$new_project_name.xcworkspace"

  if [[ -d "$workspace_path" ]]; then
    open "$workspace_path"
  else
    echo "Không tìm thấy workspace để mở: $workspace_path"
  fi
}

install_pods_if_possible() {
  local target_dir="$1"

  if [[ "${SCAFFOLD_SKIP_POD_INSTALL:-}" == "1" ]]; then
    echo "Bỏ qua pod install vì SCAFFOLD_SKIP_POD_INSTALL=1."
    return
  fi

  if [[ ! -f "$target_dir/Podfile" ]]; then
    return
  fi

  if ! command -v pod >/dev/null 2>&1; then
    echo "Không tìm thấy CocoaPods. Hãy chạy thủ công: cd \"$target_dir\" && pod install"
    return
  fi

  echo "Đang chạy pod install..."
  (cd "$target_dir" && pod install)
}

write_base_project_info() {
  local target_dir="$1"
  local info_path="$target_dir/$BASE_PROJECT_INFO_FILE"
  local generated_at

  generated_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  if [[ ! -f "$info_path" ]]; then
    cat > "$info_path" <<EOF
{
  "baseProject": "$BASE_PROJECT_NAME",
  "baseVersion": "unknown",
  "changeLogs": [],
  "generatedAt": "$generated_at"
}
EOF
    return
  fi

  GENERATED_AT="$generated_at" perl -0pi -e 's/"generatedAt"\s*:\s*(null|"[^"]*")/"generatedAt": "$ENV{GENERATED_AT}"/' "$info_path"
}

main() {
  local new_project_name
  local output_parent_input
  local output_parent
  local output_parent_abs
  local target_dir

  new_project_name="$(prompt_required "Nhập tên project: ")"

  if [[ ! "$new_project_name" =~ ^[A-Za-z][A-Za-z0-9]*$ ]]; then
    echo "Tên project chỉ nên gồm chữ/số và bắt đầu bằng chữ để hợp lệ với Swift module, target và bundle id."
    exit 1
  fi

  output_parent_input="$(prompt_optional "Nhập đường dẫn chứa project (để trống để tạo trong thư mục hiện tại): ")"
  if [[ -z "$output_parent_input" ]]; then
    output_parent="."
  else
    output_parent="$(expand_path "$output_parent_input")"
  fi

  mkdir -p "$output_parent"
  output_parent_abs="$(cd "$output_parent" && pwd -P)"
  target_dir="$output_parent_abs/$new_project_name"

  if [[ -e "$target_dir" ]]; then
    echo "Đường dẫn đã tồn tại: $target_dir"
    exit 1
  fi

  echo "Đang tạo project tại: $target_dir"

  progress "Đang clone template project"
  clone_project_template "$target_dir"

  progress "Đang đổi tên file/folder project"
  rename_project_paths "$target_dir" "$new_project_name"

  progress "Đang cập nhật reference trong source/config"
  replace_project_name_in_files "$target_dir" "$new_project_name"

  progress "Đang ghi thông tin base version"
  write_base_project_info "$target_dir"

  progress "Đang cài đặt CocoaPods"
  install_pods_if_possible "$target_dir"

  progress "Đang mở workspace"
  open_workspace "$target_dir" "$new_project_name"

  echo "Tạo project hoàn tất."
  echo "Workspace: $target_dir/$new_project_name.xcworkspace"
  echo "Base info: $target_dir/$BASE_PROJECT_INFO_FILE"
  echo ""
  echo "============================================================"
  echo "Vui lòng đọc README.md trước khi bắt đầu code."
  echo "============================================================"
}

main "$@"
