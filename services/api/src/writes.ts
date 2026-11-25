
import type { Database, Statement } from './platform.ts';
import { digest, isId, query } from './platform.ts';
import { HttpError } from './http.ts';

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

function canonical(value: Json): string {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (value !== null && typeof value === 'object') {
    return '{' + Object.keys(value).sort()
      .map(key => JSON.stringify(key) + ':' + canonical(value[key] ?? null)).join(',') + '}';
  }
  return JSON.stringify(value);
}

export async function idempotent<T extends Json>(db: Database, actor: string, operation: string, key: string,
  input: Json, now: number, build: () => { result: T; statements: Statement[] }, requiredMutation?: Statement): Promise<T> {
  if (!isId(actor) || !/^[a-z][a-z_.]{1,39}$/.test(operation) || !/^[A-Za-z0-9_-]{8,80}$/.test(key)) {
    throw new HttpError(400,'invalid_request');
  }
  const sha = await digest(canonical(input));
  const find = () => query(db,`SELECT fingerprint,result,expires_at FROM idempotency_keys
    WHERE actor_id=? AND operation=? AND request_key=?`,actor,operation,key)
    .first<{ fingerprint: string; result: string; expires_at: number }>();
  function replay(previous: NonNullable<Awaited<ReturnType<typeof find>>>) {
    if (previous.fingerprint !== sha || previous.expires_at <= now) throw new HttpError(409,'conflict');
    return JSON.parse(previous.result) as T;
  }
  const previous = await find();
  if (previous) return replay(previous);
  const proposal = build();
  try {
    await db.batch([
      ...(requiredMutation?[requiredMutation]:[]),
      query(db,`INSERT INTO idempotency_keys VALUES (?,?,?,${requiredMutation?'CASE WHEN changes()=1 THEN ? ELSE NULL END':'?'},?,?)`,
        actor,operation,key,sha,JSON.stringify(proposal.result),now+86_400_000),
      ...proposal.statements,
    ]);
    return proposal.result;
  } catch (error) {
    const winner = await find();
    if (!winner) {
      // A missed conditional write aborts the entire batch at the ledger insert.
      if (requiredMutation&&error instanceof Error&&error.message.includes('NOT NULL constraint failed: idempotency_keys.fingerprint')) {
        throw new HttpError(409,'conflict');
      }
      throw error;
    }
    return replay(winner);
  }
}

export type AuditEvent = 'reservation' | 'expiry' | 'access_denied' | 'budget_denied' | 'job_done' | 'job_failure' | 'deletion_replay';
export type AuditResult = 'allowed' | 'denied' | 'completed' | 'retry' | 'failed';

export function auditStatement(db: Database, event: AuditEvent, result: AuditResult, now: number, actor: string | null = null) {
  return query(db,'INSERT INTO audit_events VALUES (?,?,?,?,?)',crypto.randomUUID(),actor,event,result,now);
}
