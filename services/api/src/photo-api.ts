import { HttpError,readJson } from './http.ts';
import { MediaStore } from './media.ts';
import type { Reservation } from './media.ts';
import type { Actor } from './auth.ts';
import { Budget } from './cost.ts';
import { PhotoAccess } from './photo-access.ts';
import type { PhotoParent,PhotoVariant } from './photo-access.ts';
import { inspectPhoto,photoLimits } from './photo-format.ts';
import type { PhotoPurpose } from './photo-format.ts';
import { bearer } from './membership-api.ts';
import type { MembershipDependencies,ReadReservations } from './membership-api.ts';
import { MembershipStore } from './membership-store.ts';
import { allowRate } from './rate.ts';
import { isId } from './platform.ts';
import type { Env } from './platform.ts';

export function photoTarget(path:string) {
  if(path==='/v1/uploads') return {kind:'reserve',methods:'POST'} as const;
  if(path==='/v1/media/grants') return {kind:'grant',methods:'POST'} as const;
  if(path==='/v1/gallery') return {kind:'gallery',methods:'GET'} as const;
  const match=/^\/v1\/(uploads|media|gallery)\/([^/]+)(?:\/(body|complete))?$/.exec(path);
  if(!match||!match[2]) return null;
  const [,group,id,action]=match;
  if(group==='uploads') {
    if(action==='body') return {kind:'body',methods:'PUT',id} as const;
    if(action==='complete') return {kind:'complete',methods:'POST',id} as const;
    return {kind:'status',methods:'GET, DELETE',id} as const;
  }
  if(action) return null;
  return group==='gallery'?{kind:'album',methods:'GET',id} as const:{kind:'relay',methods:'GET',id} as const;
}

type Target=NonNullable<ReturnType<typeof photoTarget>>;

function context(kind:unknown,id:unknown):PhotoParent {
  if((kind!=='post'&&kind!=='profile'&&kind!=='album'&&kind!=='comment')||typeof id!=='string'||!isId(id)) {
    throw new HttpError(400,'invalid_request');
  }
  return {kind,id};
}

function variantOf(value:unknown):PhotoVariant {
  if(value!=='full'&&value!=='thumb') throw new HttpError(400,'invalid_request');
  return value;
}

export async function photoBytes(r:Request,max:number) {
  if(r.headers.get('content-type')!=='image/jpeg'||r.headers.has('content-encoding')) {
    throw new HttpError(415,'unsupported_media_type');
  }
  const header=r.headers.get('content-length');
  if(header!==null&&!/^[1-9]\d{0,8}$/.test(header)) throw new HttpError(400,'invalid_request');
  if(header!==null&&Number(header)>max) throw new HttpError(413,'payload_too_large');
  if(!r.body) throw new HttpError(400,'invalid_request');
  const reader=r.body.getReader(), buffer=new Uint8Array(max);
  let filled=0;
  try {
    for(;;) {
      let result:ReadableStreamReadResult<Uint8Array>;
      try {result=await reader.read();} catch {throw new HttpError(400,'invalid_request');}
      if(result.done) break;
      if(result.value.length>max-filled) {
        await reader.cancel().catch(()=>undefined);
        throw new HttpError(413,'payload_too_large');
      }
      buffer.set(result.value,filled);
      filled+=result.value.length;
    }
  } finally {reader.releaseLock();}
  if(!filled||header!==null&&Number(header)!==filled) throw new HttpError(400,'invalid_request');
  return buffer.buffer.slice(0,filled);
}

function status(row:Reservation) {
  return {id:row.id,state:row.state,expiresAt:row.expires_at,purpose:row.comment_scope&&row.purpose==='post'?'comment':row.purpose};
}

export async function handlePhoto(request:Request,url:URL,target:Target,env:Env,deps:MembershipDependencies,
  clock:()=>number,reads:ReadReservations,network:string):Promise<Response|{data:unknown;status:number}> {
  const now=clock();
  if(url.search&&target.kind!=='gallery'&&target.kind!=='relay') throw new HttpError(400,'invalid_request');
  const token=await deps.verify(bearer(request),now);
  if(!token) throw new HttpError(401,'authentication_required');
  const session=await new MembershipStore(env.DB,now,deps.key).context(token,request.headers.get('x-app-session')??'');
  if(session.phase!=='active') throw new HttpError(403,'access_denied');
  const member=session.member;
  const actor:Actor={id:member.id,sessionId:session.session.id,role:member.role==='artist'?'artist':'member'};
  const id='id' in target?target.id:null;
  if(id!==null&&!isId(id)) throw new HttpError(404,'not_found');
  const upload=['reserve','body','complete','status'].includes(target.kind);
  const read=request.method==='GET';
  const group=upload?(read?'upload-status':target.kind):target.kind==='relay'?'bytes':'photo-list';
  const relay=target.kind==='relay';
  const batch=read?4:1;
  const lease='photo:'+group+':'+actor.sessionId+':'+network;
  if(read) {
    const flags=await env.DB.prepare("SELECT name,enabled FROM feature_flags WHERE name IN ('maintenance_mode','media_grants_enabled')").all<{name:string;enabled:number}>();
    if(flags.results.some(row=>row.name==='maintenance_mode'&&row.enabled===1)) throw new HttpError(503,'maintenance',60);
    if(relay&&!flags.results.some(row=>row.name==='media_grants_enabled'&&row.enabled===1)) throw new HttpError(503,'cost_limited',60);
  }
  if(!read||!reads.take(lease,now)) {
    const allowed=await new Budget(env.DB).admit(request.method==='DELETE'?'essential':upload&&!read?'optional-write':'standard',
      {requests:batch,d1Reads:80*batch,d1Writes:upload?22:9,d1IndexWrites:12,r2B:relay?batch:0},now,
      relay||target.kind==='grant'?['media_grants_enabled']:upload&&!read&&request.method!=='DELETE'?['image_upload_enabled']:[]);
    if(!allowed.allowed) throw new HttpError(503,'cost_limited',60);
    const rate=await allowRate(env.DB,[
      {kind:'user',key:'photo:'+group+':'+actor.id,limit:read?120:24},
      {kind:'session',key:'photo:'+group+':'+actor.sessionId,limit:read?100:20},
      {kind:'network',key:'photo:'+group+':'+network,limit:read?450:100},
    ],now,batch);
    if(!rate.allowed) throw new HttpError(429,'rate_limited',rate.retryAfter);
    if(read) reads.install(lease,now);
  }
  const access=new PhotoAccess(env,actor.id,now);
  if(target.kind==='gallery') return {data:await access.gallery(url.searchParams,deps.key),status:200};
  if(target.kind==='album'&&id) return {data:await access.album(id),status:200};
  if(target.kind==='relay'&&id) {
    if([...url.searchParams.keys()].some(key=>!['parent','parent_id','variant'].includes(key))) throw new HttpError(400,'invalid_request');
    return access.relay(context(url.searchParams.get('parent'),url.searchParams.get('parent_id')),id,
      variantOf(url.searchParams.get('variant')),request.headers.get('range'));
  }
  if(target.kind==='grant') {
    const b=await readJson(request);
    if(!Array.isArray(b.ids)||b.ids.length<1||b.ids.length>20||
        !b.ids.every((x:unknown)=>typeof x==='string'&&isId(x))||new Set(b.ids).size!==b.ids.length||
        (b.mode!==undefined&&b.mode!=='relay'&&b.mode!=='direct')) throw new HttpError(400,'invalid_request');
    return {data:await access.grants(context(b.parent,b.parentId),b.ids as string[],variantOf(b.variant),b.mode==='direct'?'direct':'relay'),status:200};
  }

  const store=new MediaStore(env,clock,undefined,undefined,{member:actor.id,id:actor.sessionId,validSince:token.validSince??0});
  if(target.kind==='reserve') {
    const b=await readJson(request);
    if(typeof b.purpose!=='string'||(b.purpose!=='comment'&&!Object.hasOwn(photoLimits,b.purpose))||typeof b.bytes!=='number'||
        typeof b.sha256!=='string'||!/^[a-f0-9]{64}$/.test(b.sha256)||b.mime!=='image/jpeg') throw new HttpError(400,'invalid_request');
    const purpose=(b.purpose==='comment'?'post':b.purpose) as PhotoPurpose;
    const variant=b.variantOf??null;
    if((purpose==='thumbnail')!==(variant!==null)||variant!==null&&(typeof variant!=='string'||!isId(variant))) throw new HttpError(400,'invalid_request');
    if(purpose==='gallery'&&member.role!=='artist'&&member.role!=='content_operator') throw new HttpError(403,'access_denied');
    if(b.bytes>photoLimits[purpose][1]) throw new HttpError(413,'payload_too_large');
    return {data:status(await store.reserve(actor,request.headers.get('idempotency-key')??'',b.bytes,'image/jpeg',{
      purpose,hash:b.sha256,variant,comment:b.purpose==='comment',
    })),status:201};
  }
  if(!id) throw new HttpError(404,'not_found');
  const existing=await store.status(id,actor.id);
  if(!existing.purpose) throw new HttpError(404,'not_found');
  if(target.kind==='status') {
    if(request.method==='DELETE'){await store.cancel(actor,id);return {data:null,status:204};}
    return {data:status(existing),status:200};
  }
  if(target.kind==='body') {
    if(!['reserved','quarantined'].includes(existing.state)||existing.expires_at<=clock()) throw new HttpError(409,'conflict');
    await store.quarantine(actor,id,await photoBytes(request,existing.reserved_bytes));
  } else {
    const purpose=existing.purpose;
    await store.approve(actor,id,async (bytes,mime)=>mime==='image/jpeg'&&inspectPhoto(bytes,purpose));
  }
  return {data:status(await store.status(id,actor.id)),status:200};
}
