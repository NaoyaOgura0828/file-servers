# ADR-001: AWS CloudFormation を AWS CDK へ移行する

## Status

Accepted

## Context

- 当初の AWS インフラは `cloudformation/` 配下の YAML テンプレートと bash デプロイスクリプト群で管理していた
- 環境ごとの差分 (`Environment` parameter)、テスト容易性、リファクタリング耐性に欠けた
- `automate-financial-trade` プロジェクトで CDK v2 (TypeScript) の運用知見が蓄積されており、同等基準で扱える見込みだった
- 既存の物理リソース (`SSMCloudWatchAgentRole` IAM Role、`FileServer` / `BackupServer` の CloudWatch Dashboard) は稼働中で、削除・再作成は不可

## Decision

`infra/cdk/` に AWS CDK v2 (TypeScript) プロジェクトを新設し、既存 CloudFormation スタックを以下の手順で CDK 管理下へ移行する。

1. 既存 CFn テンプレートの全リソースに `DeletionPolicy: Retain` を付与して update-stack
2. 既存 CFn スタック (`iam-role`, `cloudwatch-dashboard`) を delete-stack (リソースは残存)
3. CDK スタック (`fs-prod-iam-role`, `fs-prod-cloudwatch-dashboard`) を `cdk import` で残存リソースから生成
4. `cdk diff` で no changes を確認、不要な `Retain` ポリシーを `cdk deploy` で除去

CDK スタックは AWS サービス種別ごと:
- `fs-prod-iam-role`: IAM Role (`SSMCloudWatchAgentRole`)
- `fs-prod-cloudwatch-dashboard`: CloudWatch Dashboard × 2

リソースの物理名 (RoleName / DashboardName) は **既存値を維持** する (ハイブリッドアクティベーションが Role 名を参照しているため)。dev 環境は規約準拠の名前 (`fs-dev-...`) に分岐。

## Alternatives Considered

| 案 | 却下理由 |
|---|---|
| Terraform へ移行 | 既に CDK の運用知見があり、再学習コスト不要 |
| CloudFormation のまま改善 | 環境差分の表現が `Conditions`/`Parameters` で煩雑、テストが困難 |
| 物理名を CDK 規約に変更 (`fs-prod-iam-role-ssm-cloudwatch-agent` 等) | ハイブリッドアクティベーション再登録が必要になり、運用停止が発生 |
| 既存 CFn スタックを残したまま新規 CDK で平行運用 | 同名リソースの衝突、責務不明瞭 |

## Consequences

### 利点

- 環境別 config (TypeScript) で dev / prod 差分を明示的に管理
- スタック分割を AWS サービス種別単位 (`iam-role.ts` / `cloudwatchDashboard.ts`) に固定し、追加・変更の見通しが良い
- Jest による 3 階層テスト (unit / integration / system) で 22 件のリグレッションガードを獲得
- `cdk import` の resource-mapping は `infra/cdk/import/*.json` に保存し、再現可能

### 欠点

- 物理名と CDK 命名規約の食い違い (prod は legacy 名、dev は規約名) が二重ルールとなる
- `cdk import` 操作には DeletionPolicy 経由の準備工程が必要で、手順が長い
- 既存 CDK 規約 (`{sys}-{env}-{service}`) と部分的に乖離

### 影響範囲

- 新規 IAM ロール / Dashboard 追加は CDK で行う
- 既存 CFn 配下のスクリプト群 (`cloudformation/*.sh`) は廃止
- 移行 runbook は本 ADR + [how-to/deploy-cdk.md](../how-to/deploy-cdk.md) に集約

## Related

- [infra/cdk/README.md](../../infra/cdk/README.md)
- [how-to/deploy-cdk.md](../how-to/deploy-cdk.md)
- グローバル skill: cfn-to-cdk-migration
