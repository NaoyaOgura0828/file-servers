import { EnvType } from './types';

const SYS = 'fs';

/**
 * 物理名は env ごとに切り替える。
 *
 * - prod: 既存 CloudFormation で稼働中のリソース名を維持し、`cdk import` で
 *   既存リソースを CDK 管理下に取り込めるようにする。
 * - dev: 新規環境のため cdk SKILL.md の命名規約 (`{sys}-{env}-...`) に従う。
 */
export function naming(envType: EnvType) {
  const p = `${SYS}-${envType}`;

  if (envType === 'prod') {
    return {
      sys: SYS,
      prefix: p,
      ssmCloudWatchAgentRoleName: 'SSMCloudWatchAgentRole',
      fileServerDashboardName: 'FileServer',
      backupServerDashboardName: 'BackupServer',
    };
  }

  return {
    sys: SYS,
    prefix: p,
    ssmCloudWatchAgentRoleName: `${p}-iam-role-ssm-cloudwatch-agent`,
    fileServerDashboardName: `${p}-cloudwatch-dashboard-fileserver`,
    backupServerDashboardName: `${p}-cloudwatch-dashboard-backupserver`,
  };
}
