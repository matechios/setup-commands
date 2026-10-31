#!/bin/bash
# Install ios-firebase on this Mac: write the command into ~/.local/bin and
# check the tools it needs. The tool is embedded at the end of this file, so
# this file is all a dev needs; run a newer copy of it to update.
#   ./install-ios-firebase.sh [bin_dir]
#
# Do not edit below the marker line: scripts/build-installer.sh regenerates it
# from bin/ios-firebase.
set -euo pipefail

MARKER=__IOS_FIREBASE_TOOL__
BIN_DIR="${1:-$HOME/.local/bin}"
TARGET="$BIN_DIR/ios-firebase"

if [[ -t 1 ]]; then
  C_RED=$'\033[31m' C_YEL=$'\033[33m' C_GRN=$'\033[32m' C_BLU=$'\033[34m' C_DIM=$'\033[2m' C_B=$'\033[1m' C_0=$'\033[0m'
else
  C_RED= C_YEL= C_GRN= C_BLU= C_DIM= C_B= C_0=
fi
ok()   { echo "  ${C_GRN}✓${C_0} $*"; }
warn() { echo "  ${C_YEL}!${C_0} $*"; }
bad()  { echo "  ${C_RED}✗${C_0} $*"; }
fix()  { echo "    ${C_DIM}$*${C_0}"; }
die()  { bad "$*"; exit 1; }

tool_body() { sed -n "/^$MARKER\$/,\$p" "${BASH_SOURCE[0]}" | tail -n +2; }
VERSION="$(tool_body | sed -n 's/^TOOL_VERSION=//p' | head -1)"
COMMIT="$(tool_body | sed -n 's/^TOOL_COMMIT=//p' | head -1)"
VERSION="$VERSION${COMMIT:+ ($COMMIT)}"
[[ -n "$VERSION" ]] || die "File cài đặt bị lỗi: không có tool đi kèm. Tải lại file cài đặt."

echo
echo "${C_BLU}==>${C_0} ${C_B}Cài đặt ios-firebase $VERSION${C_0}"
echo

previous=
[[ ! -x "$TARGET" ]] || previous="$("$TARGET" --version 2>/dev/null | sed 's/^ios-firebase //' || true)"
mkdir -p "$BIN_DIR" 2>/dev/null || die "Không tạo được thư mục $BIN_DIR"
tool_body > "$TARGET.tmp" && chmod +x "$TARGET.tmp" && mv -f "$TARGET.tmp" "$TARGET" \
  || die "Không ghi được $TARGET"
if [[ -n "$previous" && "$previous" != "$VERSION" ]]; then
  ok "ios-firebase: cập nhật $previous → $VERSION"
else
  ok "ios-firebase $VERSION"
fi

warnings=0
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    warn "${BIN_DIR/#$HOME/~} chưa có trong PATH. Thêm vào ~/.zshrc rồi mở lại Terminal:"
    fix "echo 'export PATH=\"${BIN_DIR/#$HOME/\$HOME}:\$PATH\"' >> ~/.zshrc"
    warnings=$((warnings + 1))
    ;;
esac

xcodes="$("$TARGET" xcodes 2>/dev/null | sed -n 's/^  [* ] \([^ ]*\) .*/\1/p' | paste -sd, - | sed 's/,/, /g')"
if [[ -z "$xcodes" ]]; then
  bad "Chưa cài Xcode. Cài Xcode từ App Store rồi chạy lại file cài đặt."
  warnings=$((warnings + 1))
elif [[ "$xcodes" == *", "* ]]; then
  ok "Xcode $xcodes ${C_DIM}· chọn bản để build bằng --xcode <version>${C_0}"
else
  ok "Xcode $xcodes"
fi

if ! command -v firebase >/dev/null 2>&1 && command -v brew >/dev/null 2>&1 && [[ -t 0 ]]; then
  read -r -p "  ${C_YEL}?${C_0} Chưa có Firebase CLI. Cài bằng Homebrew? [Y/n] " answer
  if [[ ! "$answer" =~ ^[Nn] ]]; then
    log="$(mktemp -t ios-firebase-brew)"
    printf '    %s' "${C_DIM}Đang cài Firebase CLI…${C_0}"
    if brew install firebase-cli > "$log" 2>&1; then
      printf '\r\033[K'
      rm -f "$log"
    else
      printf '\n'
      bad "Cài Firebase CLI lỗi. Log: $log"
    fi
  fi
fi
if command -v firebase >/dev/null 2>&1; then
  account="$(firebase login:list --json 2>/dev/null | plutil -extract result.0.user.email raw -o - - 2>/dev/null || true)"
  if [[ -n "$account" ]]; then
    ok "Firebase CLI $(firebase --version 2>/dev/null) · $account"
  else
    warn "Firebase CLI chưa đăng nhập. Chạy:"
    fix "firebase login"
    warnings=$((warnings + 1))
  fi
else
  bad "Chưa có Firebase CLI. Cài bằng:"
  fix "brew install firebase-cli"
  warnings=$((warnings + 1))
fi

echo
if (( warnings == 0 )); then
  echo "${C_GRN}${C_B}Cài đặt xong.${C_0} Trong thư mục repo app, chạy ${C_B}ios-firebase init${C_0} để bắt đầu."
else
  echo "${C_YEL}${C_B}Đã cài ios-firebase.${C_0} Xử lý $warnings mục ở trên rồi chạy ${C_B}ios-firebase init${C_0} trong repo app."
fi
command -v xcbeautify >/dev/null 2>&1 \
  || echo "${C_DIM}Mẹo: brew install xcbeautify để log build dễ đọc hơn.${C_0}"
exit 0
__IOS_FIREBASE_TOOL__
#!/bin/bash
# ios-firebase: archive the iOS app in the current git repo on this Mac and
# upload it to Firebase App Distribution. Signing uses the Apple account and
# profiles already set up in Xcode on this machine; the upload uses the account
# from `firebase login`. Only committed code is built.
#
#   ios-firebase [options]          check, build and upload
#   ios-firebase init [options]     create .ios-firebase.json for this repo
#   ios-firebase xcodes             list the installed Xcode versions
#   ios-firebase --version          print the tool version
#
# Team settings live in .ios-firebase.json at the root of the app repo. Build
# output goes to ~/Library/Developer/ios-firebase/<owner>/<repo>/<timestamp>/.
# The build itself runs in a git worktree of HEAD next to it (src/) with its
# own DerivedData, so Xcode can keep working on the repo in the meantime.
# Works with the bash 3.2 that ships with macOS.
set -euo pipefail

# Bump TOOL_VERSION for every release; scripts/build-installer.sh fills in
# TOOL_COMMIT in the copy it embeds into install-ios-firebase.sh.
TOOL_VERSION=1.0
TOOL_COMMIT=14530d1-dirty
CONFIG_NAME=.ios-firebase.json
OUT_ROOT="${IOS_FIREBASE_HOME:-$HOME/Library/Developer/ios-firebase}"
KEEP_RUNS=5
FIREBASE="${FIREBASE_BIN:-firebase}"
PLISTBUDDY=/usr/libexec/PlistBuddy
KNOWN_KEYS="scheme workspace project configuration firebase_plist groups testers export_options_plist xcode"

if [[ -t 1 ]]; then
  C_RED=$'\033[31m' C_YEL=$'\033[33m' C_GRN=$'\033[32m' C_DIM=$'\033[2m' C_B=$'\033[1m' C_0=$'\033[0m'
else
  C_RED= C_YEL= C_GRN= C_DIM= C_B= C_0=
fi

PROBLEMS=0
fail() { echo "${C_RED}✗ $*${C_0}" >&2; exit 1; }
ok()   { echo "  ${C_GRN}✓${C_0} $*"; }
warn() { echo "  ${C_YEL}!${C_0} $*"; }
bad()  { echo "  ${C_RED}✗${C_0} $*"; PROBLEMS=$((PROBLEMS + 1)); }
hint() { echo "${C_YEL}→ $*${C_0}" >&2; }
step() { echo; echo "${C_B}== $*${C_0}"; }

usage() {
  cat <<'EOF'
Build app iOS trong repo hiện tại và upload lên Firebase App Distribution.

  ios-firebase [tùy chọn]         kiểm tra, build, upload
  ios-firebase init [tùy chọn]    tạo .ios-firebase.json cho repo
  ios-firebase xcodes             liệt kê các bản Xcode đã cài
  ios-firebase --version          in phiên bản của tool

Tùy chọn khi build:
  -g, --groups a,b        nhóm tester (ghi đè "groups" trong config; "" = không gửi cho ai)
  -t, --testers a@x,b@y   email tester (ghi đè "testers")
  -m, --message TEXT      ghi chú cho tester trong release notes
      --notes-file FILE   thêm nội dung FILE vào release notes
  -c, --configuration X   build configuration (mặc định theo config, hoặc Debug)
      --scheme X          scheme (ghi đè config)
      --app-version X     ghi đè MARKETING_VERSION
      --build N           ghi đè CURRENT_PROJECT_VERSION
      --pod-install       chạy pod install trước khi build
      --xcode X           chọn Xcode theo version (16, 16.4) hoặc đường dẫn .app
                          (ghi đè "xcode" trong config; xem: ios-firebase xcodes)
      --dry-run           chỉ kiểm tra và in release notes dự kiến, không build
      --no-upload         build và export .ipa, không upload
      --open              mở release trên Firebase console sau khi upload
  -v, --verbose           in toàn bộ log xcodebuild

Tùy chọn của init:
      --scheme X  --plist PATH  --groups a,b  -c X  --xcode X  --force

Release notes luôn kèm branch, commit, configuration, version và người build.
EOF
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
tool_version() {
  local commit="$TOOL_COMMIT"
  [[ -n "$commit" ]] || commit="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --short HEAD 2>/dev/null || true)"
  echo "$TOOL_VERSION${commit:+ ($commit)}"
}

CMD=run
case "${1:-}" in
  init) CMD=init; shift ;;
  xcodes) CMD=xcodes; shift ;;
  -V | --version | version) echo "ios-firebase $(tool_version)"; exit 0 ;;
esac

OPT_GROUPS= OPT_GROUPS_SET=false OPT_TESTERS= OPT_TESTERS_SET=false
OPT_MESSAGE= OPT_NOTES_FILE= OPT_CONFIGURATION= OPT_SCHEME= OPT_PLIST=
OPT_VERSION= OPT_BUILD= OPT_XCODE= OPT_POD_INSTALL=false DRY_RUN=false NO_UPLOAD=false
OPEN_CONSOLE=false VERBOSE=false FORCE=false

need_arg() { [[ $# -ge 2 ]] || fail "Thiếu giá trị cho $1"; }
while (($#)); do
  case "$1" in
    -g | --groups) need_arg "$@"; OPT_GROUPS="$2"; OPT_GROUPS_SET=true; shift 2 ;;
    -t | --testers) need_arg "$@"; OPT_TESTERS="$2"; OPT_TESTERS_SET=true; shift 2 ;;
    -m | --message) need_arg "$@"; OPT_MESSAGE="$2"; shift 2 ;;
    --notes-file) need_arg "$@"; OPT_NOTES_FILE="$2"; shift 2 ;;
    -c | --configuration) need_arg "$@"; OPT_CONFIGURATION="$2"; shift 2 ;;
    --scheme) need_arg "$@"; OPT_SCHEME="$2"; shift 2 ;;
    --plist) need_arg "$@"; OPT_PLIST="$2"; shift 2 ;;
    --app-version) need_arg "$@"; OPT_VERSION="$2"; shift 2 ;;
    --build) need_arg "$@"; OPT_BUILD="$2"; shift 2 ;;
    --xcode) need_arg "$@"; OPT_XCODE="$2"; shift 2 ;;
    -V | --version) echo "ios-firebase $(tool_version)"; exit 0 ;;
    --pod-install) OPT_POD_INSTALL=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --no-upload) NO_UPLOAD=true; shift ;;
    --open) OPEN_CONSOLE=true; shift ;;
    --force) FORCE=true; shift ;;
    -v | --verbose) VERBOSE=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) fail "Tham số không hợp lệ: $1 (xem ios-firebase --help)" ;;
  esac
done

if [[ -n "$OPT_NOTES_FILE" ]]; then
  [[ -f "$OPT_NOTES_FILE" ]] || fail "Không tìm thấy file release notes: $OPT_NOTES_FILE"
  OPT_NOTES_FILE="$(cd "$(dirname "$OPT_NOTES_FILE")" && pwd)/$(basename "$OPT_NOTES_FILE")"
fi
for v in "$OPT_VERSION" "$OPT_BUILD"; do
  [[ -z "$v" || "$v" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "'$v' không hợp lệ (dạng 1, 1.2 hoặc 1.2.3)"
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
xml_strings() { sed -n 's|^.*<string>\(.*\)</string>.*$|\1|p' | sed 's/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g'; }
strip_ansi() { sed -E $'s/\033\\[[0-9;]*[A-Za-z]//g'; }
# "a, b,,c" -> "a,b,c"
normalize_list() { tr -d '[:space:]' | tr -s ',' | sed 's/^,//; s/,$//'; }
plist_get() { "$PLISTBUDDY" -c "Print :$1" "$2" 2>/dev/null; }

goto_repo_root() {
  TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "Thư mục hiện tại không nằm trong git repo. Chạy lệnh từ repo của app."
  cd "$TOP"
  CONFIG="$TOP/$CONFIG_NAME"
}

# Read a string or a list (JSON array or "a,b") from the config.
cfg_type() { plutil -type "$1" "$CONFIG" 2>/dev/null; }
cfg_str() {
  local type
  type="$(cfg_type "$1")" || return 0
  [[ "$type" == string ]] || fail "$CONFIG_NAME: \"$1\" phải là chuỗi"
  plutil -extract "$1" raw -o - "$CONFIG"
}
cfg_list() {
  local type
  type="$(cfg_type "$1")" || return 0
  case "$type" in
    string) plutil -extract "$1" raw -o - "$CONFIG" | normalize_list ;;
    array) plutil -extract "$1" xml1 -o - "$CONFIG" | xml_strings | paste -sd, - | normalize_list ;;
    *) fail "$CONFIG_NAME: \"$1\" phải là mảng chuỗi" ;;
  esac
}

load_config() {
  plutil -convert xml1 -o /dev/null "$CONFIG" 2>/dev/null \
    || fail "$CONFIG_NAME không phải JSON hợp lệ (lưu ý: không dùng null)"
  local key
  for key in $(plutil -convert xml1 -o - "$CONFIG" | sed -n $'s|^\t<key>\\(.*\\)</key>$|\\1|p'); do
    [[ " $KNOWN_KEYS " == *" $key "* ]] || warn "$CONFIG_NAME: bỏ qua khóa không biết \"$key\""
  done
  CFG_SCHEME="$(cfg_str scheme)"
  CFG_WORKSPACE="$(cfg_str workspace)"
  CFG_PROJECT="$(cfg_str project)"
  CFG_CONFIGURATION="$(cfg_str configuration)"
  CFG_PLIST="$(cfg_str firebase_plist)"
  CFG_GROUPS="$(cfg_list groups)"
  CFG_TESTERS="$(cfg_list testers)"
  CFG_EXPORT_OPTIONS="$(cfg_str export_options_plist)"
  CFG_XCODE="$(cfg_str xcode)"
}

# Installed Xcode apps as "<version><TAB><path>", newest first.
list_xcodes() {
  local app v
  { mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null; ls -d /Applications/Xcode*.app 2>/dev/null; } \
    | grep -v '/\.Trash/' | awk '!seen[$0]++' \
    | while IFS= read -r app; do
        [[ -x "$app/Contents/Developer/usr/bin/xcodebuild" ]] || continue
        v="$(plist_get CFBundleShortVersionString "$app/Contents/Info.plist")" || continue
        printf '%s\t%s\n' "$v" "$app"
      done | sort -t$'\t' -k1,1rV
}

# Xcode that xcodebuild uses without --xcode: DEVELOPER_DIR, then xcode-select.
default_developer_dir() { echo "${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null)}"; }

# Sets DEVELOPER_DIR from --xcode, or else "xcode" in the config: a version
# ("16", "16.4") picks the newest installed Xcode with that version, anything
# else is the path of an Xcode app. With neither, keeps the default Xcode, or
# the newest one when the default is the Command Line Tools.
select_xcode() {
  local want="${OPT_XCODE:-${CFG_XCODE:-}}" source="--xcode" app installed
  [[ -n "$OPT_XCODE" ]] || source="\"xcode\" trong $CONFIG_NAME"
  installed="$(list_xcodes)"
  if [[ -z "$want" ]]; then
    xcodebuild -version >/dev/null 2>&1 && return 0
    app="$(cut -f2 <<< "$installed" | sed -n 1p)"
    [[ -n "$app" ]] || return 0
    warn "Xcode mặc định là $(default_developer_dir), không phải Xcode. Dùng bản mới nhất: $app"
  elif [[ "$want" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    app="$(awk -F'\t' -v w="$want" '$1 == w || index($1, w ".") == 1 { print $2; exit }' <<< "$installed")"
    if [[ -z "$app" ]]; then
      bad "Không có Xcode $want ($source). Các bản đã cài: $(cut -f1 <<< "$installed" | paste -sd, - | sed 's/,/, /g')"
      return 1
    fi
  else
    app="${want%/}"
    if [[ ! -x "$app/Contents/Developer/usr/bin/xcodebuild" ]]; then
      bad "Không tìm thấy Xcode tại $app ($source)"
      return 1
    fi
  fi
  export DEVELOPER_DIR="$app/Contents/Developer"
}

check_xcode() {
  if XCODE_VERSION="$(xcodebuild -version 2>/dev/null | sed -n 1p)" && [[ -n "$XCODE_VERSION" ]]; then
    ok "$XCODE_VERSION ($(default_developer_dir | sed 's|/Contents/Developer$||'))"
    return 0
  fi
  bad "xcodebuild không chạy được (Xcode mặc định: $(default_developer_dir)). Cài Xcode, hoặc chọn bản khác bằng --xcode (xem: ios-firebase xcodes)"
  return 1
}

# List *.xcworkspace / *.xcodeproj near the repo root, skipping Pods and the
# project.xcworkspace inside every .xcodeproj.
find_containers() {
  find . -maxdepth 2 -name "*.$1" -not -path "*/Pods/*" -not -path "*.xcodeproj/*" -not -path "./.git/*" \
    | sed 's|^\./||' | sort
}

# Sets WORKSPACE or PROJECT and CONTAINER. Returns 1 with a message when ambiguous.
detect_container() {
  WORKSPACE="${CFG_WORKSPACE:-}" PROJECT="${CFG_PROJECT:-}"
  if [[ -z "$WORKSPACE$PROJECT" ]]; then
    local workspaces projects
    workspaces="$(find_containers xcworkspace)"
    projects="$(find_containers xcodeproj)"
    if [[ -n "$workspaces" && $(wc -l <<< "$workspaces") -eq 1 ]]; then
      WORKSPACE="$workspaces"
    elif [[ -z "$workspaces" && -n "$projects" && $(wc -l <<< "$projects") -eq 1 ]]; then
      PROJECT="$projects"
    else
      bad "Không tự chọn được workspace/project (tìm thấy: $(echo $workspaces $projects)). Khai báo \"workspace\" hoặc \"project\" trong $CONFIG_NAME"
      return 1
    fi
  fi
  if [[ -n "$WORKSPACE" ]]; then
    [[ -d "$WORKSPACE" ]] || { bad "Không tìm thấy workspace $WORKSPACE"; return 1; }
    CONTAINER=(-workspace "$WORKSPACE")
  else
    [[ -d "$PROJECT" ]] || { bad "Không tìm thấy project $PROJECT"; return 1; }
    CONTAINER=(-project "$PROJECT")
  fi
}

# Prints the schemes of CONTAINER, without Pods schemes.
list_schemes() {
  local json
  json="$(mktemp -t ios-firebase-list)"
  xcodebuild -list -json "${CONTAINER[@]}" > "$json" 2>/dev/null || true
  { plutil -extract workspace.schemes xml1 -o - "$json" 2>/dev/null \
      || plutil -extract project.schemes xml1 -o - "$json" 2>/dev/null; } \
    | xml_strings | grep -v '^Pods' | awk '!seen[$0]++' || true
  rm -f "$json"
}

# Scheme named after the workspace/project, or the only scheme.
guess_scheme() {
  local schemes name
  schemes="$(list_schemes)"
  name="$(basename "${WORKSPACE:-$PROJECT}")"
  name="${name%.*}"
  if grep -qxF "$name" <<< "$schemes"; then
    echo "$name"
  elif [[ -n "$schemes" && $(wc -l <<< "$schemes") -eq 1 ]]; then
    echo "$schemes"
  else
    echo "$schemes" >&2
    return 1
  fi
}

# GoogleService-Info*.plist files in the source tree (including git-ignored ones).
find_firebase_plists() {
  find . -name "GoogleService-Info*.plist" -type f \
    -not -path "./.git/*" -not -path "*/Pods/*" -not -path "*/build/*" -not -path "*/DerivedData/*" \
    -not -path "*/.build/*" -not -path "*/Carthage/*" -not -path "*.xcarchive/*" \
    | sed 's|^\./||' | sort
}

# Interactive pick from a list when stdin is a terminal.
choose() {
  local prompt="$1"; shift
  local PS3="$prompt: " item
  select item in "$@"; do
    [[ -n "$item" ]] && { echo "$item"; return 0; }
  done
  return 1
}

repo_key() {
  local origin
  origin="$(git remote get-url origin 2>/dev/null || true)"
  if [[ -n "$origin" ]]; then
    sed -E 's#\.git$##; s#/+$##; s#^.*[:/]([^/:]+/[^/:]+)$#\1#' <<< "$origin"
  else
    echo "local/$(basename "$TOP")"
  fi | tr -c 'A-Za-z0-9._/\n-' '_'
}

# Runs a firebase command with --json; sets FB_RESULT (file) and FB_ERROR.
firebase_json() {
  FB_RESULT="$(mktemp -t ios-firebase-fb)"
  FB_ERROR=
  if "$FIREBASE" "$@" --json --non-interactive > "$FB_RESULT" 2>/dev/null \
    && [[ "$(plutil -extract status raw -o - "$FB_RESULT" 2>/dev/null)" == success ]]; then
    return 0
  fi
  FB_ERROR="$(plutil -extract error raw -o - "$FB_RESULT" 2>/dev/null || strip_ansi < "$FB_RESULT" | tail -5)"
  return 1
}

# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------
cmd_init() {
  goto_repo_root
  if [[ -e "$CONFIG" && "$FORCE" != true ]]; then
    fail "Đã có $CONFIG_NAME. Thêm --force để tạo lại."
  fi
  CFG_WORKSPACE= CFG_PROJECT=
  step "Tạo $CONFIG_NAME cho $(basename "$TOP")"
  CFG_XCODE=
  select_xcode && check_xcode || fail "Cần Xcode để đọc danh sách scheme."
  detect_container || fail "Repo cần có đúng một .xcworkspace, hoặc đúng một .xcodeproj nếu không có workspace."
  ok "${WORKSPACE:-$PROJECT}"

  local scheme="$OPT_SCHEME" schemes
  if [[ -z "$scheme" ]]; then
    if ! scheme="$(guess_scheme 2>/dev/null)"; then
      schemes="$(list_schemes)"
      [[ -n "$schemes" ]] || fail "Không đọc được scheme nào của ${WORKSPACE:-$PROJECT}."
      if [[ -t 0 ]]; then
        local -a list=()
        while IFS= read -r s; do list+=("$s"); done <<< "$schemes"
        scheme="$(choose "Chọn scheme" "${list[@]}")"
      else
        fail "Có nhiều scheme, chạy lại với --scheme <tên>. Các scheme: $(paste -sd, - <<< "$schemes" | sed 's/,/, /g')"
      fi
    fi
  fi
  ok "Scheme: $scheme"

  local plist="$OPT_PLIST" plists dev
  if [[ -z "$plist" ]]; then
    plists="$(find_firebase_plists)"
    [[ -n "$plists" ]] || fail "Không tìm thấy GoogleService-Info*.plist nào trong repo. Truyền --plist <đường dẫn>."
    dev="$(grep -iE '(^|/)[^/]*dev[^/]*$' <<< "$plists" || true)"
    if [[ -n "$dev" && $(wc -l <<< "$dev") -eq 1 ]]; then
      plist="$dev"
    elif [[ -t 0 ]]; then
      local -a list=()
      while IFS= read -r p; do list+=("$p"); done <<< "$plists"
      plist="$(choose "Chọn plist Firebase dùng để upload" "${list[@]}")"
    else
      fail "Không tự chọn được plist Firebase, chạy lại với --plist <đường dẫn>. Các file: $(paste -sd, - <<< "$plists" | sed 's/,/, /g')"
    fi
  fi
  plist="${plist#./}"
  [[ -f "$plist" ]] || fail "Không tìm thấy $plist"
  local app_id project_id
  app_id="$(plist_get GOOGLE_APP_ID "$plist")" || fail "$plist không có GOOGLE_APP_ID"
  project_id="$(plist_get PROJECT_ID "$plist" || true)"
  ok "Firebase plist: $plist → project $project_id, app $app_id"
  if ! git ls-files --error-unmatch -- "$plist" >/dev/null 2>&1; then
    warn "$plist không có trong git. Các dev khác cần đặt file này đúng đường dẫn trên máy họ."
  fi

  local groups="$OPT_GROUPS"
  if [[ "$OPT_GROUPS_SET" != true && -t 0 ]]; then
    if [[ -n "$project_id" ]] && command -v "$FIREBASE" >/dev/null 2>&1 \
      && firebase_json appdistribution:groups:list --project "$project_id"; then
      local available
      available="$(plutil -extract result.groups xml1 -o - "$FB_RESULT" 2>/dev/null | xml_strings \
        | sed -n 's|^projects/[^/]*/groups/||p' | paste -sd, - || true)"
      echo "  Nhóm trên Firebase: ${available:-(chưa có)}"
    fi
    read -r -p "  Nhóm tester mặc định (cách nhau bằng dấu phẩy, để trống nếu chưa có): " groups
  fi
  groups="$(normalize_list <<< "$groups")"

  local configuration="${OPT_CONFIGURATION:-Debug}" tmp
  tmp="$(mktemp -t ios-firebase-init)"
  plutil -create xml1 "$tmp"
  if [[ -n "$WORKSPACE" ]]; then
    plutil -insert workspace -string "$WORKSPACE" "$tmp"
  else
    plutil -insert project -string "$PROJECT" "$tmp"
  fi
  plutil -insert scheme -string "$scheme" "$tmp"
  plutil -insert configuration -string "$configuration" "$tmp"
  # A version is the same on every machine; a path may not be.
  if [[ "$OPT_XCODE" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    plutil -insert xcode -string "$OPT_XCODE" "$tmp"
  fi
  plutil -insert firebase_plist -string "$plist" "$tmp"
  plutil -insert groups -array "$tmp"
  local g
  for g in ${groups//,/ }; do
    plutil -insert groups -string "$g" -append "$tmp"
  done
  # plutil escapes "/" as "\/"; both are valid JSON, the plain form reads better.
  plutil -convert json -r -o - "$tmp" | sed 's|\\/|/|g' > "$CONFIG"
  rm -f "$tmp"

  step "Đã tạo $CONFIG_NAME"
  cat "$CONFIG"
  echo
  [[ -n "$groups" ]] || warn "Chưa có nhóm tester: build sẽ chỉ được upload, không gửi cho ai. Sửa \"groups\" khi cần."
  echo "Commit file này để cả team dùng chung:"
  echo "  git add $CONFIG_NAME && git commit -m \"Add ios-firebase config\""
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  step "Kiểm tra (ios-firebase $(tool_version))"

  # Git: only committed code is built, so the build matches HEAD exactly.
  HEAD_SHA="$(git rev-parse --verify --quiet HEAD)" || fail "Repo chưa có commit nào"
  SHORT_SHA="$(git rev-parse --short HEAD)"
  BRANCH="$(git symbolic-ref --quiet --short HEAD || echo "detached")"
  local dirty upstream ahead
  dirty="$(git status --porcelain)"
  if [[ -n "$dirty" ]]; then
    bad "Có thay đổi chưa commit. Chỉ build code đã commit, hãy commit hoặc stash trước:"
    head -15 <<< "$dirty" | sed 's/^/      /'
    (( $(wc -l <<< "$dirty") <= 15 )) || echo "      …"
  else
    ok "Git: $BRANCH @ $SHORT_SHA, không có thay đổi chưa commit"
  fi
  if upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"; then
    ahead="$(git rev-list --count '@{u}..HEAD')"
    (( ahead == 0 )) || warn "$ahead commit chưa push lên $upstream"
  else
    warn "Branch $BRANCH chưa có upstream, commit $SHORT_SHA chưa có trên remote"
  fi

  # Config
  if [[ ! -f "$CONFIG" ]]; then
    bad "Chưa có $CONFIG_NAME. Chạy: ios-firebase init"
    return
  fi
  load_config
  ok "Cấu hình: $CONFIG_NAME"
  CONFIGURATION="${OPT_CONFIGURATION:-${CFG_CONFIGURATION:-Debug}}"
  TESTER_GROUPS="$CFG_GROUPS" TESTERS="$CFG_TESTERS"
  [[ "$OPT_GROUPS_SET" != true ]] || TESTER_GROUPS="$(normalize_list <<< "$OPT_GROUPS")"
  [[ "$OPT_TESTERS_SET" != true ]] || TESTERS="$(normalize_list <<< "$OPT_TESTERS")"

  # Xcode, workspace and scheme
  local have_xcode=false have_container=false
  select_xcode && check_xcode && have_xcode=true
  detect_container && have_container=true
  SCHEME="${OPT_SCHEME:-$CFG_SCHEME}"
  if [[ -z "$SCHEME" ]] && $have_xcode && $have_container; then
    if ! SCHEME="$(guess_scheme 2>/dev/null)"; then
      SCHEME=
      bad "Không tự chọn được scheme. Khai báo \"scheme\" trong $CONFIG_NAME"
    fi
  fi
  if $have_container && [[ -n "$SCHEME" ]]; then
    ok "${WORKSPACE:-$PROJECT} | scheme $SCHEME | $CONFIGURATION"
  fi

  # CocoaPods: the Pods sandbox must match Podfile.lock, otherwise the build
  # fails minutes later in the "[CP] Check Pods Manifest.lock" phase.
  PODS_DIR=
  if $have_container; then
    PODS_DIR="$(dirname "${WORKSPACE:-$PROJECT}")"
    if [[ -f "$PODS_DIR/Podfile" ]]; then
      if [[ "$OPT_POD_INSTALL" == true ]]; then
        ok "CocoaPods: sẽ chạy pod install"
      elif diff -q "$PODS_DIR/Podfile.lock" "$PODS_DIR/Pods/Manifest.lock" >/dev/null 2>&1; then
        ok "CocoaPods: Pods đã đồng bộ với Podfile.lock"
      else
        bad "Pods chưa đồng bộ với Podfile.lock. Chạy pod install, hoặc thêm --pod-install"
      fi
    fi
  fi

  # Firebase config that the build should contain
  local plist="${OPT_PLIST:-${CFG_PLIST:-GoogleService-Info-Dev.plist}}" matches
  plist="${plist#./}"
  if [[ "$plist" != */* ]]; then
    matches="$(find_firebase_plists | grep -E "(^|/)${plist//./\\.}$" || true)"
    if [[ -n "$matches" && $(wc -l <<< "$matches") -eq 1 ]]; then
      plist="$matches"
    else
      bad "Tìm thấy $(grep -c . <<< "$matches") file $plist. Ghi đường dẫn đầy đủ vào \"firebase_plist\" trong $CONFIG_NAME"
      plist=
    fi
  fi
  SRC_PLIST=
  if [[ -n "$plist" && ! -f "$plist" ]]; then
    bad "Không tìm thấy $plist (\"firebase_plist\" trong $CONFIG_NAME)"
  elif [[ -n "$plist" ]]; then
    APP_ID="$(plist_get GOOGLE_APP_ID "$plist" || true)"
    PROJECT_ID="$(plist_get PROJECT_ID "$plist" || true)"
    PLIST_BUNDLE_ID="$(plist_get BUNDLE_ID "$plist" || true)"
    if [[ ! "$APP_ID" =~ ^[0-9]+:[0-9]+:ios:[0-9a-fA-F]+$ ]]; then
      bad "$plist không có GOOGLE_APP_ID hợp lệ của app iOS (đọc được: '${APP_ID}')"
    elif [[ -z "$PROJECT_ID" ]]; then
      bad "$plist không có PROJECT_ID"
    else
      SRC_PLIST="$plist"
      ok "Firebase: $plist → project $PROJECT_ID, app $APP_ID"
    fi
  fi

  # Firebase CLI, login and tester groups
  if ! command -v "$FIREBASE" >/dev/null 2>&1; then
    bad "Chưa cài Firebase CLI. Cài bằng: brew install firebase-cli (hoặc npm install -g firebase-tools), rồi chạy: firebase login"
  elif [[ -n "$SRC_PLIST" && "$NO_UPLOAD" != true ]]; then
    check_firebase_access
  fi

  if [[ "$NO_UPLOAD" != true && -z "$TESTER_GROUPS$TESTERS" ]]; then
    warn "Không có nhóm tester hay email nào: build chỉ được upload, không gửi cho ai"
  fi
}

check_firebase_access() {
  local account=
  if firebase_json login:list; then
    account="$(plutil -extract result.0.user.email raw -o - "$FB_RESULT" 2>/dev/null || true)"
  fi
  # Also proves the account can use App Distribution in this project.
  if ! firebase_json appdistribution:groups:list --project "$PROJECT_ID"; then
    if [[ -z "$account" ]] || grep -qiE "authenticat|login|credentials" <<< "$FB_ERROR"; then
      bad "Firebase CLI chưa đăng nhập hoặc phiên đã hết hạn. Chạy: firebase login --reauth"
    elif grep -qiE "403|permission|denied" <<< "$FB_ERROR"; then
      bad "Tài khoản $account không có quyền App Distribution trên project $PROJECT_ID. Nhờ owner cấp role \"Firebase App Distribution Admin\" (hoặc Editor)."
    else
      bad "Không truy cập được App Distribution của project $PROJECT_ID ($account): $FB_ERROR"
    fi
    return
  fi
  local available g missing=
  available="$(plutil -extract result.groups xml1 -o - "$FB_RESULT" 2>/dev/null | xml_strings \
    | sed -n 's|^projects/[^/]*/groups/||p' || true)"
  for g in ${TESTER_GROUPS//,/ }; do
    grep -qxF "$g" <<< "$available" || missing="$missing $g"
  done
  if [[ -n "$missing" ]]; then
    bad "Nhóm không có trên Firebase project $PROJECT_ID:$missing. Các nhóm hiện có: $(paste -sd, - <<< "$available" | sed 's/,/, /g')"
  else
    ok "Firebase CLI: $account | gửi cho: $(recipients)"
  fi
}

recipients() {
  local out=
  [[ -z "$TESTER_GROUPS" ]] || out="nhóm ${TESTER_GROUPS//,/, }"
  [[ -z "$TESTERS" ]] || out="${out:+$out; }${TESTERS//,/, }"
  echo "${out:-không ai (chỉ upload)}"
}

# ---------------------------------------------------------------------------
# Release notes
# ---------------------------------------------------------------------------
write_release_notes() {
  local out="$1" version="$2"
  {
    if [[ -n "$OPT_MESSAGE" ]]; then
      printf '%s\n\n' "$OPT_MESSAGE"
    fi
    if [[ -n "$OPT_NOTES_FILE" ]]; then
      cat "$OPT_NOTES_FILE"
      printf '\n\n'
    fi
    echo "---"
    echo "$SCHEME $version · $CONFIGURATION"
    echo "$BRANCH @ $SHORT_SHA"
    echo "Build bởi $(git config user.name || whoami) lúc $(date '+%Y-%m-%d %H:%M')"
  } > "$out"
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
explain_xcode_failure() {
  local log="$1"
  if grep -qE "No Accounts|No account for team|Your session has expired|sign in again|account .* not found" "$log"; then
    hint "Apple account trong Xcode chưa đăng nhập hoặc đã hết phiên. Mở Xcode → Settings → Accounts để đăng nhập lại."
  elif grep -qE "has no devices|no devices from which to generate" "$log"; then
    hint "Team chưa đăng ký thiết bị nào nên không tạo được ad hoc profile. Đăng ký UDID của tester tại developer.apple.com → Devices."
  elif grep -qE 'No signing certificate "(iOS|Apple) Distribution"|Missing private key|doesn.t include signing certificate' "$log"; then
    hint "Máy này thiếu certificate Apple Distribution (kèm private key) để ký bản release-testing. Mở Xcode → Settings → Accounts → Manage Certificates."
  elif grep -qE "errSecInternalComponent|User interaction is not allowed|unable to unlock keychain" "$log"; then
    hint "Login keychain đang khóa (hay gặp khi chạy qua SSH). Chạy trong Terminal của phiên đăng nhập, hoặc: security unlock-keychain ~/Library/Keychains/login.keychain-db"
  elif grep -qE "sandbox is not in sync with the Podfile.lock" "$log"; then
    hint "Pods chưa đồng bộ với Podfile.lock. Chạy pod install, hoặc thêm --pod-install."
  elif grep -qE "does not contain a scheme named|is not currently configured for the" "$log"; then
    hint "Scheme hoặc configuration không tồn tại. Kiểm tra \"scheme\" và \"configuration\" trong $CONFIG_NAME."
  elif grep -qE "No profiles? for|couldn.t find any provisioning profiles|requires a provisioning profile|doesn.t match the entitlements|conflicting provisioning settings|doesn.t include the currently selected device" "$log"; then
    hint "Lỗi provisioning profile. Thử Distribute App → Release Testing trong Xcode Organizer với cùng archive để xem chi tiết. Nếu project dùng manual signing, khai báo \"export_options_plist\" trong $CONFIG_NAME."
  fi
  hint "Log đầy đủ: $log"
}

run_xcodebuild() {
  local log="$1" status
  shift
  echo "${C_DIM}  xcodebuild $*${C_0}"
  echo "${C_DIM}  log: $log${C_0}"
  set +e
  if [[ "$VERBOSE" == true ]]; then
    xcodebuild "$@" 2>&1 | tee "$log"
  elif command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild "$@" 2>&1 | tee "$log" | xcbeautify --quiet
  else
    xcodebuild "$@" 2>&1 | tee "$log" | grep --line-buffered -E ': error: |^error: |\*\* [A-Z ]+ (SUCCEEDED|FAILED) \*\*'
  fi
  status=${PIPESTATUS[0]}
  set -e
  if (( status != 0 )); then
    explain_xcode_failure "$log"
    fail "xcodebuild lỗi (exit $status)"
  fi
}

# release-testing replaced ad-hoc in Xcode 15.3.
export_method() {
  local v major minor
  v="$(sed -n 's/^Xcode \([0-9.]*\).*/\1/p' <<< "$XCODE_VERSION")"
  major="${v%%.*}"
  minor="$(cut -d. -f2 <<< "$v.0")"
  if (( major < 15 || (major == 15 && minor < 3) )); then echo ad-hoc; else echo release-testing; fi
}

stage_pods() {
  [[ "$OPT_POD_INSTALL" == true && -f "$PODS_DIR/Podfile" ]] || return 0
  step "pod install"
  if [[ -f "$PODS_DIR/Gemfile" ]]; then
    (cd "$PODS_DIR" && bundle install --quiet && bundle exec pod install)
  else
    (cd "$PODS_DIR" && pod install)
  fi
  local dirty
  dirty="$(git status --porcelain)"
  if [[ -n "$dirty" ]]; then
    echo "$dirty" | sed 's/^/  /'
    fail "pod install đã thay đổi file trong git, nên build sẽ không khớp commit $SHORT_SHA. Chạy pod install trong repo, commit các thay đổi rồi chạy lại."
  fi
}

stage_archive() {
  step "Archive $SCHEME ($CONFIGURATION)"
  local -a settings=()
  [[ -z "$OPT_VERSION" ]] || settings+=("MARKETING_VERSION=$OPT_VERSION")
  [[ -z "$OPT_BUILD" ]] || settings+=("CURRENT_PROJECT_VERSION=$OPT_BUILD")
  run_xcodebuild "$LOG_DIR/archive.log" \
    "${CONTAINER[@]}" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    ${settings[@]+"${settings[@]}"} \
    archive

  APP_VERSION="$(plist_get ApplicationProperties:CFBundleShortVersionString "$ARCHIVE_PATH/Info.plist" || echo "?")"
  APP_BUILD="$(plist_get ApplicationProperties:CFBundleVersion "$ARCHIVE_PATH/Info.plist" || echo "?")"
  if [[ -n "$OPT_VERSION" && "$APP_VERSION" != "$OPT_VERSION" ]] || [[ -n "$OPT_BUILD" && "$APP_BUILD" != "$OPT_BUILD" ]]; then
    fail "Archive có version $APP_VERSION ($APP_BUILD), không khớp --app-version/--build. Info.plist phải dùng \$(MARKETING_VERSION) và \$(CURRENT_PROJECT_VERSION)."
  fi
  ok "Archive: $APP_VERSION ($APP_BUILD)"

  verify_firebase_config
}

# The upload goes to the Firebase app from firebase_plist, so the build must
# actually contain that config: catches a configuration that bundles only the
# production plist. With both plists bundled, which one the app reads at
# runtime is up to the app's code.
verify_firebase_config() {
  local app found=false listing= p id bundle_id
  app="$(find "$ARCHIVE_PATH/Products/Applications" -maxdepth 1 -name "*.app" | sed -n 1p)"
  [[ -n "$app" ]] || fail "Không tìm thấy .app trong $ARCHIVE_PATH"
  while IFS= read -r p; do
    id="$(plist_get GOOGLE_APP_ID "$p")" || continue
    listing="${listing:+$listing, }${p#"$app"/} ($id)"
    [[ "$id" != "$APP_ID" ]] || found=true
  done < <(find "$app" -name "GoogleService-Info*.plist" -not -path "*/Frameworks/*" -not -path "*/PlugIns/*" -not -path "*/Extensions/*")
  $found || fail "App vừa build không chứa Firebase config của $SRC_PLIST ($APP_ID). Plist có trong app: ${listing:-không có}. Kiểm tra configuration $CONFIGURATION có copy $SRC_PLIST vào app không."
  bundle_id="$(plist_get CFBundleIdentifier "$app/Info.plist" || true)"
  if [[ -n "$PLIST_BUNDLE_ID" && "$bundle_id" != "$PLIST_BUNDLE_ID" ]]; then
    warn "Bundle ID của app ($bundle_id) khác BUNDLE_ID trong $SRC_PLIST ($PLIST_BUNDLE_ID)"
  fi
  ok "App có Firebase config $APP_ID"
}

stage_export() {
  step "Export .ipa"
  local options="$RUN_DIR/ExportOptions.plist"
  if [[ -n "$CFG_EXPORT_OPTIONS" ]]; then
    [[ -f "$CFG_EXPORT_OPTIONS" ]] || fail "Không tìm thấy $CFG_EXPORT_OPTIONS (\"export_options_plist\" trong $CONFIG_NAME)"
    cp "$CFG_EXPORT_OPTIONS" "$options"
  else
    plutil -create xml1 "$options"
    plutil -insert method -string "$(export_method)" "$options"
    plutil -insert destination -string export "$options"
    plutil -insert signingStyle -string automatic "$options"
  fi
  run_xcodebuild "$LOG_DIR/export.log" \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$options" \
    -allowProvisioningUpdates
  IPA="$(find "$EXPORT_PATH" -maxdepth 1 -name "*.ipa" | sed -n 1p)"
  [[ -n "$IPA" ]] || fail "Export xong nhưng không thấy file .ipa trong $EXPORT_PATH"
  ok "$IPA ($(du -h "$IPA" | cut -f1 | tr -d ' '))"
}

stage_upload() {
  step "Upload Firebase App Distribution"
  local -a args=(appdistribution:distribute "$IPA" --app "$APP_ID" --release-notes-file "$NOTES" --non-interactive)
  [[ -z "$TESTER_GROUPS" ]] || args+=(--groups "$TESTER_GROUPS")
  [[ -z "$TESTERS" ]] || args+=(--testers "$TESTERS")
  local log="$LOG_DIR/upload.log" status
  set +e
  "$FIREBASE" "${args[@]}" 2>&1 | tee "$log"
  status=${PIPESTATUS[0]}
  set -e
  if (( status != 0 )); then
    if grep -qiE "authenticat|firebase login" "$log"; then
      hint "Firebase CLI chưa đăng nhập hoặc phiên đã hết hạn. Chạy: firebase login --reauth"
    elif grep -qiE "403|permission|denied" "$log"; then
      hint "Tài khoản Firebase không có quyền App Distribution trên project $PROJECT_ID."
    elif grep -qiE "404|not found" "$log"; then
      hint "Không tìm thấy app $APP_ID, hoặc project $PROJECT_ID chưa bật App Distribution (Firebase console → App Distribution → Get started)."
    fi
    hint "File .ipa vẫn ở $IPA"
    fail "Upload lỗi (exit $status). Log: $log"
  fi
  TESTING_URI="$(strip_ansi < "$log" | sed -n 's/.*Share this release with testers who have access: \(https:[^ ]*\).*/\1/p' | tail -1)"
  CONSOLE_URI="$(strip_ansi < "$log" | sed -n 's/.*View this release in the Firebase console: \(https:[^ ]*\).*/\1/p' | tail -1)"
}

# ---------------------------------------------------------------------------
# Build checkout
# ---------------------------------------------------------------------------
# Git-ignored paths the build may need (Pods, a Firebase plist kept out of git,
# local xcconfig...), without build output.
list_ignored() {
  git ls-files --others --ignored --exclude-standard --directory \
    | grep -vE '(^|/)(DerivedData|build|\.build)/$|\.(xcarchive|ipa)/?$|(^|/)\.DS_Store$' || true
}

# One build per repo at a time: they share the worktree and DerivedData.
lock_build() {
  local lock="$REPO_OUT/build.lock" pid
  if ! mkdir "$lock" 2>/dev/null; then
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      fail "Repo này đang được build bởi một lần chạy khác (pid $pid). Đợi lần đó xong rồi chạy lại."
    fi
    rm -rf "$lock"
    mkdir "$lock" || fail "Không tạo được $lock"
  fi
  echo $$ > "$lock/pid"
  LOCK="$lock"
}

# Check out HEAD_SHA into a worktree outside the repo and cd into it, so later
# edits, branch switches and Xcode builds in the repo cannot reach this build.
# The worktree and its ignored files are kept between runs so builds stay
# incremental.
stage_checkout() {
  step "Chuẩn bị mã nguồn @ $SHORT_SHA"
  local base p keep
  base="$(cd "$REPO_OUT" && pwd -P)"
  SRC_DIR="$base/src"
  DERIVED_DATA="$base/DerivedData"
  git worktree prune
  if git worktree list --porcelain | grep -qxF "worktree $SRC_DIR"; then
    git -C "$SRC_DIR" checkout --quiet --force --detach "$HEAD_SHA"
    git -C "$SRC_DIR" clean -ffdq
  else
    rm -rf "$SRC_DIR"
    git worktree add --quiet --detach "$SRC_DIR" "$HEAD_SHA"
    warn "Lần đầu build trong worktree nên sẽ lâu hơn, các lần sau build tiếp từ cache"
  fi
  if [[ -f "$SRC_DIR/.gitmodules" ]]; then
    git -C "$SRC_DIR" submodule update --quiet --init --recursive
  fi

  keep="$(list_ignored)"
  (cd "$SRC_DIR" && list_ignored) | while IFS= read -r p; do
    grep -qxF -- "$p" <<< "$keep" || rm -rf "${SRC_DIR:?}/$p"
  done
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    mkdir -p "$SRC_DIR/$(dirname "$p")"
    if [[ "$p" == */ ]]; then
      rsync -a --delete "$p" "$SRC_DIR/$p"
    else
      rsync -a "$p" "$SRC_DIR/$p"
    fi
  done <<< "$keep"
  ok "Worktree: $SRC_DIR"
  cd "$SRC_DIR"
}

cleanup() {
  prune_runs
  [[ -z "$LOCK" ]] || rm -rf "$LOCK"
}

prune_runs() {
  [[ -d "$REPO_OUT" ]] || return 0
  find "$REPO_OUT" -mindepth 1 -maxdepth 1 -type d -name "20*" | sort -r | tail -n +$((KEEP_RUNS + 1)) \
    | while IFS= read -r d; do rm -rf "$d"; done
}

cmd_run() {
  goto_repo_root
  REPO_KEY="$(repo_key)"
  REPO_OUT="$OUT_ROOT/$REPO_KEY"
  preflight
  if (( PROBLEMS > 0 )); then
    echo
    fail "Có $PROBLEMS lỗi cần xử lý trước khi build."
  fi

  if [[ "$DRY_RUN" == true ]]; then
    step "Release notes dự kiến"
    local preview
    preview="$(mktemp -t ios-firebase-notes)"
    write_release_notes "$preview" "<version> (<build>)"
    cat "$preview"
    rm -f "$preview"
    echo
    echo "Dry run: dừng trước khi build."
    return
  fi

  RUN_DIR="$REPO_OUT/$(date +%Y%m%d-%H%M%S)"
  LOG_DIR="$RUN_DIR/logs"
  ARCHIVE_PATH="$RUN_DIR/$SCHEME.xcarchive"
  EXPORT_PATH="$RUN_DIR/export"
  NOTES="$RUN_DIR/release-notes.txt"
  mkdir -p "$REPO_OUT"
  LOCK=
  trap cleanup EXIT
  lock_build
  mkdir -p "$LOG_DIR"
  # Keep the Mac awake until this script exits.
  caffeinate -i -w $$ &

  stage_checkout
  stage_pods
  stage_archive
  stage_export
  write_release_notes "$NOTES" "$APP_VERSION ($APP_BUILD)"
  if [[ "$NO_UPLOAD" == true ]]; then
    step "Xong (không upload)"
    echo "  IPA: $IPA"
    echo "  Release notes: $NOTES"
    return
  fi
  stage_upload

  step "Đã upload $SCHEME $APP_VERSION ($APP_BUILD) · $CONFIGURATION lên Firebase"
  echo "  Gửi cho:  $(recipients)"
  echo "  Commit:   $BRANCH @ $SHORT_SHA"
  [[ -z "$TESTING_URI" ]] || echo "  Tester:   $TESTING_URI"
  [[ -z "$CONSOLE_URI" ]] || echo "  Console:  $CONSOLE_URI"
  echo "  IPA:      $IPA"
  if [[ "$OPEN_CONSOLE" == true && -n "$CONSOLE_URI" ]]; then
    open "$CONSOLE_URI"
  fi
}

cmd_xcodes() {
  local installed current v app
  installed="$(list_xcodes)"
  [[ -n "$installed" ]] || fail "Chưa cài Xcode nào."
  current="$(default_developer_dir)"
  echo "Xcode đã cài (* là bản mặc định):"
  while IFS=$'\t' read -r v app; do
    if [[ "$current" == "$app/Contents/Developer" ]]; then
      printf '  %s %-8s %s\n' "*" "$v" "$app"
    else
      printf '  %s %-8s %s\n' " " "$v" "$app"
    fi
  done <<< "$installed"
  echo
  echo "Chọn bản khác: --xcode <version>, hoặc \"xcode\": \"<version>\" trong $CONFIG_NAME."
}

case "$CMD" in
  init) cmd_init ;;
  xcodes) cmd_xcodes ;;
  run) cmd_run ;;
esac
