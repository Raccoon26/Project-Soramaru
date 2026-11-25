
import { cloudflare } from '@cloudflare/vite-plugin';
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vite';
import { localEnvironment } from './local-config.ts';

const environment = localEnvironment(process.env.SORAMARU_RUNTIME);
const persistState = environment === 'test'
  ? false
  : { path: fileURLToPath(new URL('../../.local/backend/local', import.meta.url)) };

export default defineConfig({
  plugins: [cloudflare({ remoteBindings: false, persistState })],
});
