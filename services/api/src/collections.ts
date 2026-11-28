import { actorGuard,type CommunityStore } from './community-store.ts';
import { albumAllowed,parameters,requiredId } from './discovery.ts';
import { HttpError } from './http.ts';
import { openCursor,pageSize,sealCursor } from './paging.ts';
import { query } from './platform.ts';
import { banned } from './community-input.ts';
import { memberVisible,postPhotoVisible,postVisible,requestTime,viewer,visibilityCte } from './visibility.ts';

const maxFolders=40;
const maxEntries=100;
const canSeeFolder=`(f.owner_id=${viewer} OR (
  EXISTS (SELECT 1 FROM member_profiles pr WHERE pr.member_id=f.owner_id AND pr.collection_public=1)
  AND ${memberVisible('f.owner_id',viewer)}))`;
function entryVisible(member=viewer) {
  return `(CASE WHEN e.post_id IS NOT NULL THEN EXISTS(
      SELECT 1 FROM posts p WHERE p.id=e.post_id AND ${postVisible('p',member,requestTime)}
      AND (e.photo_id IS NULL OR EXISTS(SELECT 1 FROM post_media pm JOIN media_reservations r ON r.id=pm.media_id
        WHERE pm.post_id=p.id AND pm.media_id=e.photo_id AND r.state IN ('approved','attached')
        AND ${postPhotoVisible('p.id','pm.media_id',member,requestTime)})))
    ELSE ${albumAllowed('e.album_id',member)} AND (
       e.photo_id IS NULL OR EXISTS(SELECT 1 FROM photo_album_items pi JOIN media_reservations r ON r.id=pi.media_id
       WHERE pi.album_id=e.album_id AND pi.media_id=e.photo_id AND r.state IN ('approved','attached'))) END)`;
}
const visibleEntries=(filter:string)=>`${visibilityCte}, candidates AS MATERIALIZED (
  SELECT e.*,f.owner_id FROM collection_entries e JOIN collection_folders f ON f.id=e.folder_id
  WHERE ${filter} AND ${canSeeFolder} AND ${actorGuard}
), viewer_entries AS MATERIALIZED (
  SELECT e.id FROM candidates e WHERE ${entryVisible()}
), owner_entries AS MATERIALIZED (
  SELECT e.id FROM candidates e WHERE e.owner_id=${viewer} OR ${entryVisible('e.owner_id')}
), eligible AS MATERIALIZED (
  SELECT e.* FROM candidates e JOIN viewer_entries v ON v.id=e.id JOIN owner_entries o ON o.id=e.id
)`;
function title(value:unknown) {
  if(typeof value!=='string'||banned.test(value)||[...value.trim()].length<1||[...value.trim()].length>40||
    /[\r\n\t]/u.test(value)) throw new HttpError(400,'invalid_request');
  return value.trim().normalize('NFC');
}

type Entry={id:string;postId:string|null;albumId:string|null;photoId:string|null;created:number;label:string;attachable:number};

export class Collections {
  readonly store:CommunityStore;
  readonly key:CryptoKey;
  constructor(store:CommunityStore,key:CryptoKey) {
    this.store=store;
    this.key=key;
  }
  private get db() {return this.store.db;}
  private get actor() {return this.store.actor.member.id;}
  private get now() {return this.store.now;}

  async folders(owner:string) {
    const owns=owner===this.actor;
    const rows=await query(this.db,`${owns?visibilityCte:visibleEntries('f.owner_id=?')} SELECT f.id,f.title,f.version
      FROM collection_folders f WHERE f.owner_id=? AND ${canSeeFolder} AND ${actorGuard}
      ${owns?'':'AND EXISTS(SELECT 1 FROM eligible e WHERE e.folder_id=f.id)'}
      ORDER BY f.created_at DESC,f.id DESC LIMIT ?`,this.actor,this.now,
    ...(owns?[]:[owner,...this.store.guard]),owner,...this.store.guard,maxFolders)
      .all<{id:string;title:string;version:number}>();
    return {items:rows.results};
  }

  async items(folder:string,params:URLSearchParams) {
    parameters(params,['cursor','limit','sort']);
    const sort=params.get('sort')??'newest';
    if(sort!=='newest'&&sort!=='oldest') throw new HttpError(400,'invalid_request');
    const order=sort==='newest'?'DESC':'ASC';
    const comparator=sort==='newest'?'<':'>';
    const limit=pageSize(params.get('limit'));
    const scope=JSON.stringify(['collection',this.actor,folder,sort]);
    const cursor=params.get('cursor');
    const position=cursor?await openCursor(this.key,cursor,scope,this.now):null;
    const cutoff=position?.cutoff??this.now;
    const header=await query(this.db,`${visibleEntries('f.id=?')} SELECT f.id,f.title,f.version,f.owner_id=${viewer} AS owned
      FROM collection_folders f WHERE f.id=? AND ${canSeeFolder} AND ${actorGuard}
      AND (f.owner_id=${viewer} OR EXISTS(SELECT 1 FROM eligible))`,
    this.actor,this.now,folder,...this.store.guard,folder,...this.store.guard).first();
    if(!header) throw new HttpError(404,'not_found');
    const rows=(await query(this.db,`${visibleEntries('f.id=?')} SELECT e.id,e.created_at AS created,e.post_id AS postId,e.album_id AS albumId,
      e.photo_id AS photoId,coalesce(substr(p.body,1,100),c.title) AS label,
      (e.photo_id IS NOT NULL AND p.author_id=${viewer} AND e.owner_id=${viewer}) AS attachable
      FROM eligible e
      LEFT JOIN posts p ON p.id=e.post_id LEFT JOIN content_items c ON c.id=e.album_id
      WHERE e.created_at<=?
      ${position?`AND (e.created_at,e.id)${comparator}(?,?)`:''}
      ORDER BY e.created_at ${order},e.id ${order} LIMIT ?`,this.actor,this.now,folder,...this.store.guard,cutoff,
    ...(position?[position.created,position.id]:[]),limit+1).all<Entry>()).results;
    const page=rows.slice(0,limit).map(row=>({...row,attachable:row.attachable===1}));
    const last=page.at(-1);
    return {...header,items:page,nextCursor:last&&rows.length>limit?await sealCursor(this.key,{
      scope,cutoff,created:last.created,id:last.id,expires:position?.expires??this.now+900_000,
    }):null};
  }

  async create(body:Record<string,unknown>) {
    if(Object.keys(body).some(k=>k!=='id'&&k!=='title')) throw new HttpError(400,'invalid_request');
    const name=title(body.title);
    const id=requiredId(body.id);
    const row=await query(this.db,`INSERT INTO collection_folders (id,owner_id,title,created_at)
      SELECT ?,?,?,? WHERE ${actorGuard}
        AND (SELECT count(*) FROM collection_folders WHERE owner_id=?)<?
      ON CONFLICT(id) DO NOTHING RETURNING id,title,version`,id,this.actor,name,this.now,...this.store.guard,this.actor,maxFolders).first();
    if (row) return row;
    const existing=await query(this.db,`SELECT id,title,version FROM collection_folders WHERE id=? AND owner_id=? AND title=? AND ${actorGuard}`,
      id,this.actor,name,...this.store.guard).first();
    if(!existing) throw new HttpError(409,'conflict');
    return existing;
  }

  async update(folder:string,version:number,body:Record<string,unknown>) {
    if(Object.keys(body).some(k=>k!=='title')) throw new HttpError(400,'invalid_request');
    const row=await query(this.db,`UPDATE collection_folders SET title=?,version=version+1
      WHERE id=? AND owner_id=? AND version=? AND ${actorGuard} RETURNING id,title,version`,
    title(body.title),folder,this.actor,version,...this.store.guard).first();
    if(!row) throw new HttpError(409,'conflict');
    return row;
  }

  async drop(folder:string,version:number) {
    const changed=await query(this.db,`DELETE FROM collection_folders WHERE id=? AND owner_id=? AND version=? AND ${actorGuard} RETURNING id`,
      folder,this.actor,version,...this.store.guard).first();
    if(!changed) throw new HttpError(409,'conflict');
  }

  async add(folder:string,body:Record<string,unknown>) {
    if(Object.keys(body).some(k=>!['postId','albumId','photoId'].includes(k))) throw new HttpError(400,'invalid_request');
    const post=body.postId===undefined?null:requiredId(body.postId);
    const album=body.albumId===undefined?null:requiredId(body.albumId);
    const photo=body.photoId===undefined?null:requiredId(body.photoId);
    if((post===null)===(album===null)) throw new HttpError(400,'invalid_request');
    const [insert,selected]=await this.db.batch([
      query(this.db,`${visibilityCte} INSERT INTO collection_entries(id,folder_id,post_id,album_id,photo_id,created_at)
        SELECT ?,f.id,e.post_id,e.album_id,e.photo_id,? FROM collection_folders f
        CROSS JOIN (SELECT ? AS post_id,? AS album_id,? AS photo_id) e
        WHERE f.id=? AND f.owner_id=? AND ${actorGuard} AND ${entryVisible()}
        AND (SELECT count(*) FROM collection_entries n WHERE n.folder_id=f.id)<?
        ON CONFLICT DO NOTHING`,this.actor,this.now,crypto.randomUUID(),this.now,post,album,photo,folder,this.actor,
      ...this.store.guard,maxEntries),
      query(this.db,`${visibilityCte} SELECT e.id FROM collection_entries e JOIN collection_folders f ON f.id=e.folder_id
        WHERE f.id=? AND f.owner_id=? AND e.post_id IS ? AND e.album_id IS ? AND e.photo_id IS ?
        AND ${actorGuard} AND ${entryVisible()}`,this.actor,this.now,folder,this.actor,post,album,photo,...this.store.guard),
    ]);
    const row=selected?.results[0];
    if(!row) {
      if (insert?.meta.changes!==0) throw new HttpError(409,'conflict');
      throw new HttpError(404,'not_found');
    }
    return row;
  }

  async modifyEntries(folder:string,body:Record<string,unknown>) {
    if(Object.keys(body).some(k=>!['ids','destination'].includes(k))||!Array.isArray(body.ids)||
        body.ids.length<1||body.ids.length>20) throw new HttpError(400,'invalid_request');
    const ids=[...new Set(body.ids.map(requiredId))];
    const destination=body.destination===undefined?null:requiredId(body.destination);
    if(destination===folder) throw new HttpError(400,'invalid_request');
    const json=JSON.stringify(ids);
    const source=`EXISTS(SELECT 1 FROM collection_folders f WHERE f.id=? AND f.owner_id=?) AND folder_id=? AND id IN (SELECT value FROM json_each(?))`;
    if(!destination) {
      await query(this.db,`DELETE FROM collection_entries WHERE ${source} AND ${actorGuard}`,
        folder,this.actor,folder,json,...this.store.guard).run();
      return;
    }
    const result=await query(this.db,`${visibilityCte} UPDATE collection_entries AS e SET folder_id=?
      WHERE ${source} AND ${actorGuard} AND ${entryVisible()}
      AND EXISTS(SELECT 1 FROM collection_folders d WHERE d.id=? AND d.owner_id=?)
      AND (SELECT count(*) FROM collection_entries n WHERE n.folder_id=?)+json_array_length(?)<=?
      AND NOT EXISTS(SELECT 1 FROM collection_entries dupe WHERE dupe.folder_id=?
        AND dupe.post_id IS e.post_id AND dupe.album_id IS e.album_id AND dupe.photo_id IS e.photo_id)`,
    this.actor,this.now,destination,folder,this.actor,folder,json,...this.store.guard,destination,this.actor,
    destination,json,maxEntries,destination).run();
    return {moved:result.meta.changes};
  }

  async collectors(album:string,params:URLSearchParams) {
    parameters(params,['cursor','limit']);
    const limit=pageSize(params.get('limit'));
    const scope=JSON.stringify(['collectors',this.actor,album]);
    const raw=params.get('cursor');
    const position=raw?await openCursor(this.key,raw,scope,this.now):null;
    const cutoff=position?.cutoff??this.now;
    const rows=(await query(this.db,`${visibilityCte}, kept AS MATERIALIZED (
      SELECT f.owner_id AS id,max(e.created_at) AS created FROM collection_entries e
      JOIN collection_folders f ON f.id=e.folder_id JOIN member_profiles pr ON pr.member_id=f.owner_id
      WHERE e.album_id=? AND e.photo_id IS NULL AND e.created_at<=? AND pr.collection_public=1
        AND ${albumAllowed('e.album_id')} AND ${albumAllowed('e.album_id','f.owner_id')}
        AND ${memberVisible('f.owner_id',viewer)} AND ${actorGuard}
      GROUP BY f.owner_id)
      SELECT k.id,k.created,pr.nickname AS label FROM kept k JOIN member_profiles pr ON pr.member_id=k.id
      ${position?'WHERE (k.created,k.id)<(?,?)':''} ORDER BY k.created DESC,k.id DESC LIMIT ?`,
    this.actor,this.now,album,cutoff,...this.store.guard,...(position?[position.created,position.id]:[]),limit+1)
      .all<{id:string;created:number;label:string}>()).results;
    const items=rows.slice(0,limit);
    const last=items.at(-1);
    return {items,nextCursor:last&&rows.length>limit?await sealCursor(this.key,{
      scope,cutoff,created:last.created,id:last.id,expires:position?.expires??this.now+900_000,
    }):null};
  }

  async recent(params:URLSearchParams) {
    parameters(params,['cursor','limit']);
    const limit=pageSize(params.get('limit'));
    const scope=JSON.stringify(['recent-albums',this.actor]);
    const raw=params.get('cursor');
    const position=raw?await openCursor(this.key,raw,scope,this.now):null;
    const cutoff=position?.cutoff??this.now;
    const rows=(await query(this.db,`${visibilityCte} SELECT r.album_id AS id,r.seen_at AS created,ci.title AS label,
      (SELECT pi.media_id FROM photo_album_items pi WHERE pi.album_id=ci.id ORDER BY pi.position LIMIT 1) AS coverId
      FROM recent_albums r JOIN content_items ci ON ci.id=r.album_id WHERE r.owner_id=? AND r.seen_at<=?
      AND ${albumAllowed('r.album_id')} AND ${actorGuard} ${position?'AND (r.seen_at,r.album_id)<(?,?)':''}
      ORDER BY r.seen_at DESC,r.album_id DESC LIMIT ?`,this.actor,this.now,this.actor,cutoff,...this.store.guard,
    ...(position?[position.created,position.id]:[]),limit+1).all<{id:string;created:number;label:string;coverId:string|null}>()).results;
    const items=rows.slice(0,limit);
    const last=items.at(-1);
    return {items,nextCursor:last&&rows.length>limit?await sealCursor(this.key,{
      scope,cutoff,created:last.created,id:last.id,expires:position?.expires??this.now+900_000,
    }):null};
  }

  async recordRecent(id:string) {
    await this.db.batch([
      query(this.db,`${visibilityCte} INSERT INTO recent_albums(owner_id,album_id,seen_at)
        SELECT ?,?,? WHERE ${albumAllowed('?')} AND ${actorGuard}
        ON CONFLICT(owner_id,album_id) DO UPDATE SET seen_at=excluded.seen_at
        WHERE excluded.seen_at-recent_albums.seen_at>=300000`,
      this.actor,this.now,this.actor,id,this.now,id,...this.store.guard),
      query(this.db,`DELETE FROM recent_albums WHERE changes()=1 AND owner_id=? AND album_id IN (
        SELECT album_id FROM recent_albums WHERE owner_id=? ORDER BY seen_at DESC,album_id DESC LIMIT 1 OFFSET 100)`,
      this.actor,this.actor),
    ]);
  }

  async clearRecent(id:string|null) {
    await query(this.db,`DELETE FROM recent_albums WHERE owner_id=? AND ${actorGuard}${id?' AND album_id=?':''}`,
      this.actor,...this.store.guard,...(id?[id]:[])).run();
  }
}
