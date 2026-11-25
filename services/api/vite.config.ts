
import { cloudflare } from '@cloudflare/vite-plugin';
import { bindings } from '@cloudflare/config/public';
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vite';
import { localEnvironment } from './local-config.ts';

const environment = localEnvironment(process.env.SORAMARU_RUNTIME);
const authKey=process.env.SORAMARU_LOCAL_AUTH_KEY;
const authMode=authKey!==undefined;
if (authKey!==undefined&&!/^[0-9a-f]{64}$/.test(authKey)) throw new Error('Invalid local authentication key');
const slot=process.env.SORAMARU_TEST_SLOT;
if (slot!==undefined&&(!authMode||environment!=='test'||!/^[a-f0-9-]{36}$/.test(slot))) throw new Error('Invalid test slot');
const state=environment==='local'?'local':slot?'test-'+slot:null;
const persistState = state===null ? false :
  {path:fileURLToPath(new URL('../../.local/backend/'+state,import.meta.url))};

export default defineConfig(({command})=>{
  if (command!=='serve'&&authMode) throw new Error('Firebase Emulator is development only');
  return {plugins:[cloudflare({remoteBindings:false,persistState,...(authKey===undefined?{}:{
    types:{generate:false},
    config:loaded=>{
      const worker=loaded.worker;
      if (!worker||typeof worker!=='object') throw new Error('Missing local Worker');
      return {...loaded,worker:{...worker,entrypoint:'./src/local-emulator.ts',
        env:{...worker.env,AUTH_SESSION_KEY:bindings.text(authKey)}}};
    },
  })})]};
});
