# How-to: SMB アクセスログを CloudWatch Logs に転送する

FileServer / BackupServer の SMB 共有に対する操作を構造化監査ログとして `/var/log/samba/audit.log` に出力し、CloudWatch Logs に転送する。サーバーごとに監査対象操作のセットを切り替えられる。

## 目的

- 「誰が・どの IP から・どの共有に対して・何の操作をしたか」を CloudWatch Logs Insights で検索可能にする
- サーバーの用途に応じて監査の粒度を調整する:
  - **FileServer**: メタデータ操作セット (接続/切断 + ディレクトリ作成/削除/リネーム/権限変更)
  - **BackupServer**: 接続イベントのみ (`connect` / `disconnect`)。Time Machine の rename/unlink 大量発生を避け、CW Logs ingestion を抑制 ([ADR-008](../decisions/ADR-008-smb-vfs-full-audit.md))

## 前提条件

- Samba (smbd) が稼働している (Ubuntu 26.04 / Samba 4.18+)
- CloudWatch Agent がハイブリッドアクティベーション登録済み
- root / sudo 権限

## 構成

```
smbd (vfs_full_audit) ──syslog(LOCAL5)──> rsyslog (40-samba-audit.conf)
                                              │
                                              ▼
                                   /var/log/samba/audit.log (640 root:adm)
                                              │
                                              ▼
                                       CloudWatch Agent
                                              │
                                              ▼
              CloudWatch Logs: /onprem/FileServer  stream: smb-audit
```

ログ 1 行の例 (`audit.log`):

```
2026-05-10T14:00:12+09:00 FileServer smbd_audit[1234]: NaoyaOgura|192.168.0.42|FileServer|connect|ok|
2026-05-10T14:00:30+09:00 FileServer smbd_audit[1234]: NaoyaOgura|192.168.0.42|FileServer|mkdirat|ok|/work/2026Q2
2026-05-10T14:00:45+09:00 FileServer smbd_audit[1234]: NaoyaOgura|192.168.0.42|FileServer|renameat|ok|old.txt -> new.txt
```

`<user>|<client_ip>|<share>|<op>|ok|<args...>` の順でパイプ区切り。

## 監査対象操作

`AUDIT_SUCCESS_OPS` (samba conf の任意変数) で操作セットを上書きできる。未指定なら下記デフォルトセット。

| opname | 意味 | FileServer | BackupServer |
|---|---|---|---|
| `connect` | 共有への接続 | ✅ | ✅ |
| `disconnect` | 共有からの切断 | ✅ | ✅ |
| `mkdirat` | ディレクトリ作成 | ✅ | — |
| `unlinkat` | ファイル削除 / ディレクトリ削除 (rmdir 相当) | ✅ | — |
| `renameat` | リネーム / 移動 | ✅ | — |
| `fchmod` | パーミッション変更 | ✅ | — |
| `fchown` | 所有者変更 | ✅ | — |

設定ファイルの指定例:

```bash
# FileServer (デフォルト = メタデータ監査セット)
ENABLE_AUDIT="yes"
# AUDIT_SUCCESS_OPS は未指定でよい (省略でデフォルト)

# BackupServer (接続イベントのみ)
ENABLE_AUDIT="yes"
AUDIT_SUCCESS_OPS="connect disconnect"
```

> [!IMPORTANT]
> Samba 4.18+ で VFS が "-at" 系に統合されたため、旧名 (`mkdir` / `rmdir` / `unlink` / `rename` / `chmod` / `chown`) を smb.conf に書くと **`init_bitmap: Could not find opname mkdir` エラーで全接続が拒否**される。詳細は [ADR-008](../decisions/ADR-008-smb-vfs-full-audit.md#opname-の-at-系統合への追従) を参照。

`open` / `close` / `read` / `write` 等のファイル単位イベントは **意図的に対象外**。CW Logs ingestion コスト抑制のため、メタデータ操作のみに絞っている。

> [!NOTE]
> Finder のドラッグ&ドロップによる純粋なファイルコピー (open + write + close のみ) は **どの op にも該当せず audit.log に何も出ない**。一方、TextEdit/Word/Pages 等の上書き保存は temp+rename の atomic save パターンのため `renameat` で捕捉される。Finder の「新規フォルダ」は `mkdirat` で記録される。
>
> 監査が動作しているかの確認は **新規フォルダ作成** が確実 (`mkdirat` イベントが必ず出る)。ファイル単体の追跡が必要なら ADR-008 の Consequences と Alternatives を参照のうえ `create_file` 追加を別途検討する。

## 手順

### Step 1. 設定ファイルで監査を有効化

`app/config/samba/FileServer.conf`:

```bash
ENABLE_AUDIT="yes"
```

BackupServer は `ENABLE_AUDIT="no"` のままとする ([ADR-008](../decisions/ADR-008-smb-vfs-full-audit.md))。

### Step 2. samba.sh を再適用

```bash
sudo /home/NaoyaOgura/file-servers/app/setup/samba.sh FileServer.conf
```

スクリプトが以下を一括で行う:

1. `vfs objects = catia fruit streams_xattr full_audit` を smb.conf に注入
2. `full_audit:*` 設定を `[global]` に追加
3. `/etc/rsyslog.d/40-samba-audit.conf` 配置 (LOCAL5 → audit.log)
4. `/etc/logrotate.d/samba_audit` 配置 (daily / 30 世代)
5. `/var/log/samba/audit.log` を 640 root:adm で初期化
6. smbd / rsyslog 再起動

### Step 3. CloudWatch Agent 側の登録

`app/config/cloudwatch_agent/FileServer.conf`:

```bash
LOG_PATHS="/var/log/rsync/rsync_fileserver.log:rsync /var/log/samba/audit.log:smb-audit"
```

```bash
sudo /home/NaoyaOgura/file-servers/app/setup/cloudwatch_agent.sh FileServer.conf
```

### Step 4. 動作確認

ローカル監査ログにイベントが入るか:

```bash
sudo tail -f /var/log/samba/audit.log
# 別端末から SMB 接続試行 → connect イベントが流れるはず
```

CloudWatch Logs に転送されているか:

```bash
aws logs tail /onprem/FileServer --log-stream-names smb-audit --since 5m \
    --region ap-northeast-1 --profile FileServers
```

## 無効化したい場合

```bash
# ENABLE_AUDIT を no に変更
sudo sed -i 's/^ENABLE_AUDIT=.*/ENABLE_AUDIT="no"/' \
    /home/NaoyaOgura/file-servers/app/config/samba/FileServer.conf

# 再適用 — drop-in と logrotate 設定はスクリプトが自動撤去する
sudo /home/NaoyaOgura/file-servers/app/setup/samba.sh FileServer.conf
```

`/var/log/samba/audit.log` ファイル自体は残る (手動で削除可)。CloudWatch Agent 側の `LOG_PATHS` から `/var/log/samba/audit.log:smb-audit` を外すかは任意 (audit OFF にすればログは増えなくなる)。

## トラブルシュート

### 症状: 監査有効化後に SMB 接続できなくなった

`smbd` ログに `init_bitmap: Could not find opname <name>` が出ている場合、`full_audit:success` の opname が当該 Samba バージョンで未対応:

```bash
sudo journalctl -u smbd --since "10 minutes ago" --no-pager | grep -E "init_bitmap|full_audit"
```

緊急復旧:

```bash
# smb.conf の opname を新名 ("-at" 系) に置換
sudo sed -i 's|^\(\s*full_audit:success = \).*|\1connect disconnect mkdirat unlinkat renameat fchmod fchown|' \
    /etc/samba/smb.conf
sudo testparm -s >/dev/null && sudo smbcontrol smbd reload-config
```

恒久対応はスクリプト側 (`app/setup/samba.sh` の `write_smb_conf` 内) を修正してから samba.sh を再適用する。

### 症状: audit.log にイベントが書かれない

```bash
# 1. smbd が full_audit を読んでいるか
sudo testparm -s 2>&1 | grep full_audit

# 2. rsyslog が drop-in を読んでいるか
sudo rsyslogd -N1 2>&1 | tail
sudo systemctl status rsyslog --no-pager -l | tail -10

# 3. syslog 経由で確認 (drop-in 配置前なら /var/log/syslog にも出るはず)
sudo journalctl --since "5 minutes ago" --no-pager | grep smbd_audit

# 4. ファイル権限
ls -la /var/log/samba/audit.log
# 期待: -rw-r----- syslog adm

# 5. rsyslog が omfile suspended を出していないか
sudo journalctl -u rsyslog --since "5 minutes ago" --no-pager | grep -i "omfile\|suspend"
```

> [!IMPORTANT]
> **オーナーが `root:adm` だと rsyslog が書き込めない**。Ubuntu の rsyslog は `syslog` ユーザー (adm グループ所属) で稼働するが、`root:adm 0640` だと `adm` グループは read 権のみで書き込み不可。`omfile suspended` ログが出ていればこれが原因。緊急復旧:
>
> ```bash
> sudo chown syslog:adm /var/log/samba/audit.log
> sudo systemctl restart rsyslog
> ```
>
> 恒久対応は `samba.sh` を再適用 (現行版は `syslog:adm 0640` で作成 + 既存ファイルの自動正規化)。

`& stop` を含む drop-in は LOCAL5 を専有するため、rsyslog 起動順序の問題で初回イベントを取りこぼす可能性は低い。SMB 接続を再度試して反映を確認する。

### 症状: CloudWatch Logs に流れない

```bash
sudo systemctl status amazon-cloudwatch-agent --no-pager -l | tail
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status -m onPremise
sudo grep -i audit /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
```

設定 JSON に `/var/log/samba/audit.log` の `collect_list` エントリが入っていなければ、`cloudwatch_agent.sh` の再実行が必要。

## 関連

- [ADR-008: vfs_full_audit + rsyslog + CloudWatch Logs](../decisions/ADR-008-smb-vfs-full-audit.md)
- [reference/configurations.md > `samba/<server>.conf`](../reference/configurations.md#sambaserverconf)
- [reference/scripts.md > `samba.sh`](../reference/scripts.md#sambash)
- [Operations > ログ確認](../operations.md#ログ確認)
