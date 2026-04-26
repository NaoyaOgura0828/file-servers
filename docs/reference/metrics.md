# Reference: CloudWatch Metrics & Logs

`app/setup/cloudwatch_agent.sh` が設定する CloudWatch Metrics / Logs の仕様。

## 名前空間 / ロググループ

| 種別 | 値 | 出力源 |
|---|---|---|
| メトリクス名前空間 | `OnPremises/<SERVER_NAME>` | `cloudwatch_agent.sh` 生成 JSON |
| ロググループ | `/onprem/<SERVER_NAME>` | 同上 |

`SERVER_NAME` は config (`cloudwatch_agent/<server>.conf`) で定義。例: `BackupServer` / `FileServer`。

## メトリクス一覧

> [!NOTE]
> 採取間隔 60 秒 (CloudWatch Agent デフォルト)。CFn 旧版から CDK Dashboard に表示するもののみ採取。

| 種別 | メトリクス名 | 単位 | 内容 |
|---|---|---|---|
| CPU | `CPU_IDLE` | Percent | CPU アイドル率 (`totalcpu=true`) |
| メモリ | `MEM_USED_PERCENT` | Percent | メモリ使用率 |
| ディスク | `DISK_USED_PERCENT` | Percent | ディスク使用率 (mountpoint ごと) |
| Swap | `SWAP_USED_PERCENT` | Percent | Swap 使用率 |

## 監視対象ディスク

`/` は常時監視。`MOUNTPOINTS` 設定で追加マウントポイントを監視できる。

例 (`cloudwatch_agent/BackupServer.conf`):
```bash
MOUNTPOINTS="/mnt/timemachine"
```

→ 監視対象: `/`, `/mnt/timemachine`

## ログストリーム

`/onprem/<SERVER_NAME>` ロググループ配下に以下のストリームが作成される。

| ストリーム名 | ソースファイル | 用途 |
|---|---|---|
| `smbd` | `/var/log/samba/log.smbd` | Samba 認証異常、アクセスエラー |
| `nmbd` | `/var/log/samba/log.nmbd` | NetBIOS 名前解決異常 |
| `syslog` | `/var/log/syslog` | systemd / カーネル / OOM / NIC 障害 |
| カスタム (任意) | `LOG_PATHS` で指定 | rsync 等のアプリログ |

`LOG_PATHS` 形式 (空白区切り):
```
"/var/log/rsync/rsync_fileserver.log:rsync /var/log/app/app.log:application"
```

→ それぞれ `rsync` / `application` ストリームへ。

## ダッシュボード

CDK スタック `fs-prod-cloudwatch-dashboard` が以下を作成:

| ダッシュボード名 | 監視対象 | 表示メトリクス |
|---|---|---|
| `FileServer` | OnPremises/FileServer / host=fileserver | CPU / メモリ / ディスク (`SEARCH` で全マウント) / Swap |
| `BackupServer` | OnPremises/BackupServer / host=backupserver | 同上 |

ダッシュボード本体は `infra/cdk/lib/cloudwatchDashboard.ts` で定義。

## 推奨アラーム

CloudWatch Alarm として設定推奨。

| 優先度 | メトリクス | 条件 | 対応 |
|---|---|---|---|
| 🔴 高 | `DISK_USED_PERCENT` | > 90% | データ削除 / LV 拡張 (`lvm_extend.sh`) |
| 🔴 高 | `MEM_USED_PERCENT` | > 90% | プロセス特定 (`top` / `ps`)、必要なら restart |
| 🟡 中 | `SWAP_USED_PERCENT` | > 10% | メモリ増設または高負荷プロセス特定 |

## メトリクスの確認 (CLI)

```bash
aws cloudwatch list-metrics \
  --namespace OnPremises/BackupServer \
  --region ap-northeast-1 --profile FileServers

aws cloudwatch get-metric-statistics \
  --namespace OnPremises/BackupServer \
  --metric-name DISK_USED_PERCENT \
  --dimensions Name=host,Value=backupserver \
  --start-time $(date -u -d '1 hour ago' +%FT%T) \
  --end-time $(date -u +%FT%T) \
  --period 300 --statistics Average \
  --region ap-northeast-1 --profile FileServers
```

## ログの確認 (CLI)

```bash
aws logs tail /onprem/BackupServer --follow \
  --region ap-northeast-1 --profile FileServers
```

## 関連

- [設定ファイルリファレンス](configurations.md)
- [スクリプトリファレンス](scripts.md)
- [Operations](../operations.md)
