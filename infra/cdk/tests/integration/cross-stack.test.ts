/**
 * 結合テスト: スタック間の命名整合性・参照一貫性を検証する。
 *
 * naming.ts が dev/prod で異なるプレフィックスを生成することと、
 * 各スタックが naming.ts の物理名を正しく参照していることを確認する。
 * クロススタック参照（CloudFormation Outputs）が存在しないことも検証する。
 */
import * as cdk from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { devConfig } from '../../config/dev';
import { prodConfig } from '../../config/prod';
import { naming } from '../../config/naming';
import { IamRoleStack } from '../../lib/iamRole';
import { CloudWatchDashboardStack } from '../../lib/cloudwatchDashboard';

const config = devConfig;
const env = { account: config.account, region: config.region };
const n = naming(config.envType);

describe('IAM ↔ naming consistency', () => {
  const app = new cdk.App();
  const template = Template.fromStack(new IamRoleStack(app, 'IamTest', { config, env }));

  it('should create role whose name matches naming.ssmCloudWatchAgentRoleName', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      RoleName: n.ssmCloudWatchAgentRoleName,
    });
  });
});

describe('CloudWatch Dashboard ↔ naming consistency', () => {
  const app = new cdk.App();
  const template = Template.fromStack(new CloudWatchDashboardStack(app, 'DashTest', { config, env }));

  it('should create FileServer dashboard whose name matches naming.fileServerDashboardName', () => {
    template.hasResourceProperties('AWS::CloudWatch::Dashboard', {
      DashboardName: n.fileServerDashboardName,
    });
  });

  it('should create BackupServer dashboard whose name matches naming.backupServerDashboardName', () => {
    template.hasResourceProperties('AWS::CloudWatch::Dashboard', {
      DashboardName: n.backupServerDashboardName,
    });
  });
});

describe('No cross-stack references (anti-pattern prevention)', () => {
  const cases = [
    { name: 'dev', config: devConfig },
    { name: 'prod', config: prodConfig },
  ];

  cases.forEach(({ name, config: cfg }) => {
    it(`should not generate CloudFormation Outputs in any ${name} stack`, () => {
      const app = new cdk.App();
      const cfgEnv = { account: cfg.account, region: cfg.region };

      const stacks = [
        new IamRoleStack(app, `${name}-Iam`, { config: cfg, env: cfgEnv }),
        new CloudWatchDashboardStack(app, `${name}-Dash`, { config: cfg, env: cfgEnv }),
      ];

      for (const stack of stacks) {
        const template = Template.fromStack(stack);
        const json = template.toJSON();
        expect(json.Outputs).toBeUndefined();
      }
    });
  });
});

describe('naming() environment isolation', () => {
  const devN = naming('dev');
  const prodN = naming('prod');

  it('should produce different prefixes for dev and prod', () => {
    expect(devN.prefix).toBe('fs-dev');
    expect(prodN.prefix).toBe('fs-prod');
    expect(devN.prefix).not.toBe(prodN.prefix);
  });

  it('should produce different IAM role names for dev and prod', () => {
    expect(devN.ssmCloudWatchAgentRoleName).not.toBe(prodN.ssmCloudWatchAgentRoleName);
  });

  it('should produce different dashboard names for dev and prod', () => {
    expect(devN.fileServerDashboardName).not.toBe(prodN.fileServerDashboardName);
    expect(devN.backupServerDashboardName).not.toBe(prodN.backupServerDashboardName);
  });
});
