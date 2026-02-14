# shellscript

オンプレミスファイルサーバーをAWSに統合するためのセットアップスクリプト集。

## 前提条件

- AWS CLI がインストール・設定済み（プロファイル: `FileServers`）
- sudo 権限
- インターネット接続（AWS エンドポイントへの HTTPS 通信）

## クイックスタート（完全なセットアップ例）

以下は、オンプレミスファイルサーバーでrsyncログをCloudWatchに送信する完全なセットアップ例です。

```bash
# 1. SSMハイブリッドアクティベーションを作成（管理端末で実行）
cd /home/NaoyaOgura/file-servers/shellscript
./create_activation.sh FileServer

# 2. 対象サーバーでSSM Agentを登録（生成されたドキュメント参照）
# （手順は生成された How_to_Activation_for_FileServer.md を参照）

# 3. 設定ファイルを確認・編集（必要に応じて）
cat config/FileServer.conf
# 必要に応じて編集: vi config/FileServer.conf

# 4. CloudWatch Agentをセットアップ（設定ファイルを使用）
sudo ./setup_cloudwatch_agent.sh config/FileServer.conf

# 5. ログローテーション設定をインストール
sudo ./install_logrotate.sh

# 6. rsyncスクリプトの動作確認
sudo ./rsync_fileserver.sh
sudo tail -f /var/log/rsync/rsync_fileserver.log

# 7. crontabに定期実行を設定
crontab -e
# 以下を追加（毎時0分に実行）:
# 0 * * * * sudo /home/NaoyaOgura/file-servers/shellscript/rsync_fileserver.sh
```

## ディレクトリ構成

```
shellscript/
├── config/                         # 設定ファイル
│   ├── sample.conf                 # CloudWatch Agent設定のサンプル
│   ├── FileServer.conf             # FileServer用のCloudWatch Agent設定
│   ├── BackupServer.conf           # BackupServer用のCloudWatch Agent設定
│   └── rsync_logrotate.conf        # rsyncログのローテーション設定
├── create_activation.sh            # SSMハイブリッドアクティベーション作成
├── setup_cloudwatch_agent.sh       # CloudWatch Agentセットアップ
├── install_logrotate.sh            # ログローテーション設定インストール
├── rsync_fileserver.sh             # rsyncバックアップスクリプト
└── README.md                       # このファイル
```

## スクリプト一覧

### 1. create_activation.sh

SSM ハイブリッドアクティベーションを作成し、オンプレミスサーバーを AWS Systems Manager のマネージドインスタンスとして登録する準備を行う。

**使用方法:**

```bash
./create_activation.sh <サーバー名>
```

**処理内容:**

1. IAM ロール（`SSMCloudWatchAgentRole`）の ARN を取得
2. SSM ハイブリッドアクティベーションを作成
3. Activation ID / Code を含む JSON ファイルを出力
4. 対象サーバーでの登録手順をまとめたマークダウンドキュメントを生成

**出力ファイル:**

| ファイル | 内容 |
|---|---|
| `activation-<サーバー名>-<タイムスタンプ>.json` | アクティベーション情報（ID, Code） |
| `How_to_Activation_for_<サーバー名>.md` | サーバー側での登録手順書 |

---

### 2. setup_cloudwatch_agent.sh

CloudWatch Agent をインストール・設定し、メトリクスとログの収集を開始する。

**前提:** `create_activation.sh` で作成したアクティベーションを使い、対象サーバーに SSM Agent を登録済みであること。

**使用方法:**

```bash
sudo ./setup_cloudwatch_agent.sh <設定ファイルパス>
```

**引数:**

| 引数 | 説明 | 必須 |
|------|------|------|
| `<設定ファイルパス>` | 設定ファイルのパス | ✓ |

**オプション:**

| オプション | 説明 |
|-----------|------|
| `-h, --help` | ヘルプメッセージを表示 |

**例:**

```bash
# 設定ファイルを指定して実行
sudo ./setup_cloudwatch_agent.sh config/FileServer.conf

# 絶対パスでも指定可能
sudo ./setup_cloudwatch_agent.sh /home/user/file-servers/shellscript/config/FileServer.conf
```

**前提:** `create_activation.sh` で作成したアクティベーションを使い、対象サーバーに SSM Agent を登録済みであること。

**設定ファイルについて:**

すべての設定は設定ファイルで管理します。これにより、設定の再現性とバージョン管理が容易になります。

**設定ファイルの形式（例: `config/FileServer.conf`）:**

```bash
# サーバー名（必須）
SERVER_NAME="FileServer"

# 監視するマウントポイント（スペース区切りで複数指定可能）
MOUNTPOINTS="/mnt/fileserver /mnt/fileserver-backup"

# CloudWatchで監視するカスタムログファイル（スペース区切りで複数指定可能）
LOG_PATHS="/var/log/rsync/rsync_fileserver.log:rsync-backup"
```

設定ファイルのサンプルは `config/sample.conf` を参照してください。

**カスタムログパスについて:**

- 設定ファイルの `LOG_PATHS` で追加したログファイルは、指定されたロググループに収集されます
- 形式: `<ファイルパス>:<ログストリーム名>`
  - 例: `/var/log/rsync/rsync.log:rsync-backup`
  - ログストリーム名を省略した場合は、ファイル名から自動生成されます
- 指定したログファイルが存在しない場合は警告が表示されますが、設定は継続されます

**処理内容:**

| Step | 内容 |
|------|------|
| 1 | CloudWatch Agent のインストール（未インストール時のみ） |
| 2 | JSON 設定ファイルの作成 |
| 3 | systemd サービスファイルの設定（IMDS 無効化含む） |
| 4 | `/root/.aws/config` の作成 |
| 5 | `common-config.toml` の作成（認証情報設定） |
| 6 | SSM Parameter Store への設定バックアップ |
| 7 | CloudWatch Agent への設定適用・起動 |
| 8 | ステータス確認 |

**収集メトリクス（名前空間: `OnPremises/<サーバー名>`）:**

| カテゴリ | メトリクス名 | 内容 | 用途 |
|---------|-------------|------|------|
| **CPU** | `CPU_IDLE` | CPU アイドル率 | CPU負荷の監視 |
| | `CPU_IOWAIT` | CPU I/O 待ち率 | ディスクI/Oボトルネックの検出 |
| **メモリ** | `MEM_USED_PERCENT` | メモリ使用率 | メモリ使用状況の監視 |
| | `MEM_AVAILABLE` | 利用可能メモリ | 空きメモリ容量 |
| | `MEM_USED` | 使用中メモリ | 使用メモリ量 |
| **ディスク容量** | `DISK_USED_PERCENT` | ディスク使用率 | ディスク容量の監視 |
| | `DISK_FREE` | ディスク空き容量 | 残り容量の確認 |
| | `DISK_USED` | ディスク使用量 | 使用容量の確認 |
| | `DISK_INODES_USED` | 使用中inode数 | ファイル数の監視 |
| | `DISK_INODES_FREE` | 空きinode数 | inode枯渇の検出 |
| | `DISK_INODES_TOTAL` | 総inode数 | inode上限の確認 |
| **ディスクI/O** | `DISKIO_READ_BYTES` | ディスク読み込みバイト数/秒 | 読み込み性能の監視 |
| | `DISKIO_WRITE_BYTES` | ディスク書き込みバイト数/秒 | 書き込み性能の監視 |
| | `DISKIO_READS` | 読み込みIOPS | 読み込み頻度の監視 |
| | `DISKIO_WRITES` | 書き込みIOPS | 書き込み頻度の監視 |
| | `DISKIO_READ_TIME` | 読み込み待ち時間 | 読み込み遅延の検出 |
| | `DISKIO_WRITE_TIME` | 書き込み待ち時間 | 書き込み遅延の検出 |
| | `DISKIO_IO_TIME` | 総I/O時間 | 総合的なI/O負荷 |
| **ネットワーク** | `NET_BYTES_SENT` | 送信バイト数/秒 | 送信帯域の監視 |
| | `NET_BYTES_RECV` | 受信バイト数/秒 | 受信帯域の監視 |
| | `NET_PACKETS_SENT` | 送信パケット数/秒 | 送信負荷の監視 |
| | `NET_PACKETS_RECV` | 受信パケット数/秒 | 受信負荷の監視 |
| | `NET_ERR_IN` | 受信エラー | ネットワーク障害の検出 |
| | `NET_ERR_OUT` | 送信エラー | ネットワーク障害の検出 |
| | `NET_DROP_IN` | 受信ドロップ | パケットロスの検出 |
| | `NET_DROP_OUT` | 送信ドロップ | パケットロスの検出 |
| **Swap** | `SWAP_USED_PERCENT` | Swap使用率 | メモリ不足の検出 |
| | `SWAP_FREE` | Swap空き容量 | Swap残量の確認 |
| | `SWAP_USED` | Swap使用量 | Swap使用状況 |

**監視対象ディスク:** デフォルトで `/` を監視。追加のマウントポイント（例: `/mnt/fileserver`, `/mnt/backup`）を設定ファイルで指定可能。

**ファイルサーバー特有の監視ポイント:**
- **ディスクI/O**: rsync実行時やSambaアクセス時のボトルネック検出に重要
- **ネットワーク**: ファイル転送速度の監視とネットワーク障害の早期検出
- **inode**: 小さいファイルが多い環境でinode枯渇を事前に検出

**収集ログ（ロググループ: `/onprem/<サーバー名>`）:**

| ログストリーム | ソース | 監視対象 |
|---|---|---|
| `smbd` | `/var/log/samba/log.smbd` | Samba 認証異常、アクセスエラー |
| `nmbd` | `/var/log/samba/log.nmbd` | NetBIOS 名前解決異常 |
| `messages` | `/var/log/messages` | systemd イベント、カーネル I/O、OOM、NIC 障害 |
| カスタム | `--log-path` で指定 | ユーザー指定のログファイル（rsyncログなど） |

---

### 3. install_logrotate.sh

rsyncログのローテーション設定をシステムにインストールする。

**使用方法:**

```bash
sudo ./install_logrotate.sh
```

**処理内容:**

1. 設定ファイル（`config/rsync_logrotate.conf`）の存在確認
2. インストール内容の表示と確認プロンプト
3. `/etc/logrotate.d/rsync_fileserver` への設定コピー
4. パーミッション設定（644）
5. 構文チェック
6. ログディレクトリの確認・作成
7. インストール結果の表示

**ログローテーション設定の内容:**

| 項目 | 設定値 | 説明 |
|------|--------|------|
| 頻度 | `daily` | 日次でローテーション |
| 保持世代数 | `30` | 30日分のログを保持 |
| 圧縮 | `compress` + `delaycompress` | 古いログは圧縮、最新1世代は無圧縮 |
| 空ファイル | `notifempty` | 空のログファイルはローテートしない |
| ファイル権限 | `0644 root:root` | 新しいログファイルの権限 |
| ローテート後処理 | CloudWatch Agent再読み込み | ログファイル切り替えを通知 |

**例:**

```bash
# ログローテーション設定のインストール
sudo ./install_logrotate.sh

# インストール後の確認
sudo logrotate -d /etc/logrotate.d/rsync_fileserver
```

**注意:**
- このスクリプトはsudo権限で実行する必要があります
- rsyncログを使用する場合に実行します（オプション）

---

### 4. rsync_fileserver.sh

rsyncを使用してファイルサーバーのバックアップを実行する。

**使用方法:**

```bash
sudo ./rsync_fileserver.sh
```

**処理内容:**

1. root権限チェック
2. ロックファイルによる重複実行の防止
3. ソース・宛先ディレクトリの存在確認
4. rsyncの実行（完全同期）
5. 実行時間と終了ステータスの記録
6. ログファイルへの詳細な実行記録

**バックアップ設定:**

| 項目 | 設定値 |
|------|--------|
| ソース | `/mnt/fileserver/` |
| 宛先 | `/mnt/fileserver-backup/` |
| ログファイル | `/var/log/rsync/rsync_fileserver.log` |
| ロックファイル | `/var/run/rsync_fileserver.lock` |

**rsyncオプション:**

- `-a`: アーカイブモード（パーミッション、タイムスタンプ等を保持）
- `-h`: 人間が読みやすい形式
- `-v`: 詳細表示
- `--progress`: 進捗表示
- `--delete`: 宛先にのみ存在するファイルを削除（完全同期）
- `--stats`: 統計情報を表示

**特徴:**

1. **ロック機構**: 重複実行を防止。既に実行中の場合はエラーで終了
2. **エラーハンドリング**: ソース・宛先の存在確認、rsync失敗時の記録
3. **実行時間記録**: 開始時刻、終了時刻、経過時間をログに記録
4. **完全同期**: `--delete`オプションでソースと宛先を完全に同期

**crontab設定例:**

```bash
# 毎時0分に実行
0 * * * * sudo /home/NaoyaOgura/file-servers/shellscript/rsync_fileserver.sh
```

**ログの確認:**

```bash
# リアルタイムでログを確認
sudo tail -f /var/log/rsync/rsync_fileserver.log

# 実行履歴を確認
sudo grep "rsync開始\|rsync終了" /var/log/rsync/rsync_fileserver.log

# 最新の実行結果を確認
sudo tail -50 /var/log/rsync/rsync_fileserver.log
```

**注意:**
- このスクリプトはsudo権限で実行する必要があります
- 実行中は別のインスタンスが起動できません（ロック機構）
- ログファイルは`install_logrotate.sh`でローテーション設定することを推奨

---

## rsyncログのCloudWatch監視設定

rsyncのログを固定ファイルに出力し、CloudWatchで監視する場合は以下の手順を実行してください。

### 1. ログローテーション設定のインストール

インストールスクリプトを使用して、ログローテーション設定をシステムにインストールします。

```bash
# ログローテーション設定のインストール
sudo ./install_logrotate.sh
```

スクリプトが以下の処理を自動的に実行します：
- 設定ファイルを `/etc/logrotate.d/rsync_fileserver` にコピー
- パーミッション設定（644）
- 構文チェック
- ログディレクトリの確認・作成

**ログローテーション設定の内容:**
- 日次でローテーション
- 30日分のログを保持
- 古いログは圧縮（`.gz`）
- 空のログファイルはローテートしない
- CloudWatch Agentへの自動通知

### 2. 設定ファイルにログパスを追加

設定ファイル（例: `config/FileServer.conf`）を編集して、rsyncログを追加します。

```bash
# 設定ファイルを編集
vi config/FileServer.conf
```

以下のように `LOG_PATHS` を設定：

```bash
LOG_PATHS="/var/log/rsync/rsync_fileserver.log:rsync-backup"
```

### 3. CloudWatch Agentをセットアップ

```bash
# 設定ファイルを指定してセットアップ
sudo /home/NaoyaOgura/file-servers/shellscript/setup_cloudwatch_agent.sh config/FileServer.conf
```

### 4. rsyncスクリプトの動作確認

```bash
# 手動実行でログが正しく出力されるか確認
~/rsync_fileserver.sh

# ログファイルの確認
sudo tail -f /var/log/rsync/rsync_fileserver.log
```

### 5. CloudWatch Logsでの確認

AWS CloudWatchコンソールで以下を確認：
- ロググループ: `/onprem/BackupServer`
- ログストリーム: `rsync-backup`

rsyncの実行開始時刻、プロセスID、転送されたファイルの詳細が記録されます。

## 新規サーバーの追加方法

新しいサーバーを監視対象に追加する場合は、以下の手順で設定ファイルを作成します。

```bash
# 1. サンプル設定ファイルをコピー
cd /home/NaoyaOgura/file-servers/shellscript
cp config/sample.conf config/NewServer.conf

# 2. 設定ファイルを編集
vi config/NewServer.conf

# 3. 必要な項目を設定
#    - SERVER_NAME: サーバー名を設定
#    - MOUNTPOINTS: 監視するマウントポイントを設定
#    - LOG_PATHS: 監視するログファイルを設定

# 4. CloudWatch Agentをセットアップ
sudo ./setup_cloudwatch_agent.sh config/NewServer.conf
```

**設定例（Webサーバーの場合）:**

```bash
SERVER_NAME="WebServer"
MOUNTPOINTS="/var/www"
LOG_PATHS="/var/log/httpd/access_log:apache-access /var/log/httpd/error_log:apache-error"
```

## 実行順序

```
1. create_activation.sh  （管理端末で実行）
        ↓
   対象サーバーで SSM Agent を登録（生成されたドキュメント参照）
        ↓
2. 設定ファイルの作成・編集（config/*.conf）
        ↓
3. setup_cloudwatch_agent.sh <設定ファイル> （対象サーバーで実行）
        ↓
4. install_logrotate.sh （rsyncログのローテーション設定）
        ↓
5. rsync_fileserver.sh の手動実行テスト
        ↓
6. crontabに rsync_fileserver.sh を登録（定期実行）
```

---

## メトリクスの詳細説明と活用方法

### ディスクI/Oメトリクス（重要度：高）

ファイルサーバーの性能ボトルネックを検出する最重要メトリクスです。

| メトリクス | 正常値の目安 | アラート推奨値 | 説明 |
|-----------|------------|--------------|------|
| `DISKIO_READ_BYTES`<br>`DISKIO_WRITE_BYTES` | 用途により変動 | - | rsync実行時は急増。Sambaアクセス時の転送速度を確認 |
| `DISKIO_READS`<br>`DISKIO_WRITES` | < 500 IOPS | > 1000 IOPS | 高い場合はディスクがボトルネックの可能性 |
| `DISKIO_READ_TIME`<br>`DISKIO_WRITE_TIME` | < 10ms | > 50ms | 遅延が大きい場合はディスク性能の問題 |

**活用方法:**
- rsyncの実行タイミングと`DISKIO_WRITE_BYTES`の相関を確認
- `CPU_IOWAIT`と`DISKIO_*_TIME`が同時に高い場合、ディスクがボトルネック
- 定常的にIOPSが高い場合、SSD化を検討

### ネットワークメトリクス（重要度：高）

Sambaでのファイル転送速度とネットワーク障害を監視します。

| メトリクス | 正常値の目安 | アラート推奨値 | 説明 |
|-----------|------------|--------------|------|
| `NET_BYTES_SENT`<br>`NET_BYTES_RECV` | 用途により変動 | - | ファイル転送時の帯域使用状況を確認 |
| `NET_ERR_IN`<br>`NET_ERR_OUT` | 0 | > 0 | ネットワークエラーが発生している場合は調査 |
| `NET_DROP_IN`<br>`NET_DROP_OUT` | 0 | > 10/秒 | パケットロスが発生している場合は調査 |

**活用方法:**
- Sambaアクセス時の転送速度（Bytes/秒）をベースライン化
- ネットワークエラー・ドロップが発生した場合、スイッチ/ケーブルを確認
- 1Gbps = 125MB/s、10Gbps = 1250MB/sと比較して帯域使用率を算出

### inodeメトリクス（重要度：中）

小さいファイルが多い環境でディスク容量が残っていてもファイルを作成できなくなる問題を検出します。

| メトリクス | 正常値の目安 | アラート推奨値 | 説明 |
|-----------|------------|--------------|------|
| `DISK_INODES_USED` / `DISK_INODES_TOTAL` | < 80% | > 90% | inode使用率。90%超えたら古いファイルの削除を検討 |

**活用方法:**
- ディスク容量（`DISK_USED_PERCENT`）は十分なのにファイル作成エラーが出る場合、inode枯渇を疑う
- 小さいファイルが大量にある場合は定期的に監視

### Swapメトリクス（重要度：中）

メモリ不足の早期検出に使用します。

| メトリクス | 正常値の目安 | アラート推奨値 | 説明 |
|-----------|------------|--------------|------|
| `SWAP_USED_PERCENT` | 0% | > 10% | Swapが使われ始めたら性能低下のサイン |

**活用方法:**
- Swapが使われ始めたらメモリ増設を検討
- `MEM_AVAILABLE`と併せて監視し、メモリ不足の兆候を早期検出

### 推奨アラート設定

以下のメトリクスにCloudWatch Alarmを設定することを推奨します。

| 優先度 | メトリクス | 条件 | 説明 |
|-------|-----------|------|------|
| 🔴 高 | `DISK_USED_PERCENT` | > 90% | ディスク容量逼迫 |
| 🔴 高 | `DISK_INODES_USED` / `DISK_INODES_TOTAL` | > 90% | inode枯渇警告 |
| 🔴 高 | `MEM_USED_PERCENT` | > 90% | メモリ逼迫 |
| 🟡 中 | `SWAP_USED_PERCENT` | > 10% | メモリ不足の兆候 |
| 🟡 中 | `CPU_IOWAIT` | > 50% | ディスクI/O待ち時間が多い |
| 🟡 中 | `DISKIO_*_TIME` | > 50ms | ディスク遅延 |
| 🟢 低 | `NET_ERR_*` | > 0 | ネットワークエラー |
| 🟢 低 | `NET_DROP_*` | > 10/秒 | パケットロス |

### CloudWatch Dashboardの作成例

以下のメトリクスを組み合わせたダッシュボードを作成すると、ファイルサーバーの状態を一目で把握できます。

**グラフ1: システムリソース**
- `CPU_IOWAIT`（折れ線グラフ）
- `MEM_USED_PERCENT`（折れ線グラフ）
- `SWAP_USED_PERCENT`（折れ線グラフ）

**グラフ2: ディスク容量**
- `DISK_USED_PERCENT` per マウントポイント（折れ線グラフ）
- `DISK_FREE` per マウントポイント（折れ線グラフ）

**グラフ3: ディスクI/O**
- `DISKIO_READ_BYTES` + `DISKIO_WRITE_BYTES`（積み上げ面グラフ）
- `DISKIO_READS` + `DISKIO_WRITES`（積み上げ面グラフ）

**グラフ4: ネットワーク帯域**
- `NET_BYTES_SENT` + `NET_BYTES_RECV`（積み上げ面グラフ）

**グラフ5: エラー・異常**
- `NET_ERR_IN` + `NET_ERR_OUT`（折れ線グラフ）
- `NET_DROP_IN` + `NET_DROP_OUT`（折れ線グラフ）

