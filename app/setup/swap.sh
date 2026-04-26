#!/usr/bin/env bash
#
# Swap セットアップスクリプト (Ubuntu 26.04 対応)
#
# 指定サイズの swapfile を作成し、有効化 + /etc/fstab 登録まで行う。
# 既存 swapfile (同パス) があれば既存値を尊重して終了する (idempotent)。
#
# 旧 setup_swap.sh の後継。dd ではなく fallocate を優先 (高速)、xfs 等で
# fallocate が不適切な場合は dd にフォールバックする。

set -euo pipefail

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
使用方法: $0 [--size <GB>] [--path <swapfile path>]

swapfile を作成・有効化し /etc/fstab に登録する (Ubuntu 26.04)。

オプション:
  --size <GB>     swapfile サイズ (GB 単位、整数)。省略時: 6
  --path <path>   swapfile パス。省略時: /swapfile
  -h, --help      このヘルプを表示

注意:
  - root 権限で実行してください: sudo $0
  - 既存の同パス swapfile が有効化済みなら何もしません (idempotent)。
EOF
}

# ----------------------------------------------------------------------------
# 引数パース
# ----------------------------------------------------------------------------

parse_args() {
    SWAP_SIZE_GB=6
    SWAP_PATH="/swapfile"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            --size)
                shift
                [[ $# -gt 0 ]] || err "--size の引数が不足しています。"
                [[ "$1" =~ ^[0-9]+$ ]] || err "--size は整数 (GB) を指定してください: $1"
                SWAP_SIZE_GB="$1"
                shift
                ;;
            --path)
                shift
                [[ $# -gt 0 ]] || err "--path の引数が不足しています。"
                SWAP_PATH="$1"
                shift
                ;;
            *) err "不明な引数: $1 (詳細は '$0 --help')" ;;
        esac
    done
}

require_root() {
    [[ $(id -u) -eq 0 ]] || err "root 権限で実行してください: sudo $0 ..."
}

# ----------------------------------------------------------------------------
# プラン
# ----------------------------------------------------------------------------

print_plan() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "${sep}"
    echo "Swap セットアップを実行します。"
    echo ""
    echo "  swapfile path:   ${SWAP_PATH}"
    echo "  size:            ${SWAP_SIZE_GB} GB"
    echo "  既存 swap 概況:"
    swapon --show 2>/dev/null | sed 's/^/    /' || echo "    (なし)"
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
# Steps
# ----------------------------------------------------------------------------

create_swapfile() {
    echo "Step 1: swapfile の作成 (${SWAP_PATH}, ${SWAP_SIZE_GB}GB)"
    if [[ -f "${SWAP_PATH}" ]] && swapon --show=NAME --noheadings | grep -qx "${SWAP_PATH}"; then
        echo "  既に有効化済の swapfile があります。スキップします。"
        SKIP_REST="yes"
        return 0
    fi
    SKIP_REST="no"

    if [[ -e "${SWAP_PATH}" ]]; then
        warn "${SWAP_PATH} が既に存在します (有効化はされていません)。再作成します。"
        rm -f "${SWAP_PATH}"
    fi

    # fallocate を試行 → 失敗時 dd フォールバック
    if ! fallocate -l "${SWAP_SIZE_GB}G" "${SWAP_PATH}" 2>/dev/null; then
        warn "fallocate が使えないため dd で作成します (時間がかかります)。"
        dd if=/dev/zero of="${SWAP_PATH}" bs=1M count="$((SWAP_SIZE_GB * 1024))" status=progress
    fi
    chmod 600 "${SWAP_PATH}"
    echo "  完了 ($(du -h "${SWAP_PATH}" | cut -f1))"
}

enable_swap() {
    [[ "${SKIP_REST}" == "yes" ]] && return 0
    echo "Step 2: mkswap + swapon"
    mkswap "${SWAP_PATH}" >/dev/null
    swapon "${SWAP_PATH}"
    echo "  完了"
}

update_fstab() {
    [[ "${SKIP_REST}" == "yes" ]] && return 0
    echo "Step 3: /etc/fstab 更新"
    local entry="${SWAP_PATH} none swap sw 0 0"
    if grep -qE "^${SWAP_PATH//\//\\/}\s" /etc/fstab; then
        echo "  既存エントリを検出。スキップします。"
    else
        echo "${entry}" >> /etc/fstab
        echo "  追記: ${entry}"
    fi
}

print_summary() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    cat <<EOF

${sep}
Swap セットアップが完了しました。
${sep}

現在の swap 状況:
$(swapon --show | sed 's/^/  /')

確認:
  free -h
  swapon --show
  cat /etc/fstab | grep swap
${sep}
EOF
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"
    require_root
    print_plan
    confirm_or_abort

    create_swapfile
    enable_swap
    update_fstab
    print_summary
}

main "$@"
