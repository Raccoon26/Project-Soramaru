import { banned } from './community-input.ts';
import { HttpError } from './http.ts';
import { query } from './platform.ts';
import type { Database } from './platform.ts';

export type SearchKind='post'|'member'|'tag'|'album';

export function normalizeSearch(text: string) {
  return text.normalize('NFKC').toLowerCase()
    .replace(/[\u30a1-\u30f6\u30fd-\u30fe]/gu,kana=>String.fromCharCode(kana.charCodeAt(0)-0x60))
    .replace(/\s+/gu,' ').trim();
}

export function searchInput(value: string|null) {
  if (value===null||value.length>240||banned.test(value)) throw new HttpError(400,'invalid_request');
  const normalized=normalizeSearch(value);
  const tokens=normalized.split(' ');
  if (!normalized||[...normalized].length>60||tokens.length>4) throw new HttpError(400,'invalid_request');
  return {normalized,tokens};
}

export function literalMatch(tokens: string[]) {
  return tokens.map(token=>'"'+token.replaceAll('"','""')+'"').join(' AND ');
}

export function indexedText(db:Database, kind:SearchKind, id:string, text:string, version:number, requireChange=false, fromBackfill=false) {
  const body=normalizeSearch(text);
  const conditions={post:"SELECT 1 FROM posts WHERE id=? AND version=? AND state='approved'",
    member:'SELECT 1 FROM member_profiles WHERE member_id=? AND version=? AND configured_at IS NOT NULL',
    tag:'SELECT 1 FROM tags WHERE id=? AND ?=0',
    album:"SELECT 1 FROM content_items WHERE id=? AND version=? AND kind='gallery' AND state='approved'"};
  return query(db,`INSERT INTO search_documents(kind,target,prefix,body,source_version) SELECT ?,?,?,?,? WHERE ${fromBackfill?'EXISTS('+conditions[kind]+')':requireChange?'changes()=1':'1'}
    ON CONFLICT(kind,target) DO UPDATE SET prefix=excluded.prefix,body=excluded.body,source_version=excluded.source_version
      WHERE search_documents.source_version<=excluded.source_version AND
        (search_documents.source_version<>excluded.source_version OR search_documents.body<>excluded.body OR search_documents.prefix<>excluded.prefix)`,
  kind,id,body.slice(0,240),kind==='post'||kind==='album'?body:'',version,...(fromBackfill?[id,version]:[]));
}

const sources={
  post:"SELECT id,body AS text,version FROM posts WHERE id>? AND state='approved' ORDER BY id LIMIT ?",
  member:"SELECT member_id AS id,nickname AS text,version FROM member_profiles WHERE member_id>? AND configured_at IS NOT NULL ORDER BY member_id LIMIT ?",
  tag:"SELECT id,label AS text,0 AS version FROM tags WHERE id>? ORDER BY id LIMIT ?",
  album:"SELECT id,title AS text,version FROM content_items WHERE id>? AND kind='gallery' AND state='approved' ORDER BY id LIMIT ?",
} as const;

export async function backfillSearch(db:Database,kind:SearchKind,limit=20) {
  if (!Number.isInteger(limit)||limit<1||limit>40) throw new RangeError('Invalid search batch size');
  const mark=await query(db,'SELECT last_id FROM discovery_backfill WHERE kind=?',kind).first<{last_id:string}>();
  const previous=mark?.last_id??'';
  const rows=(await query(db,sources[kind],previous,limit).all<{id:string;text:string;version:number}>()).results;
  const last=rows.at(-1)?.id;
  if (last) await db.batch([
    ...rows.map(row=>indexedText(db,kind,row.id,row.text,row.version,false,true)),
    query(db,`INSERT INTO discovery_backfill VALUES (?,?) ON CONFLICT(kind) DO UPDATE SET last_id=excluded.last_id
      WHERE discovery_backfill.last_id=?`,kind,last,previous),
  ]);
  return {count:rows.length,complete:rows.length<limit};
}
