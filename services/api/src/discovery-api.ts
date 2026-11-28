import { Collections } from './collections.ts';
import { requireEmptyBody } from './community-api.ts';
import { CommunityStore } from './community-store.ts';
import { Discovery,kindInput,requiredId } from './discovery.ts';
import { HttpError,readJson } from './http.ts';
import { admit,bearer } from './membership-api.ts';
import type { MembershipDependencies,ReadReservations } from './membership-api.ts';
import { MembershipStore } from './membership-store.ts';
import type { Env } from './platform.ts';

export function discoveryTarget(path:string) {
  const routes=[
    [/^\/v1\/search$/,'search','GET'],
    [/^\/v1\/members\/official$/,'official','GET'],
    [/^\/v1\/tags\/popular$/,'popular','GET'],
    [/^\/v1\/favorites$/,'favorites','GET'],
    [/^\/v1\/favorites\/(post|member|tag)\/([^/]+)$/,'favorite','GET, PUT, DELETE'],
    [/^\/v1\/me\/blocks$/,'blocks','GET'],
    [/^\/v1\/me\/blocks\/([^/]+)$/,'unblock','PUT, DELETE'],
    [/^\/v1\/collections$/,'folders','GET, POST'],
    [/^\/v1\/members\/([^/]+)\/collections$/,'memberFolders','GET'],
    [/^\/v1\/collections\/([^/]+)$/,'folder','GET, PATCH, DELETE'],
    [/^\/v1\/collections\/([^/]+)\/entries$/,'entry','POST, PATCH'],
    [/^\/v1\/gallery\/([^/]+)\/collectors$/,'collectors','GET'],
    [/^\/v1\/me\/recents$/,'recent','GET, DELETE'],
    [/^\/v1\/me\/recents\/([^/]+)$/,'recentAlbum','PUT, DELETE'],
  ] as const;
  for(const [match,kind,methods] of routes) {
    const parts=match.exec(path);
    if(parts) return {kind,methods,a:parts[1],b:parts[2]};
  }
  return null;
}

type Target=NonNullable<ReturnType<typeof discoveryTarget>>;

export async function handleDiscovery(request:Request,url:URL,target:Target,env:Env,deps:MembershipDependencies,
  now:number,reads:ReadReservations,network:string) {
  if(request.method!=='GET'&&url.search) throw new HttpError(400,'invalid_request');
  const identity=await deps.verify(bearer(request),now);
  if(!identity) throw new HttpError(401,'authentication_required');
  const actor=await new MembershipStore(env.DB,now,deps.key).context(identity,request.headers.get('x-app-session')??'');
  if(actor.phase!=='active') throw new HttpError(403,'access_denied');
  const method=request.method;
  if(method==='PUT') await requireEmptyBody(request);
  const read=method==='GET';
  const expensive=target.kind==='search'||target.kind==='popular'||target.kind==='collectors'||target.kind==='memberFolders';
  const essential=target.kind==='unblock'||target.kind==='recent'&&method==='DELETE';
  const category=expensive?'search':read?'read':target.kind;
  const lease='discovery:'+actor.session.id+':'+network;
  if(read&&url.search&&['popular','favorite','folders','memberFolders'].includes(target.kind)) throw new HttpError(400,'invalid_request');
  const scopes=[
    {kind:'user',key:'discovery:'+category+':'+actor.member.id,limit:expensive?20:read?48:20},
    {kind:'session',key:'discovery:'+category+':'+actor.session.id,limit:expensive?16:read?40:16},
    {kind:'network',key:'discovery:'+category+':'+network,limit:expensive?140:read?300:100},
    {kind:'operation',key:'discovery:'+category,limit:expensive?210:read?600:180},
  ] as const;
  if(read&&!expensive) {
    const maintenance=await env.DB.prepare("SELECT enabled FROM feature_flags WHERE name='maintenance_mode'").first<{enabled:number}>();
    if(maintenance?.enabled!==0) throw new HttpError(503,'maintenance',60);
    if(!reads.take(lease,now)) {
      await admit(env,now,scopes,4,'read',{rowsPerRequest:550});
      reads.install(lease,now);
    }
  } else await admit(env,now,scopes,1,essential?'essential':read?'read':'write',
    {rowsPerRequest:target.kind==='memberFolders'?32_000:expensive?2_500:1_000,...(expensive?{priority:'bulk' as const}:{}),extraWrites:read?0:target.kind==='folder'?120:30,
      flags:expensive?['search_enabled']:[]});
  const store=new CommunityStore(env.DB,actor,now);
  const discover=new Discovery(store,deps.key);
  const collections=new Collections(store,deps.key);
  const success=(data:unknown,status=200)=>({data,status});
  switch(target.kind) {
    case 'search':return success(await discover.search(url.searchParams));
    case 'popular':return success(await discover.popular());
    case 'official':return success(await discover.official(url.searchParams));
    case 'favorites':return success(await discover.favoriteList(kindInput(url.searchParams.get('kind')??'post',false) as 'post'|'member'|'tag',url.searchParams));
    case 'favorite':return success(await discover.favorite(kindInput(target.a,false) as 'post'|'member'|'tag',requiredId(target.b),method));
    case 'blocks':return success(await discover.blocks(url.searchParams));
    case 'unblock': {
      if(method==='PUT') {
        await store.block(requiredId(target.a));
      } else await discover.unblock(requiredId(target.a));
      return success(null,204);
    }
    case 'folders':return method==='GET'?success(await collections.folders(actor.member.id)):
      success(await collections.create(await readJson(request)),201);
    case 'memberFolders':return success(await collections.folders(requiredId(target.a)));
    case 'folder': {
      const id=requiredId(target.a);
      if(method==='GET') return success(await collections.items(id,url.searchParams));
      const version=request.headers.get('if-match')?.match(/^"([1-9][0-9]{0,8})"$/)?.[1];
      if(!version) throw new HttpError(400,'invalid_request');
      if(method==='PATCH') return success(await collections.update(id,Number(version),await readJson(request)));
      await collections.drop(id,Number(version));
      return success(null,204);
    }
    case 'entry': {
      const id=requiredId(target.a);
      const body=await readJson(request);
      if(method==='POST') return success(await collections.add(id,body),201);
      return success(await collections.modifyEntries(id,body)??{removed:true});
    }
    case 'collectors':return success(await collections.collectors(requiredId(target.a),url.searchParams));
    case 'recent':
      if(method==='GET') return success(await collections.recent(url.searchParams));
      await collections.clearRecent(null);
      return success(null,204);
    case 'recentAlbum':
      if(method==='PUT') await collections.recordRecent(requiredId(target.a));
      else await collections.clearRecent(requiredId(target.a));
      return success(null,204);
  }
}
