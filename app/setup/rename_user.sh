#!/usr/bin/env bash
#
# ユーザー名 + ホームディレクトリリネームスクリプト (Ubuntu 26.04)
#
# 既存ユーザー (例: 標準インストール時の "ubuntu") を NaoyaOgura にリネームし、
# /home/<old> を /home/NaoyaOgura に移動する。
# サーバー初期化の最も早い段階で 1 度だけ実行する想定。
#
# Ubuntu の adduser/usermod は既定で大文字を含むユーザー名を拒否する (NAME_REGEX)。
# usermod / groupmod に --badname を渡すことでこの制限を回避する。
# (--badname は shadow-utils 4.13+。Ubuntu 24.04 / 26.04 で利用可能。)
#
# 重要:
#   - 対象ユーザーがログイン中・プロセス実行中のときは実行できない。
#   - 対象ユーザー自身のセッション (sudo / su 含む) からは実行できない。
#   - 別 TTY (Ctrl+Alt+F2) で root ログインするか、別の管理ユーザーから実行すること。

set -euo pipefail

readonly DEFAULT_NEW_USER="NaoyaOgura"

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
使用方法: $0 <既存ユーザー名> [オプション]

ユーザー名と /home/<user> を ${DEFAULT_NEW_USER} に変更する (Ubuntu 26.04)。

引数:
  <既存ユーザー名>          リネーム対象ユーザー (例: ubuntu)

オプション:
  --new-name <name>         新ユーザー名 (デフォルト: ${DEFAULT_NEW_USER})
  -y, --yes                 確認プロンプトをスキップ
  -h, --help                このヘルプを表示

挙動:
  1. usermod -l <new> --badname <old>      ユーザー名を変更 (大文字許可)
  2. groupmod -n <new> --badname <old>     primary group が同名なら変更
  3. usermod -d /home/<new> -m <new>       home 移動 (内容コピー、所有権維持)
  4. /var/mail/<old> をリネーム
  5. /etc/sudoers.d/<old> を中身置換 + リネーム
  6. /var/spool/cron/crontabs/<old> をリネーム
  7. /var/lib/systemd/linger/<old> をリネーム

注意:
  - root 権限で実行すること: sudo $0 ...
  - 対象ユーザーがログイン中 / プロセス実行中の場合は中止する
  - 対象ユーザー自身のセッション (sudo / su 含む) からは実行不可
  - SSH 認証 / 鍵 / .bashrc など旧 home 内のパスを参照する設定は手動確認が必要
EOF
}

# ----------------------------------------------------------------------------
# 引数パース
# ----------------------------------------------------------------------------

OLD_USER=""
NEW_USER="${DEFAULT_NEW_USER}"
ASSUME_YES="no"

parse_args() {
    if [[ $# -eq 0 ]]; then
        echo "エラー: 既存ユーザー名を指定してください。" >&2
        echo "詳細は '$0 --help' を参照してください。" >&2
        exit 1
    fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            --new-name)
                shift
                [[ $# -gt 0 ]] || err "--new-name の引数が不足しています。"
                NEW_USER="$1"
                shift
                ;;
            -y|--yes) ASSUME_YES="yes"; shift ;;
            -*) err "不明なオプション: $1" ;;
            *)
                if [[ -z "${OLD_USER}" ]]; then
                    OLD_USER="$1"
                else
                    err "複数の引数が指定されています: $1"
                fi
                shift
                ;;
        esac
    done
    [[ -n "${OLD_USER}" ]] || err "既存ユーザー名を指定してください。"
    [[ -n "${NEW_USER}" ]] || err "新ユーザー名が空です。"
}

require_root() {
    [[ $(id -u) -eq 0 ]] || err "root 権限で実行してください: sudo $0 ..."
}

# ----------------------------------------------------------------------------
# 事前チェック
# ----------------------------------------------------------------------------

precheck() {
    id "${OLD_USER}" >/dev/null 2>&1 || err "ユーザーが存在しません: ${OLD_USER}"

    if [[ "${OLD_USER}" == "${NEW_USER}" ]]; then
        err "既存ユーザー名と新ユーザー名が同一です: ${OLD_USER}"
    fi

    if id "${NEW_USER}" >/dev/null 2>&1; then
        err "新ユーザー名が既に存在します: ${NEW_USER}"
    fi

    if [[ -e "/home/${NEW_USER}" ]]; then
        err "/home/${NEW_USER} が既に存在します。事前に退避してください。"
    fi

    if [[ "$(id -un)" == "${OLD_USER}" ]] || [[ "${SUDO_USER:-}" == "${OLD_USER}" ]]; then
        err "対象ユーザー (${OLD_USER}) のセッションから実行することはできません。別 TTY / 別管理ユーザーから実行してください。"
    fi

    if loginctl list-users --no-legend 2>/dev/null | awk '{print $2}' | grep -qx "${OLD_USER}"; then
        err "対象ユーザー (${OLD_USER}) がログイン中です。先にログアウトしてください: loginctl terminate-user ${OLD_USER}"
    fi
    if who 2>/dev/null | awk '{print $1}' | grep -qx "${OLD_USER}"; then
        err "対象ユーザー (${OLD_USER}) のセッションがあります。先にログアウトしてください。"
    fi

    if pgrep -u "${OLD_USER}" >/dev/null 2>&1; then
        err "対象ユーザー (${OLD_USER}) のプロセスが残っています。先に終了してください: pkill -KILL -u ${OLD_USER}"
    fi

    # --badname サポート確認 (Ubuntu 26.04 想定では存在するはず)
    if ! usermod --help 2>&1 | grep -q -- '--badname'; then
        warn "usermod に --badname がありません (古い shadow-utils)。大文字を含むユーザー名は拒否される可能性があります。"
    fi
}

# ----------------------------------------------------------------------------
# 状態収集 + プラン
# ----------------------------------------------------------------------------

OLD_HOME=""
OLD_PRIMARY_GROUP=""
OLD_GID=""

collect_state() {
    OLD_HOME=$(getent passwd "${OLD_USER}" | awk -F: '{print $6}')
    OLD_GID=$(getent passwd "${OLD_USER}" | awk -F: '{print $4}')
    OLD_PRIMARY_GROUP=$(getent group "${OLD_GID}" | awk -F: '{print $1}')
}

print_plan() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "${sep}"
    echo "ユーザー名 + ホームディレクトリリネームを実行します。"
    echo ""
    echo "  対象ユーザー (旧):       ${OLD_USER} (uid=$(id -u "${OLD_USER}"), gid=${OLD_GID})"
    echo "  新ユーザー名:            ${NEW_USER}"
    echo "  旧 home:                 ${OLD_HOME}"
    echo "  新 home:                 /home/${NEW_USER}"
    echo "  primary group (旧):      ${OLD_PRIMARY_GROUP}"
    if [[ "${OLD_PRIMARY_GROUP}" == "${OLD_USER}" ]]; then
        echo "  primary group リネーム:  yes (旧ユーザー名と同名のため)"
    else
        echo "  primary group リネーム:  no (旧ユーザー名と異なるため)"
    fi
    echo "${sep}"
}

confirm_or_abort() {
    if [[ "${ASSUME_YES}" == "yes" ]]; then
        return 0
    fi
    local yn
    read -r -p "この内容で実行してよろしいですか？ (y/N) " yn
    case "${yn}" in
        [yY]) return 0 ;;
        *) echo "中止しました。"; exit 0 ;;
    esac
}

# ----------------------------------------------------------------------------
# Steps
# ----------------------------------------------------------------------------

# usermod / groupmod は --badname があれば付与、無ければそのまま実行する。
usermod_with_badname() {
    if usermod --help 2>&1 | grep -q -- '--badname'; then
        usermod --badname "$@"
    else
        usermod "$@"
    fi
}

groupmod_with_badname() {
    if groupmod --help 2>&1 | grep -q -- '--badname'; then
        groupmod --badname "$@"
    else
        groupmod "$@"
    fi
}

rename_login() {
    echo "Step 1: ユーザー名変更 (${OLD_USER} -> ${NEW_USER})"
    usermod_with_badname -l "${NEW_USER}" "${OLD_USER}" \
        || err "usermod による rename に失敗しました。--badname が必要な可能性があります (shadow-utils 4.13+)。"
    echo "  完了"
}

rename_primary_group() {
    if [[ "${OLD_PRIMARY_GROUP}" != "${OLD_USER}" ]]; then
        echo "Step 2: primary group は旧ユーザー名と異なるためスキップ (${OLD_PRIMARY_GROUP})"
        return 0
    fi
    echo "Step 2: primary group 名変更 (${OLD_PRIMARY_GROUP} -> ${NEW_USER})"
    groupmod_with_badname -n "${NEW_USER}" "${OLD_PRIMARY_GROUP}" \
        || err "groupmod による rename に失敗しました。"
    echo "  完了"
}

move_home() {
    echo "Step 3: home 移動 (${OLD_HOME} -> /home/${NEW_USER})"
    # -m: old home の中身を new home に移動 (mv 相当)、所有権は usermod が更新
    usermod -d "/home/${NEW_USER}" -m "${NEW_USER}"
    echo "  完了"
}

move_mail_spool() {
    local old_spool="/var/mail/${OLD_USER}"
    local new_spool="/var/mail/${NEW_USER}"
    if [[ -e "${old_spool}" ]]; then
        echo "Step 4: mail spool 移動 (${old_spool} -> ${new_spool})"
        mv "${old_spool}" "${new_spool}"
        chown "${NEW_USER}":"$(id -gn "${NEW_USER}")" "${new_spool}" 2>/dev/null \
            || chown "${NEW_USER}" "${new_spool}" 2>/dev/null \
            || warn "  mail spool の chown に失敗"
        echo "  完了"
    else
        echo "Step 4: mail spool は存在しないためスキップ"
    fi
}

update_sudoers() {
    local old_file="/etc/sudoers.d/${OLD_USER}"
    local new_file="/etc/sudoers.d/${NEW_USER}"
    echo "Step 5: sudoers.d エントリ更新"
    if [[ -f "${old_file}" ]]; then
        # \\b は GNU sed の単語境界。OLD_USER がたまたま部分一致するワードを誤置換しないように。
        sed -i "s/\\b${OLD_USER}\\b/${NEW_USER}/g" "${old_file}"
        mv "${old_file}" "${new_file}"
        chmod 0440 "${new_file}"
        chown root:root "${new_file}"
        echo "  ${old_file} -> ${new_file}"
    else
        echo "  ${old_file} は存在しないためスキップ"
    fi
    if grep -RqsE "\\b${OLD_USER}\\b" /etc/sudoers /etc/sudoers.d 2>/dev/null; then
        warn "  /etc/sudoers または /etc/sudoers.d に '${OLD_USER}' を含む記述が残っています。手動確認してください: sudo grep -RnE '\\b${OLD_USER}\\b' /etc/sudoers /etc/sudoers.d"
    fi
}

move_crontab() {
    local old_cron="/var/spool/cron/crontabs/${OLD_USER}"
    local new_cron="/var/spool/cron/crontabs/${NEW_USER}"
    if [[ -f "${old_cron}" ]]; then
        echo "Step 6: crontab 移動 (${old_cron} -> ${new_cron})"
        mv "${old_cron}" "${new_cron}"
        # crontab グループが存在する環境では crontab、それ以外はユーザー所有のまま
        if getent group crontab >/dev/null 2>&1; then
            chown "${NEW_USER}":crontab "${new_cron}"
        else
            chown "${NEW_USER}" "${new_cron}"
        fi
        chmod 0600 "${new_cron}"
        echo "  完了"
    else
        echo "Step 6: 個人 crontab なし、スキップ"
    fi
}

move_linger() {
    local old_linger="/var/lib/systemd/linger/${OLD_USER}"
    local new_linger="/var/lib/systemd/linger/${NEW_USER}"
    if [[ -e "${old_linger}" ]]; then
        echo "Step 7: systemd linger 設定移動"
        mv "${old_linger}" "${new_linger}"
        echo "  完了"
    else
        echo "Step 7: systemd linger 設定なし、スキップ"
    fi
}

# ----------------------------------------------------------------------------
# 完了表示
# ----------------------------------------------------------------------------

print_summary() {
    local sep="------------------------------------------------------------------------------------------------------------------------------------------------------"
    cat <<EOF

${sep}
ユーザー名 + home リネームが完了しました。
${sep}

  旧ユーザー: ${OLD_USER}
  新ユーザー: ${NEW_USER} (uid=$(id -u "${NEW_USER}"))
  home:       $(getent passwd "${NEW_USER}" | awk -F: '{print $6}')
  primary:    $(id -gn "${NEW_USER}")
  groups:     $(id -Gn "${NEW_USER}")

確認コマンド:
  id ${NEW_USER}
  ls -la /home/${NEW_USER}
  getent passwd ${NEW_USER}
  groups ${NEW_USER}

手動確認推奨ポイント:
  - SSH authorized_keys / 鍵パスの整合 (~/.ssh)
  - .bashrc / .profile 等の旧 home パスのハードコード
  - /etc/sudoers (本体) に '${OLD_USER}' 記述が残っていないか
  - systemd unit / cron / スクリプトに '${OLD_USER}' を直書きしていないか
${sep}
EOF
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

main() {
    parse_args "$@"
    require_root
    precheck
    collect_state
    print_plan
    confirm_or_abort

    rename_login
    rename_primary_group
    move_home
    move_mail_spool
    update_sudoers
    move_crontab
    move_linger
    print_summary
}

main "$@"
