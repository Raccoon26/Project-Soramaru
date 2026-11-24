import process from 'node:process';

import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { mkdir, readdir, readFile, rename } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL, URL } from 'node:url';
import { join } from 'node:path';
import { bindingNames, compatibilityDate, localEnvironment } from '../services/api/local-config.ts';
import { digest } from '../services/api/src/platform.ts';

const backendRoot = fileURLToPath(new URL('../.local/backend/', import.meta.url));

export function simulator(environment = 'test', { persist = false } = {}) {
  const mode = localEnvironment(environment);
  const names = bindingNames(mode);
  const path = join(backendRoot, mode);
  return new Miniflare(convertV4MiniflareOptions({
    name: 'soramaru-emulator',
    compatibilityDate,
    modules: true,
    script: 'export default {fetch(){return new Response("emulator")}}',
    host: '127.0.0.1',
    d1Databases: { DB: names.db },
    r2Buckets: { PRIVATE_MEDIA: names.media, QUARANTINE: names.quarantine },
    resourcePersistencePath: persist ? join(path, 'v3') : undefined,
    outboundService: () => new globalThis.Response('Network disabled', { status: 403 }),
  }));
}

export async function migrations() {
  const dir = new URL('../database/migrations/', import.meta.url);
  const files = (await readdir(dir)).filter(name => name.endsWith('.sql')).sort();
  return Promise.all(files.map(async (name, index) => {
    if (!name.startsWith(String(index + 1).padStart(4, '0') + '_')) {
      throw new Error('Migration order or duplicate version: ' + name);
    }
    const source = (await readFile(new URL(name, dir), 'utf8')).replaceAll('\r\n', '\n');
    return { version: index + 1, name, checksum: await digest(source),
      statements: source.split(/^-- statement\s*$/m).map(sql => sql.trim()).filter(Boolean) };
  }));
}

export const migrationLedger = `CREATE TABLE schema_migrations (
  version INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, checksum TEXT NOT NULL CHECK(length(checksum)=64),
  applied_at INTEGER NOT NULL CHECK(applied_at>=0)
) STRICT`;

export async function migrate(db, list = undefined) {
  const steps = list ?? await migrations();
  for (const [index, step] of steps.entries()) {
    if (step.version !== index + 1 || step.statements.length === 0) throw new Error('Migration sequence invalid');
  }
  await db.prepare(migrationLedger.replace('CREATE TABLE','CREATE TABLE IF NOT EXISTS')).run();
  const { results: applied } = await db.prepare('SELECT * FROM schema_migrations ORDER BY version').all();
  for (const [index, row] of applied.entries()) {
    const candidate = steps[index];
    if (!candidate || candidate.version !== row.version || candidate.name !== row.name || candidate.checksum !== row.checksum) {
      throw new Error('Migration history diverged at version ' + row.version);
    }
  }
  for (const entry of steps.slice(applied.length)) {
    const ledger = db.prepare('INSERT INTO schema_migrations VALUES (?,?,?,?)')
      .bind(entry.version, entry.name, entry.checksum, Date.now());
    try {
      await db.batch([ledger, ...entry.statements.map(sql => db.prepare(sql))]);
    } catch (error) {
      const competing = await db.prepare('SELECT name, checksum FROM schema_migrations WHERE version=?').bind(entry.version).first();
      if (!competing || competing.name !== entry.name || competing.checksum !== entry.checksum) throw error;
    }
  }
  return steps.length;
}

export const demoMember = '10000000-0000-4000-8000-000000000001';

export async function seed(db) {
  await db.batch([
    db.prepare("INSERT INTO member_numbers VALUES ('SYNTH0001',0) ON CONFLICT(number) DO NOTHING"),
    db.prepare("INSERT INTO members(id,auth_uid,member_no,state,joined_at,updated_at) VALUES (?,NULL,'SYNTH0001','active',0,0) ON CONFLICT(id) DO NOTHING").bind(demoMember),
    db.prepare("INSERT INTO member_profiles(member_id,nickname,updated_at) VALUES (?,'Sample',0) ON CONFLICT(member_id) DO NOTHING").bind(demoMember),
  ]);
}

async function run() {
  const [action, suppliedMode] = process.argv.slice(2);
  const mode = localEnvironment(suppliedMode ?? process.env.SORAMARU_RUNTIME);
  if (action === 'reset') {
    await mkdir(backendRoot, { recursive: true });
    try {
      await rename(join(backendRoot, mode), join(backendRoot, mode + '-previous-' + globalThis.crypto.randomUUID()));
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  } else if (action !== 'migrate' && action !== 'seed') {
    throw new Error('Choose migrate, seed or reset');
  }
  const runtime = simulator(mode, { persist: true });
  try {
    const db = await runtime.getD1Database('DB');
    const version = await migrate(db);
    if (action === 'seed') await seed(db);
    globalThis.console.log(mode + ' emulated D1 schema ' + version);
  } finally {
    await runtime.dispose();
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await run();
}
