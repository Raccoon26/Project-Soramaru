export type HealthResponse = {
  status: 'ok';
};

export type ApiErrorCode = 'not_found' | 'method_not_allowed';

export type ApiErrorResponse = {
  error: { code: ApiErrorCode };
};

export type CursorPage<T> = {
  items: T[];
  nextCursor: string | null;
};
