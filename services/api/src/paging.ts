
import type { CursorPage } from '@soramaru/shared';
import { HttpError } from './http.ts';
import { isId, query } from './platform.ts';
import type { Database } from './platform.ts';

interface Position { cutoff: number; created: number; id: string; expires: number; scope: string }

function encode(bytes: Uint8Array) {
  return btoa(String.fromCharCode(...bytes)).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');
}

function decode(value: string) {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) throw new Error('Invalid base64url');
  const bytes = Uint8Array.from(atob(value.replaceAll('-','+').replaceAll('_','/')), char => char.charCodeAt(0));
  if (encode(bytes) !== value) throw new Error('Non-canonical token');
  return bytes;
}

export function cursorKey(secret: Uint8Array<ArrayBuffer>) {
  if (secret.byteLength < 32) throw new Error('Cursor key must be at least 32 bytes');
  return crypto.subtle.importKey('raw',secret,{ name:'HMAC',hash:'SHA-256' },false,['sign','verify']);
}

export async function openCursor(key: CryptoKey, raw: string, scope: string, now: number): Promise<Position> {
  try {
    const [encoded, mac, extra] = raw.split('.');
    if (raw.length > 768 || !encoded || !mac || extra !== undefined) throw new Error('Malformed cursor');
    const bytes = decode(encoded);
    if (!await crypto.subtle.verify('HMAC', key, decode(mac), bytes)) throw new Error('Invalid MAC');
    const value = JSON.parse(new TextDecoder().decode(bytes)) as Position;
    if (!isId(value.id) || value.scope !== scope || value.expires <= now ||
        !Number.isSafeInteger(value.created) || !Number.isSafeInteger(value.cutoff) ||
        value.created < 0 || value.created > value.cutoff || value.cutoff > now) throw new Error('Invalid position');
    return value;
  } catch {
    throw new HttpError(400,'invalid_request');
  }
}

export async function sealCursor(key: CryptoKey, position: Position) {
  const bytes=new TextEncoder().encode(JSON.stringify(position));
  return encode(bytes)+'.'+encode(new Uint8Array(await crypto.subtle.sign('HMAC',key,bytes)));
}

export function pageSize(raw: string | null) {
  if (raw === null) return 20;
  if (!/^[1-9]\d?$/.test(raw) || Number(raw)>50) throw new HttpError(400,'invalid_request');
  return Number(raw);
}

const visiblePost = `p.state='approved' AND p.publish_at<=?
  AND EXISTS(SELECT 1 FROM members AS m WHERE m.id=p.author_id AND m.state='active')
  AND NOT EXISTS(SELECT 1 FROM blocks WHERE blocker_id=? AND blocked_id=p.author_id)
  AND NOT EXISTS(SELECT 1 FROM blocks WHERE blocked_id=? AND blocker_id=p.author_id)`;

export async function readFeed(db: Database, key: CryptoKey, actor: string, now: number,
  limit: number, rawCursor: string | null = null, author: string | null = null) {
  if (!isId(actor) || author !== null && !isId(author) || !Number.isInteger(limit) || limit < 1 || limit > 50) {
    throw new HttpError(400,'invalid_request');
  }
  const scope = ['feed',actor,author ?? 'all'].join(':');
  const position = rawCursor === null ? null : await openCursor(key,rawCursor,scope,now);
  const cutoff = position?.cutoff ?? now;
  const authorFilter = author === null ? '' : 'AND p.author_id=?';
  const sort = position ? 'AND (p.created_at,p.id)<(?,?)' : '';
  const stmt = query(db,`SELECT p.id,p.author_id,p.created_at
    FROM posts AS p WHERE ${visiblePost} AND p.created_at<=? ${authorFilter} ${sort}
    ORDER BY p.created_at DESC,p.id DESC LIMIT ?`,
  cutoff,actor,actor,cutoff,...(author ? [author] : []),...(position ? [position.created,position.id] : []),limit+1);
  const result = await stmt.all<{ id: string; author_id: string; created_at: number }>();
  const items = result.results.slice(0,limit);
  const last = items.at(-1);
  let nextCursor = null;
  if (last && result.results.length>limit) {
    const bytes = new TextEncoder().encode(JSON.stringify({
      cutoff, created: last.created_at, id: last.id, expires: position?.expires ?? now + 900_000, scope,
    } satisfies Position));
    nextCursor = encode(bytes) + '.' + encode(new Uint8Array(await crypto.subtle.sign('HMAC',key,bytes)));
  }
  return { page: { items, nextCursor } satisfies CursorPage<typeof items[number]>, meta: result.meta };
}

export function visibleContent(db: Database, id: string, now: number) {
  if (!isId(id)) throw new HttpError(404,'not_found');
  return query(db,`SELECT c.id,c.kind,c.title,c.publish_at FROM content_items AS c
    JOIN members m ON m.id=c.publisher_id AND m.state='active'
    WHERE c.id=? AND c.state='approved' AND c.visibility='members' AND c.publish_at<=?`, id,now).first();
}
