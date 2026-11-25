
import { bindings, defineConfig } from '@cloudflare/config/public';
import { bindingNames, localEnvironment, compatibilityDate } from './local-config.ts';

const environment = localEnvironment(process.env.SORAMARU_RUNTIME);
const names = bindingNames(environment);

export default defineConfig({
  worker: {
    name: 'soramaru-local-api',
    entrypoint: './src/index.ts',
    compatibilityDate,
    workersDev: false,
    previewUrls: false,
    env: {
      APP_ENV: bindings.text(environment),
      DB: bindings.d1({ id: names.db, name: names.d1Name, dev: { remote: false } }),
      PRIVATE_MEDIA: bindings.r2({ name: names.media, dev: { remote: false } }),
      QUARANTINE: bindings.r2({ name: names.quarantine, dev: { remote: false } }),
    },
  },
});
