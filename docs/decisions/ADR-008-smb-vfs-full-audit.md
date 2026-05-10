# ADR-008: SMB アクセスログを vfs_full_audit + rsyslog + CloudWatch Logs で収集する

## Status

Accepted (2026-05-10)

## Context

- FileServer / BackupServer は Samba (smbd) で SMB 共有を提供し、Mac/Windows クライアントから日常的にアクセスされる
- 「いつ・誰が・どの共有に対して何をしたか」を **CloudWatch Logs に集約して長期保存・検索可能にする** 要件がある
- 既存の `/var/log/samba/log.smbd` は smbd デーモンの起動/停止程度しか記録されず、ファイル単位の操作監査には使えない
- `smb.conf` の `log file = /var/log/samba/log.%m` はクライアントごとに別ファイルが生成されるため、CloudWatch Agent の `file_path` で固定 tail できず、機械可読フォーマットでもない
- Samba 自身が持つ監査機構には次の選択肢がある:
  - **vfs_full_audit**: VFS 操作 (connect/disconnect/mkdirat/unlinkat/renameat/...) を syslog に出力。プレフィクスで `<user>|<client_ip>|<share>` 等を構造化可能
  - **log level + auth_audit / auth_json_audit**: 認証イベント (ログイン試行) のみ
- BackupServer は Time Machine 用途で **rename/unlink が常時大量発生する** (差分作成時に膨大な数の中間ファイルが生成・削除される)。すべての操作を audit すると CloudWatch Logs ingestion 料金とノイズが過大になる

## Decision

| 項目 | 採用 |
|---|---|
| 監査機構 | `vfs_full_audit` (syslog facility=LOCAL5, priority=NOTICE) |
| 出力経路 | smbd → syslog(LOCAL5) → rsyslog drop-in → `/var/log/samba/audit.log` → CloudWatch Agent → CloudWatch Logs `/onprem/<server>/smb-audit` |
| ログ前置文字列 | `full_audit:prefix = %u|%I|%S` (ユーザー \| クライアント IP \| 共有名) |
| 監査対象操作 (success) | サーバー別に `AUDIT_SUCCESS_OPS` で上書き可能 (既定はメタデータセット) |
| 監査対象操作 (failure) | `connect` のみ (拒否された接続) |
| FileServer | `ENABLE_AUDIT="yes"`、`AUDIT_SUCCESS_OPS` 未指定 (既定の `connect disconnect mkdirat unlinkat renameat fchmod fchown`) |
| BackupServer | `ENABLE_AUDIT="yes"`、`AUDIT_SUCCESS_OPS="connect disconnect"` (Time Machine の rename/unlink 大量発生を避けるため接続イベントのみ) |
| ローテーション | logrotate (daily / 30 世代 / postrotate で rsyslog HUP) |
| ローカル出力先 | `/var/log/samba/audit.log` (640 root:adm) |

`vfs objects` の並びは `catia fruit streams_xattr full_audit` とし、full_audit を末尾に置いて他モジュールの変換後の VFS 呼び出しを補足する。

CloudWatch Agent の `app/config/cloudwatch_agent/{FileServer,BackupServer}.conf` で `LOG_PATHS` に `/var/log/samba/audit.log:smb-audit` を追加し、それぞれ `/onprem/FileServer/smb-audit` / `/onprem/BackupServer/smb-audit` に転送する。BackupServer 側のストリームは接続イベントのみが流れる想定。

## ファイル書き込み単体は意図的に対象外

`full_audit:success` に `openat` / `pread` / `pwrite` / `create_file` 等の **読み書き系 op を含めない**。理由:

- macOS Time Machine 以外でも、Mac/Win クライアントは 1 ファイル操作で多数の low-level open/read/write を発行する
- メタデータ操作 (mkdirat / unlinkat / renameat / fchmod / fchown) で「**何が変化したか**」は完全に追跡可能
- 既存ファイルを上書き保存する Mac アプリ (TextEdit, Word, Pages 等) の atomic save は temp+rename パターンのため `renameat` で捕捉される
- Finder のドラッグ&ドロップによる純粋なコピー (新規ファイル) のみ、現 op リストでは記録されない (open+write+close の系列が含まれないため)。これは許容する

「誰がどのファイルを開いたか」を厳密に追跡したい場合は `create_file` の追加を別途検討する。CW Logs ingestion 料金が増えるため、要件確定後に判断する。

## ログファイルパーミッションの注意点

> [!IMPORTANT]
> `/var/log/samba/audit.log` のオーナーは **`syslog:adm` 0640** とする。`root:adm 0640` で作成すると `adm` グループに read 権しかなく、rsyslog (Ubuntu 既定で `syslog` ユーザー稼働、adm グループ所属) からの append が拒否され、`omfile suspended` エラーで CW Logs まで届かない。

`/var/log/samba/` 自体は `drwxr-x--- root:adm` で adm グループに write 権がないため、rsyslog はこのディレクトリに **新規ファイルを作成できない**。`samba.sh` が事前に `syslog:adm 0640` で空ファイルを作成し、logrotate も `create 0640 syslog adm` でローテ後ファイルを root 権限で作成し直す。

旧版 `samba.sh` で `root:adm 0640` で作られた既存ファイルは、再実行時にスクリプトが自動で `chown syslog:adm` に正規化する。

## opname の "-at" 系統合への追従

> [!IMPORTANT]
> Samba 4.18+ で VFS インターフェースが `*at(2)` 系に統合され、`vfs_full_audit` の **opname 命名も変更された**。旧来の `mkdir` `rmdir` `unlink` `rename` `chmod` `chown` を `success` リストに書くと `init_bitmap: Could not find opname mkdir` エラーで **すべての SMB 接続が拒否される** (本 ADR 採用時の実害として確認済)。

| 旧 opname (Samba ≤ 4.17) | 新 opname (Samba 4.18+) | 備考 |
|---|---|---|
| `mkdir` | `mkdirat` | |
| `rmdir` | `unlinkat` | `unlinkat` がフラグで rmdir/unlink 双方を表す |
| `unlink` | `unlinkat` | 同上 |
| `rename` | `renameat` | |
| `chmod` | `fchmod` | |
| `chown` | `fchown` | |

Ubuntu 26.04 同梱 Samba は 4.23 系のため新 opname のみが有効。`samba.sh` は新 opname で smb.conf を生成する。サポート対象の opname 一覧は `source3/modules/vfs_full_audit.c` のディスパッチテーブル (各 Samba バージョンの実装) を参照。

## Alternatives Considered

| 案 | 却下理由 |
|---|---|
| `log level = 1 auth_json_audit:3@/var/log/samba/auth.log` のみ | 認証イベント (ログイン試行) しか記録されず、「どのファイルが操作されたか」が分からない。要件未充足 |
| `vfs_full_audit` で `success = open close read write` も含める | open/close で 1 接続あたり数百〜数千件、Time Machine 環境では数十万件/日に達し、CW Logs ingestion コストが過大。メタデータ操作 (mkdirat/unlinkat/renameat/fchmod/fchown) のみで「誰が何をしたか」は十分追跡可能 |
| BackupServer も FileServer と同じメタデータ操作セット (mkdirat/unlinkat/renameat/...) で audit ON | Time Machine の差分生成は rename/unlink を毎秒数十件発生させ、1 バックアップで数十万件規模、CW Logs ingestion 料金とノイズが容認できない。Backup のメタデータ挙動は macOS 側 Time Machine ログで追跡可能。**接続イベントのみは別途有効化** (`AUDIT_SUCCESS_OPS="connect disconnect"`) |
| BackupServer は完全 OFF (audit 無効) | 「どの端末がいつ接続/切断したか」は最低限のセキュリティ監視として欲しい。接続イベントだけなら 1 接続あたり 2 行で発生頻度も低く、CW Logs コストはほぼ無視できる |
| smbd ログ (`/var/log/samba/log.smbd` / `log.%m`) を CW Logs にそのまま流す | 非構造化テキスト、クライアントごとにファイルが分裂、フィールド抽出が困難 |
| Samba audit を経由せず eBPF / auditd で SMB を観測 | プロジェクトの可観測性スタックに合わず、運用コスト過大。Samba 自身が出すなら samba を信頼する |
| ログを直接 CW Logs に投げる (rsyslog imfile プラグイン → omfile を経由しない) | rsyslog → ファイル → CW Agent の 3 段は一見冗長だが、ローカルでの検索/ローテーション/オフライン時のバッファ用途で有用。Agent が落ちても直近ログはローカルに残る |

## Consequences

### 利点

- 「誰が・どの IP から・どの共有で・何をしたか」の構造化監査ログが CloudWatch Logs Insights で検索可能になる
- ログ量は接続イベント中心 + メタデータ操作なので CW Logs ingestion 料金が抑えられる (Time Machine を除外している前提で)
- 共通 syslog facility (LOCAL5) を専用ファイルに振り分ける rsyslog 経由方式により、後で別フィルタを追加することも容易
- スクリプト (`samba.sh`) のフラグ (`ENABLE_AUDIT`) で ON/OFF が冪等に切替可能。OFF 切替時は drop-in / logrotate も自動撤去する

### 欠点 / 未対応事項

- 一度の **opname 命名差** によるサービス断 (本 ADR 採用初日に発生) のように、Samba バージョン差で破壊的変更が混入し得る。Samba メジャーアップグレード時は opname の有効性を `init_bitmap` ログで確認する
- BackupServer はメタデータ操作 (mkdirat/unlinkat/renameat/fchmod/fchown) が監査対象から外れる。接続元 IP と接続時刻だけは `connect`/`disconnect` で取得できるが、ファイル単位の書き換え検知は別レイヤー (NAS 接続元 IP の制限、Time Machine 側暗号化、CW メトリクスの容量推移) に依存する
- `& stop` を含む rsyslog drop-in は LOCAL5 ファシリティを完全に Samba 監査に専有する。将来的に他用途で LOCAL5 を使う場合は本 drop-in を見直す必要がある
- 監査ログは平文 (640 syslog:adm) でディスクに残る。プライバシー要件によっては保存期間・暗号化の追加検討が必要
- 純粋なファイル新規作成 (Finder ドラッグ&ドロップのコピー等、open+write+close のみで rename を伴わない操作) は記録されない。記録が必要な場合は `create_file` 追加の判断を別途行う

### 影響範囲

- `app/setup/samba.sh`: `ENABLE_AUDIT` フラグおよび `AUDIT_SUCCESS_OPS` 任意設定の追加、`vfs objects` 動的組立、smb.conf に `full_audit:*` 注入、rsyslog drop-in / logrotate 配置ステップ。OFF 切替時はクリーンアップ
- `app/config/samba/{FileServer,BackupServer,sample}.conf`: `ENABLE_AUDIT` 行追加 (FileServer=yes / BackupServer=yes (接続のみ) / sample=no)。BackupServer は `AUDIT_SUCCESS_OPS="connect disconnect"`
- `app/config/rsyslog/samba_audit.conf` (新規): `local5.* /var/log/samba/audit.log` + `& stop`
- `app/config/logrotate/samba_audit.conf` (新規): daily/30 世代/postrotate で rsyslog 再オープン
- `app/config/cloudwatch_agent/{FileServer,BackupServer}.conf`: `LOG_PATHS` に `/var/log/samba/audit.log:smb-audit` 追加

## Related

- [How-to: SMB アクセスログを CloudWatch Logs に転送する](../how-to/smb-audit-logs.md)
- [reference/configurations.md > `samba/<server>.conf`](../reference/configurations.md#sambaserverconf)
- [reference/scripts.md > `samba.sh`](../reference/scripts.md#sambash)
- [Operations > ログ確認](../operations.md#ログ確認)
- [ADR-002: app/config を目的別ディレクトリに分割](ADR-002-app-config-purpose-split.md)
