import * as cdk from 'aws-cdk-lib';
import * as iam from 'aws-cdk-lib/aws-iam';
import { Construct } from 'constructs';
import { EnvironmentConfig } from '../config/types';
import { naming } from '../config/naming';

export interface IamRoleStackProps extends cdk.StackProps {
  readonly config: EnvironmentConfig;
}

export class IamRoleStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: IamRoleStackProps) {
    super(scope, id, props);

    const { config } = props;
    const n = naming(config.envType);

    new iam.Role(this, 'SsmCloudWatchAgent', {
      roleName: n.ssmCloudWatchAgentRoleName,
      description: 'IAM Role for SSM Managed Instances with CloudWatch Agent',
      assumedBy: new iam.ServicePrincipal('ssm.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
        iam.ManagedPolicy.fromAwsManagedPolicyName('CloudWatchAgentServerPolicy'),
      ],
    });
  }
}
