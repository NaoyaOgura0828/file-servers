import * as cdk from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { devConfig } from '../../config/dev';
import { IamRoleStack } from '../../lib/iamRole';
import { CloudWatchDashboardStack } from '../../lib/cloudwatchDashboard';

const config = devConfig;
const env = { account: config.account, region: config.region };

describe('IamRoleStack', () => {
  const app = new cdk.App();
  const stack = new IamRoleStack(app, 'TestIamRole', { config, env });
  const template = Template.fromStack(stack);

  it('should create SSM CloudWatch Agent role with expected name', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      RoleName: 'fs-dev-iam-role-ssm-cloudwatch-agent',
    });
  });

  it('should create exactly 1 IAM role', () => {
    template.resourceCountIs('AWS::IAM::Role', 1);
  });

  it('should attach SSM and CloudWatch Agent managed policies', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      ManagedPolicyArns: [
        { 'Fn::Join': ['', ['arn:', { Ref: 'AWS::Partition' }, ':iam::aws:policy/AmazonSSMManagedInstanceCore']] },
        { 'Fn::Join': ['', ['arn:', { Ref: 'AWS::Partition' }, ':iam::aws:policy/CloudWatchAgentServerPolicy']] },
      ],
    });
  });

  it('should allow ssm.amazonaws.com to assume the role', () => {
    template.hasResourceProperties('AWS::IAM::Role', {
      AssumeRolePolicyDocument: {
        Statement: [
          {
            Action: 'sts:AssumeRole',
            Effect: 'Allow',
            Principal: { Service: 'ssm.amazonaws.com' },
          },
        ],
        Version: '2012-10-17',
      },
    });
  });
});

describe('CloudWatchDashboardStack', () => {
  const app = new cdk.App();
  const stack = new CloudWatchDashboardStack(app, 'TestDashboard', { config, env });
  const template = Template.fromStack(stack);

  it('should create exactly 2 dashboards', () => {
    template.resourceCountIs('AWS::CloudWatch::Dashboard', 2);
  });

  it('should create FileServer dashboard with expected name', () => {
    template.hasResourceProperties('AWS::CloudWatch::Dashboard', {
      DashboardName: 'fs-dev-cloudwatch-dashboard-fileserver',
    });
  });

  it('should create BackupServer dashboard with expected name', () => {
    template.hasResourceProperties('AWS::CloudWatch::Dashboard', {
      DashboardName: 'fs-dev-cloudwatch-dashboard-backupserver',
    });
  });

  it('should embed FileServer host metrics in dashboard body', () => {
    const dashboards = template.findResources('AWS::CloudWatch::Dashboard');
    const bodies = Object.values(dashboards).map((r) => r.Properties.DashboardBody as string);
    expect(bodies.some((b) => b.includes('OnPremises/FileServer') && b.includes('"FileServer"'))).toBe(true);
  });

  it('should embed BackupServer host metrics in dashboard body', () => {
    const dashboards = template.findResources('AWS::CloudWatch::Dashboard');
    const bodies = Object.values(dashboards).map((r) => r.Properties.DashboardBody as string);
    expect(bodies.some((b) => b.includes('OnPremises/BackupServer') && b.includes('"BackupServer"'))).toBe(true);
  });
});
