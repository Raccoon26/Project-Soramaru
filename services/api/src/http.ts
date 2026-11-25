
import type { ApiErrorCode, ApiErrorResponse } from '@soramaru/shared';

export class HttpError extends Error {
  readonly status: number;
  readonly code: ApiErrorCode;
  readonly retryAfter: number | undefined;

  constructor(status: number, code: ApiErrorCode, retryAfter?: number) {
    super(code);
    this.status = status;
    this.code = code;
    this.retryAfter = retryAfter;
  }
}

export const headers = {
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
};

export function jsonResponse(body: unknown, requestId: string, status = 200, extra: HeadersInit = {}) {
  const responseHeaders = new Headers(extra);
  for (const [key,value] of Object.entries(headers)) responseHeaders.set(key,value);
  responseHeaders.set('X-Request-Id', requestId);
  return Response.json(body, { status, headers: responseHeaders });
}

export function failure(error: HttpError, id: string, methods?: string) {
  const extra = new Headers();
  if (methods) extra.set('Allow', methods);
  if (error.retryAfter !== undefined) extra.set('Retry-After', String(error.retryAfter));
  return jsonResponse({ error: { code: error.code } } satisfies ApiErrorResponse, id, error.status, extra);
}

export async function readJson(request: Request, maxBytes = 16_384): Promise<Record<string, unknown>> {
  if (request.headers.get('content-type')?.split(';')[0]?.trim().toLowerCase() !== 'application/json') {
    throw new HttpError(415, 'unsupported_media_type');
  }
  const encoding = request.headers.get('content-encoding');
  if (encoding && encoding !== 'identity') throw new HttpError(415, 'unsupported_media_type');
  const declared = request.headers.get('content-length');
  if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > maxBytes)) {
    throw new HttpError(413, 'payload_too_large');
  }
  const reader = request.body?.getReader();
  if (!reader) throw new HttpError(400, 'invalid_request');
  const body = new Uint8Array(maxBytes);
  let bytes = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (bytes + value.byteLength > maxBytes) {
        await reader.cancel().catch(() => undefined);
        throw new HttpError(413, 'payload_too_large');
      }
      body.set(value, bytes);
      bytes += value.byteLength;
    }
  } finally {
    reader.releaseLock();
  }
  try {
    const result: unknown = JSON.parse(new TextDecoder('utf-8',{ fatal: true }).decode(body.subarray(0,bytes)));
    if (typeof result !== 'object' || result === null || Array.isArray(result)) throw new Error('Expected JSON object');
    return result as Record<string, unknown>;
  } catch {
    throw new HttpError(400, 'invalid_request');
  }
}

export function validateUrl(raw: string): URL {
  if (raw.length > 2048 || /%(?![0-9a-f]{2})/i.test(raw) ||
      /%(?:00|2f|5c)/i.test(raw.split('?')[0] ?? '') || raw.includes('\\')) {
    throw new HttpError(400, 'invalid_request');
  }
  const url = new URL(raw);
  if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password || url.hash) {
    throw new HttpError(400, 'invalid_request');
  }
  const keys = [...url.searchParams.keys()];
  if (keys.length > 8 || new Set(keys).size !== keys.length || keys.some(key => !/^[a-z_]{1,24}$/.test(key))) {
    throw new HttpError(400, 'invalid_request');
  }
  return url;
}
