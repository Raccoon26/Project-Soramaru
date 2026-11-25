
import type { HealthResponse } from '@soramaru/shared';
import type { Env, QueryMeta } from './platform.ts';
import { checkEnvironment, query, schemaVersion } from './platform.ts';
import { authenticate, denyUnconfigured } from './auth.ts';
import type { Verifier } from './auth.ts';
import { Budget } from './cost.ts';
import { EdgeBurst, allowRate } from './rate.ts';
import type { TrustedNetwork } from './rate.ts';
import { failure, HttpError, jsonResponse, validateUrl } from './http.ts';
import { enqueue, runJobs } from './jobs.ts';
import { MediaStore } from './media.ts';

type Operation = 'health' | 'readiness' | 'session' | 'unknown';
interface Event {
  requestId: string;
  operation: Operation;
  status: number;
  durationMs: number;
  estimatedGate: string | null;
  d1: { reads: number; writes: number };
}

interface Dependencies {
  verify: Verifier;
  clock: () => number;
  log: (event: Event) => void;
  network: TrustedNetwork;
  burst: EdgeBurst;
}

function aggregate(meta: QueryMeta[], field: 'rows_read' | 'rows_written') {
  return meta.reduce((sum,item) => sum + item[field],0);
}

export function createApi(overrides: Partial<Dependencies> = {}) {
  const { verify,clock,log,network,burst } = {
    verify: denyUnconfigured,clock: Date.now,log: (event: Event) => console.info(JSON.stringify(event)),
    network: () => null,burst: new EdgeBurst(),...overrides,
  };

  return function fetch(request: Request, binding?: Partial<Env>): Response | Promise<Response> {
    const id = crypto.randomUUID();
    const start = performance.now();
    let operation: Operation = 'unknown';
    let tier: string | null = null;
    const meta: QueryMeta[] = [];
    const send = (response: Response) => {
      log({ requestId:id,operation,status:response.status,durationMs:Math.max(0,Math.round(performance.now()-start)),
        estimatedGate:tier,d1:{ reads:aggregate(meta,'rows_read'),writes:aggregate(meta,'rows_written') } });
      return response;
    };
    let url: URL;
    try {
      url = validateUrl(request.url);
    } catch {
      return send(failure(new HttpError(400,'invalid_request'),id));
    }
    switch (url.pathname) {
      case '/v1/health': operation = 'health'; break;
      case '/v1/ready': operation = 'readiness'; break;
      case '/v1/me/session': operation = 'session'; break;
      default: return send(failure(new HttpError(404,'not_found'),id));
    }
    if (request.method !== 'GET') return send(failure(new HttpError(405,'method_not_allowed'),id,'GET'));
    if (url.search || request.body !== null) return send(failure(new HttpError(400,'invalid_request'),id));
    if (operation === 'health') {
      return send(jsonResponse({status:'ok'} satisfies HealthResponse,id));
    }
    if (!burst.allow(clock())) return send(failure(new HttpError(429,'rate_limited',1),id));

    return (async () => {
      try {
        const env = checkEnvironment(binding);
        if (operation === 'readiness') {
          const result = await query(env.DB,'SELECT max(version) AS version FROM schema_migrations').all<{ version: number }>();
          meta.push(result.meta);
          if (result.results[0]?.version !== schemaVersion) throw new HttpError(503,'unavailable',30);
          return send(jsonResponse({status:'ready'},id));
        }
        const now = clock();
        // Only the official test harness injects a verifier. The runtime entrypoint
        // never passes one and rejects staging/production configuration.
        const actor = await authenticate(env.DB,request.headers.get('authorization'),
          env.APP_ENV === 'test' ? verify : denyUnconfigured,now,result => meta.push(result));
        const networkKey = network() ?? 'unattributed';
        const scopes = [
          { kind:'user',key:actor.id,limit:60 },
          { kind:'session',key:actor.sessionId,limit:30 },
          { kind:'network',key:networkKey,limit:120 },
          { kind:'operation',key:'session',limit:180 },
        ] as const;
        const admission = await new Budget(env.DB).admit('standard',{
          requests:1,d1Reads:36,d1Writes:scopes.length*2,d1IndexWrites:scopes.length,
        },now);
        meta.push(admission.meta);
        tier = admission.tier ?? 'denied';
        if (!admission.allowed) {
          const flag = await query(env.DB,"SELECT enabled FROM feature_flags WHERE name='maintenance_mode'").all<{enabled:number}>();
          meta.push(flag.meta);
          throw new HttpError(503,flag.results[0]?.enabled === 1 ? 'maintenance' : 'cost_limited',60);
        }
        const limit = await allowRate(env.DB,scopes,now);
        meta.push(limit.meta);
        if (!limit.allowed) throw new HttpError(429,'rate_limited',limit.retryAfter);
        return send(jsonResponse({role:actor.role},id));
      } catch (error) {
        return send(failure(error instanceof HttpError ? error : new HttpError(503,'unavailable',30),id));
      }
    })();
  };
}

export default {
  fetch: createApi(),
  async scheduled(controller: { scheduledTime?: number } | null, bindings: Partial<Env>) {
    const env = checkEnvironment(bindings);
    const now = Date.now();
    const budget = new Budget(env.DB);
    const admission = await budget.admit('essential',{ jobRuns:1,d1Reads:140,d1Writes:85,
      d1IndexWrites:40,r2A:12,r2B:10 },now);
    if (!admission.allowed) return;
    const eventTime = controller?.scheduledTime ?? now;
    const window = Math.floor((Number.isSafeInteger(eventTime) && eventTime >= 0 && eventTime <= now ? eventTime : now)/900_000);
    await enqueue(env.DB,'expire_uploads','expiry:' + window,{},now,{required:true}).run();
    const store = new MediaStore(env);
    const optional = await query(env.DB,`SELECT count(*) AS open FROM feature_flags
      WHERE (name='scheduled_jobs_enabled' AND enabled=1) OR (name='maintenance_mode' AND enabled=0)`).first<{open:number}>();
    // Only expiry has a runtime handler in DEV-03. Follow-up jobs and outbox
    // delivery are exercised through explicit test adapters.
    await runJobs(env.DB,{expire_uploads:async () => { await store.expire(); }},Date.now,5,
      optional?.open !== 2 || admission.tier === 'reduced' || admission.tier === 'blocked' || admission.tier === 'emergency');
  },
};
