import { HttpError } from './http.ts';
import { Budget } from './cost.ts';
import { rangeOf } from './media.ts';
import type { DirectSigner,MediaRow } from './media.ts';
import { openCursor,pageSize,sealCursor } from './paging.ts';
import { query } from './platform.ts';
import type { Database,Env,SqlValue } from './platform.ts';

export type PhotoContext='post'|'profile'|'album';
export interface PhotoParent {kind:PhotoContext;id:string}
export type PhotoVariant='full'|'thumb';

export function memberVisible(member: string) {
  return `EXISTS(SELECT 1 FROM members m WHERE m.id=${member} AND m.state='active')
    AND NOT EXISTS(SELECT 1 FROM blocks WHERE blocker_id=? AND blocked_id=${member})
    AND NOT EXISTS(SELECT 1 FROM blocks WHERE blocked_id=? AND blocker_id=${member})`;
}

export function postVisible(alias: string) {
  return `${alias}.state='approved' AND ${alias}.publish_at<=? AND ${memberVisible(alias+'.author_id')}`;
}

const albumJoin=`FROM content_items c JOIN photo_albums a ON a.content_id=c.id
 JOIN official_identities o ON o.id=a.identity_id AND o.member_id=c.publisher_id`;
const albumVisible=`c.kind='gallery' AND c.state='approved' AND c.visibility='members' AND c.publish_at<=?
 AND a.rights_state IN ('approved','synthetic') AND o.active=1 AND ${memberVisible('c.publisher_id')}
 AND (EXISTS(SELECT 1 FROM role_grants g WHERE g.member_id=c.publisher_id AND g.role='artist'
    AND g.revoked_at IS NULL AND g.starts_at<=? AND (g.ends_at IS NULL OR g.ends_at>?))
  OR (EXISTS(SELECT 1 FROM content_operator_grants g WHERE g.member_id=c.publisher_id
    AND g.revoked_at IS NULL AND g.starts_at<=? AND g.ends_at>?)
    AND NOT EXISTS(SELECT 1 FROM role_grants ar WHERE ar.member_id=c.publisher_id AND ar.role='administrator'
    AND ar.revoked_at IS NULL AND ar.starts_at<=? AND (ar.ends_at IS NULL OR ar.ends_at>?))))`;

export class PhotoAccess {
  readonly actor:string;
  readonly env:Env;
  readonly now:number;

  constructor(env:Env,actor:string,now:number) {
    this.env=env;
    this.actor=actor;
    this.now=now;
  }

  private get db():Database {return this.env.DB;}
  private get albumArgs() {
    return [this.now,this.actor,this.actor,this.now,this.now,this.now,this.now,this.now,this.now] as const;
  }

  private references(parent:PhotoParent) {
    switch(parent.kind) {
      case 'post':return {
        sql:`SELECT p.author_id AS owner,pm.media_id FROM post_media pm JOIN posts p ON p.id=pm.post_id
          WHERE p.id=? AND ${postVisible('p')}`,
        params:[parent.id,this.now,this.actor,this.actor],purpose:'post',
      };
      case 'profile':return {
        sql:`SELECT pr.member_id AS owner,pr.avatar_media_id AS media_id FROM member_profiles pr
          WHERE pr.member_id=? AND ${memberVisible('pr.member_id')}`,
        params:[parent.id,this.actor,this.actor],purpose:'avatar',
      };
      case 'album':return {
        sql:`SELECT c.publisher_id AS owner,pi.media_id ${albumJoin}
          JOIN photo_album_items pi ON pi.album_id=c.id WHERE c.id=? AND ${albumVisible}`,
        params:[parent.id,...this.albumArgs],purpose:'gallery',
      };
    }
  }

  private async authorized(parent:PhotoParent,ids:readonly string[],variant:PhotoVariant) {
    const source=this.references(parent);
    const thumbnail=variant==='thumb'&&parent.kind!=='profile';
    const selected=thumbnail?'t':'m';
    return (await query(this.db,`SELECT m.id AS root_id,${selected}.*
      FROM (${source.sql}) ref JOIN media_objects m ON m.id=ref.media_id AND m.owner_id=ref.owner
      JOIN media_reservations r ON r.id=m.id AND r.owner_id=ref.owner
      ${thumbnail?`JOIN media_objects t ON t.variant_of=m.id AND t.owner_id=m.owner_id
        JOIN media_reservations tr ON tr.id=t.id AND tr.owner_id=t.owner_id
        AND tr.purpose='thumbnail' AND tr.state IN ('approved','attached')`:''}
      WHERE m.id IN (SELECT value FROM json_each(?)) AND r.state IN ('approved','attached') AND r.purpose=?
      AND ${selected}.mime='image/jpeg' AND ${selected}.width IS NOT NULL AND ${selected}.height IS NOT NULL`,
      ...source.params,JSON.stringify(ids),source.purpose).all<MediaRow&{root_id:string;width:number;height:number;version:number}>()).results;
  }

  async grants(parent:PhotoParent,ids:readonly string[],variant:PhotoVariant,mode:'relay'|'direct',signer?: DirectSigner) {
    const rows=await this.authorized(parent,ids,variant);
    if(rows.length!==ids.length) throw new HttpError(404,'not_found');
    // A direct URL grants bearer access until its TTL elapses.
    if(mode==='direct'&&!signer) throw new HttpError(503,'unavailable',60);
    if(mode==='direct') {
      const gate=await new Budget(this.db).admit('direct',{
        signatures:ids.length,r2B:8*ids.length,
      },this.now,['media_grants_enabled']);
      if(!gate.allowed) throw new HttpError(503,'cost_limited',60);
    }
    const byId=new Map(rows.map(row=>[row.root_id,row]));
    return {items:await Promise.all(ids.map(async id=>{
      const row=byId.get(id)!;
      return {
      id:row.root_id,width:row.width,height:row.height,version:row.version,
      ...(signer&&mode==='direct'?{url:await signer.issue({key:row.object_key,expiresIn:60}),expiresIn:60}
        :{path:photoPath(parent,row.root_id,variant)}),
      };
    }))};
  }

  async relay(parent:PhotoParent,id:string,variant:PhotoVariant,requestRange:string|null) {
    const [row]=await this.authorized(parent,[id],variant);
    if(!row) throw new HttpError(404,'not_found');
    const range=rangeOf(requestRange,row.actual_bytes);
    const object=await this.env.PRIVATE_MEDIA.get(row.object_key,requestRange?{range}:undefined);
    if(!object||object.size!==row.actual_bytes||object.customMetadata?.sha256!==row.sha256) {
      if(object) await object.body.cancel().catch(()=>undefined);
      throw new HttpError(404,'not_found');
    }
    const headers=new Headers({
      'Content-Type':'image/jpeg','Content-Length':String(range.length),'Accept-Ranges':'bytes',
      'Cache-Control':'private, no-store','X-Content-Type-Options':'nosniff',
    });
    if(requestRange) headers.set('Content-Range',`bytes ${range.offset}-${range.offset+range.length-1}/${row.actual_bytes}`);
    return new Response(object.body,{status:requestRange?206:200,headers});
  }

  async gallery(params:URLSearchParams,key:CryptoKey) {
    if([...params.keys()].some(value=>!['limit','cursor'].includes(value))) throw new HttpError(400,'invalid_request');
    const size=pageSize(params.get('limit'));
    const scope='gallery:'+this.actor;
    const cursor=params.get('cursor');
    const position=cursor===null?null:await openCursor(key,cursor,scope,this.now);
    const cutoff=position?.cutoff??this.now;
    const args:SqlValue[]=position?[position.created,position.id]:[];
    const rows=(await query(this.db,`SELECT c.id,c.title,c.publish_at AS publishedAt,o.display_name AS author,
      (SELECT count(*) FROM photo_album_items pi WHERE pi.album_id=c.id) AS count,
      (SELECT pi.media_id FROM photo_album_items pi WHERE pi.album_id=c.id ORDER BY pi.position LIMIT 1) AS coverId
      ${albumJoin} WHERE ${albumVisible} AND c.publish_at<=?
      ${position?'AND (c.publish_at,c.id)<(?,?)':''} ORDER BY c.publish_at DESC,c.id DESC LIMIT ?`,
      ...this.albumArgs,cutoff,...args,size+1).all<{id:string;title:string;publishedAt:number;author:string;count:number;coverId:string|null}>()).results;
    const items=rows.slice(0,size);
    const last=items.at(-1);
    const nextCursor=last&&rows.length>size?await sealCursor(key,{
      scope,id:last.id,created:last.publishedAt,cutoff,expires:position?.expires??this.now+900_000,
    }):null;
    return {items,nextCursor};
  }

  async album(id:string) {
    const row=await query(this.db,`SELECT c.id,c.title,c.publish_at AS publishedAt,o.display_name AS author,
      (SELECT json_group_array(media_id) FROM
        (SELECT media_id FROM photo_album_items WHERE album_id=c.id ORDER BY position)) AS photos
      ${albumJoin} WHERE c.id=? AND ${albumVisible}`,id,...this.albumArgs)
      .first<{id:string;title:string;publishedAt:number;author:string;photos:string}>();
    if(!row) throw new HttpError(404,'not_found');
    return {...row,photos:JSON.parse(row.photos) as string[]};
  }
}

export function photoPath(parent:PhotoParent,id:string,variant:PhotoVariant) {
  return '/v1/media/'+id+'?parent='+parent.kind+'&parent_id='+parent.id+'&variant='+variant;
}
