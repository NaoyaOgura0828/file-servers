#!/usr/bin/env bash
#
# Claude Code セットアップスクリプト (Ubuntu 26.04 対応)
#
# 1. 公式インストーラで Claude Code を ~/.local 配下に導入
# 2. 個人設定 repo (CLAUDE.md / skills / commands / memory) を ~/.claude/ にクローン
# 3. 初回利用前の `claude login` 案内
#
# 注意: 本スクリプトは **ユーザー権限で実行**する (sudo $0 ではない)。
#       Claude Code はユーザーローカル (~/.local/bin) にインストールされる。

set -euo pipefail

readonly CLAUDE_INSTALLER_URL="https://claude.ai/install.sh"
readonly CLAUDE_CONFIG_REPO_DEFAULT="https://github.com/NaoyaOgura0828/claude-settings.git"
readonly CLAUDE_CONFIG_DIR="${HOME}/.claude"
readonly ALIAS_RC_FILE="${HOME}/.bashrc"
readonly ALIAS_LINE='alias claude-auto="claude --dangerously-skip-permissions"'

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

err() {
    echo "エラー: $*" >&2
    exit 1
}

warn() {
    echo "警告: $*" >&2
}

show_help() {
    cat <<EOF
使用方法: $0 [--config-repo <git URL>] [--skip-config]

Claude Code をインストールし、個人設定 repo を ~/.claude/ にクローンする (Ubuntu 26.04)。

オプション:
  --config-repo <URL>    設定 repo の git URL を上書き指定 (省略時: ${CLAUDE_CONFIG_REPO_DEFAULT})
  --skip-config          設定 repo の clone を行わずインストールのみ実施
  -h, --help             このヘルプを表示

動作:
  1. Claude Code を ${CLAUDE_INSTALLER_URL} 経由でインストール (~/.local/bin)
  2. 設定 repo を ~/.claude/ に clone
     - 既存 ~/.claude/ がある場合はタイムスタンプ付きでバックアップ
  3. ${ALIAS_RC_FILE} に claude-auto エイリアスを冪等追記
     (alias claude-auto="claude --dangerously-skip-permissions")
  4. 認証案内 (\`claude login\`) を表示

注意:
  - **ユーザー権限で実行する** (sudo \$0 ではない)。
  - 認証情報 (~/.claude/.credentials.json) は claude login で生成されるため本スクリプトでは触らない。
EOF
}

# ----------------------------------------------------------------------------
# 引数パース
# ----------------------------------------------------------------------------

parse_args() {
    CLAUDE_CONFIG_REPO="${CLAUDE_CONFIG_REPO_DEFAULT}"
    SKIP_CONFIG="no"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            --config-repo)
                shift
                [[ $# -gt 0 ]] || err "--config-repo の引数が不足しています。"
                CLAUDE_CONFIG_REPO="$1"
                shift
                ;;
            --skip-config)
                SKIP_CONFIG="yes"
                shift
                ;;
            *) err "不明な引数: $1 (詳細は '$0 --help')" ;;
        esac
    done
}

ensure_not_root() {
    [[ $(id -u) -ne 0 ]] || err "本スクリプトはユーザー権限で実行してください。"
}

ensure_dependencies() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v git  >/dev/null 2>&1 || missing+=(git)
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "依存パッケージを apt でインストール: ${missing[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y "${missing[@]}"
    fi
}

# ----------------------------------------------------------------------------
# プラン
# ----------------------------------------------------------------------------

print_plan() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "${sep}"
    echo "Claude Code のセットアップを実行します。"
    echo ""
    echo "  ユーザー:           $(whoami)"
    echo "  HOME:               ${HOME}"
    echo "  既存 claude:        $(command -v claude || echo "(未導入)")"
    echo "  設定 repo:          ${CLAUDE_CONFIG_REPO}"
    echo "  設定 clone スキップ: ${SKIP_CONFIG}"
    echo "  ~/.claude 状態:     $([[ -d "${CLAUDE_CONFIG_DIR}" ]] && echo "存在 (バックアップして再 clone)" || echo "未作成")"
    echo "  alias 追記先:       ${ALIAS_RC_FILE} (claude-auto)"
    echo "${sep}"
}

confirm_or_abort() {
    local yn
    read -r -p "この設定で実行してよろしいですか？ (Y/n) " yn
    case "${yn}" in
        [yY]) return 0 ;;
        *) echo "中止しました。"; exit 0 ;;
    esac
}

# ----------------------------------------------------------------------------
# Step 1: Claude Code インストール
# ----------------------------------------------------------------------------

install_claude_code() {
    echo "Step 1: Claude Code のインストール (公式インストーラ)"
    if command -v claude >/dev/null 2>&1; then
        echo "  既にインストール済 ($(claude --version 2>&1 | head -1))"
        local yn
        read -r -p "  再インストール (アップデート) しますか？ (y/N) " yn
        case "${yn}" in
            [yY]) ;;
            *) echo "  既存版を維持してスキップします。"; return 0 ;;
        esac
    fi

    curl -fsSL "${CLAUDE_INSTALLER_URL}" | bash \
        || err "Claude Code のインストールに失敗しました。"

    if ! command -v claude >/dev/null 2>&1; then
        warn "claude コマンドが PATH 上で見つかりません。"
        warn "  -> ~/.local/bin がシェルの PATH に含まれているか確認してください。"
        warn "  -> 例: 'export PATH=\"\$HOME/.local/bin:\$PATH\"' を ~/.bashrc に追記"
    else
        echo "  完了: $(claude --version 2>&1 | head -1)"
    fi
}

# ----------------------------------------------------------------------------
# Step 2: 個人設定 repo の clone
# ----------------------------------------------------------------------------

setup_claude_config() {
    if [[ "${SKIP_CONFIG}" == "yes" ]]; then
        echo "Step 2: 設定 repo の clone はスキップ (--skip-config)"
        return 0
    fi
    echo "Step 2: 設定 repo の clone (${CLAUDE_CONFIG_REPO})"

    if [[ -e "${CLAUDE_CONFIG_DIR}" ]]; then
        local backup="${CLAUDE_CONFIG_DIR}.bak.$(date +%Y%m%d-%H%M%S)"
        mv "${CLAUDE_CONFIG_DIR}" "${backup}"
        echo "  既存 ${CLAUDE_CONFIG_DIR} を ${backup} に退避"
        warn "  退避ディレクトリには .credentials.json (auth) や history.jsonl が含まれる可能性があります。"
        warn "  必要であれば clone 後に手動で復元してください。"
    fi

    git clone "${CLAUDE_CONFIG_REPO}" "${CLAUDE_CONFIG_DIR}"
    echo "  完了: ${CLAUDE_CONFIG_DIR}"
}

# ----------------------------------------------------------------------------
# Step 3: claude-auto エイリアスを ~/.bashrc に追記
# ----------------------------------------------------------------------------

setup_claude_alias() {
    echo "Step 3: claude-auto エイリアスを ${ALIAS_RC_FILE} に追記"
    if [[ -f "${ALIAS_RC_FILE}" ]] && grep -Fxq "${ALIAS_LINE}" "${ALIAS_RC_FILE}"; then
        echo "  既に存在するためスキップ: ${ALIAS_LINE}"
        return 0
    fi
    {
        echo ""
        echo "# Added by app/setup/claude.sh"
        echo "${ALIAS_LINE}"
    } >> "${ALIAS_RC_FILE}"
    echo "  追記しました: ${ALIAS_LINE}"
    echo "  反映には 'source ${ALIAS_RC_FILE}' または再ログインが必要です。"
}

# ----------------------------------------------------------------------------
# サマリ
# ----------------------------------------------------------------------------

print_summary() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    cat <<EOF

${sep}
Claude Code のセットアップが完了しました。
${sep}

  バージョン:     $(claude --version 2>/dev/null | head -1 || echo "(claude が PATH にない場合は再ログインまたは PATH 設定を見直し)")
  設定ディレクトリ: ${CLAUDE_CONFIG_DIR}
  設定 repo:      ${CLAUDE_CONFIG_REPO}

次の作業:
  1. PATH 確認 (~/.local/bin がない場合):
       echo 'export PATH="\$HOME/.local/bin:\$PATH"' >> ~/.bashrc && source ~/.bashrc

  2. 追記済 alias を有効化 (シェル再起動 または):
       source ${ALIAS_RC_FILE}
       # 以降は 'claude-auto' で 'claude --dangerously-skip-permissions' を起動可能

  3. ログイン (ブラウザが開く):
       claude login

  4. 設定確認:
       cat ~/.claude/CLAUDE.md
       ls ~/.claude/skills/
${sep}
EOF
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"
    ensure_not_root
    ensure_dependencies
    print_plan
    confirm_or_abort

    install_claude_code
    setup_claude_config
    setup_claude_alias
    print_summary
}

main "$@"
