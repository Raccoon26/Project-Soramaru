import { CommunityStore } from './community-store.ts';
import { postRequestBytes } from './community-input.ts';
import { HttpError,readJson } from './http.ts';
import { admit,bearer,ReadReservations } from './membership-api.ts';
import type { MembershipDependencies } from './membership-api.ts';
import { MembershipStore } from './membership-store.ts';
import { isId } from './platform.ts';
import type { Env } from './platform.ts';

export function communityTarget(path: string) {
  if (path==='/v1/posts') return {kind:'posts',methods:'GET, POST'} as const;
  if (path==='/v1/reports') return {kind:'report',methods:'POST'} as const;
  if (path==='/v1/tags/popular') return {kind:'popular',methods:'GET'} as const;
  const routes=[
    {prefix:'/v1/posts/',kind:'post',methods:'GET, PATCH, DELETE'},
    {prefix:'/v1/members/',kind:'member',methods:'GET'},
    {prefix:'/v1/me/blocks/',kind:'block',methods:'PUT'},
  ] as const;
  const route=routes.find(item=>path.startsWith(item.prefix));
  return route?{...route,id:path.slice(route.prefix.length)}:null;
}

type Target=NonNullable<ReturnType<typeof communityTarget>>;

export async function handleCommunity(request: Request,url: URL,target: Target,env: Env,deps: MembershipDependencies,
  now: number,reads: ReadReservations,network: string) {
  const identity=await deps.verify(bearer(request),now);
  if (!identity) throw new HttpError(401,'authentication_required');
  const actor=await new MembershipStore(env.DB,now,deps.key).context(identity,request.headers.get('x-app-session')??'');
  if (actor.phase!=='active') throw new HttpError(403,'access_denied');
  const id='id' in target?target.id:null;
  if (id!==null&&!isId(id)) throw new HttpError(404,'not_found');
  const read=request.method==='GET';
  if (url.search&&!(read&&target.kind==='posts')) throw new HttpError(400,'invalid_request');
  const essential=target.kind==='report'||target.kind==='block';
  const category=read?'read':essential?target.kind:'write';
  const lease='community:'+actor.session.id+':'+network;
  const scopes=[
    {kind:'user',key:'community:'+category+':'+actor.member.id,limit:read?96:target.kind==='report'?5:12},
    {kind:'session',key:'community:'+category+':'+actor.session.id,limit:read?64:10},
    {kind:'network',key:'community:'+category+':'+network,limit:read?400:90},
    {kind:'operation',key:'community:'+category,limit:read?600:180},
  ] as const;
  if (read) {
    const flag=await env.DB.prepare("SELECT enabled FROM feature_flags WHERE name='maintenance_mode'").first<{enabled:number}>();
    if (flag?.enabled!==0) throw new HttpError(503,'maintenance',60);
    if (!reads.take(lease,now)) {
      await admit(env,now,scopes,4,'read',{rowsPerRequest:350});
      reads.install(lease,now);
    }
  } else {
    await admit(env,now,scopes,1,essential?'essential':'write',{
      rowsPerRequest:90,extraWrites:essential?12:140,flags:essential?[]:['posting_enabled'],
    });
  }
  const store=new CommunityStore(env.DB,actor,now);
  if (target.kind==='popular') return {data:{items:[],availability:'planned'},status:200};
  if (target.kind==='member'&&id) return {data:await store.member(id),status:200};
  if (target.kind==='report') {
    await store.report(await readJson(request));
    return {data:{status:'accepted'},status:202};
  }
  if (target.kind==='block'&&id) {
    const reader=request.body?.getReader();
    if (reader) {
      try {
        if (!(await reader.read()).done) {
          await reader.cancel().catch(()=>undefined);
          throw new HttpError(400,'invalid_request');
        }
      } finally {
        reader.releaseLock();
      }
    }
    await store.block(id);
    return {data:null,status:204};
  }
  if (read) return {data:id?await store.detail(id):await store.list(url.searchParams,deps.key),status:200};
  const key=request.headers.get('idempotency-key')??'';
  const raw=request.headers.get('if-match');
  const expected=raw?.match(/^"([1-9][0-9]{0,8})"$/)?.[1];
  if (id&&!expected) throw new HttpError(400,'invalid_request');
  if (request.method==='DELETE'&&id&&expected) {
    await store.remove(id,key,Number(expected));
    return {data:null,status:204};
  }
  const body=await readJson(request,postRequestBytes);
  return {data:await store.save(id,body,key,expected?Number(expected):null),status:id?200:201};
}
