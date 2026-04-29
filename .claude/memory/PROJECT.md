---
name: file-servers project basics
description: file-servers リポジトリの SystemName / AWS アカウント / リージョン / プロファイルなど基本情報
type: project
updated: 2026-04-26
---

# File Servers プロジェクト基本情報

## 識別子

| 項目 | 値 |
|------|----|
| SystemName (`sys`) | `fs` |
| AWS アカウント ID | `856221042201` |
| リージョン | `ap-northeast-1` |
| AWS CLI プロファイル | `FileServers` |

**Why:** `infra/cdk/config/{dev,prod}.ts` および `naming.ts` の値、デプロイコマンドの `--profile` 指定、CFn 旧スクリプト (`cloudformation/*.sh`) の `AWS_PROFILE` で必須となる確定値。

**How to apply:**
- CDK config (`config/dev.ts`, `config/prod.ts`) の `account` / `region`、`naming.ts` の `SYS` を変更しない。
- デプロイ・差分確認コマンドには常に `--profile FileServers` を付ける。
- 新規スタック・リソース命名時は `fs-{env}-...` 形式 (cdk SKILL.md 準拠) を踏襲する。
- アカウント ID をハードコードする箇所が増えた場合は `config/` に集約する。

## IaC 構成

- IaC: AWS CDK v2 (TypeScript) — 配置: `infra/cdk/`
- 旧 `cloudformation/` は CDK 化後の参考資料。CDK 化済みリソース: IAM Role (SSM + CloudWatch Agent), CloudWatch Dashboard × 2 (FileServer / BackupServer)。
- ハイブリッドアクティベーション用 IAM ロールの旧物理名は `SSMCloudWatchAgentRole`。CDK 化後は `fs-{env}-iam-role-ssm-cloudwatch-agent`。既存アクティベーションを維持する場合はロール名の取扱いに注意。
