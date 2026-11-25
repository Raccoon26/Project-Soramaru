
import { digest, query } from './platform.ts';
import type { Database } from './platform.ts';

export interface LimitScope { kind: 'user' | 'session' | 'network' | 'operation'; key: string; limit: number }

export class EdgeBurst {
  private window = -1;
  private used = 0;

  private readonly maxPerSecond: number;

  constructor(maxPerSecond = 100) {
    this.maxPerSecond = maxPerSecond;
  }

  allow(now: number) {
    const second = Math.floor(now / 1000);
    if (second < this.window) return false;
    if (second !== this.window) {
      this.window = second;
      this.used = 0;
    }
    if (this.used >= this.maxPerSecond) return false;
    this.used++;
    return true;
  }
}

// Resolver must come from verified infrastructure. Local mode deliberately groups
// unauthenticated requests together and ignores request-controlled IP headers.
export type TrustedNetwork = () => string | null;

export async function allowRate(db: Database, scopes: readonly LimitScope[], now: number) {
  const window = Math.floor(now / 60_000);
  const keys = await Promise.all(scopes.map(async scope => ({
    scope: scope.kind + ':' + await digest(scope.key),
    ceiling: scope.limit,
  })));
  if (!keys.length || new Set(keys.map(key => key.scope)).size !== keys.length ||
      keys.some(key => !Number.isSafeInteger(key.ceiling) || key.ceiling < 1)) {
    throw new Error('Invalid rate policy');
  }
  const response = await query(db, `
    WITH incoming AS MATERIALIZED (
      SELECT json_extract(value,'$.scope') AS scope,json_extract(value,'$.ceiling') AS ceiling
      FROM json_each(?1)
    )
    INSERT INTO rate_limits(scope,window,count)
    SELECT scope,?2,1 FROM incoming WHERE NOT EXISTS (
      SELECT 1 FROM incoming AS i JOIN rate_limits AS r ON i.scope=r.scope
      WHERE r.window>?2 OR r.window=?2 AND r.count>=i.ceiling
    )
    ON CONFLICT(scope) DO UPDATE SET count=CASE WHEN window=excluded.window THEN count+1 ELSE 1 END, window=excluded.window
    RETURNING scope
  `, JSON.stringify(keys), window).all();
  return { allowed: response.results.length === keys.length, meta: response.meta,
    retryAfter: Math.max(1, Math.ceil(((window + 1) * 60_000 - now) / 1000)) };
}
