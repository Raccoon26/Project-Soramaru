
import process from 'node:process';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { URL, pathToFileURL } from 'node:url';
import { migrationLedger, migrations, simulator } from './local-backend.mjs';
import { digest, isId } from '../services/api/src/platform.ts';

const format = 1;
const maxRows = 1200;
const maxCipherBytes = 8_000_000;
const expectedTables = ['schema_migrations',
  'member_numbers','members','member_profiles','terms_acceptances','member_sessions','role_grants',
  'official_identities','staff_credentials','staff_challenges','deletion_requests',
  'posts','comments','tags','post_tags','blocks','reactions','badge_catalog','badge_awards','applied_badges',
  'media_capacity','media_owner_capacity','media_reservations','media_objects','post_media','content_items',
  'usage_windows','feature_flags','rate_limits','scheduled_jobs','outbox','idempotency_keys','audit_events',
  'notifications','notification_reads'];
const crypt = globalThis.crypto;
const buffer = globalThis.Buffer;

function identifier(name) {
  if (!/^[a-z][a-z_0-9]*$/.test(name)) throw new Error('Invalid snapshot identifier');
  return '"' + name + '"';
}

export async function captureRows(db) {
  const rows = await db.batch(expectedTables.map(table =>
    db.prepare('SELECT * FROM ' + identifier(table) + ' ORDER BY rowid LIMIT ' + (maxRows + 1))));
  if (rows.some(row => row.results.length > maxRows)) throw new Error('Synthetic backup row limit exceeded');
  const schema = await db.prepare(`SELECT name,type,sql FROM sqlite_schema
    WHERE sql IS NOT NULL AND substr(name,1,1) <> '_' AND substr(name,1,7) <> 'sqlite_'
    ORDER BY name,type`).all();
  const tables = Object.fromEntries(expectedTables.map((table,i) => [table, rows[i].results]));
  if (tables.schema_migrations.length !== (await migrations()).length) throw new Error('Apply all local migrations before backup');
  return { schema: schema.results, tables };
}

export function schemaIdentity(entries) {
  return entries.map(entry => [
    entry.name,entry.type,entry.sql.replace(/\s+/g,' ').replace(/\( | \)/g, match=>match.trim()).trim(),
  ]);
}

export async function backup(db, key, now = Date.now()) {
  const content = JSON.stringify({ format, at: now, ...await captureRows(db) });
  const bytes = new globalThis.TextEncoder().encode(content);
  if (bytes.length > maxCipherBytes - 16) throw new Error('Synthetic backup byte limit exceeded');
  const aad = await digest(content);
  const iv = crypt.getRandomValues(new Uint8Array(12));
  const cipher = await crypt.subtle.encrypt({ name:'AES-GCM',iv,additionalData:new globalThis.TextEncoder().encode(aad) },key,bytes);
  return {
    format, checksum:aad,
    nonce:buffer.from(iv).toString('base64url'), data:buffer.from(cipher).toString('base64url'),
  };
}

export async function backupKey(secret) {
  if (secret.byteLength !== 32) throw new Error('A 32-byte AES key is required');
  return crypt.subtle.importKey('raw',secret,'AES-GCM',false,['encrypt','decrypt']);
}

async function unpack(envelope,key) {
  if (envelope?.format !== format || typeof envelope.checksum !== 'string' ||
      !/^[0-9a-f]{64}$/.test(envelope.checksum) || typeof envelope.data !== 'string' ||
      envelope.data.length > Math.ceil(maxCipherBytes * 4/3)) throw new Error('Invalid backup envelope');
  const iv = buffer.from(envelope.nonce,'base64url');
  if (iv.byteLength !== 12) throw new Error('Invalid nonce');
  const data = await crypt.subtle.decrypt({name:'AES-GCM',iv,additionalData:new globalThis.TextEncoder().encode(envelope.checksum)},
    key,buffer.from(envelope.data,'base64url'));
  const content = new globalThis.TextDecoder('utf-8',{fatal:true}).decode(data);
  if (await digest(content) !== envelope.checksum) throw new Error('Backup checksum mismatch');
  return JSON.parse(content);
}

// Deletion journal is collected from the latest trusted database before restore.
// Every entry is applied while the target remains unavailable to the application.
export async function restore(db,envelope,key,journal) {
  const saved = await unpack(envelope,key);
  const list = await migrations();
  if (!journal || !Number.isSafeInteger(journal.through) || journal.through < saved.at ||
      !Array.isArray(journal.entries) || journal.entries.length > maxRows ||
      saved.format !== format || !Number.isSafeInteger(saved.at)) throw new Error('Deletion journal or backup version invalid');
  const names = Object.keys(saved.tables);
  if (JSON.stringify(names) !== JSON.stringify(expectedTables) ||
      saved.tables.schema_migrations.length !== list.length ||
      saved.tables.schema_migrations.some((entry,i) => entry.checksum !== list[i].checksum ||
        entry.version !== list[i].version || entry.name !== list[i].name)) throw new Error('Backup schema differs');
  const empty = await db.prepare(`SELECT 1 AS busy FROM sqlite_schema WHERE type='table'
    AND substr(name,1,1)<>'_' AND substr(name,1,7)<>'sqlite_' LIMIT 1`).first();
  if (empty) throw new Error('Restore requires a separate empty database');

  const sql = list.flatMap(item => item.statements);
  const create = sql.filter(statement => /^CREATE TABLE /.test(statement));
  const attach = sql.filter(statement => /^CREATE (?:(?:UNIQUE )?INDEX|TRIGGER) /.test(statement));
  const records = expectedTables.flatMap(table => {
    const rows = saved.tables[table];
    if (!Array.isArray(rows) || rows.length > maxRows) throw new Error('Invalid snapshot records');
    return rows.map(row => {
      const columns = Object.keys(row);
      if (!columns.length) throw new Error('Empty snapshot record');
      return db.prepare('INSERT INTO ' + identifier(table) + ' (' + columns.map(identifier).join(',') +
        ') VALUES (' + columns.map(() => '?').join(',') + ')').bind(...columns.map(column => row[column]));
    });
  });
  const deletion = journal.entries.flatMap(entry => {
    if (!Number.isSafeInteger(entry.at) || entry.at < 1 || entry.at > journal.through) {
      throw new Error('Invalid deletion journal entry timestamp');
    }
    if (entry.kind === 'post' || entry.kind === 'content') {
      if (!isId(entry.id)) throw new Error('Invalid deletion journal content ID');
      const table = entry.kind === 'post' ? 'posts' : 'content_items';
      return [db.prepare("UPDATE " + table +
        " SET state='deleted',updated_at=max(updated_at,?1),version=version+1 WHERE id=?2 AND state<>'deleted'")
        .bind(entry.at,entry.id)];
    }
    if (!isId(entry.memberId) || entry.kind && entry.kind !== 'account') throw new Error('Invalid deletion journal account ID');
    return [
      db.prepare(`UPDATE members SET state='deleting',revoked_before=max(revoked_before,?1),
        updated_at=max(updated_at,?1),version=version+1 WHERE id=?2 AND state NOT IN ('deleting','deleted')`)
        .bind(entry.at,entry.memberId),
      db.prepare(`UPDATE posts SET state='hidden',updated_at=max(updated_at,?1),version=version+1
        WHERE author_id=?2 AND state='approved'`).bind(entry.at,entry.memberId),
      db.prepare(`UPDATE content_items SET state='hidden',updated_at=max(updated_at,?1),version=version+1
        WHERE publisher_id=?2 AND state='approved'`).bind(entry.at,entry.memberId),
      db.prepare(`INSERT INTO deletion_requests SELECT ?1,?2,'requested',?3,?3
        FROM members WHERE id=?2 AND state='deleting' ON CONFLICT(member_id) DO NOTHING`)
        .bind(crypt.randomUUID(),entry.memberId,entry.at),
      db.prepare(`INSERT INTO audit_events VALUES (?1,(SELECT id FROM members WHERE id=?2),
        'deletion_replay','completed',?3)`).bind(crypt.randomUUID(),entry.memberId,entry.at),
    ];
  });
  await db.batch([
    db.prepare(migrationLedger),
    ...create.map(statement => db.prepare(statement)),
    db.prepare('PRAGMA defer_foreign_keys=ON'),
    ...records,...attach.map(statement => db.prepare(statement)),...deletion,
  ]);
  return saved.at;
}

const archive = new URL('../.local/backend/backups/',import.meta.url);

async function run() {
  const [action,file] = process.argv.slice(2);
  const hex = process.env.SORAMARU_BACKUP_KEY;
  if (!hex || !/^[0-9a-f]{64}$/i.test(hex)) throw new Error('Provide SORAMARU_BACKUP_KEY through the local process environment');
  const key = await backupKey(buffer.from(hex,'hex'));
  if (action === 'backup') {
    const runtime = simulator('local',{ persist:true });
    try {
      const db = await runtime.getD1Database('DB');
      const envelope = await backup(db,key);
      await mkdir(archive,{recursive:true});
      const name = 'synthetic-' + Date.now() + '.json';
      await writeFile(new URL(name,archive),JSON.stringify(envelope) + '\n',{flag:'wx'});
      globalThis.console.log('Saved ' + name);
    } finally {
      await runtime.dispose();
    }
  } else if (action === 'verify' && /^synthetic-\d+\.json$/.test(file ?? '')) {
    const runtime = simulator('test');
    try {
      const envelope = JSON.parse(await readFile(new URL(file,archive),'utf8'));
      const db = await runtime.getD1Database('DB');
      await restore(db,envelope,key,{ through:Date.now(),entries:[] });
      const actual = await captureRows(db);
      const original = await unpack(envelope,key);
      if (JSON.stringify(actual.tables) !== JSON.stringify(original.tables)) throw new Error('Data comparison failed');
      if (JSON.stringify(schemaIdentity(actual.schema)) !== JSON.stringify(schemaIdentity(original.schema))) {
        throw new Error('Schema comparison failed');
      }
      globalThis.console.log('Synthetic restore data and schema verified');
    } finally {
      await runtime.dispose();
    }
  } else {
    throw new Error('Choose backup or verify synthetic-<time>.json');
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await run();
}
