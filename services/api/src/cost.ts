
import { query } from './platform.ts';
import type { Database } from './platform.ts';

type Period = 'day' | 'month' | 'gauge';

// D1 writes include predicted index writes. Index writes are also reported separately.
export const metricDefinitions = {
  requests: ['day', 100_000],
  d1Reads: ['day', 5_000_000],
  d1Writes: ['day', 100_000],
  d1IndexWrites: ['day', 100_000],
  d1DatabaseBytes: ['gauge', 500_000_000],
  d1AccountBytes: ['gauge', 5_000_000_000],
  r2A: ['month', 1_000_000],
  r2B: ['month', 10_000_000],
  r2StoredBytes: ['gauge', 10_000_000_000],
  reservedBytes: ['gauge', 10_000_000_000],
  signatures: ['month', 1_000_000],
  jobRuns: ['day', 5_000],
  notificationWork: ['day', 10_000],
  backupWork: ['month', 100],
} as const satisfies Record<string, readonly [Period, number]>;

export type Metric = keyof typeof metricDefinitions;
export type Usage = Partial<Record<Metric, number>>;
type Limits = Record<Metric, number>;
export type CostTier = 'normal' | 'warning' | 'reduced' | 'blocked' | 'emergency';
export type Priority = 'bulk' | 'optional-write' | 'standard' | 'essential' | 'direct';
export const flags = [
  'maintenance_mode', 'registration_enabled', 'posting_enabled', 'comments_enabled',
  'image_upload_enabled', 'audio_upload_enabled', 'media_grants_enabled', 'direct_media_enabled',
  'downloads_enabled', 'search_enabled', 'notifications_enabled', 'scheduled_jobs_enabled',
] as const;
export type Feature = Exclude<typeof flags[number], 'maintenance_mode'>;
const directMetrics = ['r2A','r2B','r2StoredBytes'] satisfies Metric[];
const metrics = Object.keys(metricDefinitions) as Metric[];

export interface CostConfiguration {
  limits: Limits;
  warning: number;
  reduced: number;
  blocked: number;
  emergency: number;
  essentialCeiling: number;
  snapshotTtl: number;
}

export function costConfiguration(overrides: Partial<Omit<CostConfiguration, 'limits'>> & { limits?: Usage } = {}): CostConfiguration {
  const limits = Object.fromEntries(metrics.map(metric => [
    metric, overrides.limits?.[metric] ?? metricDefinitions[metric][1],
  ])) as Limits;
  const values = {
    warning: 70, reduced: 80, blocked: 90, emergency: 95, essentialCeiling: 98,
    snapshotTtl: 3_600_000, ...overrides, limits,
  };
  const steps = [values.warning, values.reduced, values.blocked, values.emergency, values.essentialCeiling];
  if (steps.some((step, i) => !Number.isInteger(step) || step <= (steps[i - 1] ?? 0) || step >= 100) ||
      !Number.isSafeInteger(values.snapshotTtl) || values.snapshotTtl <= 0 ||
      metrics.some(metric => !Number.isSafeInteger(limits[metric]) || limits[metric] <= 0 ||
        limits[metric] > metricDefinitions[metric][1])) {
    throw new Error('Invalid cost configuration');
  }
  return values;
}

export function utcWindows(now: number) {
  const day = new Date(now).toISOString().slice(0, 10);
  return { day, month: day.slice(0, 7) };
}

function validated(usage: Usage) {
  for (const [name, value] of Object.entries(usage)) {
    if (!Object.hasOwn(metricDefinitions, name) || !Number.isSafeInteger(value) || value < 0) {
      throw new Error('Invalid usage estimate');
    }
  }
}

const projection = `
WITH
  config AS MATERIALIZED (
    SELECT key AS metric, json_extract(value,'$.period') AS period,
      json_extract(value,'$.limit') AS max_value,
      CASE WHEN key='reservedBytes' THEN coalesce((SELECT held_bytes FROM media_capacity WHERE singleton=1),0)
        ELSE json_extract(value,'$.delta') END AS delta
    FROM json_each(?1)
  ),
  previous AS MATERIALIZED (
    SELECT metric, period, max_value, delta,
      CASE WHEN period = 'day' AND day <> ?2 OR period = 'month' AND month <> ?3
        THEN 0 ELSE coalesce(json_extract(counters,'$.' || metric),0) END AS old_value,
      CASE WHEN period = 'day' AND substr(snap_time,1,10) <> ?2
              OR period = 'month' AND substr(snap_time,1,7) <> ?3
        THEN 0 ELSE coalesce(json_extract(snapshot,'$.provider.' || metric),0) END AS observed,
      CASE WHEN period = 'day' AND substr(snap_time,1,10) <> ?2
              OR period = 'month' AND substr(snap_time,1,7) <> ?3
        THEN 0 ELSE coalesce(json_extract(snapshot,'$.checkpoint.' || metric),0) END AS checkpoint
    FROM config CROSS JOIN (
      SELECT *,coalesce(strftime('%Y-%m-%d',snapshot_at / 1000,'unixepoch'),'') AS snap_time
      FROM usage_windows WHERE name='service'
    )
  ),
  projected AS MATERIALIZED (
    SELECT metric, CASE WHEN metric='reservedBytes' THEN delta
        WHEN period='gauge' THEN max(old_value,delta) ELSE old_value+delta END AS total,
      CASE WHEN metric='reservedBytes' THEN delta
         WHEN period = 'gauge' THEN max(old_value,observed,delta)
         ELSE max(old_value+delta, observed+max(0,old_value-checkpoint)+delta) END * 100.0 / max_value AS pct
    FROM previous
  ),
  summary AS MATERIALIZED (
    SELECT json_group_object(metric,total) AS counters,max(pct) AS ratio FROM projected
  )
`;

export class Budget {
  private readonly db: Database;
  private readonly config: CostConfiguration;

  constructor(db: Database, config = costConfiguration()) {
    this.db = db;
    this.config = config;
  }

  async admit(priority: Priority, estimates: Usage, now: number, features: readonly Feature[] = []) {
    validated(estimates);
    const { day, month } = utcWindows(now);
    const ceiling = {
      bulk: this.config.reduced,
      'optional-write': this.config.blocked,
      standard: this.config.emergency,
      essential: this.config.essentialCeiling,
      direct: this.config.blocked,
    }[priority];
    const requiredFeatures = priority === 'direct'
      ? [...new Set([...features,'direct_media_enabled','media_grants_enabled'])] : features;
    const delta: Usage = {
      ...estimates,
      // Reserve a write and a conservative read allowance for accounting and flag checks.
      d1Reads: (estimates.d1Reads ?? 0) + 5 + requiredFeatures.length,
      d1Writes: (estimates.d1Writes ?? 0) + 1,
    };
    const config = Object.fromEntries(metrics.map(metric => [metric, {
      period: metricDefinitions[metric][0], limit: this.config.limits[metric], delta: delta[metric] ?? 0,
    }]));
    const result = await query(this.db, projection + `
      UPDATE usage_windows
      SET day=?2, month=?3, counters=(SELECT counters FROM summary)
      WHERE name='service' AND day<=?2 AND month<=?3
        AND (SELECT ratio FROM summary) < ?4
        AND (?5=1 OR EXISTS (SELECT 1 FROM feature_flags WHERE name='maintenance_mode' AND enabled=0))
        AND NOT EXISTS (
          SELECT 1 FROM json_each(?6) AS f
          LEFT JOIN feature_flags AS s ON s.name=f.value WHERE coalesce(s.enabled,0)=0
        )
        AND (?7=0 OR (snapshot_at > 0 AND snapshot_at <= ?8 AND snapshot_at > ?9
          AND json_type(snapshot,'$.provider.r2A') = 'integer'
          AND json_type(snapshot,'$.provider.r2B') = 'integer'
          AND json_type(snapshot,'$.provider.r2StoredBytes') = 'integer'))
      RETURNING (SELECT ratio FROM summary) AS ratio
    `, JSON.stringify(config), day, month, ceiling, priority === 'essential' ? 1 : 0,
      JSON.stringify(requiredFeatures), priority === 'direct' ? 1 : 0, now, now - this.config.snapshotTtl)
      .all<{ ratio: number }>();
    const ratio = result.results[0]?.ratio;
    return { allowed: ratio !== undefined, tier: ratio === undefined ? null : this.tier(ratio),
      meta: result.meta };
  }

  tier(ratio: number): CostTier {
    if (ratio >= this.config.emergency) return 'emergency';
    if (ratio >= this.config.blocked) return 'blocked';
    if (ratio >= this.config.reduced) return 'reduced';
    return ratio >= this.config.warning ? 'warning' : 'normal';
  }

  async compareSnapshot(provider: Usage, capturedAt: number, now: number) {
    validated(provider);
    if (!Number.isSafeInteger(capturedAt) || capturedAt <= 0 || capturedAt > now ||
        directMetrics.some(metric => provider[metric] === undefined)) {
      throw new Error('Incomplete or invalid provider snapshot');
    }
    // Reconciliation stamps a checkpoint of locally charged work. Old readings may
    // gate service conservatively but must never enable direct media.
    return query(this.db, `UPDATE usage_windows
      SET snapshot_at=?, snapshot=json_object('provider',json(?),'checkpoint',json(counters))
      WHERE name='service' AND snapshot_at < ? AND day <= ? AND month <= ?`,
    capturedAt, JSON.stringify(provider), capturedAt, utcWindows(capturedAt).day, utcWindows(capturedAt).month).run();
  }

  async setFlag(name: typeof flags[number], enabled: boolean, version: number, now: number) {
    return (await query(this.db, `UPDATE feature_flags SET enabled=?,version=version+1,updated_at=?
      WHERE name=? AND version=? AND updated_at<=?`, enabled ? 1 : 0, now, name, version, now).run()).meta.changes === 1;
  }
}
