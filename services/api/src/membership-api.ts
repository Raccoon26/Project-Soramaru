import { Budget } from './cost.ts';
import { allowRate } from './rate.ts';
import type { LimitScope } from './rate.ts';
import { isId,query } from './platform.ts';
import { base64url } from './firebase.ts';
import type { Env } from './platform.ts';
import { HttpError,readJson } from './http.ts';
import { MembershipStore,inputText } from './membership-store.ts';
import { policyDocuments,policyVersion } from './membership-policy.ts';
import type { FirebaseVerifier } from './firebase.ts';

export interface MembershipDependencies {
  verify: FirebaseVerifier;
  key: CryptoKey;
  sendCode: (kind: 'verify'|'reset', tokenOrEmail: string) => Promise<void>;
}

type Path='policies'|'email'|'issue'|'renew'|'status'|'profile'|'accept'|'devices'|'device';
export interface Target {path: Path; methods: string; id?: string}

export function membershipTarget(pathname: string): Target|null {
  switch (pathname) {
    case '/v1/auth/policies': return {path:'policies',methods:'GET'};
    case '/v1/auth/email': return {path:'email',methods:'POST'};
    case '/v1/sessions': return {path:'devices',methods:'GET, POST, DELETE'};
    case '/v1/sessions/renew': return {path:'renew',methods:'POST'};
    case '/v1/me/session': return {path:'status',methods:'GET'};
    case '/v1/me': return {path:'profile',methods:'GET, PATCH'};
    case '/v1/me/terms': return {path:'accept',methods:'POST'};
  }
  if (!pathname.startsWith('/v1/sessions/')) return null;
  return {path:'device',methods:'GET, DELETE',id:pathname.slice('/v1/sessions/'.length)};
}

interface Lease { expires:number; left:number }
const blockSize=4;
export class ReadReservations {
  private readonly leases=new Map<string,Lease>();

  take(key:string,now:number) {
    const lease=this.leases.get(key);
    if (!lease||lease.expires<=now||lease.left===0) return false;
    lease.left--;
    return true;
  }

  install(key:string,now:number) {
    if (this.leases.size>=512) {
      const oldest=this.leases.keys().next().value;
      if (oldest!==undefined) this.leases.delete(oldest);
    }
    const expires=Math.min(now+15_000,(Math.floor(now/60_000)+1)*60_000);
    this.leases.set(key,{expires,left:blockSize-1});
  }
}

async function admit(env: Env,now:number,scopes:readonly LimitScope[],units:number,operation:'read'|'write'|'essential'|'registration') {
  const gate=await new Budget(env.DB).admit(operation==='essential'?'essential':operation==='read'?'standard':'optional-write',{
    requests:units,d1Reads:15*units,d1Writes:scopes.length*2+(operation==='read'?0:8),d1IndexWrites:scopes.length,
  },now,operation==='registration'?['registration_enabled']:[]);
  if (!gate.allowed) {
    const maintenance=await query(env.DB,"SELECT enabled FROM feature_flags WHERE name='maintenance_mode'").first<{enabled:number}>();
    throw new HttpError(503,maintenance?.enabled===1?'maintenance':'cost_limited',60);
  }
  const rate=await allowRate(env.DB,scopes,now,units);
  if (!rate.allowed) throw new HttpError(429,'rate_limited',rate.retryAfter);
}

function bearer(request: Request) {
  const value=request.headers.get('authorization')?.match(/^Bearer ([A-Za-z0-9._-]{1,8192})$/)?.[1];
  if (!value) throw new HttpError(401,'authentication_required');
  return value;
}

function emailAddress(value: unknown) {
  const email=inputText(value,3,254).toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(email)) throw new HttpError(400,'invalid_request');
  return email;
}

export async function handleMembership(request:Request,target:Target,env:Env,options:MembershipDependencies,
  now:number,reads:ReadReservations,network:string) {
  if (target.path==='policies') return {data:{version:policyVersion,documents:policyDocuments},status:200};
  const needBody=request.method==='POST'&&target.path!=='renew'||request.method==='PATCH';
  const body=needBody?await readJson(request):{};
  const store=new MembershipStore(env.DB,now,options.key);
  if (target.path==='email') {
    const kind=body['kind'];
    if (kind!=='verify'&&kind!=='reset') throw new HttpError(400,'invalid_request');
    const value=kind==='verify'?bearer(request):emailAddress(body['email']);
    const principal=kind==='verify'?await options.verify(value,now):null;
    if (kind==='verify'&&!principal) throw new HttpError(401,'authentication_required');
    const subject=principal?.uid??value;
    const raw=new TextEncoder().encode(JSON.stringify(['mail-cooldown-v1',kind,subject]));
    const key=base64url(new Uint8Array(await crypto.subtle.sign('HMAC',options.key,raw)));
    const utcDay=new Date(now).toISOString().slice(0,10);
    const dailyLimit=kind==='verify'?700:100;
    const buckets:LimitScope[]=[
      {kind:'user',key:'email:'+kind+':'+key,limit:1},
      {kind:'network',key:'email:'+kind+':'+network,limit:15},
      {kind:'operation',key:'email:'+kind,limit:30},
    ];
    await admit(env,now,buckets,1,'write');
    const cooldown=await query(env.DB,`INSERT INTO rate_limits VALUES (?1,?2,1)
      ON CONFLICT(scope) DO UPDATE SET window=excluded.window WHERE window<=?2-60000 RETURNING count`,
      'membership-mail-cooldown:'+key,now).all();
    if (!cooldown.results.length) throw new HttpError(429,'rate_limited',60);
    // The independent UTC day cap reserves capacity before attempting delivery.
    const quota=await query(env.DB,`INSERT INTO rate_limits VALUES (?1,?2,1)
      ON CONFLICT(scope) DO UPDATE SET count=count+1 WHERE count<?3 RETURNING count`,
      'membership-mail:'+kind+':'+utcDay,Math.floor(now/60_000),dailyLimit).all();
    if (!quota.results.length) throw new HttpError(429,'rate_limited',3600);
    await options.sendCode(kind,value);
    return {data:{status:'accepted'},status:202};
  }
  const token=bearer(request);
  const identity=await options.verify(token,now);
  if (!identity) throw new HttpError(401,'authentication_required');
  if (target.path==='devices'&&request.method==='POST') {
    await admit(env,now,[
      {kind:'user',key:'session:issue:'+identity.uid,limit:8},
      {kind:'network',key:'session:issue:'+network,limit:90},
      {kind:'operation',key:'session:issue',limit:180},
    ],1,'registration');
    const nonce=request.headers.get('idempotency-key')??'';
    return {data:await store.issue(identity,nonce,inputText(body['alias'],1,40),inputText(body['os'],1,8)),status:201};
  }
  const appSession=request.headers.get('x-app-session')??'';
  const actor=await store.context(identity,appSession);
  if (target.id!==undefined&&!isId(target.id)) throw new HttpError(404,'not_found');
  if (actor.phase!=='active'&&!['status','profile','accept','renew'].includes(target.path)&&
    !(target.path==='device'&&target.id===actor.session.id&&request.method==='DELETE')) throw new HttpError(403,'access_denied');
  const read=request.method==='GET';
  const category=read?'read':request.method==='DELETE'?'revoke':target.path==='renew'?'renew':'write';
  const scopes:LimitScope[]=[
    {kind:'user',key:'membership:'+category+':'+actor.member.id,limit:read?96:20},
    {kind:'session',key:'membership:'+category+':'+actor.session.id,limit:read?64:12},
    {kind:'network',key:'membership:'+category+':'+network,limit:read?400:90},
    {kind:'operation',key:'membership:'+category,limit:read?600:180},
  ];
  const lease=actor.session.id+':'+network;
  if (read) {
    const flag=await query(env.DB,"SELECT enabled FROM feature_flags WHERE name='maintenance_mode'").first<{enabled:number}>();
    if (flag?.enabled!==0) throw new HttpError(503,'maintenance',60);
    if (!reads.take(lease,now)) {
      await admit(env,now,scopes,blockSize,'read');
      reads.install(lease,now);
    }
  } else {
    await admit(env,now,scopes,1,request.method==='DELETE'?'essential':'write');
  }
  switch (target.path) {
    case 'status': return {data:store.snapshot(actor),status:200};
    case 'renew': return {data:await store.renew(actor),status:200};
    case 'profile': {
      if (request.method==='GET') return {data:store.snapshot(actor).profile,status:200};
      const expected=request.headers.get('if-match')?.match(/^"([1-9][0-9]{0,8})"$/)?.[1];
      if (!expected) throw new HttpError(400,'invalid_request');
      await store.edit(actor,body,Number(expected));
      return {data:store.snapshot(await store.context(identity,appSession)),status:200};
    }
    case 'accept':
      await store.accept(actor,body);
      return {data:store.snapshot(await store.context(identity,appSession)),status:200};
    case 'devices':
      if (request.method==='GET') return {data:await store.list(actor),status:200};
      await store.revokeAll(actor);
      return {data:null,status:204};
    case 'device':
      if (request.method==='GET') return {data:await store.detail(actor,target.id??''),status:200};
      await store.revoke(actor,target.id??'');
      return {data:null,status:204};
    default: throw new HttpError(404,'not_found');
  }
}
