
import { query } from './platform.ts';
import type { Database } from './platform.ts';
import { auditStatement } from './writes.ts';

export const jobKinds = ['publish_notice','birthday_card','anniversary_card','notifications','expire_uploads',
  'reconcile_media','reconcile_usage','backup','deliver_outbox','member_deletion'] as const;
export type JobKind = typeof jobKinds[number];
interface Job {
  id: string;
  kind: JobKind;
  payload: string;
  attempts: number;
  max_attempts: number;
  lease_token: string;
  lease_until: number;
}

export function enqueue(db: Database, kind: JobKind, dedupe: string, payload: object, runAt: number,
  options: { required?: boolean; maxAttempts?: number; id?: string } = {}) {
  if (!jobKinds.includes(kind) || !/^[A-Za-z0-9:_-]{1,120}$/.test(dedupe)) throw new Error('Invalid job');
  return query(db,`INSERT INTO scheduled_jobs (id,kind,dedupe_key,payload,required,state,run_at,max_attempts)
    VALUES (?,?,?,?,?,'ready',?,?) ON CONFLICT(dedupe_key) DO NOTHING`,
  options.id ?? crypto.randomUUID(),kind,dedupe,JSON.stringify(payload),options.required ? 1 : 0,runAt,options.maxAttempts ?? 5);
}

export function eventStatements(db: Database, key: string, eventType: string, payload: object, now: number) {
  const eventId = crypto.randomUUID();
  const jobId = crypto.randomUUID();
  return [
    enqueue(db,'deliver_outbox','outbox:' + key,{ eventId },now,{ id: jobId }),
    query(db,'INSERT INTO outbox VALUES (?,?,?,?,?,?,NULL)',eventId,key,eventType,JSON.stringify(payload),jobId,now),
  ];
}

export async function claim(db: Database, now: number, limit = 5, essentialOnly = false, kinds: readonly string[] = jobKinds) {
  if (!Number.isInteger(limit) || limit < 1 || limit > 10) throw new Error('Invalid job batch size');
  const token = crypto.randomUUID();
  // Cap cleanup and due selection separately. Stale leases use a different index.
  const results = await db.batch<Job>([
    query(db,`UPDATE scheduled_jobs SET state='dead',lease_until=NULL,lease_token=NULL,last_error='lease_expired'
      WHERE id IN (SELECT id FROM scheduled_jobs WHERE state='leased' AND lease_until<=?
      AND attempts>=max_attempts ORDER BY lease_until,id LIMIT ?)`,now,limit),
    query(db,`UPDATE scheduled_jobs SET state='leased',lease_until=?2,lease_token=?3,attempts=attempts+1
      WHERE id IN (
        SELECT id FROM (
          SELECT id,run_at FROM scheduled_jobs WHERE state='ready' AND run_at<=?1 AND (?5=0 OR required=1)
            AND kind IN (SELECT value FROM json_each(?6))
          UNION ALL
          SELECT id,run_at FROM scheduled_jobs WHERE state='leased' AND lease_until<=?1
            AND attempts<max_attempts AND (?5=0 OR required=1) AND kind IN (SELECT value FROM json_each(?6))
        ) ORDER BY run_at,id LIMIT ?4
      )
      RETURNING id,kind,payload,attempts,max_attempts,lease_token,lease_until`,now,now+60_000,token,limit,essentialOnly ? 1 : 0,JSON.stringify(kinds)),
  ]);
  return results[1]?.results ?? [];
}

type JobHandler = (payload: unknown, jobId: string) => Promise<void>;
export type Handlers = Partial<Record<JobKind,JobHandler>>;

export async function finish(db: Database, job: Job, now: number, succeeded: boolean, jitter = Math.random) {
  const terminal = !succeeded && job.attempts >= job.max_attempts;
  const state = succeeded ? 'done' : terminal ? 'dead' : 'ready';
  const next = succeeded || terminal ? now
    : now + Math.min(300_000,1000*2**(job.attempts-1)) + Math.floor(jitter()*1_000);
  const changed = await query(db,`UPDATE scheduled_jobs SET state=?,run_at=?,lease_token=NULL,lease_until=NULL,last_error=?
    WHERE id=? AND state='leased' AND lease_token=? AND lease_until>?`,
  state,next,succeeded ? null : 'handler_failed',job.id,job.lease_token,now).run();
  if (changed.meta.changes !== 1) return false;
  return true;
}

export async function runJobs(db: Database, handlers: Handlers, clock = Date.now, limit = 5, essentialOnly = false) {
  const jobs = await claim(db,clock(),limit,essentialOnly,Object.keys(handlers));
  for (const job of jobs) {
    let succeeded = false;
    try {
      const handler = handlers[job.kind];
      if (!handler) throw new Error('Handler unavailable');
      await handler(JSON.parse(job.payload),job.id);
      succeeded = true;
    } catch {
      // Exception messages can include credentials or user data.
    }
    const now = clock();
    if (await finish(db,job,now,succeeded)) {
      await auditStatement(db,succeeded ? 'job_done' : 'job_failure',succeeded ? 'completed'
        : job.attempts >= job.max_attempts ? 'failed' : 'retry',now).run();
    }
  }
  return jobs.length;
}

export type EventDelivery = (event: { id: string; kind: string; payload: unknown }) => Promise<void>;

export function outboxHandler(db: Database, deliver: EventDelivery, clock = Date.now): JobHandler {
  return async (input,jobId) => {
    const row = await query(db,`SELECT id,event_type,event_payload,delivered_at FROM outbox WHERE job_id=?`,jobId)
      .first<{ id: string; event_type: string; event_payload: string; delivered_at: number | null }>();
    if (!row || typeof input !== 'object' || input === null || !('eventId' in input) || input.eventId !== row.id) {
      throw new Error('Outbox reference mismatch');
    }
    if (row.delivered_at !== null) return;
    // Receivers must deduplicate by event ID across an external success/DB failure.
    await deliver({ id: row.id,kind: row.event_type,payload: JSON.parse(row.event_payload) });
    await query(db,'UPDATE outbox SET delivered_at=? WHERE id=? AND delivered_at IS NULL',clock(),row.id).run();
  };
}
