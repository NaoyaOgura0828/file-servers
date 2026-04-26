# How-to: AWS CDK デプロイ

`infra/cdk/` の AWS リソース (IAM Role / CloudWatch Dashboard) を更新する手順。

## 目的

CDK スタック (`fs-prod-iam-role` / `fs-prod-cloudwatch-dashboard`) の変更を AWS に反映する。

## 前提条件

- 管理ホストで AWS CLI v2 + SSO ログイン済 (`aws sso login --profile FileServers`)
- Node.js 22+
- アカウント `856221042201` / リージョン `ap-northeast-1` (CDK Bootstrap 済)

## 入力情報

- 環境: `dev` または `prod` (`-c env=...` で指定)
- 対象スタック: 個別指定 or `--all`

## 手順

### 1. 依存関係の同期

```bash
cd infra/cdk
npm install
```

### 2. 差分確認 (デプロイ前必須)

```bash
npx cdk diff -c env=prod --all --profile FileServers
```

> [!IMPORTANT]
> 出力に **意図しない置換 (Replacement)** が含まれていないか必ず確認する。IAM Role や Dashboard の論理 ID 変更はリソース再作成を引き起こし、ハイブリッドアクティベーションが切れる。

### 3. テスト実行

```bash
npx tsc --noEmit
npm test
```

22 件全て PASS することを確認。

### 4. デプロイ

```bash
# 全スタック
npx cdk deploy -c env=prod --all --exclusively --profile FileServers

# 個別 (推奨: 影響範囲を限定)
npx cdk deploy fs-prod-iam-role -c env=prod --exclusively --profile FileServers
npx cdk deploy fs-prod-cloudwatch-dashboard -c env=prod --exclusively --profile FileServers
```

`--exclusively` を必ず付ける (依存スタックの巻き込みを防止)。

### 5. 検証

```bash
# diff が no changes を返すことを確認
npx cdk diff -c env=prod --all --profile FileServers
# 期待出力: ✨  Number of stacks with differences: 0

# AWS Console / CLI 側で確認
aws iam get-role --role-name SSMCloudWatchAgentRole --profile FileServers
aws cloudwatch list-dashboards --profile FileServers --region ap-northeast-1
```

## 期待結果

- すべてのスタックが `UPDATE_COMPLETE` または `CREATE_COMPLETE`
- `cdk diff` で no changes
- ハイブリッドアクティベーションが引き続き Online (CloudWatch メトリクス継続)

## 失敗時対応

### CHANGE_SET レビューでロールバック

```bash
npx cdk deploy <stack> -c env=prod --no-execute --profile FileServers
# CloudFormation コンソールで ChangeSet を確認 → 問題なければ Execute、問題あれば Cancel
```

### スタック更新失敗時のリトライ

CloudFormation の自動ロールバックが完了したら再度 `cdk deploy`。

### 物理リソースが残ってスタックだけ消えた場合

[ADR-001 (CFn → CDK 移行)](../decisions/ADR-001-cfn-to-cdk-migration.md) の手順を参考に `cdk import` で再取り込み。

## ロールバック

```bash
git checkout <previous-commit>
cd infra/cdk
npm install
npx cdk deploy -c env=prod --all --exclusively --profile FileServers
```

> [!CAUTION]
> リソース置換 (Replacement) を伴うロールバックは、CloudWatch Dashboard 等が一時的に消える可能性がある。本番影響を考慮する場合は AWS Console で個別操作するほうが安全。

## 注意事項

- `cdk.context.json` は **必ずコミット**する (lookup の決定性保証)
- IAM Role 名 `SSMCloudWatchAgentRole` の物理名は変更しない (ハイブリッドアクティベーション登録に依存)
- CloudWatch Dashboard 名 `FileServer` / `BackupServer` も変更しない (cfn-import 由来の物理名)

## 関連

- [infra/cdk/README.md](../../infra/cdk/README.md)
- [ADR-001: CFn → CDK 移行](../decisions/ADR-001-cfn-to-cdk-migration.md)
