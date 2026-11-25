
import { HttpError } from './http.ts';
import type { Actor } from './auth.ts';
import { requireRole } from './auth.ts';
import { Budget } from './cost.ts';
import { allowRate } from './rate.ts';
import { auditStatement } from './writes.ts';
import { digest, isId, query } from './platform.ts';
import { policyDocuments,policyVersion } from './membership-policy.ts';
import type { PhotoPurpose } from './photo-format.ts';
import type { Env } from './platform.ts';

const keyFor = (id: string) => 'objects/' + id;
const ttl = 900_000;
const urlTtl = 300;
const maxRange = 1_048_576;
const uploadMedia = new Set(['image/jpeg','image/png','image/webp','audio/mp4','application/octet-stream']);
const terminalStates = new Set(['deleted','expired','cancelled']);
type State = 'reserved' | 'quarantined' | 'approved' | 'attached' | 'deleting' | 'cancelled' | 'expired' | 'deleted';

export interface Reservation {
  id: string;
  owner_id: string;
  reserved_bytes: number;
  mime: string;
  state: State;
  expires_at: number;
  purpose: PhotoPurpose|null;
  expected_sha: string|null;
  variant_id: string|null;
}

export interface MediaRow { id: string; object_key: string; actual_bytes: number; sha256: string; mime: string }
interface PhotoUpload {purpose:PhotoPurpose;hash:string;variant:string|null}
interface SessionGuard {id:string;member:string;validSince:number}
interface Capacity { global: number; member: number; pending: number }

export class MediaStore {
  private readonly env: Env;
  private readonly clock: () => number;
  private readonly capacity: Capacity;
  private readonly budget: Budget;
  private readonly session: SessionGuard|undefined;

  constructor(env: Env, clock = Date.now,
    capacity: Capacity = { global: 8_000_000_000, member: 52_428_800, pending: 10 }, budget = new Budget(env.DB), session?: SessionGuard) {
    this.env = env;
    this.clock = clock;
    this.capacity = capacity;
    this.session = session;
    this.budget = budget;
    if (Object.values(capacity).some(value => !Number.isSafeInteger(value) || value < 1)) {
      throw new Error('Invalid upload policy');
    }
  }

  private guard(start: number, now: number) {
    if(!this.session) return {sql:'1',params:[]};
    const arg=(index:number)=>'?'+(start+index);
    return {
      sql:`EXISTS(SELECT 1 FROM member_sessions s JOIN members m ON m.id=s.member_id
        WHERE s.id=${arg(0)} AND m.id=${arg(1)} AND m.state='active' AND s.revoked_at IS NULL
        AND s.expires_at>${arg(2)} AND s.firebase_auth_at>=max(m.revoked_before,${arg(3)})
        AND (SELECT count(*) FROM policy_acceptances WHERE member_id=m.id AND version=${arg(4)})=${arg(5)})`,
      params:[this.session.id,this.session.member,now,this.session.validSince,policyVersion,policyDocuments.length],
    };
  }

  async reserve(actor: Actor, requestKey: string, bytes: number, mime: string, photo?: PhotoUpload) {
    const now = this.clock();
    const limit = mime === 'audio/mp4' ? 26_214_400 : 800_000;
    if (!isId(actor.id) || !/^[A-Za-z0-9_-]{8,80}$/.test(requestKey) ||
        !uploadMedia.has(mime) || !Number.isSafeInteger(bytes) || bytes < 1) {
      throw new HttpError(400,'invalid_request');
    }
    if (bytes > limit) throw new HttpError(413,'payload_too_large');
    if (mime === 'audio/mp4') requireRole(actor,'artist');
    await this.admitUpload(mime,bytes,0,0);
    const db = this.env.DB;
    const id = crypto.randomUUID();
    const guard=this.guard(14,now);
    const result = await query(db,`
      INSERT INTO media_reservations
        (id,owner_id,request_key,reserved_bytes,mime,state,created_at,expires_at,updated_at,purpose,expected_sha,variant_id)
      SELECT ?1,?2,?3,?4,?5,'reserved',?6,?7,?6,?11,?12,?13
      FROM media_capacity WHERE singleton=1 AND held_bytes+2*?4<=?8
        AND EXISTS (SELECT 1 FROM members WHERE id=?2 AND state='active')
        AND coalesce((SELECT pending FROM media_owner_capacity WHERE owner_id=?2),0)<?9
        AND coalesce((SELECT held_bytes FROM media_owner_capacity WHERE owner_id=?2),0)+?4<=?10
        AND ${guard.sql}
        AND (?13 IS NULL OR EXISTS(SELECT 1 FROM media_reservations root WHERE root.id=?13 AND root.owner_id=?2
          AND root.purpose IN ('post','gallery') AND root.state IN ('approved','attached')))
      ON CONFLICT DO NOTHING RETURNING *
    `,id,actor.id,requestKey,bytes,mime,now,now+ttl,this.capacity.global,this.capacity.pending,this.capacity.member,photo?.purpose??null,photo?.hash??null,photo?.variant??null,...guard.params)
      .all<Reservation>();
    const created = result.results[0];
    if (created) {
      await auditStatement(db,'reservation','allowed',now,actor.id).run();
      return created;
    }
    const previous = await query(db,'SELECT * FROM media_reservations WHERE owner_id=? AND request_key=?',actor.id,requestKey)
      .first<Reservation>();
    if (!previous) throw new HttpError(503,'cost_limited',60);
    if (previous.reserved_bytes !== bytes || previous.mime !== mime || previous.purpose!==(photo?.purpose??null) || previous.expected_sha!==(photo?.hash??null) || previous.variant_id!==(photo?.variant??null) || terminalStates.has(previous.state) ||
        previous.state === 'deleting' || ['reserved','quarantined'].includes(previous.state) && previous.expires_at <= now) {
      throw new HttpError(409,'conflict');
    }
    return previous;
  }

  private async admitUpload(mime: string,bytes: number,write: number,read: number) {
    const audio = mime === 'audio/mp4';
    const gate = await this.budget.admit(audio || bytes >= 400_000 ? 'bulk' : 'optional-write',{
      d1Reads:30,d1Writes:10,d1IndexWrites:4,r2A:write,r2B:read,
    },this.clock(),[audio ? 'audio_upload_enabled' : 'image_upload_enabled']);
    if (!gate.allowed) throw new HttpError(503,'cost_limited',60);
  }

  async status(id: string, actor: string) {
    if (!isId(id) || !isId(actor)) throw new HttpError(404,'not_found');
    const guard=this.guard(3,this.clock());
    const found = await query(this.env.DB,`SELECT r.* FROM media_reservations r
      JOIN members m ON m.id=r.owner_id AND m.state='active' WHERE r.id=?1 AND r.owner_id=?2 AND ${guard.sql}`,id,actor,...guard.params).first<Reservation>();
    if (!found) throw new HttpError(404,'not_found');
    return found;
  }

  async quarantine(actor: Actor, id: string, data: ArrayBuffer) {
    const found = await this.status(id,actor.id);
    if (found.expires_at <= this.clock() || !['reserved','quarantined'].includes(found.state)) {
      throw new HttpError(409,'conflict');
    }
    if (data.byteLength < 1 || data.byteLength > found.reserved_bytes) throw new HttpError(413,'payload_too_large');
    await this.admitUpload(found.mime,data.byteLength,1,1);
    const sha = await digest(data);
    if(found.expected_sha!==null&&(sha!==found.expected_sha||data.byteLength!==found.reserved_bytes)) throw new HttpError(409,'conflict');
    const key = keyFor(id);
    const object = await this.env.QUARANTINE.put(key,data,{
      customMetadata: { sha256: sha }, httpMetadata: { contentType: found.mime },
      onlyIf: { etagDoesNotMatch: '*' },
    }) ?? await this.env.QUARANTINE.head(key);
    if (!object || object.size !== data.byteLength || object.customMetadata?.sha256 !== sha) {
      throw new HttpError(409,'conflict');
    }
    // A failed D1 batch leaves a private quarantine copy, so the same upload can be retried.
    const at = this.clock();
    const db = this.env.DB;
    const guard=this.guard(7,at);
    const writeGuard=this.guard(5,at);
    await db.batch([
      query(db,`INSERT INTO media_objects(id,owner_id,object_key,actual_bytes,mime,sha256,variant_of)
        SELECT id,owner_id,?1,?2,mime,?3,variant_id FROM media_reservations
        WHERE id=?4 AND owner_id=?5 AND state='reserved' AND expires_at>?6 AND ${guard.sql}
        ON CONFLICT(id) DO NOTHING`,key,data.byteLength,sha,id,actor.id,at,...guard.params),
      query(db,`UPDATE media_reservations SET state='quarantined',updated_at=?1
        WHERE id=?2 AND owner_id=?3 AND state='reserved' AND expires_at>?1
        AND EXISTS(SELECT 1 FROM media_objects WHERE id=?2 AND sha256=?4) AND ${writeGuard.sql}`,at,id,actor.id,sha,...writeGuard.params),
    ]);
    const confirmed = await this.status(id,actor.id);
    if (confirmed.state !== 'quarantined') {
      if (terminalStates.has(confirmed.state) || confirmed.state === 'deleting') {
        await this.env.QUARANTINE.delete(key);
      }
      throw new HttpError(409,'conflict');
    }
    return { sha256: sha, bytes: data.byteLength };
  }

  async approve(owner: Actor, id: string, inspect: (bytes: ArrayBuffer, mime: string) => Promise<boolean|{width:number;height:number}>) {
    const row = await this.status(id,owner.id);
    const key = keyFor(id);
    if (['approved','attached'].includes(row.state)) {
      await this.settle(row);
      return;
    }
    if (row.state !== 'quarantined' || row.expires_at <= this.clock()) throw new HttpError(409,'conflict');
    await this.admitUpload(row.mime,row.reserved_bytes,1,2);
    const db = this.env.DB;
    const meta = await query(db,'SELECT * FROM media_objects WHERE id=? AND owner_id=?',id,owner.id).first<MediaRow>();
    const quarantine = await this.env.QUARANTINE.get(key);
    if (!meta || !quarantine || quarantine.size !== meta.actual_bytes) throw new HttpError(503,'unavailable',30);
    const data = await quarantine.arrayBuffer();
    if(await digest(data)!==meta.sha256) throw new HttpError(403,'access_denied');
    const inspected=await inspect(data,meta.mime);
    if(!inspected) throw new HttpError(403,'access_denied');
    const copy = await this.env.PRIVATE_MEDIA.put(key,data,{
      customMetadata: { sha256: meta.sha256 },httpMetadata: { contentType: meta.mime },
      onlyIf: { etagDoesNotMatch: '*' },
    }) ?? await this.env.PRIVATE_MEDIA.head(key);
    if (!copy || copy.size !== meta.actual_bytes || copy.customMetadata?.sha256 !== meta.sha256) {
      throw new HttpError(503,'unavailable',30);
    }
    const now = this.clock();
    const guard=this.guard(4,now);
    const update = await db.batch([
      query(db,`UPDATE media_reservations SET state='approved',updated_at=?1
      WHERE id=?2 AND owner_id=?3 AND state='quarantined' AND expires_at>?1 AND ${guard.sql}`,now,id,owner.id,...guard.params),
      ...(typeof inspected==='object'?[query(db,`UPDATE media_objects SET width=?,height=? WHERE id=? AND changes()=1`,inspected.width,inspected.height,id)]:[]),
    ]);
    if (update[0]?.meta.changes !== 1 && !['approved','attached'].includes((await this.status(id,owner.id)).state)) {
      throw new HttpError(409,'conflict');
    }
    await this.settle(row);
  }

  private async settle(row: Reservation) {
    await this.env.QUARANTINE.delete(keyFor(row.id));
    if (row.purpose!==null) {
      await query(this.env.DB,`UPDATE media_reservations SET quarantine_released=1
        WHERE id=? AND state IN ('approved','attached') AND quarantine_released=0`,row.id).run();
    }
  }

  async attachToPost(owner: Actor, id: string, post: string, position: number) {
    await this.status(id,owner.id);
    if (!isId(post) || !Number.isInteger(position) || position < 0 || position > 9) throw new HttpError(400,'invalid_request');
    const db = this.env.DB;
    const answer = await db.batch([
      query(db,`INSERT INTO post_media(post_id,media_id,position) SELECT p.id,r.id,?1
        FROM posts p JOIN media_reservations r ON r.owner_id=p.author_id
        WHERE p.id=?2 AND r.id=?3 AND p.author_id=?4 AND p.state NOT IN ('hidden','deleted')
          AND r.state IN ('approved','attached') AND r.mime LIKE 'image/%'
        ON CONFLICT(post_id,media_id) DO NOTHING`,position,post,id,owner.id),
      query(db,`UPDATE media_reservations SET state='attached',updated_at=?
        WHERE id=? AND owner_id=? AND state='approved' AND EXISTS (
          SELECT 1 FROM post_media WHERE post_id=? AND media_id=?)`,this.clock(),id,owner.id,post,id),
    ]);
    if (answer[0]?.meta.changes !== 1) {
      const attached = await query(db,'SELECT 1 AS attached FROM post_media WHERE post_id=? AND media_id=? AND position=?',
        post,id,position).first();
      if (!attached) throw new HttpError(404,'not_found');
    }
  }

  async approved(owner: Actor, id: string) {
    const row = await this.status(id,owner.id);
    if (row.state !== 'approved' && row.state !== 'attached') throw new HttpError(404,'not_found');
    const object = await query(this.env.DB,'SELECT * FROM media_objects WHERE id=? AND owner_id=?',id,owner.id).first<MediaRow>();
    if (!object) throw new HttpError(404,'not_found');
    return object;
  }

  async cancel(owner: Actor, id: string) {
    const row = await this.status(id,owner.id);
    if (row.state === 'cancelled') return;
    if (!['reserved','quarantined','deleting',...(row.purpose?['approved','attached']:[])].includes(row.state)) throw new HttpError(409,'conflict');
    if(!await this.remove(row,'cancelled',this.session)&&(await this.status(id,owner.id)).state!=='cancelled') throw new HttpError(409,'conflict');
  }

  private async remove(row: Reservation, disposition: 'expired' | 'cancelled', session?:SessionGuard):Promise<boolean> {
    const now = this.clock();
    const db = this.env.DB;
    const guard=session?this.guard(3,now):{sql:'1',params:[]};
    await query(db,`UPDATE media_reservations AS r SET state='deleting',updated_at=?1
      WHERE id=?2 AND ${guard.sql} AND (state IN ('reserved','quarantined') OR (purpose IS NOT NULL AND state IN ('approved','attached')
      AND NOT EXISTS(SELECT 1 FROM post_media pm JOIN posts p ON p.id=pm.post_id WHERE pm.media_id=r.id AND p.state<>'deleted')
      AND NOT EXISTS(SELECT 1 FROM member_profiles pr WHERE pr.avatar_media_id=r.id)
      AND NOT EXISTS(SELECT 1 FROM photo_album_items ai JOIN content_items c ON c.id=ai.album_id WHERE ai.media_id=r.id AND c.state<>'deleted')
      AND NOT EXISTS(SELECT 1 FROM media_reservations root WHERE root.id=r.variant_id AND root.state IN ('approved','attached'))))`,now,row.id,...guard.params).run();
    const current = await query(db,'SELECT state FROM media_reservations WHERE id=?',row.id).first<{state: State}>();
    if (current?.state !== 'deleting') return false;
    if (session) await this.status(row.id,row.owner_id);
    if (row.purpose==='post'||row.purpose==='gallery') {
      const children=await query(db,`SELECT * FROM media_reservations WHERE variant_id=?
        AND purpose='thumbnail' AND state IN ('reserved','quarantined','approved','attached','deleting') LIMIT 2`,row.id).all<Reservation>();
      for(const child of children.results) await this.remove(child,disposition,session);
    }
    await this.env.QUARANTINE.delete(keyFor(row.id));
    await this.env.PRIVATE_MEDIA.delete(keyFor(row.id));
    const result = await db.batch([
      query(db,`DELETE FROM media_objects WHERE id=? AND EXISTS
        (SELECT 1 FROM media_reservations WHERE id=? AND state='deleting')
        AND NOT EXISTS(SELECT 1 FROM media_objects WHERE variant_of=?)
        AND NOT EXISTS(SELECT 1 FROM post_media WHERE media_id=?)
        AND NOT EXISTS(SELECT 1 FROM photo_album_items WHERE media_id=?)
        AND NOT EXISTS(SELECT 1 FROM member_profiles WHERE avatar_media_id=?)`,row.id,row.id,row.id,row.id,row.id,row.id),
      query(db,`UPDATE media_reservations SET state=?,updated_at=? WHERE id=? AND state='deleting'`,disposition,now,row.id),
    ]);
    if (result[1]?.meta.changes === 1 && disposition === 'expired') {
      await auditStatement(db,'expiry','completed',now,row.owner_id).run();
    }
    return result[1]?.meta.changes === 1;
  }

  async expire(limit = 5) {
    const now = this.clock();
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 10) throw new Error('Invalid cleanup batch size');
    const result = await query(this.env.DB,`SELECT * FROM media_reservations
      WHERE state IN ('reserved','quarantined','deleting') AND expires_at<=?
      ORDER BY expires_at,id LIMIT ?`,now,limit).all<Reservation>();
    for (const row of result.results) await this.remove(row,'expired');
    return result.results.length;
  }

  async prunePhotos() {
    const cutoff=this.clock()-172_800_000;
    const found=await query(this.env.DB,`SELECT r.* FROM media_reservations r WHERE r.purpose IS NOT NULL
      AND r.state IN ('approved','attached') AND r.updated_at<=?
      AND NOT EXISTS(SELECT 1 FROM post_media pm JOIN posts p ON p.id=pm.post_id WHERE pm.media_id=r.id AND p.state<>'deleted')
      AND NOT EXISTS(SELECT 1 FROM member_profiles p WHERE p.avatar_media_id=r.id)
      AND NOT EXISTS(SELECT 1 FROM photo_album_items ai JOIN content_items c ON c.id=ai.album_id WHERE ai.media_id=r.id AND c.state<>'deleted')
      AND NOT EXISTS(SELECT 1 FROM media_reservations root WHERE root.id=r.variant_id AND root.state IN ('approved','attached'))
      ORDER BY r.updated_at,r.id LIMIT 5`,cutoff).all<Reservation>();
    for(const row of found.results) await this.remove(row,'expired');
    return found.results.length;
  }

  async verifyApproved(cursor?:string) {
    const rows=(await query(this.env.DB,`SELECT m.id,m.object_key,m.actual_bytes,m.sha256
      FROM media_objects m JOIN media_reservations r ON r.id=m.id
      WHERE m.id>? AND r.purpose IS NOT NULL AND r.state IN ('approved','attached')
      ORDER BY m.id LIMIT 6`,cursor??'').all<MediaRow>()).results;
    let missing=0;
    for(const row of rows.slice(0,5)) {
      const object=await this.env.PRIVATE_MEDIA.head(row.object_key);
      if(!object||object.size!==row.actual_bytes||object.customMetadata?.sha256!==row.sha256) missing++;
    }
    return {missing,cursor:rows.length>5?rows[4]!.id:null};
  }

  async reconcile(which: 'quarantine' | 'private', cursor?: string) {
    const bucket = which === 'quarantine' ? this.env.QUARANTINE : this.env.PRIVATE_MEDIA;
    const batch = await bucket.list({ prefix: 'objects/',limit: 10,...(cursor ? {cursor} : {}) });
    let removed = 0;
    for (const object of batch.objects) {
      const id = object.key.slice('objects/'.length);
      if (!isId(id) || object.uploaded.getTime() > this.clock() - ttl) continue;
      const row = await query(this.env.DB,'SELECT * FROM media_reservations WHERE id=?',id).first<Reservation>();
      if ((!row || terminalStates.has(row.state)) ||
          (which === 'quarantine' && (row.state === 'approved' || row.state === 'attached'))) {
        if(which==='quarantine' && row && ['approved','attached'].includes(row.state)) await this.settle(row);
        else await bucket.delete(object.key);
        removed++;
      }
    }
    return { removed, cursor: batch.truncated ? batch.cursor : null };
  }
}

export interface DirectSigner {
  issue(input: { key: string; expiresIn: number }): Promise<string>;
}

export function rangeOf(value: string | null, bytes: number) {
  if (!value && bytes <= maxRange) return { offset: 0,length: bytes };
  const match = value?.match(/^bytes=(\d{1,12})-(\d{1,12})$/);
  const offset = Number(match?.[1]);
  const end = Number(match?.[2]);
  if (!match || offset > end || end >= bytes || end - offset + 1 > maxRange) {
    throw new HttpError(416,'invalid_request');
  }
  return { offset,length: end - offset + 1 };
}

export class MediaAccess {
  private readonly env: Env;
  private readonly store: MediaStore;
  private readonly budget: Budget;
  private readonly clock: () => number;

  constructor(env: Env, store: MediaStore, budget: Budget, clock = Date.now) {
    this.env = env;
    this.store = store;
    this.budget = budget;
    this.clock = clock;
  }

  async direct(actor: Actor,id: string, signer?: DirectSigner) {
    if (!signer) throw new HttpError(503,'unavailable',60);
    const object = await this.store.approved(actor,id);
    if (!(await this.budget.admit('direct',{ d1Reads: 12,signatures: 1,r2B: 8 },this.clock())).allowed) {
      throw new HttpError(503,'cost_limited',60);
    }
    return { url: await signer.issue({ key: object.object_key, expiresIn: urlTtl }),expiresIn: urlTtl };
  }

  async relay(actor: Actor,id: string,requestRange: string | null) {
    const now = this.clock();
    if (!(await this.budget.admit('standard',{ requests: 1,d1Reads: 16,d1Writes: 2,r2B: 1 },now,
      ['media_grants_enabled'])).allowed) throw new HttpError(503,'cost_limited',60);
    const rate = await allowRate(this.env.DB,[
      { kind:'user',key: 'relay:' + actor.id,limit: 30 },
      { kind:'session',key: 'relay:' + actor.sessionId,limit: 20 },
    ],now);
    if (!rate.allowed) throw new HttpError(429,'rate_limited',rate.retryAfter);
    const row = await this.store.approved(actor,id);
    const range = rangeOf(requestRange,row.actual_bytes);
    const object = await this.env.PRIVATE_MEDIA.get(row.object_key,{ range });
    if (!object || object.size !== row.actual_bytes || object.customMetadata?.sha256 !== row.sha256) {
      throw new HttpError(404,'not_found');
    }
    return { body: object.body, total: row.actual_bytes, range, contentType: row.mime };
  }
}
