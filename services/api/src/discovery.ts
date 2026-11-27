import { actorGuard, type CommunityStore } from './community-store.ts';
import { HttpError } from './http.ts';
import { pageSize,openCursor,sealCursor } from './paging.ts';
import { albumJoin,galleryVisible } from './photo-access.ts';
import { digest,isId,query } from './platform.ts';
import type { Database } from './platform.ts';
import { literalMatch,searchInput,type SearchKind } from './search-index.ts';
import { memberVisible,officialKind,postVisible,requestTime,viewer,visibilityCte } from './visibility.ts';

type FavoriteKind=Exclude<SearchKind,'album'>;
const tagVisible=(id:string,member=viewer)=>`EXISTS(SELECT 1 FROM
  (SELECT post_id FROM post_tags WHERE tag_id=${id} ORDER BY post_id DESC LIMIT 96) tagged
  JOIN posts tp ON tp.id=tagged.post_id WHERE ${postVisible('tp',member,requestTime)})`;
export const albumAllowed=(id:string,member=viewer)=>`EXISTS (SELECT 1 ${albumJoin}
  WHERE c.id=${id} AND ${galleryVisible(member,requestTime)})`;

const results={
  post:{join:'JOIN posts p ON p.id=d.target',label:'substr(p.body,1,180)',guard:`p.version=d.source_version AND ${postVisible('p',viewer,requestTime)}`},
  member:{join:'JOIN member_profiles pr ON pr.member_id=d.target',label:'pr.nickname',
    guard:`pr.version=d.source_version AND pr.configured_at IS NOT NULL AND ${memberVisible('pr.member_id',viewer)}`},
  tag:{join:'JOIN tags t ON t.id=d.target',label:'t.label',guard:tagVisible('t.id')},
  album:{join:'JOIN content_items ci ON ci.id=d.target',label:'ci.title',
    guard:`ci.version=d.source_version AND ${albumAllowed('ci.id')}`},
};
const favorites={
  post:{table:'favorite_posts',join:'JOIN posts p ON p.id=f.target_id',label:results.post.label,guard:postVisible('p',viewer,requestTime)},
  member:{table:'favorite_members',join:results.member.join.replace('d.target','f.target_id'),label:results.member.label,
    guard:`pr.configured_at IS NOT NULL AND ${memberVisible('pr.member_id',viewer)}`},
  tag:{table:'favorite_tags',join:'JOIN tags t ON t.id=f.target_id',label:results.tag.label,guard:tagVisible('t.id')},
} as const;

export function kindInput(value:unknown,allowAlbum=true): SearchKind {
  if(value==='post'||value==='member'||value==='tag'||(allowAlbum&&value==='album')) return value;
  throw new HttpError(400,'invalid_request');
}

export function parameters(params:URLSearchParams,allowed:string[]) {
  if([...params.keys()].some(key=>!allowed.includes(key)||params.getAll(key).length!==1)) throw new HttpError(400,'invalid_request');
}

export function requiredId(id:unknown) {
  if(typeof id!=='string'||!isId(id)) throw new HttpError(404,'not_found');
  return id;
}

export class Discovery {
  readonly store:CommunityStore;
  readonly key:CryptoKey;
  constructor(store:CommunityStore,key:CryptoKey) {
    this.store=store;
    this.key=key;
  }
  private get db() { return this.store.db; }
  private get actor() { return this.store.actor.member.id; }
  private get now() { return this.store.now; }

  async search(params:URLSearchParams) {
    parameters(params,['q','kind','cursor','limit']);
    const kind=kindInput(params.get('kind')??'post');
    const {normalized,tokens}=searchInput(params.get('q'));
    const limit=pageSize(params.get('limit'));
    const scope=JSON.stringify(['search',this.actor,kind,await digest(normalized)]);
    const raw=params.get('cursor');
    const position=raw?await openCursor(this.key,raw,scope,this.now):null;
    const full=(kind==='post'||kind==='album')&&tokens.every(token=>[...token].length>=3);
    const max=position?.created??Number.MAX_SAFE_INTEGER;
    const fts=kind==='album'?'album_fts':'search_fts';
    const criteria=results[kind];
    const prefixEnd=normalized+'\u{10ffff}';
    const guardValues=[...this.store.guard];
    const rows=(await query(this.db,`${visibilityCte}, candidates AS MATERIALIZED (${full?
      `SELECT rowid FROM ${fts} WHERE ${fts} MATCH ? AND rowid<? ORDER BY rowid DESC LIMIT 160`:
      `SELECT rowid FROM search_documents INDEXED BY search_prefix
        WHERE kind=? AND prefix>=? AND prefix<? AND rowid<? ORDER BY prefix,rowid LIMIT 160`})
      SELECT d.target AS id,${criteria.label} AS label,d.rowid AS created
      FROM candidates JOIN search_documents d ON d.rowid=candidates.rowid ${criteria.join}
      WHERE ${criteria.guard} AND ${actorGuard}
      ORDER BY d.rowid DESC LIMIT ?`,this.actor,this.now,
    ...(full?[literalMatch(tokens),max]:[kind,normalized,prefixEnd,max]),...guardValues,limit+1)
      .all<{id:string;label:string;created:number}>()).results;
    return this.page(rows,limit,scope,position?.cutoff??this.now,position?.expires,kind);
  }

  private async page(rows:{id:string;created:number;label:string}[], limit:number,scope:string,cutoff:number,expires?:number,kind?:string) {
    const values=rows.slice(0,limit);
    const last=values.at(-1);
    return {
      items:values.map(row=>({...row,...(kind?{kind}:{})})),
      nextCursor:last&&rows.length>limit?await sealCursor(this.key,{scope,cutoff,created:last.created,id:last.id,expires:expires??this.now+900_000}):null,
    };
  }

  async favoriteList(kind:FavoriteKind,params:URLSearchParams) {
    parameters(params,['kind','cursor','limit']);
    const limit=pageSize(params.get('limit'));
    const scope=JSON.stringify(['favorites',this.actor,kind]);
    const raw=params.get('cursor');
    const position=raw?await openCursor(this.key,raw,scope,this.now):null;
    const cutoff=position?.cutoff??this.now;
    const def=favorites[kind];
    const rows=(await query(this.db,`${visibilityCte} SELECT f.target_id AS id,${def.label} AS label,f.created_at AS created
      FROM ${def.table} f ${def.join} WHERE f.owner_id=? AND f.created_at<=? ${position?'AND (f.created_at,f.target_id)<(?,?)':''}
      AND ${def.guard} AND ${actorGuard} ORDER BY f.created_at DESC,f.target_id DESC LIMIT ?`,
    this.actor,this.now,this.actor,cutoff,...(position?[position.created,position.id]:[]),...this.store.guard,limit+1)
      .all<{id:string;label:string;created:number}>()).results;
    return this.page(rows,limit,scope,cutoff,position?.expires,kind);
  }

  async favorite(kind:FavoriteKind,id:string,method:string) {
    if(kind==='member'&&id===this.actor) throw new HttpError(400,'invalid_request');
    const def=favorites[kind];
    if(method==='DELETE') {
      await query(this.db,`DELETE FROM ${def.table} WHERE owner_id=? AND target_id=? AND ${actorGuard}`,
        this.actor,id,...this.store.guard).run();
      return {saved:false};
    }
    const visible=`EXISTS(SELECT 1 FROM (SELECT ? AS target_id) f ${def.join} WHERE ${def.guard})`;
    const read=query(this.db,`${visibilityCte} SELECT (SELECT created_at FROM ${def.table} WHERE owner_id=? AND target_id=?) AS created
      WHERE ${visible} AND ${actorGuard}`,this.actor,this.now,this.actor,id,id,...this.store.guard);
    const row=method==='PUT'?(await this.db.batch<{created:number|null}>([
      query(this.db,`${visibilityCte} INSERT INTO ${def.table}(owner_id,target_id,created_at)
        SELECT ?,?,? WHERE ${visible} AND ${actorGuard} ON CONFLICT(owner_id,target_id) DO NOTHING`,
      this.actor,this.now,this.actor,id,this.now,id,...this.store.guard),read,
    ]))[1]?.results[0]:await read.first<{created:number|null}>();
    if(!row)throw new HttpError(404,'not_found');
    return {saved:row.created!==null,createdAt:row.created};
  }

  async official(params:URLSearchParams) {
    parameters(params,['limit','cursor']);
    const limit=pageSize(params.get('limit'));
    const scope=JSON.stringify(['official-users',this.actor]);
    const raw=params.get('cursor');
    const position=raw?await openCursor(this.key,raw,scope,this.now):null;
    const cutoff=position?.cutoff??this.now;
    const rows=(await query(this.db,`${visibilityCte} SELECT m.id,o.display_name AS label,m.joined_at AS created,
      ${officialKind('m.id','o.active',requestTime)} AS category,
      EXISTS(SELECT 1 FROM favorite_members f WHERE f.owner_id=${viewer} AND f.target_id=m.id) AS saved
      FROM official_identities o JOIN members m ON m.id=o.member_id
      WHERE o.active=1 AND ${memberVisible('m.id',viewer)} AND ${actorGuard}
      AND (${officialKind('m.id','o.active',requestTime)})<>'member' AND m.joined_at<=?
      ${position?'AND (m.joined_at,m.id)<(?,?)':''} ORDER BY m.joined_at DESC,m.id DESC LIMIT ?`,
    this.actor,this.now,...this.store.guard,cutoff,...(position?[position.created,position.id]:[]),limit+1)
      .all<{id:string;label:string;created:number}>()).results;
    return this.page(rows,limit,scope,cutoff,position?.expires);
  }

  async blocks(params:URLSearchParams) {
    parameters(params,['cursor','limit']);
    const limit=pageSize(params.get('limit'));
    const scope=JSON.stringify(['blocks',this.actor]);
    const raw=params.get('cursor');
    const position=raw?await openCursor(this.key,raw,scope,this.now):null;
    const cutoff=position?.cutoff??this.now;
    const rows=(await query(this.db,`SELECT b.blocked_id AS id,b.created_at AS created,
      CASE WHEN m.state IN ('deleting','deleted') THEN NULL ELSE pr.nickname END AS label
      FROM blocks b LEFT JOIN member_profiles pr ON pr.member_id=b.blocked_id JOIN members m ON m.id=b.blocked_id
      WHERE b.blocker_id=? AND b.created_at<=? AND ${actorGuard}
      ${position?'AND (b.created_at,b.blocked_id)<(?,?)':''} ORDER BY b.created_at DESC,b.blocked_id DESC LIMIT ?`,
    this.actor,cutoff,...this.store.guard,...(position?[position.created,position.id]:[]),limit+1)
      .all<{id:string;label:string;created:number}>()).results;
    return this.page(rows,limit,scope,cutoff,position?.expires);
  }

  async unblock(id:string) {
    await query(this.db,`DELETE FROM blocks WHERE blocker_id=? AND blocked_id=? AND ${actorGuard}`,
      this.actor,id,...this.store.guard).run();
  }

  async popular() {
    const snapshot=await query(this.db,'SELECT captured_at FROM tag_discovery_snapshot WHERE singleton=1').first<{captured_at:number}>();
    if(!snapshot) return {items:[],capturedAt:null,stale:true};
    const rows=await query(this.db,`${visibilityCte}
      SELECT t.id,t.label,EXISTS(SELECT 1 FROM favorite_tags f WHERE f.owner_id=${viewer} AND f.target_id=t.id) AS saved FROM tag_discovery_snapshot s JOIN json_each(s.posts) sample
      JOIN posts p ON p.id=sample.value JOIN post_tags pt ON pt.post_id=p.id JOIN tags t ON t.id=pt.tag_id
      WHERE s.singleton=1 AND ${postVisible('p',viewer,requestTime)} AND ${actorGuard}
      GROUP BY t.id,t.label ORDER BY count(DISTINCT p.author_id) DESC,t.id LIMIT 20`,
    this.actor,this.now,...this.store.guard).all<{id:string;label:string;saved:number}>();
    return {items:rows.results.map(row=>({...row,saved:row.saved===1})),capturedAt:snapshot.captured_at,stale:this.now-snapshot.captured_at>7_200_000};
  }
}

export function refreshPopular(db:Database,now:number) {
  return query(db,`INSERT INTO tag_discovery_snapshot(singleton,captured_at,posts)
    SELECT 1,?,(SELECT json_group_array(id) FROM (
      SELECT p.id FROM posts p INDEXED BY posts_feed JOIN members m ON m.id=p.author_id
      WHERE p.state='approved' AND p.publish_at<=? AND p.created_at>=? AND m.state='active'
      ORDER BY p.created_at DESC,p.id DESC LIMIT 96))
    ON CONFLICT(singleton) DO UPDATE SET captured_at=excluded.captured_at,posts=excluded.posts
    WHERE tag_discovery_snapshot.captured_at<=excluded.captured_at-3600000`,now,now,now-604_800_000).run();
}
