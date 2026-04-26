#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { devConfig } from '../config/dev';
import { prodConfig } from '../config/prod';
import { naming } from '../config/naming';
import { EnvironmentConfig } from '../config/types';
import { IamRoleStack } from '../lib/iamRole';
import { CloudWatchDashboardStack } from '../lib/cloudwatchDashboard';

const app = new cdk.App();
const envName = app.node.tryGetContext('env') as string | undefined;

function createStacks(config: EnvironmentConfig): void {
  const { prefix } = naming(config.envType);
  const env = { account: config.account, region: config.region };

  new IamRoleStack(app, `${prefix}-iam-role`, { config, env });
  new CloudWatchDashboardStack(app, `${prefix}-cloudwatch-dashboard`, { config, env });
}

if (envName === 'dev' || !envName) {
  createStacks(devConfig);
}
if (envName === 'prod' || !envName) {
  createStacks(prodConfig);
}

app.synth();
