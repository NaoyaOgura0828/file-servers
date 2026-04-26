import * as cdk from 'aws-cdk-lib';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import { Construct } from 'constructs';
import { EnvironmentConfig, ServerMonitoringConfig } from '../config/types';
import { naming } from '../config/naming';

export interface CloudWatchDashboardStackProps extends cdk.StackProps {
  readonly config: EnvironmentConfig;
}

export class CloudWatchDashboardStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: CloudWatchDashboardStackProps) {
    super(scope, id, props);

    const { config } = props;
    const n = naming(config.envType);

    new cloudwatch.CfnDashboard(this, 'FileServerDashboard', {
      dashboardName: n.fileServerDashboardName,
      dashboardBody: buildDashboardBody(config.fileServer, this.region),
    });

    new cloudwatch.CfnDashboard(this, 'BackupServerDashboard', {
      dashboardName: n.backupServerDashboardName,
      dashboardBody: buildDashboardBody(config.backupServer, this.region),
    });
  }
}

function buildDashboardBody(server: ServerMonitoringConfig, region: string): string {
  const body = {
    widgets: [
      {
        type: 'metric',
        properties: {
          metrics: [
            [server.namespace, 'CPU_IDLE', 'host', server.host, 'cpu', 'cpu-total', { stat: 'Average', label: 'CPU Idle (%)' }],
          ],
          view: 'timeSeries',
          stacked: false,
          region,
          title: 'CPU使用状況',
          period: 300,
          yAxis: { left: { min: 0, max: 100 } },
        },
        width: 12,
        height: 6,
        x: 0,
        y: 0,
      },
      {
        type: 'metric',
        properties: {
          metrics: [
            [server.namespace, 'MEM_USED_PERCENT', 'host', server.host, { stat: 'Average', label: 'メモリ使用率 (%)' }],
          ],
          view: 'timeSeries',
          stacked: false,
          region,
          title: 'メモリ使用率',
          period: 300,
          yAxis: { left: { min: 0, max: 100 } },
        },
        width: 12,
        height: 6,
        x: 12,
        y: 0,
      },
      {
        type: 'metric',
        properties: {
          metrics: [
            [
              {
                expression: `SEARCH('{${server.namespace},host,path,device,fstype} MetricName="DISK_USED_PERCENT" host="${server.host}"', 'Average', 300)`,
                label: '${PROP("path")}',
                id: 'e1',
              },
            ],
          ],
          view: 'timeSeries',
          stacked: false,
          region,
          title: 'ディスク使用率 (%)',
          period: 300,
          yAxis: { left: { min: 0, max: 100 } },
        },
        width: 12,
        height: 6,
        x: 0,
        y: 6,
      },
      {
        type: 'metric',
        properties: {
          metrics: [
            [server.namespace, 'SWAP_USED_PERCENT', 'host', server.host, { stat: 'Average', label: 'Swap使用率 (%)' }],
          ],
          view: 'timeSeries',
          stacked: false,
          region,
          title: 'Swap使用率',
          period: 300,
          yAxis: { left: { min: 0, max: 100 } },
        },
        width: 12,
        height: 6,
        x: 12,
        y: 6,
      },
    ],
  };
  return JSON.stringify(body);
}
