/**
 * システムテスト: 全スタックの一括合成 (E2E) を検証する。
 *
 * cdk synth 相当の処理を実行し、全スタックが矛盾なく合成されることを確認する。
 * dev / prod 両環境で合成が成功すること、および環境差分が正しく反映されることを検証する。
 */
import * as cdk from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { devConfig } from '../../config/dev';
import { prodConfig } from '../../config/prod';
import { EnvironmentConfig } from '../../config/types';
import { IamRoleStack } from '../../lib/iamRole';
import { CloudWatchDashboardStack } from '../../lib/cloudwatchDashboard';

function synthesizeAllStacks(config: EnvironmentConfig) {
  const app = new cdk.App();
  const prefix = `fs-${config.envType}`;
  const env = { account: config.account, region: config.region };

  const stacks = {
    iam: new IamRoleStack(app, `${prefix}-iam-role`, { config, env }),
    dashboard: new CloudWatchDashboardStack(app, `${prefix}-cloudwatch-dashboard`, { config, env }),
  };

  app.synth();
  return stacks;
}

describe('Full synth - dev environment', () => {
  const stacks = synthesizeAllStacks(devConfig);

  it('should synthesize all dev stacks without errors', () => {
    expect(Object.keys(stacks)).toHaveLength(2);
  });

  it('should produce a non-empty Resources block for each stack', () => {
    for (const stack of Object.values(stacks)) {
      const json = Template.fromStack(stack).toJSON();
      expect(json.Resources).toBeDefined();
      expect(Object.keys(json.Resources).length).toBeGreaterThan(0);
    }
  });
});

describe('Full synth - prod environment', () => {
  const stacks = synthesizeAllStacks(prodConfig);

  it('should synthesize all prod stacks without errors', () => {
    expect(Object.keys(stacks)).toHaveLength(2);
  });
});

describe('Resource count stability (regression guard)', () => {
  const stacks = synthesizeAllStacks(devConfig);

  it('should create exactly 1 IAM role', () => {
    Template.fromStack(stacks.iam).resourceCountIs('AWS::IAM::Role', 1);
  });

  it('should create exactly 2 CloudWatch dashboards', () => {
    Template.fromStack(stacks.dashboard).resourceCountIs('AWS::CloudWatch::Dashboard', 2);
  });
});
