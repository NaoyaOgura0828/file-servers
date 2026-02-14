# CloudFormation テンプレート

オンプレミスファイルサーバー監視システムのAWSリソースをデプロイするためのCloudFormationテンプレート集。

## ディレクトリ構成

```
cloudformation/
├── README.md                    # このファイル
├── create_stacks.sh             # スタック新規作成スクリプト
├── exec_change_sets.sh          # スタック更新スクリプト（Change Set使用）
├── delete_stacks.sh             # スタック削除スクリプト
└── templates/                   # テンプレートディレクトリ
    ├── iam-role/
    │   └── iam-role.yml         # IAMロールテンプレート
    └── cloudwatch-dashboard/
        └── cloudwatch-dashboard.yml  # CloudWatchダッシュボードテンプレート
```

## テンプレート一覧

### 1. IAM Role (`iam-role`)

**ファイル**: `templates/iam-role/iam-role.yml`

**目的**: SSM Managed InstancesとCloudWatch Agent用のIAMロールを作成

**作成されるリソース**:
- IAMロール: `SSMCloudWatchAgentRole`
  - マネージドポリシー:
    - `AmazonSSMManagedInstanceCore`: SSM基本機能
    - `CloudWatchAgentServerPolicy`: CloudWatchメトリクス・ログ送信

**用途**: ハイブリッドアクティベーション作成時に使用

**依存関係**: なし（最初にデプロイ）

### 2. CloudWatch Dashboard (`cloudwatch-dashboard`)

**ファイル**: `templates/cloudwatch-dashboard/cloudwatch-dashboard.yml`

**目的**: FileServerとBackupServerの監視ダッシュボードを作成

**作成されるリソース**:
- CloudWatchダッシュボード: `FileServer`
  - 名前空間: `OnPremises/FileServer`
- CloudWatchダッシュボード: `BackupServer`
  - 名前空間: `OnPremises/BackupServer`

**監視項目**:
- CPU使用状況（Idle、IO Wait）
- メモリ使用率・使用量
- Swap使用率
- ディスク使用率・容量・inode
- ディスクI/O（データ量、操作回数、処理時間）
- ネットワーク（データ量、パケット数、エラー/ドロップ）

**パラメータ**:
- `Environment`: 環境名（Production/Development/Staging）
  - デフォルト: Production

**出力**:
- `FileServerDashboardURL`: FileServerダッシュボードのURL
- `BackupServerDashboardURL`: BackupServerダッシュボードのURL

**前提条件**:
- CloudWatch Agentが各サーバーにインストール済み
- メトリクスが送信されている（名前空間: `OnPremises/FileServer`, `OnPremises/BackupServer`）

**依存関係**: なし（IAMロールとは独立）

## デプロイ方法

### 前提条件

1. AWS CLIがインストール済み
2. プロファイルが設定済み
   - プロファイル名: `FileServers`
   - リージョン: `ap-northeast-1`
3. 適切なIAM権限
   - CloudFormation操作権限
   - IAM作成権限（iam-roleテンプレート使用時）
   - CloudWatch Dashboard作成権限（cloudwatch-dashboardテンプレート使用時）

### スクリプトの使い方

#### 1. 新規スタック作成

`create_stacks.sh` を編集して、作成したいスタックを有効化します。

```bash
# create_stacks.sh の編集例
#####################################
# 構築対象リソース
#####################################
# IAMロールスタックの作成
create_stack iam-role

# CloudWatchダッシュボードスタックの作成
create_stack cloudwatch-dashboard
```

スクリプトを実行:

```bash
cd /home/NaoyaOgura/file-servers/cloudformation/
./create_stacks.sh
```

#### 2. スタック更新（Change Set使用）

`exec_change_sets.sh` を編集して、更新したいスタックを有効化します。

```bash
# exec_change_sets.sh の編集例
#####################################
# 変更対象リソース
#####################################
# IAMロールスタックの変更セット実行
# exec_change_set iam-role

# CloudWatchダッシュボードスタックの変更セット実行
exec_change_set cloudwatch-dashboard
```

スクリプトを実行:

```bash
cd /home/NaoyaOgura/file-servers/cloudformation/
./exec_change_sets.sh
```

スクリプトは以下を実行します:
1. Change Setを作成
2. 変更内容を表示
3. 実行確認
4. Change Setを実行またはキャンセル

#### 3. スタック削除

`delete_stacks.sh` を編集して、削除したいスタックを有効化します。

```bash
# delete_stacks.sh の編集例
#####################################
# 削除対象リソース
#####################################
# IAMロールスタックの削除
# delete_stack iam-role

# CloudWatchダッシュボードスタックの削除
delete_stack cloudwatch-dashboard
```

スクリプトを実行:

```bash
cd /home/NaoyaOgura/file-servers/cloudformation/
./delete_stacks.sh
```

**警告**: 削除は取り消せません。実行前に確認メッセージが表示されます。

### AWS CLIで直接実行

スクリプトを使わずに、AWS CLIで直接操作することもできます。

#### 新規作成

```bash
aws cloudformation create-stack \
    --stack-name <STACK_NAME> \
    --template-body file://templates/<SERVICE_NAME>/<SERVICE_NAME>.yml \
    --capabilities CAPABILITY_NAMED_IAM \
    --profile FileServers \
    --region ap-northeast-1
```

#### 更新（Change Set）

```bash
# Change Set作成
aws cloudformation create-change-set \
    --stack-name <STACK_NAME> \
    --change-set-name <CHANGE_SET_NAME> \
    --template-body file://templates/<SERVICE_NAME>/<SERVICE_NAME>.yml \
    --capabilities CAPABILITY_NAMED_IAM \
    --profile FileServers \
    --region ap-northeast-1

# Change Set確認
aws cloudformation describe-change-set \
    --stack-name <STACK_NAME> \
    --change-set-name <CHANGE_SET_NAME> \
    --profile FileServers \
    --region ap-northeast-1

# Change Set実行
aws cloudformation execute-change-set \
    --stack-name <STACK_NAME> \
    --change-set-name <CHANGE_SET_NAME> \
    --profile FileServers \
    --region ap-northeast-1
```

#### 削除

```bash
aws cloudformation delete-stack \
    --stack-name <STACK_NAME> \
    --profile FileServers \
    --region ap-northeast-1
```

## デプロイ順序

推奨されるデプロイ順序:

1. **IAM Role** (`iam-role`)
   - ハイブリッドアクティベーション作成時に必要
   - 他のリソースとは独立

2. **CloudWatch Dashboard** (`cloudwatch-dashboard`)
   - メトリクスが送信されていれば、いつでもデプロイ可能
   - IAMロールとは独立

依存関係がないため、任意の順序でデプロイできます。

## デプロイ例（初回セットアップ）

### Step 1: IAMロールの作成

```bash
cd /home/NaoyaOgura/file-servers/cloudformation/

# create_stacks.sh を編集
vi create_stacks.sh
# create_stack iam-role のコメントを解除

# 実行
./create_stacks.sh
```

作成されるIAMロール: `SSMCloudWatchAgentRole`

### Step 2: ハイブリッドアクティベーションの作成

```bash
cd /home/NaoyaOgura/file-servers/shellscript/
./create_activation.sh
```

### Step 3: CloudWatch Agentのセットアップ

各サーバーで実行:

```bash
cd /home/NaoyaOgura/file-servers/shellscript/
sudo ./setup_cloudwatch_agent.sh config/FileServer.conf
sudo ./setup_cloudwatch_agent.sh config/BackupServer.conf
```

### Step 4: CloudWatchダッシュボードの作成

```bash
cd /home/NaoyaOgura/file-servers/cloudformation/

# create_stacks.sh を編集
vi create_stacks.sh
# create_stack cloudwatch-dashboard のコメントを解除

# 実行
./create_stacks.sh
```

### Step 5: ダッシュボードの確認

スタック作成完了後、出力されるURLにアクセス:

```bash
# スタック情報を取得
aws cloudformation describe-stacks \
    --stack-name cloudwatch-dashboard \
    --profile FileServers \
    --region ap-northeast-1 \
    --query "Stacks[0].Outputs"
```

または、AWSコンソールで確認:
1. CloudWatchコンソールを開く
2. 左側メニューから「ダッシュボード」を選択
3. 「FileServer」または「BackupServer」をクリック

## トラブルシューティング

### スタック作成に失敗する

**症状**: `CREATE_FAILED` ステータス

**原因と対処法**:

1. **テンプレートの構文エラー**
   ```bash
   aws cloudformation validate-template \
       --template-body file://templates/<SERVICE_NAME>/<SERVICE_NAME>.yml \
       --profile FileServers
   ```

2. **IAM権限不足**
   - 使用しているIAMユーザー/ロールに必要な権限があるか確認
   - `iam-role` テンプレートの場合: `iam:CreateRole`, `iam:AttachRolePolicy` など

3. **リソース名の重複**
   - 同じ名前のリソースが既に存在する場合は削除するか、テンプレートを変更

**イベントログの確認**:
```bash
aws cloudformation describe-stack-events \
    --stack-name <STACK_NAME> \
    --profile FileServers \
    --region ap-northeast-1 \
    --max-items 10
```

### Change Setが失敗する

**症状**: `FAILED` ステータス、または「変更がない」というメッセージ

**対処法**:

1. **変更がない場合**
   - テンプレートが現在のスタックと同じ内容の場合、Change Setは作成されません
   - これは正常な動作です

2. **Change Setの削除**
   ```bash
   aws cloudformation delete-change-set \
       --stack-name <STACK_NAME> \
       --change-set-name <CHANGE_SET_NAME> \
       --profile FileServers
   ```

### ダッシュボードにデータが表示されない

**症状**: ダッシュボードは作成されたが、グラフにデータがない

**原因と対処法**:

1. **CloudWatch Agentが起動していない**
   ```bash
   sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
       -a status \
       -m onPremise
   ```

2. **メトリクスが送信されていない**
   ```bash
   # メトリクスの確認
   aws cloudwatch list-metrics \
       --namespace OnPremises/FileServer \
       --profile FileServers \
       --region ap-northeast-1
   ```

3. **名前空間が一致していない**
   - CloudWatch Agentの設定: `OnPremises/FileServer`
   - ダッシュボードの設定: `OnPremises/FileServer`
   - 大文字小文字も含めて完全一致する必要があります

4. **メトリクス名が一致していない**
   - CloudWatch Agent設定ファイル (`/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json`) の `rename` フィールドを確認
   - 例: `"rename": "CPU_IDLE"` → ダッシュボードでも `CPU_IDLE` を使用

### スクリプトが実行できない

**症状**: `Permission denied`

**対処法**:
```bash
chmod +x create_stacks.sh exec_change_sets.sh delete_stacks.sh
```

### jqコマンドがない

`exec_change_sets.sh` は `jq` を使用して変更内容を整形表示します。

**インストール**:
```bash
# Amazon Linux / RHEL / CentOS
sudo yum install -y jq

# Ubuntu / Debian
sudo apt-get install -y jq

# macOS
brew install jq
```

`jq` がない場合でも、変更内容はJSON形式で表示されます。

## スタックの命名規則

スタック名はサービス名（ディレクトリ名）と同じになります:

| サービス名 | スタック名 | テンプレートパス |
|-----------|----------|----------------|
| iam-role | iam-role | templates/iam-role/iam-role.yml |
| cloudwatch-dashboard | cloudwatch-dashboard | templates/cloudwatch-dashboard/cloudwatch-dashboard.yml |

新しいテンプレートを追加する場合も、この規則に従ってください:

```
templates/
└── <SERVICE_NAME>/
    └── <SERVICE_NAME>.yml
```

## カスタマイズ

### AWSプロファイルの変更

各スクリプトの先頭でプロファイルを変更できます:

```bash
# AWSプロファイル設定
AWS_PROFILE="FileServers"  # ← 変更する
```

### パラメータの指定

パラメータを持つテンプレートの場合、スクリプトを修正してパラメータを渡せます:

```bash
# create_stacks.sh の create_stack 関数に --parameters を追加
aws cloudformation create-stack \
    --stack-name ${STACK_NAME} \
    --template-body file://${TEMPLATE_PATH} \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters ParameterKey=Environment,ParameterValue=Production \
    --profile ${AWS_PROFILE}
```

### タグの追加

スタックにタグを追加する場合:

```bash
aws cloudformation create-stack \
    --stack-name ${STACK_NAME} \
    --template-body file://${TEMPLATE_PATH} \
    --capabilities CAPABILITY_NAMED_IAM \
    --tags Key=Project,Value=FileServers Key=Environment,Value=Production \
    --profile ${AWS_PROFILE}
```

## ベストプラクティス

1. **Change Setを活用**
   - 本番環境では必ずChange Setで変更内容を確認してから実行
   - `exec_change_sets.sh` を使用

2. **バージョン管理**
   - テンプレートはGitで管理
   - 変更履歴を残す

3. **パラメータの外部化**
   - 環境ごとに異なる値はパラメータ化
   - デフォルト値を設定

4. **出力の活用**
   - 作成されたリソースのARNやURLを出力
   - 他のスタックから参照可能にする（Export）

5. **タグ付け**
   - リソースにタグを付けて管理しやすくする
   - コスト配分、環境識別に活用

6. **ドリフト検出**
   - 定期的にドリフト検出を実行
   - 手動変更がないか確認

## 参考資料

- [AWS CloudFormation User Guide](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/)
- [AWS CloudFormation Template Reference](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/template-reference.html)
- [Change Sets - AWS CloudFormation](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-updating-stacks-changesets.html)
- [CloudWatch Dashboards - AWS Documentation](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch_Dashboards.html)

## サポート

問題が発生した場合:

1. CloudFormationイベントログを確認
2. CloudWatch Logsでエラーログを確認
3. AWSサポートに問い合わせ

---

**最終更新**: 2026-02-14
