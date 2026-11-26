import { commentRequestBytes,counts,exposeCounts,Interactions } from './interactions.ts';
import { CommunityStore } from './community-store.ts';
import { postRequestBytes } from './community-input.ts';
import { HttpError,readJson } from './http.ts';
import { admit,bearer,ReadReservations } from './membership-api.ts';
import type { MembershipDependencies } from './membership-api.ts';
import { MembershipStore } from './membership-store.ts';
import { isId } from './platform.ts';
import type { Env } from './platform.ts';

export function communityTarget(path: string) {
  const comments=/^\/v1\/posts\/([^/]+)\/comments$/.exec(path);
  if(comments?.[1]) return {kind:'comments',id:comments[1],methods:'GET, POST'} as const;
  const comment=/^\/v1\/comments\/([^/]+)$/.exec(path);
  if(comment?.[1]) return {kind:'comment',id:comment[1],methods:'GET, PATCH, DELETE'} as const;
  const reaction=/^\/v1\/reactions\/(post|comment)\/([^/]+)$/.exec(path);
  if(reaction?.[2]) return {kind:'reaction',id:reaction[2],on:reaction[1]==='post'?'post':'comment',methods:'PUT, DELETE'} as const;
  if(path==='/v1/stamps') return {kind:'stamps',methods:'GET'} as const;
  if(path==='/v1/me/activity') return {kind:'activity',methods:'GET'} as const;
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

async function requireEmptyBody(request:Request) {
  const reader=request.body?.getReader();
  if(!reader) return;
  try {
    if(!(await reader.read()).done) {
      await reader.cancel().catch(()=>undefined);
      throw new HttpError(400,'invalid_request');
    }
  } finally { reader.releaseLock(); }
}

export async function handleCommunity(request: Request,url: URL,target: Target,env: Env,deps: MembershipDependencies,
  now: number,reads: ReadReservations,network: string) {
  const identity=await deps.verify(bearer(request),now);
  if (!identity) throw new HttpError(401,'authentication_required');
  const actor=await new MembershipStore(env.DB,now,deps.key).context(identity,request.headers.get('x-app-session')??'');
  if (actor.phase!=='active') throw new HttpError(403,'access_denied');
  const id='id' in target?target.id:null;
  if (id!==null&&!isId(id)) throw new HttpError(404,'not_found');
  const read=request.method==='GET';
  if (url.search&&!(read&&['posts','comments','activity'].includes(target.kind))) throw new HttpError(400,'invalid_request');
  const essential=target.kind==='report'||target.kind==='block';
  const interactionWrite=['comments','comment','reaction'].includes(target.kind);
  const category=read?'read':essential||interactionWrite?target.kind:'write';
  const lease='community:'+actor.session.id+':'+network;
  const scopes=[
    {kind:'user',key:'community:'+category+':'+actor.member.id,limit:read?96:target.kind==='report'?5:target.kind==='reaction'?36:12},
    {kind:'session',key:'community:'+category+':'+actor.session.id,limit:read?64:target.kind==='reaction'?28:10},
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
      rowsPerRequest:90,extraWrites:essential?12:target.kind==='reaction'?12:interactionWrite?25:140,flags:essential?[]:interactionWrite?['comments_enabled']:['posting_enabled'],
    });
  }
  const store=new CommunityStore(env.DB,actor,now);
  const interactions=new Interactions(store);
  if(target.kind==='stamps') return {data:await interactions.catalog(),status:200};
  if(target.kind==='activity') return {data:await interactions.activity(url.searchParams,deps.key),status:200};
  if(target.kind==='reaction') {
    await requireEmptyBody(request);
    return {data:await interactions.react(target.on,target.id,request.method==='PUT'),status:200};
  }
  if(read&&target.kind==='comments') return {data:await interactions.list(target.id,url.searchParams,deps.key),status:200};
  if(read&&target.kind==='comment') return {data:await interactions.detail(target.id),status:200};
  if (target.kind==='popular') return {data:{items:[],availability:'planned'},status:200};
  if (target.kind==='member'&&id) return {data:await store.member(id),status:200};
  if (target.kind==='report') {
    await store.report(await readJson(request));
    return {data:{status:'accepted'},status:202};
  }
  if (target.kind==='block'&&id) {
    await requireEmptyBody(request);
    await store.block(id);
    return {data:null,status:204};
  }
  if(read) {
    if(id) {
      const post=await store.detail(id);
      const metrics=await counts(env.DB,actor.member.id,now,'post',[id]);
      return {data:{...post,...exposeCounts(metrics.get(id))},status:200};
    }
    const page=await store.list(url.searchParams,deps.key);
    const metrics=await counts(env.DB,actor.member.id,now,'post',
      [...new Set([...page.items,...page.pinned].map(post=>post.id))]);
    const annotate=(post:typeof page.items[number])=>({...post,...exposeCounts(metrics.get(post.id))});
    return {data:{...page,items:page.items.map(annotate),pinned:page.pinned.map(annotate)},status:200};
  }
  const key=request.headers.get('idempotency-key')??'';
  const raw=request.headers.get('if-match');
  const expected=raw?.match(/^"([1-9][0-9]{0,8})"$/)?.[1];
  if(target.kind==='comments') return {data:await interactions.save(target.id,null,await readJson(request,commentRequestBytes),key,null),status:201};
  if (id&&!expected) throw new HttpError(400,'invalid_request');
  if(target.kind==='comment') {
    if(request.method==='DELETE') {
      await interactions.remove(target.id,key,Number(expected));
      return {data:null,status:204};
    }
    return {data:await interactions.save(null,target.id,await readJson(request,commentRequestBytes),key,Number(expected)),status:200};
  }
  if (request.method==='DELETE'&&id&&expected) {
    await store.remove(id,key,Number(expected));
    return {data:null,status:204};
  }
  const body=await readJson(request,postRequestBytes);
  return {data:await store.save(id,body,key,expected?Number(expected):null),status:id?200:201};
}
