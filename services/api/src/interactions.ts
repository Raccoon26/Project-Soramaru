import { graphemeSegments } from 'unicode-segmenter/grapheme';
import { actorGuard,CommunityStore } from './community-store.ts';
import { moderate } from './community-input.ts';
import { HttpError } from './http.ts';
import { openCursor,pageSize,sealCursor } from './paging.ts';
import { isId,query } from './platform.ts';
import type { Database,SqlValue,Statement } from './platform.ts';
import { idempotent } from './writes.ts';
import { acceptedComment,memberVisible,postVisible,requestTime,viewer,visibilityCte,visibleThread } from './visibility.ts';

export const commentRequestBytes=24_000;
const stampEnabled="s.state='published' AND s.rights_state IN ('synthetic','approved') AND i.enabled=1";
const stampPublic="s.state IN ('published','retired') AND s.rights_state IN ('synthetic','approved')";
const postAccess=postVisible('p',viewer,requestTime);
const commentAccess=acceptedComment('c');
const commentSource='FROM comments c JOIN posts p ON p.id=c.post_id LEFT JOIN member_profiles pr ON pr.member_id=c.author_id';
const selection=`c.id,c.post_id AS postId,c.parent_id AS parentId,c.created_at AS createdAt,c.updated_at AS updatedAt,
  CASE WHEN c.state='approved' THEN c.author_id ELSE NULL END AS authorId,
  CASE WHEN c.state='approved' THEN c.body ELSE '' END AS body,
  CASE WHEN c.state='approved' THEN c.version ELSE NULL END AS version,
  CASE WHEN c.state='approved' THEN pr.avatar_media_id ELSE NULL END AS avatarMediaId,
  CASE WHEN c.state='approved' THEN pr.nickname ELSE NULL END AS nickname,
  c.state='deleted' AS removed,
  CASE WHEN c.state='approved' THEN (SELECT cm.media_id FROM comment_media cm WHERE cm.comment_id=c.id) END AS photoId,
  CASE WHEN c.state='approved' THEN (SELECT json_object('id',i.id,'label',i.label,'description',i.description,'icon',i.icon)
    FROM stamp_items i JOIN stamp_sets s ON s.id=i.set_id WHERE i.id=c.stamp_id AND ${stampPublic}) END AS stamp,
  CASE WHEN c.state='approved' AND EXISTS(SELECT 1 FROM official_identities o JOIN role_grants g ON g.member_id=o.member_id
    WHERE o.member_id=c.author_id AND o.active=1 AND g.role='artist' AND g.revoked_at IS NULL
    AND g.starts_at<=${requestTime} AND (g.ends_at IS NULL OR g.ends_at>${requestTime})) THEN 'artist'
  WHEN c.state='approved' AND EXISTS(SELECT 1 FROM official_identities o JOIN content_operator_grants g ON g.member_id=o.member_id
    WHERE o.member_id=c.author_id AND o.active=1 AND g.revoked_at IS NULL AND g.starts_at<=${requestTime} AND g.ends_at>${requestTime})
    AND NOT EXISTS(SELECT 1 FROM role_grants a WHERE a.member_id=c.author_id AND a.role='administrator' AND a.revoked_at IS NULL
      AND a.starts_at<=${requestTime} AND (a.ends_at IS NULL OR a.ends_at>${requestTime})) THEN 'official' ELSE 'member' END AS category`;
type Kind='post'|'comment';
type Comment={id:string;postId:string;parentId:string|null;authorId:string|null;createdAt:number;removed:number;stamp:string|null};
type Metrics={id:string;likes:number;liked:number;comments:number};
type Activity={kind:string;id:string;postId:string;commentId:string|null;createdAt:number;body:string};

function commentInput(input:Record<string,unknown>,editing:boolean) {
  if(Object.keys(input).some(k=>!['body','photoId','stampId',...(editing?[]:['parentId'])].includes(k))) {
    throw new HttpError(400,'invalid_request');
  }
  const body=input.body??'',photoId=input.photoId??null,stampId=input.stampId??null,parentId=input.parentId??null;
  if(typeof body!=='string'||photoId!==null&&(typeof photoId!=='string'||!isId(photoId))||
    stampId!==null&&(typeof stampId!=='string'||!/^[a-z][a-z0-9_-]{0,39}$/.test(stampId))||
    parentId!==null&&(typeof parentId!=='string'||!isId(parentId))||photoId!==null&&stampId!==null) {
    throw new HttpError(400,'invalid_request');
  }
  const normalized=body.replace(/\r\n?/g,'\n');
  if(!normalized.trim()&&!photoId&&!stampId) throw new HttpError(400,'invalid_request');
  if(new TextEncoder().encode(normalized).byteLength>12_000) throw new HttpError(413,'payload_too_large');
  let graphemes=0;
  for(const {segment} of graphemeSegments(normalized)) {
    if(++graphemes>1000||[...segment].length>64) throw new HttpError(400,'invalid_comment_length');
  }
  moderate(normalized);
  return {body:normalized,photoId,stampId,parentId};
}

function conditionFor(kind:Kind) {
  return kind==='post'?{sql:`FROM posts p WHERE p.id=? AND ${postAccess}`,owner:'p.author_id',post:'p.id',comment:'NULL'}:
    {sql:`FROM comments c JOIN posts p ON p.id=c.post_id WHERE c.id=? AND ${postAccess} AND ${commentAccess}`,
      owner:'c.author_id',post:'p.id',comment:'c.id'};
}

export async function counts(db:Database,member:string,now:number,kind:Kind,ids:string[]) {
  if(!ids.length) return new Map<string,Metrics>();
  const picked=visibilityCte+", targets AS (SELECT value AS id FROM json_each(?))";
  const column=kind==='post'?'post_id':'comment_id';
  // Indexed counts can share one bounded target list and avoid extra requests and
  // redundant counter writes. Member visibility changes without rewriting counters.
  const following=kind==='post'?`c.post_id=t.id`:
    `c.post_id=(SELECT post_id FROM comments WHERE id=t.id) AND c.parent_id=t.id`;
  const result=await query(db,`${picked} SELECT t.id,
    (SELECT count(*) FROM reactions r WHERE r.${column}=t.id AND ${memberVisible('r.member_id',viewer)}) AS likes,
    EXISTS(SELECT 1 FROM reactions r WHERE r.member_id=${viewer} AND r.${column}=t.id) AS liked,
    (SELECT count(*) FROM comments c WHERE ${following} AND ${commentAccess}) AS comments
    FROM targets t`,member,now,JSON.stringify(ids)).all<Metrics>();
  return new Map(result.results.map(r=>[r.id,r]));
}

export const exposeCounts=(row:Metrics|undefined)=>({likes:row?.likes??0,liked:row?.liked===1,commentCount:row?.comments??0});

// DEV-13 can call this immediately before display or delivery. A queued record
// cannot grant access to content that has changed since enqueue.
export async function interactionStillVisible(db:Database,payload:unknown,event:string,now:number) {
  if(!payload||typeof payload!=='object'||!['comment.created','reply.created','reaction.added'].includes(event)) return false;
  const {recipientId,actorId,postId,commentId,targetKind,targetId}=payload as Record<string,unknown>;
  if(typeof recipientId!=='string'||typeof actorId!=='string'||typeof postId!=='string'||typeof targetId!=='string'||
      ![recipientId,actorId,postId,targetId].every(isId)||recipientId===actorId||
      commentId!==null&&(typeof commentId!=='string'||!isId(commentId))||targetKind!=='post'&&targetKind!=='comment') return false;
  const target=conditionFor(targetKind);
  const flags="EXISTS(SELECT 1 FROM feature_flags WHERE name='notifications_enabled' AND enabled=1)";
  const present=event==='reaction.added'?
    `AND EXISTS(SELECT 1 FROM reactions r WHERE r.member_id=? AND r.${targetKind==='post'?'post_id':'comment_id'}=?)`:
    'AND candidate.author_id=? AND (?=candidate.post_id OR ?=candidate.parent_id)';
  return !!await query(db,`${visibilityCte}, target AS (SELECT ${target.owner} AS recipient,${target.post} AS postId ${target.sql})
    SELECT 1 FROM target LEFT JOIN comments candidate ON candidate.id=? WHERE recipient=${viewer} AND target.postId=?
    AND ${memberVisible('? ',viewer)} AND ${flags}
    AND (? IS NULL OR (candidate.post_id=target.postId AND ${acceptedComment('candidate')}))
    ${present}`,recipientId,now,targetId,commentId,postId,actorId,actorId,actorId,commentId,actorId,targetId,
    ...(event==='reaction.added'?[]:[targetId])).first();
}

export class Interactions {
  private readonly store:CommunityStore;

  constructor(store:CommunityStore) { this.store=store; }
  private get db() {return this.store.db;}
  private get id() {return this.store.actor.member.id;}
  private get now() {return this.store.now;}
  private get args() {return [this.id,this.now] as const;}

  async catalog() {
    const rows=await query(this.db,`SELECT i.id,i.label,i.description,i.icon,i.version,s.id AS setId,s.label AS setLabel,
      s.version AS setVersion FROM stamp_items i JOIN stamp_sets s ON s.id=i.set_id
      WHERE ${stampEnabled} ORDER BY s.id,i.position LIMIT 100`).all();
    return {items:rows.results};
  }

  private async view(rows:Comment[]) {
    const metrics=await counts(this.db,this.id,this.now,'comment',rows.map(r=>r.id));
    return rows.map(row=>({...row,removed:row.removed===1,stamp:row.stamp?JSON.parse(row.stamp) as unknown:null,
      ...exposeCounts(metrics.get(row.id)),...(row.removed?{likes:0,liked:false}:{})}));
  }

  private async requireTarget(kind:Kind,id:string) {
    const target=conditionFor(kind);
    if(!await query(this.db,`${visibilityCte} SELECT 1 ${target.sql} AND ${actorGuard}`,...this.args,id,...this.store.guard).first()) {
      throw new HttpError(404,'not_found');
    }
  }

  async detail(id:string) {
    const row=await query(this.db,`${visibilityCte} SELECT ${selection} ${commentSource}
      WHERE c.id=? AND ${postAccess} AND ${visibleThread('c')} AND ${actorGuard}`,...this.args,id,...this.store.guard).first<Comment>();
    if(!row) throw new HttpError(404,'not_found');
    const [item]=await this.view([row]);
    return item!;
  }

  async list(post:string,params:URLSearchParams,key:CryptoKey) {
    const parent=params.get('parent');
    if([...params.keys()].some(k=>!['limit','cursor','parent'].includes(k))||parent!==null&&!isId(parent)) {
      throw new HttpError(400,'invalid_request');
    }
    await this.requireTarget('post',post);
    if(parent) {
      const root=await this.detail(parent);
      if(root.postId!==post||root.parentId!==null) throw new HttpError(404,'not_found');
    }
    const limit=pageSize(params.get('limit'));
    const scope=JSON.stringify(['comments',this.id,post,parent]);
    const raw=params.get('cursor');
    const cursor=raw===null?null:await openCursor(key,raw,scope,this.now);
    const cutoff=cursor?.cutoff??this.now;
    const position:SqlValue[]=cursor?[cursor.created,cursor.id]:[];
    const entries=await query(this.db,`${visibilityCte} SELECT ${selection} ${commentSource}
      WHERE c.post_id=? AND c.parent_id IS ? AND c.created_at<=? AND ${postAccess} AND ${visibleThread('c')}
      ${cursor?'AND (c.created_at,c.id)>(?,?)':''} ORDER BY c.created_at,c.id LIMIT ?`,
      ...this.args,post,parent,cutoff,...position,limit+1).all<Comment>();
    const rows=entries.results.slice(0,limit),last=rows.at(-1);
    return {items:await this.view(rows),nextCursor:last&&entries.results.length>limit?await sealCursor(key,{
      created:last.createdAt,id:last.id,cutoff,expires:cursor?.expires??this.now+900_000,scope,
    }):null};
  }

  private event(event: 'comment.created'|'reply.created'|'reaction.added',dedupe:string,targetKind:Kind,targetId:string,commentId:string|null,ifInserted=false) {
    const target=conditionFor(targetKind);
    const job=crypto.randomUUID(),id=crypto.randomUUID(),key='interaction:'+dedupe;
    const recipient=`${visibilityCte}, target AS (SELECT ${target.owner} AS recipient,${target.post} AS postId,
      ${target.comment} AS targetComment ${target.sql}), eligible AS (
      SELECT recipient,postId,targetComment,coalesce(?,targetComment) AS commentId FROM target
      WHERE EXISTS (SELECT 1 FROM posts p WHERE p.id=target.postId AND ${postVisible('p','target.recipient',requestTime)})
      AND (coalesce(?,targetComment) IS NULL OR EXISTS (SELECT 1 FROM comments candidate
        WHERE candidate.id=coalesce(?,targetComment) AND ${acceptedComment('candidate','target.recipient')})))`;
    const flags="EXISTS(SELECT 1 FROM feature_flags WHERE name='notifications_enabled' AND enabled=1)";
    return [
      query(this.db,`${recipient} INSERT INTO scheduled_jobs(id,kind,dedupe_key,payload,required,state,run_at,max_attempts)
        SELECT ?,'deliver_outbox',?,json_object('eventId',?),0,'ready',?,5
        FROM eligible WHERE recipient<>? AND ${flags} ${ifInserted?'AND changes()=1':''}
        ON CONFLICT(dedupe_key) DO NOTHING`,...this.args,targetId,commentId,commentId,commentId,job,'outbox:'+key,id,this.now,this.id),
      query(this.db,`${recipient} INSERT INTO outbox
        SELECT ?,?,?,json_object('actorId',?,'recipientId',recipient,'postId',postId,'commentId',commentId,
        'targetKind',?,'targetId',?),?,?,NULL FROM eligible
        WHERE EXISTS (SELECT 1 FROM scheduled_jobs WHERE id=?)`,
        ...this.args,targetId,commentId,commentId,commentId,id,key,event,this.id,targetKind,targetId,job,this.now,job),
    ];
  }

  async save(post:string|null,id:string|null,input:Record<string,unknown>,key:string,expected:number|null) {
    const data=commentInput(input,id!==null);
    const current=id?await this.detail(id):null;
    if(current?.removed) throw new HttpError(404,'not_found');
    if(current&&current.authorId!==this.id) throw new HttpError(404,'not_found');
    const postId=current?.postId??post!;
    const commentId=id??crypto.randomUUID();
    const root=id?current?.parentId??null:data.parentId;
    const attachGuard=`(? IS NULL OR EXISTS (SELECT 1 FROM media_reservations r JOIN media_objects m ON m.id=r.id
      WHERE r.id=? AND r.owner_id=? AND r.comment_scope=1 AND r.purpose='post' AND r.state IN ('approved','attached')
      AND m.width IS NOT NULL AND EXISTS(SELECT 1 FROM media_objects t JOIN media_reservations tr ON tr.id=t.id
        WHERE t.variant_of=r.id AND t.owner_id=r.owner_id AND t.width IS NOT NULL AND tr.comment_scope=1
        AND tr.purpose='thumbnail' AND tr.state IN ('approved','attached'))))`;
    const stampGuard=`(? IS NULL OR EXISTS (SELECT 1 FROM stamp_items i JOIN stamp_sets s ON s.id=i.set_id WHERE i.id=? AND ${stampEnabled}))`;
    const guard=`${actorGuard} AND EXISTS(SELECT 1 FROM posts p WHERE p.id=? AND ${postAccess}) AND ${attachGuard} AND ${stampGuard}`;
    const values=[...this.store.guard,postId,data.photoId,data.photoId,this.id,data.stampId,data.stampId];
    const change=id?
      query(this.db,`${visibilityCte} UPDATE comments AS c SET body=?,stamp_id=?,updated_at=max(updated_at,?),version=version+1
        WHERE c.id=? AND c.author_id=? AND c.version=? AND ${commentAccess} AND ${guard}`,
        ...this.args,data.body,data.stampId,this.now,id,this.id,expected,...values):
      query(this.db,`${visibilityCte} INSERT INTO comments(id,post_id,parent_id,author_id,body,stamp_id,state,created_at,updated_at)
        SELECT ?,?,?,?,?,?,'approved',?,? WHERE ${guard} AND (? IS NULL OR EXISTS(SELECT 1 FROM comments c
        WHERE c.id=? AND c.post_id=? AND c.parent_id IS NULL AND ${commentAccess}))`,
        ...this.args,commentId,postId,root,this.id,data.body,data.stampId,this.now,this.now,...values,root,root,postId);
    const result=await idempotent(this.db,this.id,id?'comment.edit':'comment.create',key,
      {postId,id,expected,...data},this.now,()=>({result:{id:commentId},statements:[
        ...this.detach(commentId),
        ...(data.photoId?[query(this.db,'INSERT INTO comment_media VALUES (?,?)',commentId,data.photoId),
          query(this.db,"UPDATE media_reservations SET state='attached',updated_at=? WHERE id=? AND state='approved'",this.now,data.photoId)]:[]),
        ...(!id?this.event(root?'reply.created':'comment.created',commentId,root?'comment':'post',root??postId,commentId):[]),
      ]}),change);
    return this.detail(result.id);
  }

  private detach(id:string) {
    return [query(this.db,'UPDATE media_reservations SET updated_at=? WHERE id=(SELECT media_id FROM comment_media WHERE comment_id=?)',
      this.now,id),query(this.db,'DELETE FROM comment_media WHERE comment_id=?',id)];
  }

  async remove(id:string,key:string,expected:number) {
    const change=query(this.db,`${visibilityCte}
      UPDATE comments AS c SET body='',stamp_id=NULL,state='deleted',updated_at=max(updated_at,?),version=version+1
      WHERE id=? AND author_id=? AND version=? AND ${commentAccess} AND ${actorGuard}
      AND EXISTS(SELECT 1 FROM posts p WHERE p.id=c.post_id AND ${postAccess})`,
      ...this.args,this.now,id,this.id,expected,...this.store.guard);
    await idempotent(this.db,this.id,'comment.remove',key,{id,expected},this.now,
      ()=>({result:{id},statements:this.detach(id)}),change);
  }

  async react(kind:Kind,id:string,add:boolean) {
    await this.requireTarget(kind,id);
    const target=conditionFor(kind);
    const column=kind==='post'?'post_id':'comment_id';
    const allowed=`${actorGuard} AND EXISTS(SELECT 1 ${target.sql})`;
    const statement=add?query(this.db,`${visibilityCte} INSERT INTO reactions(member_id,${column},created_at)
        SELECT ?,?,? WHERE ${allowed} ON CONFLICT(member_id,${column}) DO NOTHING`,
        ...this.args,this.id,id,this.now,...this.store.guard,id):
      query(this.db,`${visibilityCte} DELETE FROM reactions WHERE member_id=? AND ${column}=? AND ${allowed}`,
        ...this.args,this.id,id,...this.store.guard,id);
    const dedupe=[kind,id,this.id,Math.floor(this.now/86_400_000)].join(':');
    const changes:Statement[]=add?this.event('reaction.added',dedupe,kind,id,null,true):[];
    await this.db.batch([statement,...changes]);
    await this.requireTarget(kind,id);
    return exposeCounts((await counts(this.db,this.id,this.now,kind,[id])).get(id));
  }

  async activity(params:URLSearchParams,key:CryptoKey) {
    if([...params.keys()].some(k=>!['limit','cursor'].includes(k))) throw new HttpError(400,'invalid_request');
    const size=pageSize(params.get('limit'));
    const scope='interaction-activity:'+this.id;
    const raw=params.get('cursor');
    const cursor=raw===null?null:await openCursor(key,raw,scope,this.now,id=>{
      const [kind,resource,extra]=id.split(':');
      return extra===undefined&&['post','comment','postLike','commentLike'].includes(kind??'')&&isId(resource??'');
    });
    const cutoff=cursor?.cutoff??this.now;
    const filter=cursor?'AND (createdAt,id)<(?,?)':'';
    const args:SqlValue[]=cursor?[cursor.created,cursor.id]:[];
    const sources=[
      `SELECT 'post' AS kind,'post:'||p.id AS id,p.id AS postId,NULL AS commentId,p.created_at AS createdAt,
        substr(p.body,1,120) AS body FROM posts p WHERE p.author_id=${viewer} AND ${postAccess}`,
      `SELECT CASE WHEN c.parent_id IS NULL THEN 'comment' ELSE 'reply' END,'comment:'||c.id,p.id,c.id,c.created_at,
        substr(c.body,1,120) FROM comments c JOIN posts p ON p.id=c.post_id
        WHERE c.author_id=${viewer} AND ${postAccess} AND ${commentAccess}`,
      `SELECT 'postLike','postLike:'||p.id,p.id,NULL,r.created_at,substr(p.body,1,120)
        FROM reactions r JOIN posts p ON p.id=r.post_id WHERE r.member_id=${viewer} AND ${postAccess}`,
      `SELECT 'commentLike','commentLike:'||c.id,p.id,c.id,r.created_at,substr(c.body,1,120)
        FROM reactions r JOIN comments c ON c.id=r.comment_id JOIN posts p ON p.id=c.post_id
        WHERE r.member_id=${viewer} AND ${postAccess} AND ${commentAccess}`,
    ];
    // Limit each index-backed source before sorting the merged page.
    const labels='(kind,id,postId,commentId,createdAt,body)';
    const pieces=sources.map((sql,i)=>`a${i}${labels} AS (${sql}), page${i} AS (
      SELECT * FROM a${i} WHERE createdAt<=? ${filter} ORDER BY createdAt DESC,id DESC LIMIT ?)`).join(',');
    const values=sources.flatMap(()=>[cutoff,...args,size+1]);
    const results=await query(this.db,`${visibilityCte},${pieces}
      ${sources.map((_,i)=>'SELECT * FROM page'+i).join(' UNION ALL ')}
      ORDER BY createdAt DESC,id DESC LIMIT ?`,...this.args,...values,size+1).all<Activity>();
    const items=results.results.slice(0,size),last=items.at(-1);
    const nextCursor=last&&results.results.length>size?await sealCursor(key,{
      created:last.createdAt,id:last.id,cutoff,scope,expires:cursor?.expires??this.now+900_000,
    }):null;
    return {items,nextCursor};
  }
}
