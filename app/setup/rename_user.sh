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
#   - 対象ユーザーがログイン中・プロセス実行中の場合、別 TTY / 別管理ユーザーから
#     実行する必要がある。
#   - 対象ユーザー自身のセッション (sudo / su 含む) から呼ばれた場合は、既定で
#     systemd transient unit に切り離してリネームを実行する (--auto-detach、既定 ON)。
#     呼び出し元の SSH/TTY セッションはリネーム前に強制終了されるため、
#     新ユーザー名で再接続してジャーナル / ログを確認する。
#   - --no-auto-detach を指定すると従来の厳格な挙動 (即エラー) に戻る。
#     その場合は別 TTY (Ctrl+Alt+F2) で root ログインするか、別の管理ユーザーから実行すること。

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
  --auto-detach             対象ユーザーセッションから呼ばれた場合に systemd
                            transient unit に切り離して実行する (既定 ON)
  --no-auto-detach          上記を無効化し、対象ユーザーセッションからは即エラー
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

auto-detach モード (既定):
  対象ユーザーのセッションから呼ばれた場合、systemd-run で system.slice 配下の
  transient unit に切り離して実行する。unit 内で対象ユーザーのセッション/プロセスを
  loginctl + pkill で全停止してからリネームを実行する。呼び出し元 SSH は切断される
  ため、新ユーザー名で再接続して以下で結果を確認:
    journalctl -u <unit-name>.service
    cat /var/log/rename-user.log

注意:
  - root 権限で実行すること: sudo $0 ...
  - 対象ユーザーがログイン中 / プロセス実行中の場合、--no-auto-detach 指定時はエラー
  - SSH 認証 / 鍵 / .bashrc など旧 home 内のパスを参照する設定は手動確認が必要
EOF
}

# ----------------------------------------------------------------------------
# 引数パース
# ----------------------------------------------------------------------------

OLD_USER=""
NEW_USER="${DEFAULT_NEW_USER}"
ASSUME_YES="no"
AUTO_DETACH="yes"
DETACH_NEEDED="no"

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
            --auto-detach) AUTO_DETACH="yes"; shift ;;
            --no-auto-detach) AUTO_DETACH="no"; shift ;;
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

    # 同一セッション判定 (sudo/su も含む)。
    # - RENAME_USER_DETACHED=1 (デタッチ後の子プロセス) の場合はスキップ
    # - --auto-detach の場合は DETACH_NEEDED=yes を立てて main で分岐
    # - --no-auto-detach の場合は従来通り即エラー
    if [[ "${RENAME_USER_DETACHED:-}" != "1" ]] \
       && { [[ "$(id -un)" == "${OLD_USER}" ]] || [[ "${SUDO_USER:-}" == "${OLD_USER}" ]]; }; then
        if [[ "${AUTO_DETACH}" == "yes" ]]; then
            command -v systemd-run >/dev/null 2>&1 \
                || err "対象ユーザー (${OLD_USER}) のセッションから呼ばれましたが systemd-run が見つかりません。--no-auto-detach を指定して別 TTY から実行してください。"
            DETACH_NEEDED="yes"
        else
            err "対象ユーザー (${OLD_USER}) のセッションから実行することはできません。別 TTY / 別管理ユーザーから実行してください (または --auto-detach を指定)。"
        fi
    fi

    # ログイン中ユーザー / 残プロセスのチェック。
    # スキップ条件:
    #   - DETACH_NEEDED=yes (auto-detach の親プロセス)。子側で kill するため。
    #   - RENAME_USER_DETACHED=1 (auto-detach の子プロセス)。wrapper が事前に
    #     loginctl + pkill でクリア済みであり、user@UID.service の停止待ちで
    #     loginctl が一瞬だけユーザーを表示する偽陽性を避けるため。
    if [[ "${DETACH_NEEDED}" != "yes" ]] && [[ "${RENAME_USER_DETACHED:-}" != "1" ]]; then
        if loginctl list-users --no-legend 2>/dev/null | awk '{print $2}' | grep -qx "${OLD_USER}"; then
            err "対象ユーザー (${OLD_USER}) がログイン中です。先にログアウトしてください: loginctl terminate-user ${OLD_USER}"
        fi
        if who 2>/dev/null | awk '{print $1}' | grep -qx "${OLD_USER}"; then
            err "対象ユーザー (${OLD_USER}) のセッションがあります。先にログアウトしてください。"
        fi

        if pgrep -u "${OLD_USER}" >/dev/null 2>&1; then
            err "対象ユーザー (${OLD_USER}) のプロセスが残っています。先に終了してください: pkill -KILL -u ${OLD_USER}"
        fi
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
    if [[ "${DETACH_NEEDED}" == "yes" ]]; then
        echo ""
        echo "  実行モード:              auto-detach (systemd transient unit に切り離して実行)"
        echo "                            呼び出し元 SSH/TTY セッションは強制終了されます。"
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
# auto-detach 実行
# ----------------------------------------------------------------------------

# 対象ユーザーセッションから呼ばれた場合に、systemd transient unit に切り離して
# リネームを実行する。
#
# 流れ:
#   1. このスクリプト自身を /usr/local/sbin/.rename-user-detached.sh に複製
#      (旧 home が移動するため、リネーム実行中も読める安定した場所が必要)
#   2. systemd-run で system.slice 配下に transient unit を起動
#   3. unit 内で sleep → loginctl terminate-user → pkill で対象ユーザーを完全停止
#   4. 複製したスクリプトを RENAME_USER_DETACHED=1 + --yes で再実行
#   5. 親プロセス (このスクリプト) は exit 0 で速やかに終了
#      (残っていても直後の pkill で SIGKILL される)
run_detached() {
    local detached_script="/usr/local/sbin/.rename-user-detached.sh"
    install -m 0700 -o root -g root "${BASH_SOURCE[0]}" "${detached_script}" \
        || err "${detached_script} へのコピーに失敗しました。"

    local log_file="/var/log/rename-user.log"
    : > "${log_file}"
    chmod 0600 "${log_file}"

    local unit="rename-user-$(date +%s)-$$"

    cat <<EOF

==============================================================================
対象ユーザー (${OLD_USER}) のセッションから呼ばれたため、systemd transient
unit に切り離してリネームを実行します。

  unit:    ${unit}.service
  log:     ${log_file}

このセッションは数秒以内に切断されます。
新ユーザー (${NEW_USER}) で再接続後、以下で結果を確認してください:

  journalctl -u ${unit}.service --no-pager
  cat ${log_file}
==============================================================================
EOF
    sleep 3

    # bash -c の本体は親シェルが二重引用符内で展開する。
    # - \${OLD_USER} 等は親シェルで展開済みの文字列になる
    # - \\\$rc / \\\$? 等は子シェルで評価される
    # - シングルクォート '...' は子シェルでの quoting (リテラル化) のため
    systemd-run \
        --unit="${unit}" \
        --slice=system.slice \
        --description="Rename ${OLD_USER} -> ${NEW_USER}" \
        --setenv=RENAME_USER_DETACHED=1 \
        --working-directory=/ \
        /bin/bash -c "
exec >> '${log_file}' 2>&1
echo \"[detach] \$(date -Is) starting detach wrapper\"
sleep 5

old_uid=\$(id -u '${OLD_USER}' 2>/dev/null || echo '')

echo \"[detach] \$(date -Is) disabling linger for ${OLD_USER}\"
loginctl disable-linger '${OLD_USER}' 2>&1 || true

echo \"[detach] \$(date -Is) terminating sessions for ${OLD_USER}\"
loginctl terminate-user '${OLD_USER}' 2>&1 || true

if [[ -n \"\$old_uid\" ]]; then
    echo \"[detach] \$(date -Is) stopping user@\${old_uid}.service\"
    systemctl stop \"user@\${old_uid}.service\" 2>&1 || true
fi

# 残プロセスと loginctl 状態がクリアになるまでポーリング (最大 ~15s)
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    pkill -KILL -u '${OLD_USER}' 2>&1 || true
    sleep 1
    has_proc=\"no\"
    has_session=\"no\"
    pgrep -u '${OLD_USER}' >/dev/null 2>&1 && has_proc=\"yes\"
    if loginctl list-users --no-legend 2>/dev/null | awk '{print \$2}' | grep -qx '${OLD_USER}'; then
        has_session=\"yes\"
    fi
    if [[ \"\$has_proc\" == \"no\" ]] && [[ \"\$has_session\" == \"no\" ]]; then
        echo \"[detach] \$(date -Is) sessions and processes cleared after \${i}s\"
        break
    fi
done

if pgrep -u '${OLD_USER}' >/dev/null 2>&1; then
    echo \"[detach] \$(date -Is) WARN: processes still remain after kill loop:\"
    pgrep -au '${OLD_USER}' 2>&1 || true
fi

echo \"[detach] \$(date -Is) invoking rename script\"
'${detached_script}' '${OLD_USER}' --new-name '${NEW_USER}' --yes --no-auto-detach
rc=\$?
echo \"[detach] \$(date -Is) rename script exited rc=\$rc\"
rm -f '${detached_script}'
exit \$rc
"

    exit 0
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

    if [[ "${DETACH_NEEDED}" == "yes" ]]; then
        run_detached
        # run_detached は exit するので戻らない
        exit 0
    fi

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
