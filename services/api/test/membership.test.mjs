import assert from 'node:assert/strict';
import { test } from 'node:test';
import { simulator,migrate,migrations,seed,demoMember } from '../../../tools/local-backend.mjs';
import { query,digest } from '../src/platform.ts';
import { MembershipStore,officialOnly,staffOnly,beginDeletion } from '../src/membership-store.ts';
import { policyDocuments,policyVersion } from '../src/membership-policy.ts';
import { createApi } from '../src/index.ts';
import { allowRate } from '../src/rate.ts';

const time=Date.UTC(2026,10,25,0);
const uid='fixture-membership-store';
const identity={uid,authAt:time,verifiedEmail:true};
const uuid=()=>globalThis.crypto.randomUUID();
const nonce=()=>globalThis.Buffer.from(globalThis.crypto.getRandomValues(new Uint8Array(32))).toString('base64url');
const fail=(status,code)=>error=>error.status===status&&error.code===code;

async function run(action,initialized=true) {
  const runtime=simulator('test');
  try {
    const DB=await runtime.getD1Database('DB');
    if(initialized) await migrate(DB);
    const key=await globalThis.crypto.subtle.importKey('raw',globalThis.crypto.getRandomValues(new Uint8Array(32)),
      {name:'HMAC',hash:'SHA-256'},false,['sign']);
    const env={APP_ENV:'test',DB,PRIVATE_MEDIA:await runtime.getR2Bucket('PRIVATE_MEDIA'),QUARANTINE:await runtime.getR2Bucket('QUARANTINE')};
    return await action(env,key);
  } finally {await runtime.dispose();}
}

async function active(DB,key) {
  const store=new MembershipStore(DB,time,key);
  const issued=await store.issue(identity,nonce(),'Fixture','other');
  await store.accept(await store.context(identity,issued.sessionToken),{
    version:policyVersion,documents:policyDocuments.map(doc=>doc.kind),
  });
  const own=await store.context(identity,issued.sessionToken);
  await store.edit(own,{nickname:'空',biography:'合成'},1);
  return {store,issued};
}

test('v4 to v6 rollback and upgrade preserves members, legacy sessions and the original ledger',()=>run(async({DB})=>{
  const path=await migrations();
  await migrate(DB,path.slice(0,4));
  await seed(DB);
  const s=uuid();
  await query(DB,'INSERT INTO member_sessions VALUES (?,?,?,?,?,NULL,?)',s,demoMember,await digest(nonce()),time,time+10_000,time).run();
  const old=await query(DB,'SELECT * FROM schema_migrations ORDER BY version').all();
  const oldMember=await query(DB,'SELECT * FROM members WHERE id=?',demoMember).first();
  const broken={...path[4],statements:[...path[4].statements,'UPDATE table_not_present SET field=1']};
  await assert.rejects(migrate(DB,[...path.slice(0,4),broken]));
  assert.deepEqual((await query(DB,'SELECT * FROM schema_migrations ORDER BY version').all()).results,old.results);
  const after=await query(DB,"SELECT sql FROM sqlite_schema WHERE name='policy_acceptances'").first();
  assert.equal(after,null);
  assert.equal(await migrate(DB),6);
  assert.deepEqual(await query(DB,'SELECT * FROM members WHERE id=?',demoMember).first(),oldMember);
  const device=await query(DB,'SELECT device_os,absolute_expires_at FROM member_sessions WHERE id=?',s).first();
  assert.deepEqual(device,{device_os:'other',absolute_expires_at:null});
},false));

test('roles require active grants and official binding, and staff requires separate step-up',()=>run(async({DB},key)=>{
  const {store,issued}=await active(DB,key);
  const member=issued.profile.id;
  const [issuer,reviewer]=await Promise.all(['fixture-granter','fixture-reviewer'].map(name=>
    store.issue({...identity,uid:name},nonce(),'Fixture','other')));
  const grant=uuid();
  const values=[grant,member,issuer.profile.id,reviewer.profile.id,time-100,time+100];
  await assert.rejects(query(DB,"INSERT INTO role_grants VALUES (?,?,'artist',?,?,?,?,NULL)",
    grant,member,member,reviewer.profile.id,time-100,time+100).run());
  await query(DB,"INSERT INTO role_grants VALUES (?,?,'artist',?,?,?,?,NULL)",...values).run();
  assert.throws(()=>officialOnly({phase:'active',member:{role:'member'}}),fail(403,'access_denied'));
  assert.equal((await store.context(identity,issued.sessionToken)).member.role,'member');
  await query(DB,"INSERT INTO official_identities VALUES (?,?,'Synthetic',1)",uuid(),member).run();
  officialOnly(await store.context(identity,issued.sessionToken));
  const after=new MembershipStore(DB,time+101,key);
  assert.throws(()=>staffOnly({phase:'active',member:{role:'administrator'}}),fail(403,'access_denied'));
  assert.equal((await after.context(identity,issued.sessionToken)).member.role,'member');
  await query(DB,'UPDATE role_grants SET revoked_at=? WHERE id=?',time,grant).run();
  await query(DB,"INSERT INTO role_grants VALUES (?,?,'administrator',?,?,?,?,NULL)",uuid(),...values.slice(1)).run();
  const admin=await store.context(identity,issued.sessionToken);
  assert.equal(admin.member.role,'administrator');
  assert.throws(()=>officialOnly(admin),fail(403,'access_denied'));
  assert.throws(()=>staffOnly(admin),fail(403,'access_denied'));
  await query(DB,"UPDATE role_grants SET revoked_at=? WHERE member_id=? AND role='administrator'",time,member).run();
  await query(DB,'INSERT INTO content_operator_grants VALUES (?,?,?,?,?,?,NULL)',uuid(),...values.slice(1)).run();
  const operator=await store.context(identity,issued.sessionToken);
  assert.equal(operator.member.role,'content_operator');
  assert.throws(()=>officialOnly(operator),fail(403,'access_denied'));
}));

test('unverified, suspended, deleting and revoked devices cannot regain protected access',()=>run(async({DB},key)=>{
  const {store,issued}=await active(DB,key);
  const device2=await store.issue(identity,nonce(),'Other device','android');
  const member=issued.profile.id;
  const history=await Promise.all(Array.from({length:20},async(_,index)=>query(DB,
    'INSERT INTO member_sessions(id,member_id,session_hash,created_at,expires_at,revoked_at,last_seen) VALUES (?,?,?,?,?,?,?)',
    uuid(),member,await digest(nonce()),time+index+1,time+20_000,time+30,time+index+1)));
  await DB.batch(history);
  const later=new MembershipStore(DB,time+31,key);
  const devices=await later.list(await later.context(identity,issued.sessionToken));
  assert.equal(devices.items.length,20);
  assert.equal(devices.items[0].id,issued.session.id);
  assert.equal(devices.items[1].id,device2.session.id);
  assert.ok(devices.items.slice(2).every(device=>device.status==='revoked'));
  const ctx=await store.context(identity,issued.sessionToken);
  assert.equal((await store.context({...identity,verifiedEmail:false},issued.sessionToken)).phase,'unverified');
  await query(DB,"UPDATE members SET state='suspended' WHERE id=?",issued.profile.id).run();
  await assert.rejects(store.context(identity,issued.sessionToken),fail(403,'account_suspended'));
  await query(DB,"UPDATE members SET state='active' WHERE id=?",issued.profile.id).run();
  const renewedAt=time+8*3_600_000-30_000;
  const renewal=new MembershipStore(DB,renewedAt,key);
  await renewal.renew(await renewal.context(identity,issued.sessionToken));
  assert.ok((await renewal.context(identity,issued.sessionToken)).session.expires_at>renewedAt+3_600_000);
  const afterExpiry=new MembershipStore(DB,renewedAt+30000,key);
  await assert.rejects(afterExpiry.context(identity,device2.sessionToken),fail(401,'authentication_required'));
  await beginDeletion(DB,ctx,time+1);
  for (const entry of [issued,device2]) {
    await assert.rejects(renewal.context(identity,entry.sessionToken),fail(403,'account_deleting'));
  }
  await assert.rejects(store.issue(identity,nonce(),'Fixture','other'),fail(403,'account_deleting'));
  const deletion=await query(DB,'SELECT state FROM deletion_requests WHERE member_id=?',issued.profile.id).first();
  assert.equal(deletion.state,'requested');
  assert.equal((await query(DB,"SELECT count(*) AS count FROM scheduled_jobs WHERE kind='member_deletion'").first()).count,1);
  await assert.rejects(query(DB,"UPDATE members SET state='active' WHERE id=?",issued.profile.id).run());
}));

test('same 12 reads show D1 writes drop without last_seen writes or weakening shared quota',()=>run(async(env,key)=>{
  const {DB}=env;
  const {issued}=await active(DB,key);
  const old=[], now=[];
  const make=(secret,appSession)=>new globalThis.Request('http://localhost/v1/me/session',{
    headers:{authorization:'Bearer '+secret,...(appSession?{'x-app-session':appSession}:{})},
  });
  const compare=createApi({clock:()=>time,log:e=>old.push(e),
    verify:async()=>({firebaseUid:uid,sessionDigest:await digest(issued.sessionToken)})});
  const member=createApi({clock:()=>time,log:e=>now.push(e),membership:{
    verify:async()=>identity,key,sendCode:async()=>{},
  }});
  for(let i=0;i<12;i++) {
    assert.equal((await compare(make('legacy-fixture'),env)).status,200);
    assert.equal((await member(make('provider-fixture',issued.sessionToken),env)).status,200);
  }
  const count=(events,field)=>events.reduce((sum,event)=>sum+event.d1[field],0);
  const before=count(old,'writes'),after=count(now,'writes');
  assert.ok(before>0&&after>0&&after<=before/3);
  assert.equal((await query(DB,'SELECT last_seen FROM member_sessions WHERE id=?',issued.session.id).first()).last_seen,time);
  const pressure=await Promise.all(Array.from({length:7},()=>allowRate(DB,[
    {kind:'user',key:'amortized-test',limit:12},{kind:'operation',key:'amortized-test-2',limit:12},
  ],time,4)));
  assert.equal(pressure.filter(item=>item.allowed).length,3);
  globalThis.console.log('Cost fixture 12 reads: D1 write rows '+before+' -> '+after+', read rows '+count(old,'reads')+' -> '+count(now,'reads'));
  assert.doesNotMatch(JSON.stringify(now),/provider-fixture|x-app-session|fixture-membership-store/);
}));
