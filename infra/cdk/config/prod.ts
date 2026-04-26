import { EnvironmentConfig } from './types';

export const prodConfig: EnvironmentConfig = {
  envType: 'prod',
  account: '856221042201',
  region: 'ap-northeast-1',

  fileServer: {
    host: 'fileserver',
    namespace: 'OnPremises/FileServer',
  },
  backupServer: {
    host: 'backupserver',
    namespace: 'OnPremises/BackupServer',
  },
};
