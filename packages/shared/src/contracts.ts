
export type HealthResponse = {
  status: 'ok';
};

export type ApiErrorCode =
  | 'not_found' | 'method_not_allowed' | 'invalid_request'
  | 'authentication_required' | 'access_denied' | 'conflict'
  | 'payload_too_large' | 'unsupported_media_type' | 'rate_limited'
  | 'cost_limited' | 'maintenance' | 'unavailable' | 'internal_error'
  | 'account_suspended' | 'account_deleting' | 'recent_auth_required'
  | 'device_limit' | 'email_unverified' | 'policy_changed' | 'nickname_reserved';

export type ApiErrorResponse = {
  error: { code: ApiErrorCode };
};

export type CursorPage<T> = {
  items: T[];
  nextCursor: string | null;
};
