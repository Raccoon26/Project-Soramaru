import { HttpError } from './http.ts';
import { eventStatements } from './jobs.ts';
import type { MembershipContext } from './membership-store.ts';
import { policyDocuments,policyVersion } from './membership-policy.ts';
import { pageSize,openCursor,sealCursor } from './paging.ts';
import { digest,isId,query } from './platform.ts';
import type { Database,SqlValue } from './platform.ts';
import { idempotent } from './writes.ts';
import { banned,postInput } from './community-input.ts';
import { memberVisible,postVisible } from './photo-access.ts';

const actorGuard=`EXISTS (
 SELECT 1 FROM members a JOIN member_sessions s ON s.member_id=a.id
 JOIN member_profiles pp ON pp.member_id=a.id
 WHERE a.id=? AND s.id=? AND a.state='active' AND pp.configured_at IS NOT NULL
 AND s.revoked_at IS NULL AND s.expires_at>? AND s.firebase_auth_at>=max(a.revoked_before,?)
 AND (SELECT count(*) FROM policy_acceptances pa WHERE pa.member_id=a.id AND pa.version=?)=?
)`;

const official=`CASE WHEN o.active=1 AND EXISTS (SELECT 1 FROM role_grants g WHERE
 g.member_id=p.author_id AND g.role='artist' AND g.revoked_at IS NULL AND g.starts_at<=(SELECT t FROM request_clock) AND (g.ends_at IS NULL OR g.ends_at>(SELECT t FROM request_clock)))
 THEN 'artist' WHEN o.active=1 AND NOT EXISTS (SELECT 1 FROM role_grants a WHERE a.member_id=p.author_id
 AND a.role='administrator' AND a.revoked_at IS NULL AND a.starts_at<=(SELECT t FROM request_clock) AND (a.ends_at IS NULL OR a.ends_at>(SELECT t FROM request_clock)))
 AND EXISTS (SELECT 1 FROM content_operator_grants op WHERE
 op.member_id=p.author_id AND op.revoked_at IS NULL AND op.starts_at<=(SELECT t FROM request_clock) AND op.ends_at>(SELECT t FROM request_clock))
 THEN 'official' ELSE 'member' END`;
const joined=`FROM posts p CROSS JOIN member_profiles pr ON pr.member_id=p.author_id
 LEFT JOIN official_identities o ON o.id=p.displayed_identity_id AND o.member_id=p.author_id`;
const fields=`p.id,p.author_id,p.body,p.version,p.created_at,p.updated_at,p.quote_post_id,p.pin_rank,pr.avatar_media_id,
 (SELECT json_group_array(media_id) FROM (SELECT pm.media_id FROM post_media pm
   JOIN media_reservations r ON r.id=pm.media_id AND r.purpose='post'
   WHERE pm.post_id=p.id ORDER BY pm.position)) AS photos,
 CASE WHEN (${official})='member' THEN pr.nickname ELSE o.display_name END AS nickname,
 ${official} AS category,
 (SELECT json_group_array(json_object('id',t.id,'label',t.label)) FROM post_tags pt JOIN tags t ON t.id=pt.tag_id WHERE pt.post_id=p.id) AS tags,
 (SELECT json_object('id',q.id,'body',substr(q.body,1,180),'nickname',qp.nickname)
 FROM posts q JOIN member_profiles qp ON qp.member_id=q.author_id WHERE q.id=p.quote_post_id AND
 ${postVisible('q')}) AS quote`;

const listFields=fields.replace('p.body,','substr(p.body,1,1200) AS body,');

interface Row {
 id:string;author_id:string;body:string;version:number;created_at:number;updated_at:number;quote_post_id:string|null;
 pin_rank:number;avatar_media_id:string|null;photos:string;nickname:string;category:string;tags:string;quote:string|null;
}

function item(p: Row) {
  return {id:p.id,authorId:p.author_id,body:p.body,version:p.version,createdAt:p.created_at,updatedAt:p.updated_at,
    nickname:p.nickname,avatarMediaId:p.avatar_media_id,photos:JSON.parse(p.photos) as string[],category:p.category,pinned:p.pin_rank>0&&p.category!=='member',tags:JSON.parse(p.tags) as unknown[],
    quoteId:p.quote_post_id,quote:p.quote===null?null:JSON.parse(p.quote) as unknown};
}

export class CommunityStore {
  constructor(privateDb: Database, actor: MembershipContext, now: number) {
    this.db=privateDb;
    this.actor=actor;
    this.now=now;
  }

  readonly db: Database;
  readonly actor: MembershipContext;
  readonly now: number;

  private get id() { return this.actor.member.id; }
  private get visibility() { return [this.now,this.id,this.id] as const; }
  private get guard() { return [this.id,this.actor.session.id,this.now,this.actor.identity.validSince??0,policyVersion,policyDocuments.length] as const; }

  async list(params: URLSearchParams,key: CryptoKey) {
    const category=params.get('category')??'all';
    const author=params.get('author');
    const tag=params.get('tag');
    const cursor=params.get('cursor');
    const limit=pageSize(params.get('limit'));
    if ([...params.keys()].some(k=>!['category','author','tag','cursor','limit'].includes(k))||
        !['all','artist','official','favorites'].includes(category)||author!==null&&!isId(author)||tag!==null&&!isId(tag)) {
      throw new HttpError(400,'invalid_request');
    }
    const scope=JSON.stringify(['posts',this.id,category,author,tag]);
    const position=cursor===null?null:await openCursor(key,cursor,scope,this.now);
    if (category==='favorites') return {items:[],pinned:[],nextCursor:null,availability:'planned'};
    const cutoff=position?.cutoff??this.now;
    const filter:string[]=[];
    const values:SqlValue[]=[];
    if (author) {filter.push('p.author_id=?');values.push(author);}
    if (tag) {filter.push('p.id IN (SELECT pt.post_id FROM post_tags pt WHERE pt.tag_id=?)');values.push(tag);}
    if (category!=='all') {filter.push('p.displayed_identity_id IS NOT NULL','('+official+')=?');values.push(category);}
    if (position) {filter.push('(p.created_at,p.id)<(?,?)');values.push(position.created,position.id);}
    const where=`${postVisible('p')} AND p.created_at<=?${filter.map(value=>' AND '+value).join('')}`;
    const args=[cutoff,this.id,this.id,cutoff,...values];
    const ordered=tag?joined:joined.replace('posts p','posts p INDEXED BY '+(author?'posts_author':'posts_feed'));
    const result=await query(this.db,`WITH request_clock(t) AS (VALUES (?)) SELECT ${listFields} ${ordered} WHERE ${where}
      ORDER BY p.created_at DESC,p.id DESC LIMIT ?`,this.now,...this.visibility,...args,limit+1).all<Row>();
    const rows=result.results.slice(0,limit);
    const last=rows.at(-1);
    const nextCursor=last&&result.results.length>limit?await sealCursor(key,{
      cutoff,created:last.created_at,id:last.id,expires:position?.expires??this.now+900_000,scope,
    }):null;
    const pinRows=!cursor&&!author&&!tag&&category==='all'?(await query(this.db,`WITH request_clock(t) AS (VALUES (?)) SELECT ${listFields} ${joined.replace('posts p','posts p INDEXED BY posts_pinned')}
      WHERE p.state='approved' AND p.pin_rank>0 AND p.displayed_identity_id IS NOT NULL
      AND (${official})<>'member' AND ${postVisible('p')} ORDER BY p.pin_rank DESC,p.created_at DESC,p.id DESC LIMIT 3`,
      this.now,...this.visibility,...this.visibility).all<Row>()).results:[];
    return {items:rows.map(item),pinned:pinRows.map(item),nextCursor};
  }

  async detail(id: string) {
    const row=await query(this.db,`WITH request_clock(t) AS (VALUES (?)) SELECT ${fields} ${joined} WHERE p.id=? AND ${postVisible('p')} AND ${actorGuard}`,
      this.now,...this.visibility,id,...this.visibility,...this.guard).first<Row>();
    if (!row) throw new HttpError(404,'not_found');
    return item(row);
  }

  async member(id: string) {
    const row=await query(this.db,`SELECT member_id AS id,nickname,biography,avatar_media_id AS avatarMediaId FROM member_profiles
      WHERE member_id=? AND ${memberVisible('member_id')}`, id,this.id,this.id).first();
    if (!row) throw new HttpError(404,'not_found');
    return row;
  }

  async save(id: string|null, input: Record<string,unknown>, key: string, expected: number|null) {
    const data=postInput(input,id!==null);
    const postId=id??crypto.randomUUID();
    const attachments=data.attachments===null?null:JSON.stringify(data.attachments);
    const fingerprint=await digest(JSON.stringify([data.body.normalize('NFC'),data.quoteId,...(attachments?[attachments]:[])]));
    const permitted=`coalesce(json_array_length(?),0)=(SELECT count(DISTINCT expected_sha) FROM media_reservations
      WHERE id IN (SELECT value FROM json_each(?))) AND NOT EXISTS(SELECT 1 FROM json_each(?) picked WHERE NOT EXISTS(
      SELECT 1 FROM media_reservations r JOIN media_objects m ON m.id=r.id
      WHERE r.id=picked.value AND r.owner_id=? AND r.purpose='post' AND r.state IN ('approved','attached')
      AND m.width IS NOT NULL AND EXISTS(SELECT 1 FROM media_objects thumb JOIN media_reservations tr ON tr.id=thumb.id
        WHERE thumb.variant_of=r.id AND thumb.owner_id=r.owner_id AND tr.purpose='thumbnail'
        AND thumb.width IS NOT NULL AND tr.state IN ('approved','attached'))))`;
    const version=expected===null?1:expected+1;
    const first=id===null?
      query(this.db,`INSERT INTO posts(id,author_id,body,state,created_at,updated_at,publish_at,quote_post_id,content_hash)
        SELECT ?,?,?,'approved',?,?,?,?,? WHERE ${actorGuard}
        AND (? IS NULL OR EXISTS(SELECT 1 FROM posts q WHERE q.id=? AND ${postVisible('q')}))
        AND ${permitted} AND NOT EXISTS(SELECT 1 FROM posts WHERE author_id=? AND content_hash=? AND state='approved' AND created_at>?)`,
        postId,this.id,data.body,this.now,this.now,this.now,data.quoteId,fingerprint,...this.guard,
        data.quoteId,data.quoteId,...this.visibility,attachments,attachments,attachments,this.id,this.id,fingerprint,this.now-300_000):
      query(this.db,`UPDATE posts SET body=?,updated_at=max(updated_at,?),version=version+1,content_hash=?
        WHERE id=? AND author_id=? AND state='approved' AND displayed_identity_id IS NULL AND version=? AND (length(?)>0 OR quote_post_id IS NOT NULL OR json_array_length(?)>0
          OR (? IS NULL AND EXISTS(SELECT 1 FROM post_media WHERE post_id=posts.id)))
        AND ${actorGuard} AND ${permitted}`,data.body,this.now,fingerprint,id,this.id,expected,data.body.trim(),attachments,attachments,...this.guard,attachments,attachments,attachments,this.id);
    const result=await idempotent(this.db,this.id,id===null?'post.create':'post.edit',key,
      {id,version:expected,body:data.body,quoteId:data.quoteId,tags:data.tags,...(attachments===null?{}:{attachments:data.attachments})},this.now,()=>({
        result:{id:postId,version},
        statements:[
          query(this.db,'DELETE FROM post_tags WHERE post_id=?',postId),
          ...data.tags.flatMap(tag=>[
            query(this.db,`INSERT INTO tags VALUES (?,?,?) ON CONFLICT(normalized) DO NOTHING`,
              crypto.randomUUID(),tag.normalized,tag.label),
            query(this.db,`INSERT INTO post_tags SELECT ?,id FROM tags WHERE normalized=?`,postId,tag.normalized),
          ]),
          ...(attachments===null?[]:[
            query(this.db,'UPDATE media_reservations SET updated_at=? WHERE id IN (SELECT media_id FROM post_media WHERE post_id=?)',this.now,postId),
            query(this.db,'DELETE FROM post_media WHERE post_id=?',postId),
            query(this.db,`INSERT INTO post_media(post_id,media_id,position) SELECT ?,value,CAST(key AS INTEGER) FROM json_each(?)`,postId,attachments),
            query(this.db,`UPDATE media_reservations SET state='attached',updated_at=? WHERE state='approved'
              AND id IN (SELECT value FROM json_each(?))`,this.now,attachments),
          ]),
          ...eventStatements(this.db,'post:'+postId+':'+version,id===null?'post.created':'post.edited',{id:postId,version},this.now),
        ],
      }),first);
    return this.detail(result.id);
  }

  async remove(id: string, key: string, expected: number) {
    const first=query(this.db,`UPDATE posts SET state='deleted',body='',updated_at=max(updated_at,?),version=version+1
      WHERE id=? AND author_id=? AND version=? AND state='approved' AND displayed_identity_id IS NULL AND ${actorGuard}`,
      this.now,id,this.id,expected,...this.guard);
    await idempotent(this.db,this.id,'post.remove',key,{id,expected},this.now,()=>({
      result:{id},
      statements:[
        query(this.db,'DELETE FROM post_tags WHERE post_id=?',id),
        query(this.db,'UPDATE media_reservations SET updated_at=? WHERE id IN (SELECT media_id FROM post_media WHERE post_id=?)',this.now,id),
        query(this.db,'DELETE FROM post_media WHERE post_id=?',id),
        ...eventStatements(this.db,'post:'+id+':'+(expected+1),'post.deleted',{id},this.now),
      ],
    }),first);
  }

  async block(id: string) {
    if (this.id===id) throw new HttpError(400,'invalid_request');
    const changed=await query(this.db,`INSERT INTO blocks
      SELECT ?,?,? WHERE ${actorGuard} AND EXISTS(SELECT 1 FROM members WHERE id=? AND state='active')
      ON CONFLICT DO NOTHING`,this.id,id,this.now,...this.guard,id).run();
    if (!changed.meta.changes&&!await query(this.db,`SELECT 1 FROM blocks WHERE blocker_id=? AND blocked_id=? AND ${actorGuard}`,
      this.id,id,...this.guard).first()) throw new HttpError(404,'not_found');
  }

  async report(body: Record<string,unknown>) {
    const kind=body.kind;
    const id=body.targetId;
    const category=body.category;
    const detail=body.detail??'';
    if ((kind!=='post'&&kind!=='member')||typeof id!=='string'||!isId(id)||
        typeof category!=='string'||!['spam','disruption','harassment','inappropriate','privacy','impersonation','copyright','other'].includes(category)||
        typeof detail!=='string'||[...detail].length>500) throw new HttpError(400,'invalid_request');
    if (banned.test(detail)) throw new HttpError(400,'invalid_request');
    const target=kind==='post'?`SELECT p.author_id AS owner,p.version FROM posts p WHERE p.id=? AND ${postVisible('p')}`:
      `SELECT m.id AS owner,m.version FROM members m WHERE m.id=? AND m.state='active'`;
    const params=kind==='post'?[id,...this.visibility]:[id];
    await query(this.db,`INSERT INTO community_reports SELECT ?,?,?,?,t.owner,t.version,?, ?,?
      FROM (${target}) t WHERE t.owner<>? AND ${actorGuard}
      ON CONFLICT(reporter_id,target_kind,target_id) DO NOTHING`,
      crypto.randomUUID(),this.id,kind,id,category,detail.trim(),this.now,...params,this.id,...this.guard).run();
    if (!await query(this.db,`SELECT 1 FROM community_reports WHERE reporter_id=? AND target_kind=? AND target_id=? AND ${actorGuard}`,
      this.id,kind,id,...this.guard).first()) throw new HttpError(404,'not_found');
  }
}
