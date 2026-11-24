import { defineConfig } from '@cloudflare/config/public';

export default defineConfig({
  worker: {
    name: 'soramaru-api-dev00',
    entrypoint: './src/index.ts',
    compatibilityDate: '2026-11-24',
    workersDev: false,
    previewUrls: false,
  },
});
