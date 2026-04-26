import { EnvironmentConfig } from './types';

export const devConfig: EnvironmentConfig = {
  envType: 'dev',
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
