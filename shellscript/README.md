# shellscript

オンプレミスファイルサーバーをAWSに統合するためのセットアップスクリプト集。

## 前提条件

- AWS CLI がインストール・設定済み（プロファイル: `FileServers`）
- sudo 権限
- インターネット接続（AWS エンドポイントへの HTTPS 通信）

## スクリプト一覧

### 1. create_activation.sh

SSM ハイブリッドアクティベーションを作成し、オンプレミスサーバーを AWS Systems Manager のマネージドインスタンスとして登録する準備を行う。

**使用方法:**

```bash
sudo ./create_activation.sh <サーバー名>
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

**使用方法:**

```bash
sudo ./setup_cloudwatch_agent.sh <サーバー名>
```

**前提:** `create_activation.sh` で作成したアクティベーションを使い、対象サーバーに SSM Agent を登録済みであること。

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

| メトリクス名 | 内容 |
|---|---|
| `CPU_IDLE` | CPU アイドル率 |
| `CPU_IOWAIT` | CPU I/O 待ち率 |
| `MEM_USED_PERCENT` | メモリ使用率 |
| `MEM_AVAILABLE` | 利用可能メモリ |
| `MEM_USED` | 使用中メモリ |
| `DISK_USED_PERCENT` | ディスク使用率 |
| `DISK_FREE` | ディスク空き容量 |
| `DISK_USED` | ディスク使用量 |

**収集ログ（ロググループ: `/onprem/<サーバー名>`）:**

| ログストリーム | ソース | 監視対象 |
|---|---|---|
| `smbd` | `/var/log/samba/log.smbd` | Samba 認証異常、アクセスエラー |
| `nmbd` | `/var/log/samba/log.nmbd` | NetBIOS 名前解決異常 |
| `messages` | `/var/log/messages` | systemd イベント、カーネル I/O、OOM、NIC 障害 |

## 実行順序

```
1. create_activation.sh  （管理端末で実行）
        ↓
   対象サーバーで SSM Agent を登録（生成されたドキュメント参照）
        ↓
2. setup_cloudwatch_agent.sh （対象サーバーで実行）
```
