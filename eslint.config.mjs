import js from '@eslint/js';
import tseslint from 'typescript-eslint';

export default [
  { ignores: ['**/.local/**', '**/.cloudflare/**', '**/.dart_tool/**', '**/build/**'] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
];
