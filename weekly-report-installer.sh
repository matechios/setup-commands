#!/usr/bin/env bash
# weekly-report-installer.sh — Cài đặt ios-weekly-report vào repo hiện tại
# Usage: bash weekly-report-installer.sh (chạy từ thư mục gốc của repo)

set -e

TOOL_VERSION="1.3"
TOOLS_REPO_URL="${TOOLS_REPO_URL:-https://github.com/matechios/ios-weekly-report.git}"
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(pwd)"
GIT_HOOKS_DIR="$REPO_DIR/.git/hooks"
SCRIPTS_TARGET="$REPO_DIR/.team-tools"
CODEX_SKILL_TARGET="$REPO_DIR/.codex/skills/weekly-report"
CLAUDE_SKILL_TARGET="$REPO_DIR/.claude/skills/weekly-report"
CLAUDE_COMMANDS_TARGET="$REPO_DIR/.claude/commands"
TMP_TOOLS_DIR=""

GREEN="\033[92m"
YELLOW="\033[93m"
RED="\033[91m"
CYAN="\033[96m"
BOLD="\033[1m"
RESET="\033[0m"

STEP_TOTAL=5

step() {
    echo -e "${BOLD}[$1/${STEP_TOTAL}]${RESET} $2"
}

detail() {
    echo -e "      $1"
}

fail() {
    echo -e "${RED}${BOLD}Lỗi:${RESET} $1" >&2
    [ -n "$2" ] && echo -e "      $2" >&2
    exit 1
}

cleanup() {
    if [ -n "$TMP_TOOLS_DIR" ] && [ -d "$TMP_TOOLS_DIR" ]; then
        rm -rf "$TMP_TOOLS_DIR"
    fi
}
trap cleanup EXIT

# Kiểm tra git repo
if [ ! -d "$REPO_DIR/.git" ]; then
    fail "Thư mục hiện tại không phải git repo." "Chạy lại installer từ thư mục gốc của project."
fi

if [ ! -f "$TOOLS_DIR/hooks/commit-msg" ] || \
   [ ! -f "$TOOLS_DIR/codex-skills/weekly-report/SKILL.md" ] || \
   [ ! -f "$TOOLS_DIR/claude-skills/weekly-report/SKILL.md" ] || \
   [ ! -f "$TOOLS_DIR/claude-commands/report.md" ]; then
    echo "Đang tải bộ tool từ $TOOLS_REPO_URL..."

    if ! command -v git >/dev/null 2>&1; then
        fail "Không tìm thấy git." "Cần cài git để installer tự tải bộ tool."
    fi

    TMP_TOOLS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ios-weekly-report.XXXXXX")"
    git clone --depth 1 "$TOOLS_REPO_URL" "$TMP_TOOLS_DIR" >/dev/null 2>&1 || {
        fail "Không clone được ios-weekly-report từ GitHub." "Kiểm tra kết nối mạng hoặc đặt lại TOOLS_REPO_URL."
    }
    TOOLS_DIR="$TMP_TOOLS_DIR"
fi

echo ""
echo -e "${BOLD}ios-weekly-report installer${RESET} v${TOOL_VERSION}"
echo "Project: $REPO_DIR"
echo ""

# Copy scripts vào repo
step 1 "Cài đặt report tool vào .team-tools/"
mkdir -p "$SCRIPTS_TARGET"
cp "$TOOLS_DIR/scripts/report.py" "$SCRIPTS_TARGET/"

# Cài Codex skill local trong project
step 2 "Cài đặt Codex skill"
mkdir -p "$CODEX_SKILL_TARGET"
cp "$TOOLS_DIR/codex-skills/weekly-report/SKILL.md" "$CODEX_SKILL_TARGET/SKILL.md"

# Cài Claude skill và slash command local trong project
step 3 "Cài đặt Claude skill và slash command /report"
mkdir -p "$CLAUDE_SKILL_TARGET" "$CLAUDE_COMMANDS_TARGET"
cp "$TOOLS_DIR/claude-skills/weekly-report/SKILL.md" "$CLAUDE_SKILL_TARGET/SKILL.md"
cp "$TOOLS_DIR/claude-commands/report.md" "$CLAUDE_COMMANDS_TARGET/report.md"

# Cài commit-msg hook
step 4 "Cài đặt commit-msg hook"
if [ -f "$GIT_HOOKS_DIR/commit-msg" ] && ! cmp -s "$TOOLS_DIR/hooks/commit-msg" "$GIT_HOOKS_DIR/commit-msg"; then
    BACKUP="$GIT_HOOKS_DIR/commit-msg.backup.$(date +%Y%m%d%H%M%S)"
    cp "$GIT_HOOKS_DIR/commit-msg" "$BACKUP"
    detail "${YELLOW}Đã backup hook cũ: $BACKUP${RESET}"
fi
cp "$TOOLS_DIR/hooks/commit-msg" "$GIT_HOOKS_DIR/commit-msg"
chmod +x "$GIT_HOOKS_DIR/commit-msg"

# Tạo file .env nếu chưa có
step 5 "Cấu hình project"
if [ ! -f "$SCRIPTS_TARGET/.env" ]; then
    detail "Đã tạo .team-tools/.env"
    cat > "$SCRIPTS_TARGET/.env" << 'EOF'
# ── ios-weekly-report config ───────────────────────────────
# Tên của bạn (override git config user.name)
# REPORT_AUTHOR="Nguyen Van A"

# Google Apps Script Web App
SHEETS_WEBHOOK_URL="https://script.google.com/macros/s/AKfycbzIJt8MeIWavTEM_d0oY3ZOQJ7SLldIvJE9Xf87RyGlOIewD_A0S2XUaBOpOv8SvVxY/exec"

# Optional: đặt cùng giá trị với REPORT_SECRET trong Apps Script
# REPORT_SECRET="change-me"

EOF
fi

# Thêm .team-tools/ vào .gitignore
touch "$REPO_DIR/.gitignore"
if ! grep -q "^.team-tools/$" "$REPO_DIR/.gitignore"; then
    echo "" >> "$REPO_DIR/.gitignore"
    echo "# ios-weekly-report" >> "$REPO_DIR/.gitignore"
    echo ".team-tools/" >> "$REPO_DIR/.gitignore"
    detail "Đã thêm .team-tools/ vào .gitignore"
fi

# Tạo alias gợi ý
echo ""
echo -e "${GREEN}${BOLD}Cài đặt hoàn tất.${RESET} Phiên bản: v${TOOL_VERSION}"
echo ""
echo -e "${CYAN}CÁCH SỬ DỤNG:${RESET}"
echo ""
echo -e "  ${BOLD}Commit (tự động validate format):${RESET}"
echo -e "    git commit -m \"TASK: Mô tả công việc\""
echo -e "    git commit -m \"BUG: Sửa lỗi gì đó\""
echo -e "    git commit -m \"UPDATE: Cập nhật phần hiện có\""
echo ""
echo -e "  ${BOLD}Dùng AI generate report:${RESET}"
echo -e "    Mở Codex hoặc Claude trong repo này và nhập đúng 3 dòng đầu bắt buộc."
echo -e "    Agent sẽ đọc commit/diff trong tuần và generate cột Summary."
echo -e "    Dòng 2/3 sẽ được parse vào cột Note."
echo -e "    Dòng 1: yêu cầu báo cáo để mapping skill, ví dụ report, báo cáo tuần W30"
echo -e "    Dòng 2: Vấn đề; nếu có nhiều ý thì cách nhau bằng dấu ;"
echo -e "    Dòng 3: Plan tuần tới; nếu có nhiều ý thì cách nhau bằng dấu ;"
echo -e "    Dòng 4+: optional, ghi thêm dưới heading Note:"
echo ""
echo -e "    Ví dụ:"
echo -e "      báo cáo tuần W30"
echo -e "      Không có blocker; Cần chờ review API"
echo -e "      Hoàn tất flow thanh toán; Bổ sung test webhook"
echo ""
echo -e "    Nếu thiếu dòng 2/dòng 3, tool sẽ yêu cầu nhập lại."
echo -e "    Preview/xem trước: thêm preview hoặc xem trước ở dòng 1."
echo -e "    Claude slash command: /report"
echo ""
echo -e "  ${BOLD}Chạy thủ công nếu không dùng AI:${RESET}"
echo -e "    python .team-tools/report.py             # gửi lên Google Sheets"
echo -e "    python .team-tools/report.py --dry-run   # preview/xem trước, không gửi"
echo -e "    python .team-tools/report.py --performance-file /path/to/summary.txt"
echo -e "    python .team-tools/report.py --note-file /path/to/report-prompt.txt"
echo ""
