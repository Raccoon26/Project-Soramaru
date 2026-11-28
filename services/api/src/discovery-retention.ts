import { query } from './platform.ts';
import type { Database } from './platform.ts';

const day=86_400_000;
const maximum=20;

export function pruneDiscoveryData(db:Database,now:number) {
  return db.batch([
    query(db,`DELETE FROM idempotency_keys WHERE rowid IN (
      SELECT rowid FROM idempotency_keys WHERE expires_at<? ORDER BY expires_at LIMIT ?)`,now-day,maximum),
    // Ordinary admission windows use UTC minute numbers. Mail cooldowns use milliseconds.
    query(db,`DELETE FROM rate_limits WHERE scope IN (
      SELECT scope FROM rate_limits WHERE window<? ORDER BY window,scope LIMIT ?)`,
    Math.floor((now-2*day)/60_000),maximum),
    query(db,`DELETE FROM outbox WHERE id IN (
      SELECT o.id FROM outbox o INDEXED BY delivered_outbox_cleanup JOIN scheduled_jobs j ON j.id=o.job_id
      WHERE o.delivered_at IS NOT NULL AND o.delivered_at<? AND j.state='done' AND j.lease_token IS NULL
      ORDER BY o.delivered_at,o.id LIMIT ?)`,now-30*day,maximum),
  ]);
}
