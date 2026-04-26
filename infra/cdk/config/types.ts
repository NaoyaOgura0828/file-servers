export type EnvType = 'dev' | 'prod';

export interface ServerMonitoringConfig {
  readonly host: string;
  readonly namespace: string;
}

export interface EnvironmentConfig {
  readonly envType: EnvType;
  readonly account: string;
  readonly region: string;

  readonly fileServer: ServerMonitoringConfig;
  readonly backupServer: ServerMonitoringConfig;
}
