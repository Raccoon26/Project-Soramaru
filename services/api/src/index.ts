import type { ApiErrorResponse, HealthResponse } from '@soramaru/shared';

const responseHeaders = {
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
};

export default {
  fetch(request: Request): Response {
    if (new URL(request.url).pathname !== '/v1/health') {
      return Response.json({ error: { code: 'not_found' } } satisfies ApiErrorResponse, {
        status: 404,
        headers: responseHeaders,
      });
    }

    if (request.method !== 'GET') {
      return Response.json({ error: { code: 'method_not_allowed' } } satisfies ApiErrorResponse, {
        status: 405,
        headers: { ...responseHeaders, Allow: 'GET' },
      });
    }

    return Response.json({ status: 'ok' } satisfies HealthResponse, {
      headers: responseHeaders,
    });
  },
};
