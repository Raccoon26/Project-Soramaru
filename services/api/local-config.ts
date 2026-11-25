
export const compatibilityDate = '2026-11-24';

export function localEnvironment(value: unknown = 'local'): 'local' | 'test' {
  if (value === 'local' || value === 'test') return value;
  throw new Error('SORAMARU_RUNTIME must be local or test. Deployment is disabled.');
}

export function bindingNames(environment: 'local' | 'test') {
  return {
    db: environment === 'local'
      ? '00000000-0000-4000-8000-000000000031'
      : '00000000-0000-4000-8000-000000000032',
    d1Name: 'soramaru-emulated-' + environment,
    media: 'soramaru-private-' + environment,
    quarantine: 'soramaru-quarantine-' + environment,
  };
}
