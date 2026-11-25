
export type SqlValue = string | number | null;

export interface QueryMeta {
  changes: number;
  rows_read: number;
  rows_written: number;
}

export interface QueryResult<T = unknown> {
  results: T[];
  meta: QueryMeta;
}

export interface Statement {
  bind(...values: SqlValue[]): Statement;
  first<T = Record<string, SqlValue>>(): Promise<T | null>;
  all<T = Record<string, SqlValue>>(): Promise<QueryResult<T>>;
  run(): Promise<QueryResult>;
}

export interface Database {
  prepare(sql: string): Statement;
  batch<T = unknown>(queries: Statement[]): Promise<QueryResult<T>[]>;
}

export interface ObjectHead {
  key: string;
  size: number;
  uploaded: Date;
  customMetadata?: Record<string, string>;
  httpMetadata?: { contentType?: string };
}

export interface ObjectBody extends ObjectHead {
  body: ReadableStream<Uint8Array>;
  arrayBuffer(): Promise<ArrayBuffer>;
}

export interface Bucket {
  put(key: string, value: ArrayBuffer | Uint8Array,
    options?: { customMetadata?: Record<string, string>; httpMetadata?: { contentType: string };
      onlyIf?: { etagDoesNotMatch: string } }): Promise<ObjectHead | null>;
  get(key: string, options?: { range: { offset: number; length: number } }): Promise<ObjectBody | null>;
  head(key: string): Promise<ObjectHead | null>;
  delete(key: string): Promise<void>;
  list(options: { prefix: string; limit: number; cursor?: string }):
    Promise<{ objects: ObjectHead[] } & ({ truncated: false } | { truncated: true; cursor: string })>;
}

export interface Env {
  APP_ENV: 'local' | 'test';
  DB: Database;
  PRIVATE_MEDIA: Bucket;
  QUARANTINE: Bucket;
}

export function checkEnvironment(env: Partial<Env> | undefined): Env {
  if ((env?.APP_ENV !== 'local' && env?.APP_ENV !== 'test') ||
      typeof env.DB?.prepare !== 'function' || typeof env.DB.batch !== 'function' ||
      typeof env.PRIVATE_MEDIA?.head !== 'function' || typeof env.QUARANTINE?.head !== 'function') {
    throw new Error('Unavailable server environment or binding');
  }
  return { APP_ENV: env.APP_ENV, DB: env.DB, PRIVATE_MEDIA: env.PRIVATE_MEDIA, QUARANTINE: env.QUARANTINE };
}

export const schemaVersion = 8;

export function query(db: Database, sql: string, ...params: SqlValue[]): Statement {
  const statement = db.prepare(sql);
  return params.length === 0 ? statement : statement.bind(...params);
}

export function isId(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
}

export async function digest(data: string | ArrayBuffer): Promise<string> {
  const input = typeof data === 'string' ? new TextEncoder().encode(data) : data;
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', input)),
    octet => octet.toString(16).padStart(2, '0')).join('');
}
