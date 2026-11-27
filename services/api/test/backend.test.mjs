
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { simulator,migrate,migrations,seed,demoMember } from '../../../tools/local-backend.mjs';
import { backup,backupKey,captureRows,restore,schemaIdentity } from '../../../tools/local-backup.mjs';
import worker,{createApi} from '../src/index.ts';
import { checkEnvironment,digest,query } from '../src/platform.ts';
import { localEnvironment } from '../local-config.ts';
import { Budget,costConfiguration,utcWindows } from '../src/cost.ts';
import { allowRate,EdgeBurst } from '../src/rate.ts';
import { authenticate,requireOwner,requireRole } from '../src/auth.ts';
import { readJson } from '../src/http.ts';
import { cursorKey,pageSize,readFeed,visibleContent } from '../src/paging.ts';
import { MediaAccess,MediaStore } from '../src/media.ts';
import { idempotent } from '../src/writes.ts';
import { claim,enqueue,eventStatements,finish,outboxHandler,runJobs } from '../src/jobs.ts';

const uid = n => '20000000-0000-4000-8000-' + String(n).padStart(12,'0');
const uuid = () => globalThis.crypto.randomUUID();
const now = Date.UTC(2026,10,25,1);
const request = (path,init) => new globalThis.Request('http://localhost'+path,init);
const response = bytes => new globalThis.Response(bytes);
const codec = new globalThis.TextEncoder();
const body = value => codec.encode(value).buffer;
const pause = (status,code) => error => error.status === status && error.code === code;

async function withRuntime(run, initialize = true) {
  const runtime = simulator();
  try {
    const db = await runtime.getD1Database('DB');
    const env = {
      APP_ENV:'test',DB:db,
      PRIVATE_MEDIA:await runtime.getR2Bucket('PRIVATE_MEDIA'),
      QUARANTINE:await runtime.getR2Bucket('QUARANTINE'),
    };
    if (initialize) {
      await migrate(db);
      await seed(db);
    }
    return await run(env,runtime);
  } finally {
    await runtime.dispose();
  }
}

async function addMember(db, n, state = 'active') {
  const id = uid(n);
  const number = 'SYNTH' + String(n+10).padStart(5,'0');
  await db.batch([
    query(db,'INSERT INTO member_numbers VALUES (?,?)',number,now),
    query(db,`INSERT INTO members(id,member_no,auth_uid,state,joined_at,updated_at)
      VALUES (?,?,?,?,?,?)`,id,number,'uid-demo-'+n,state,now,now),
  ]);
  return {id,sessionId:uid(100+n),role:'member'};
}

function addPost(db,id,author,at,state='approved',publishAt=at) {
  return query(db,`INSERT INTO posts(id,author_id,body,state,created_at,updated_at,publish_at)
    VALUES (?,?,'Synthetic',?,?,?,?)`,id,author,state,at,at,publishAt).run();
}

async function session(db,actor,n) {
  const key = await digest('fixture-'+n);
  await query(db,'INSERT INTO member_sessions(id,member_id,session_hash,created_at,expires_at,revoked_at,last_seen) VALUES (?,?,?,?,?,NULL,?)',
    actor.sessionId,actor.id,key,now,now+100_000,now).run();
  return {firebaseUid:'uid-demo-'+n,sessionDigest:key};
}

test('blank installation, ordered idempotent snapshots and checksum drift on real D1', () =>
  withRuntime(async ({DB}) => {
    const all = await migrations();
    assert.equal(await migrate(DB),11);
    const before = await query(DB,'SELECT checksum,applied_at FROM schema_migrations ORDER BY version').all();
    assert.equal(await migrate(DB),11);
    assert.deepEqual((await query(DB,'SELECT checksum,applied_at FROM schema_migrations ORDER BY version').all()).results,before.results);
    await assert.rejects(migrate(DB,[all[1],all[0]]),/sequence/);
    await assert.rejects(migrate(DB,[{...all[0],checksum:'0'.repeat(64)},...all.slice(1)]),/diverged/);
  },false));

test('upgrade preserves data; partial SQL and ledger roll back before retry', () =>
  withRuntime(async ({DB}) => {
    const all = await migrations();
    await migrate(DB,all.slice(0,1));
    await seed(DB);
    const before = await query(DB,'SELECT * FROM members WHERE id=?',demoMember).first();
    const failed = {...all[1],statements:[...all[1].statements,'INSERT INTO missing_table VALUES (5)']};
    await assert.rejects(migrate(DB,[all[0],failed]));
    assert.equal((await query(DB,'SELECT max(version) AS current FROM schema_migrations').first()).current,1);
    assert.equal(await query(DB,"SELECT name FROM sqlite_schema WHERE name='posts'").first(),null);
    await Promise.all([migrate(DB),migrate(DB)]);
    assert.deepEqual(await query(DB,'SELECT * FROM members WHERE id=?',demoMember).first(),before);
  },false));

test('member ledger, foreign keys, unavailable comment parents, duplicate reactions and badge grants', () =>
  withRuntime(async ({DB}) => {
    const p = uuid();
    await addPost(DB,p,demoMember,now);
    await assert.rejects(query(DB,`INSERT INTO members(id,member_no,state,joined_at,updated_at)
      VALUES (?,'SYNTH0001','active',0,0)`,uuid()).run());
    await assert.rejects(query(DB,"DELETE FROM member_numbers WHERE number='SYNTH0001'").run());
    await assert.rejects(addPost(DB,uuid(),uuid(),now));
    await assert.rejects(query(DB,`INSERT INTO comments(id,post_id,parent_id,author_id,body,state,created_at,updated_at)
      VALUES (?,?,?,?,'x','approved',?,?)`,uuid(),p,uuid(),demoMember,now,now).run());
    const like = () => query(DB,'INSERT INTO reactions VALUES (?,?,NULL,?)',demoMember,p,now).run();
    await like();
    await assert.rejects(like());
    const badge = uuid();
    await query(DB,"INSERT INTO badge_catalog VALUES (?,'Synthetic','approved')",badge).run();
    await assert.rejects(query(DB,'INSERT INTO applied_badges VALUES (?,?)',demoMember,badge).run());
    const award = () => query(DB,'INSERT INTO badge_awards VALUES (?,?,?)',demoMember,badge,now).run();
    await award();
    await assert.rejects(award());
    await query(DB,'INSERT INTO applied_badges VALUES (?,?)',demoMember,badge).run();
    await assert.rejects(query(DB,"UPDATE members SET state='deleted' WHERE id=?",demoMember).run());
  }));

test('indexed deterministic cursor pages exclude hidden, future and two-way blocked content', () =>
  withRuntime(async ({DB}) => {
    const viewer = await addMember(DB,1);
    const blocked = await addMember(DB,2);
    await query(DB,'INSERT INTO blocks VALUES (?,?,?)',blocked.id,viewer.id,now).run();
    for (let i=0;i<13;i++) await addPost(DB,uid(300+i),demoMember,now-1);
    await addPost(DB,uid(400),demoMember,now-2,'deleted');
    await addPost(DB,uid(401),blocked.id,now-3);
    await addPost(DB,uid(402),demoMember,now-3,'approved',now+5);
    const key = await cursorKey(globalThis.crypto.getRandomValues(new Uint8Array(32)));
    const first = await readFeed(DB,key,viewer.id,now,5);
    assert.equal(first.page.items[0].id,uid(312));
    assert.equal(first.page.items.length,5);
    assert.ok(first.meta.rows_read>0);
    await addPost(DB,uid(800),demoMember,now+1);
    const second = await readFeed(DB,key,viewer.id,now+3,5,first.page.nextCursor);
    const third = await readFeed(DB,key,viewer.id,now+4,5,second.page.nextCursor);
    assert.equal(third.page.nextCursor,null);
    assert.deepEqual([...first.page.items,...second.page.items,...third.page.items].map(item=>item.id),
      Array.from({length:13},(_,i)=>uid(312-i)));
    await assert.rejects(readFeed(DB,key,viewer.id,now,5,'x'+first.page.nextCursor),pause(400,'invalid_request'));
    await assert.rejects(readFeed(DB,key,blocked.id,now,5,first.page.nextCursor),pause(400,'invalid_request'));
    await assert.rejects(readFeed(DB,key,viewer.id,now+900_000,5,first.page.nextCursor),pause(400,'invalid_request'));
    const plans = await DB.batch([
      query(DB,"EXPLAIN QUERY PLAN SELECT id FROM posts WHERE state='approved' ORDER BY created_at DESC,id DESC LIMIT 21"),
      query(DB,"EXPLAIN QUERY PLAN SELECT id FROM posts WHERE author_id=? AND state='approved' ORDER BY created_at DESC,id DESC LIMIT 21",demoMember),
      query(DB,"EXPLAIN QUERY PLAN SELECT id FROM content_items WHERE kind='radio' AND state='approved' AND visibility='members' AND publish_at<=? ORDER BY publish_at DESC,id DESC LIMIT 21",now),
      query(DB,'EXPLAIN QUERY PLAN SELECT id FROM comments WHERE post_id=? AND parent_id IS NULL ORDER BY created_at,id LIMIT 21',uid(300)),
      query(DB,'EXPLAIN QUERY PLAN SELECT id FROM notifications WHERE recipient_id=? AND read_at IS NULL ORDER BY created_at DESC,id DESC LIMIT 21',viewer.id),
      query(DB,"EXPLAIN QUERY PLAN SELECT id FROM scheduled_jobs WHERE state='ready' AND run_at<=? ORDER BY run_at,id LIMIT 5",now),
    ]);
    for (const [i,index] of ['posts_feed','posts_author','content_kind_due','comments_thread','inbox_unread','jobs_due'].entries()) {
      assert.match(plans[i].results.map(record=>record.detail).join(' '),new RegExp(index));
    }
    assert.equal(pageSize(null),20);
    assert.equal(pageSize('50'),50);
    assert.throws(()=>pageSize('51'),pause(400,'invalid_request'));
  }));

test('approved schedule becomes visible from its timestamp without Cron', () =>
  withRuntime(async ({DB}) => {
    const id=uuid();
    await query(DB,`INSERT INTO content_items(id,publisher_id,kind,title,state,visibility,publish_at,created_at,updated_at)
      VALUES (?,?,'radio','Synthetic','approved','members',?,?,?)`,id,demoMember,now+1,now,now).run();
    assert.equal(await visibleContent(DB,id,now),null);
    assert.equal((await visibleContent(DB,id,now+1)).id,id);
    await query(DB,"UPDATE content_items SET state='deleted' WHERE id=?",id).run();
    assert.equal(await visibleContent(DB,id,now+1),null);
  }));

test('server binding check and default Worker deny test credentials in every environment', () =>
  withRuntime(async env => {
    assert.throws(()=>localEnvironment('production'),/disabled/);
    assert.throws(()=>localEnvironment('staging'),/disabled/);
    assert.throws(()=>checkEnvironment({...env,QUARANTINE:undefined}),/binding/);
    const fixture = request('/v1/me/session',{headers:{Authorization:'Bearer synthetic-fixture','X-Role':'administrator'}});
    assert.equal((await worker.fetch(fixture,env)).status,401);
    assert.equal((await worker.fetch(fixture,{...env,APP_ENV:'production'})).status,503);
    assert.equal((await worker.fetch(request('/v1/ready'),env)).status,200);
    assert.equal((await worker.fetch(request('/v1/ready'),{...env,DB:undefined})).status,503);
    const local = createApi({verify:()=>{throw new Error('must never be called');},log:()=>{}});
    assert.equal((await local(fixture,{...env,APP_ENV:'local'})).status,401);
  }));

test('roles come from D1, revoked roles and inactive accounts lose access; ID input is bound', () =>
  withRuntime(async ({DB}) => {
    const artist = await addMember(DB,1);
    const admin = await addMember(DB,2);
    const reviewer = await addMember(DB,3);
    const adminAuth = await session(DB,admin,2);
    const artistAuth = await session(DB,artist,1);
    const token = 'Bearer local-fixture';
    const artistGrant = uuid();
    await DB.batch([
      query(DB,"INSERT INTO role_grants VALUES (?,?,'artist',?,?,?,NULL,NULL)",artistGrant,artist.id,admin.id,reviewer.id,now),
      query(DB,"INSERT INTO role_grants VALUES (?,?,'administrator',?,?,?,NULL,NULL)",uuid(),admin.id,artist.id,reviewer.id,now),
    ]);
    assert.equal((await authenticate(DB,token,async()=>artistAuth,now)).role,'artist');
    const currentAdmin = await authenticate(DB,token,async()=>adminAuth,now);
    assert.throws(()=>requireRole(currentAdmin,'artist'),pause(403,'access_denied'));
    assert.throws(()=>requireOwner(currentAdmin,artist.id),pause(404,'not_found'));
    await query(DB,'UPDATE role_grants SET revoked_at=? WHERE id=?',now+1,artistGrant).run();
    assert.equal((await authenticate(DB,token,async()=>artistAuth,now+2)).role,'member');
    for (const state of ['unverified','terms_required','suspended','inactive','deleting']) {
      await query(DB,'UPDATE members SET state=?,revoked_before=? WHERE id=?',state,state==='deleting'?now:0,artist.id).run();
      await assert.rejects(authenticate(DB,token,async()=>artistAuth,now+2),pause(403,'access_denied'));
    }
    await assert.rejects(authenticate(DB,token,async()=>({...adminAuth,firebaseUid:"fixture' OR 1=1 --"}),now),pause(401,'authentication_required'));
    await query(DB,'UPDATE member_sessions SET revoked_at=? WHERE id=?',now,admin.sessionId).run();
    await assert.rejects(authenticate(DB,token,async()=>adminAuth,now),pause(401,'authentication_required'));
  }));

test('structured logs and HTTP errors exclude headers, raw inputs and exception details', () =>
  withRuntime(async env => {
    const actor=await addMember(env.DB,1);
    const credentials=await session(env.DB,actor,1);
    const entries=[];
    const api=createApi({verify:async t => t==='synthetic-fixture'?credentials:null,clock:()=>now,log:event=>entries.push(event)});
    const good=await api(request('/v1/me/session',{headers:{
      authorization:'Bearer synthetic-fixture','x-request-id':'sensitive-input','x-role':'administrator',
    }}),env);
    assert.equal(good.status,200);
    assert.deepEqual(await good.json(),{role:'member'});
    assert.match(good.headers.get('x-request-id'),/^[a-f0-9-]{36}$/);
    const url=await api(request('/v1/health?next=https://example.invalid&next=x'),env);
    assert.equal(url.status,400);
    const unsafe=await api(request('/v1/%2fhealth'),env);
    assert.equal(unsafe.status,400);
    const failure=createApi({verify:async()=>{throw new Error('sensitive database diagnosis');},log:event=>entries.push(event)});
    const err=await failure(request('/v1/me/session',{headers:{authorization:'Bearer synthetic-fixture'}}),env);
    assert.equal(err.status,503);
    assert.deepEqual(await err.json(),{error:{code:'unavailable'}});
    assert.doesNotMatch(JSON.stringify(entries),/synthetic-fixture|sensitive-|example\.invalid|uid-demo|SELECT|administrator/);
    assert.ok(entries.every(event=>event.durationMs>=0&&event.d1.reads>=0));
    assert.ok(entries[0].d1.reads>0);
  }));

test('JSON decoder enforces encoding, media type, shape and actual streamed bytes',async()=>{
  const post=(text,headers={'content-type':'application/json'})=>request('/v1/fixture',{method:'POST',headers,body:text});
  assert.deepEqual(await readJson(post('{"count":2}')),{count:2});
  await assert.rejects(readJson(post('x',{'content-type':'text/plain'})),pause(415,'unsupported_media_type'));
  await assert.rejects(readJson(post('{}',{'content-type':'application/json','content-encoding':'gzip'})),pause(415,'unsupported_media_type'));
  await assert.rejects(readJson(post('[]')),pause(400,'invalid_request'));
  await assert.rejects(readJson(post('{')),pause(400,'invalid_request'));
  await assert.rejects(readJson(post('{"value":"１２３４５６"}'),12),pause(413,'payload_too_large'));
  await assert.rejects(readJson(post('{}',{'content-type':'application/json','content-length':'40000'})),
    pause(413,'payload_too_large'));
});

test('cost stages preserve essential headroom and feature flags reject stale edits',()=>
  withRuntime(async ({DB})=>{
    const gate=new Budget(DB,costConfiguration({limits:{requests:100}}));
    assert.equal((await gate.admit('standard',{requests:69},now)).tier,'normal');
    assert.equal((await gate.admit('standard',{requests:1},now)).tier,'warning');
    assert.equal((await gate.admit('bulk',{requests:10},now)).allowed,false);
    assert.equal((await gate.admit('optional-write',{requests:10},now)).tier,'reduced');
    assert.equal((await gate.admit('optional-write',{requests:10},now)).allowed,false);
    assert.equal((await gate.admit('standard',{requests:10},now)).tier,'blocked');
    assert.equal((await gate.admit('standard',{requests:5},now)).allowed,false);
    assert.equal((await gate.admit('essential',{requests:5},now)).tier,'emergency');
    assert.equal(await gate.setFlag('maintenance_mode',true,1,now),true);
    assert.equal(await gate.setFlag('maintenance_mode',false,1,now),false);
    assert.equal((await gate.admit('standard',{},now)).allowed,false);
    assert.equal((await gate.admit('essential',{requests:2},now)).allowed,true);
    assert.equal((await gate.admit('essential',{requests:1},now)).allowed,false);
    for (const feature of ['registration_enabled','posting_enabled','comments_enabled','image_upload_enabled',
      'audio_upload_enabled','media_grants_enabled','downloads_enabled','search_enabled','notifications_enabled','scheduled_jobs_enabled']) {
      assert.equal(await gate.setFlag(feature,false,1,now),true);
      assert.equal((await gate.admit('essential',{},now,[feature])).allowed,false);
    }
    const row=await query(DB,"SELECT counters FROM usage_windows WHERE name='service'").first();
    assert.equal(JSON.parse(row.counters).requests,97);
    assert.ok(JSON.parse(row.counters).d1Writes>0);
  }));

test('UTC day/month boundaries and concurrent budget projections use shared D1',()=>
  withRuntime(async ({DB})=>{
    const x=Date.UTC(2026,10,30,23,59);
    const gate=new Budget(DB,costConfiguration({limits:{requests:20,r2B:100}}));
    const outcomes=await Promise.all(Array.from({length:30},()=>new Budget(DB,
      costConfiguration({limits:{requests:20,r2B:100}})).admit('standard',{requests:1,r2B:1},x)));
    assert.equal(outcomes.filter(result=>result.allowed).length,18);
    const tomorrow=x+60_000;
    assert.deepEqual(utcWindows(tomorrow),{day:'2026-12-01',month:'2026-12'});
    assert.equal((await gate.admit('standard',{requests:1,r2B:4},tomorrow)).allowed,true);
    assert.equal((await gate.admit('standard',{requests:1},x)).allowed,false);
    const row=await query(DB,'SELECT counters FROM usage_windows').first();
    assert.equal(JSON.parse(row.counters).requests,1);
    assert.equal(JSON.parse(row.counters).r2B,4);
  }));

test('direct grants fail closed with unavailable, incomplete or stale provider measurements',()=>
  withRuntime(async ({DB})=>{
    const gate=new Budget(DB,costConfiguration({snapshotTtl:1000,limits:{r2B:100}}));
    await gate.setFlag('direct_media_enabled',true,1,now);
    assert.equal((await gate.admit('direct',{r2B:1},now)).allowed,false);
    await assert.rejects(gate.compareSnapshot({r2B:4},now,now),/Incomplete/);
    await gate.compareSnapshot({r2A:0,r2B:85,r2StoredBytes:5},now,now);
    assert.equal((await gate.admit('direct',{r2B:4},now+1)).allowed,true);
    assert.equal((await gate.admit('direct',{r2B:1},now+2)).allowed,false);
    assert.equal((await gate.admit('direct',{},now+1000)).allowed,false);
    assert.equal((await gate.compareSnapshot({r2A:0,r2B:0,r2StoredBytes:0},now-10,now)).meta.changes,0);
  }));

test('shared rate checks are atomic and untrusted forwarded addresses do not reset throttling',()=>
  withRuntime(async env=>{
    const scopes=[{kind:'user',key:uid(1),limit:3},{kind:'operation',key:'probe',limit:5}];
    const results=await Promise.all(Array.from({length:20},()=>allowRate(env.DB,scopes,now)));
    assert.equal(results.filter(result=>result.allowed).length,3);
    assert.equal((await allowRate(env.DB,scopes,now+60_000)).allowed,true);
    const api=createApi({burst:new EdgeBurst(2),clock:()=>now,log:()=>{}});
    for (let i=0;i<3;i++) {
      const r=await api(request('/v1/me/session',{headers:{
        'X-Forwarded-For':'example-'+i,'CF-Connecting-IP':'example-'+i,Authorization:'Bearer invalid',
      }}),env);
      assert.equal(r.status,i<2?401:429);
      if (i===2) assert.equal(r.headers.get('Retry-After'),'1');
    }
  }));

test('concurrent members cannot reserve beyond capacity; changed idempotent input conflicts',()=>
  withRuntime(async env=>{
    const people=await Promise.all(Array.from({length:8},(_,i)=>addMember(env.DB,i+1)));
    const store=new MediaStore(env,()=>now,{global:20,member:20,pending:1});
    const results=await Promise.allSettled(people.map((member,i)=>
      new MediaStore(env,()=>now,{global:20,member:20,pending:1}).reserve(member,'reserve-key-'+i,10,'image/png')));
    const winners=results.flatMap((result,i)=>result.status==='fulfilled'?[{row:result.value,index:i}]:[]);
    assert.equal(winners.length,1);
    const winner=winners[0];
    const owner=people[winner.index];
    assert.equal((await store.reserve(owner,'reserve-key-'+winner.index,10,'image/png')).id,winner.row.id);
    await assert.rejects(store.reserve(owner,'reserve-key-'+winner.index,9,'image/png'),pause(409,'conflict'));
    await assert.rejects(store.reserve(owner,'other-nonce',10,'audio/mp4'),pause(403,'access_denied'));
    assert.equal((await query(env.DB,'SELECT held_bytes FROM media_capacity').first()).held_bytes,20);
    await store.cancel(owner,winner.row.id);
    assert.equal((await query(env.DB,'SELECT held_bytes FROM media_capacity').first()).held_bytes,0);
    await store.reserve(people[0],'after-cancellation',10,'image/png');
  }));

test('local R2 keeps quarantine private, verifies metadata, range and owner, binds only approved attachments',()=>
  withRuntime(async env=>{
    const owner=await addMember(env.DB,1);
    const other=await addMember(env.DB,2);
    const store=new MediaStore(env,()=>now);
    const gate=new Budget(env.DB);
    const access=new MediaAccess(env,store,gate,()=>now);
    const r=await store.reserve(owner,'image-nonce',10,'image/png');
    const goodPost=uuid(), badPost=uuid(), deletedPost=uuid();
    await addPost(env.DB,goodPost,owner.id,now);
    await addPost(env.DB,badPost,other.id,now);
    await addPost(env.DB,deletedPost,owner.id,now,'deleted');
    await assert.rejects(store.quarantine(owner,r.id,body('too much data')),pause(413,'payload_too_large'));
    await store.quarantine(owner,r.id,body('01234567'));
    await assert.rejects(store.quarantine(owner,r.id,body('abcdefgh')),pause(409,'conflict'));
    await assert.rejects(store.approved(owner,r.id),pause(404,'not_found'));
    await assert.rejects(store.attachToPost(owner,r.id,goodPost,0),pause(404,'not_found'));
    await assert.rejects(store.approve(owner,r.id,async()=>false),pause(403,'access_denied'));
    assert.equal(await env.PRIVATE_MEDIA.head('objects/'+r.id),null);
    await store.approve(owner,r.id,async()=>true);
    assert.equal(await env.QUARANTINE.head('objects/'+r.id),null);
    assert.equal((await store.approved(owner,r.id)).sha256,await digest(body('01234567')));
    await assert.rejects(store.approved(other,r.id),pause(404,'not_found'));
    await assert.rejects(store.attachToPost(owner,r.id,badPost,0),pause(404,'not_found'));
    await assert.rejects(store.attachToPost(owner,r.id,deletedPost,0),pause(404,'not_found'));
    await store.attachToPost(owner,r.id,goodPost,0);
    await store.attachToPost(owner,r.id,goodPost,0);
    const result=await access.relay(owner,r.id,'bytes=2-5');
    assert.equal(await response(result.body).text(),'2345');
    assert.equal(result.total,8);
    await assert.rejects(access.relay(owner,r.id,'bytes=0-1,4-7'),pause(416,'invalid_request'));
    await assert.rejects(access.direct(owner,r.id),pause(503,'unavailable'));
    await gate.setFlag('direct_media_enabled',true,1,now);
    await gate.compareSnapshot({r2A:0,r2B:0,r2StoredBytes:0},now,now);
    const signed=await access.direct(owner,r.id,{issue:async input=>{
      assert.equal(input.expiresIn,300);
      assert.equal(input.key,'objects/'+r.id);
      return 'https://example.invalid/local-test';
    }});
    assert.equal(signed.expiresIn,300);
  }));

test('repair after a failed R2 delete retains reservations until retry, and orphan scan uses a grace period',()=>
  withRuntime(async env=>{
    let clock=Date.now();
    const good=new MediaStore(env,()=>clock);
    const owner=await addMember(env.DB,1);
    const fitting=await good.reserve(owner,'hold-to-expire',12,'image/png');
    await good.quarantine(owner,fitting.id,body('atom'));
    await assert.rejects(query(env.DB,"UPDATE media_reservations SET state='attached' WHERE id=?",fitting.id).run());
    clock+=900_000;
    const fault=new MediaStore({...env,QUARANTINE:{ delete:async()=>{throw new Error('synthetic unavailable');} }},()=>clock);
    await assert.rejects(fault.expire(),/synthetic unavailable/);
    assert.equal((await query(env.DB,'SELECT held_bytes FROM media_capacity').first()).held_bytes,24);
    assert.equal(await good.expire(),1);
    assert.equal((await query(env.DB,'SELECT held_bytes FROM media_capacity').first()).held_bytes,0);
    assert.equal(await env.QUARANTINE.head('objects/'+fitting.id),null);
    const orphan='objects/'+uuid();
    await env.PRIVATE_MEDIA.put(orphan,body('orphan'));
    clock+=900_000;
    assert.equal((await good.reconcile('private')).removed,1);
    assert.equal(await env.PRIVATE_MEDIA.head(orphan),null);
  }));

test('atomic idempotency/outbox, duplicate replay, conflict and transaction rollback',()=>
  withRuntime(async ({DB})=>{
    const command=input=>idempotent(DB,demoMember,'post.fixture','test-nonce',input,now,()=>{
      const id=uuid();
      return {result:{id},statements:[
        query(DB,`INSERT INTO posts(id,author_id,body,state,created_at,updated_at,publish_at)
          VALUES (?,?,'Synthetic','draft',?,?,?)`,id,demoMember,now,now,now),
        ...eventStatements(DB,id,'post.fixture',{id},now),
      ]};
    });
    const copies=await Promise.all(Array.from({length:5},()=>command({a:1,b:2})));
    assert.ok(copies.every(row=>row.id===copies[0].id));
    assert.deepEqual(await command({b:2,a:1}),copies[0]);
    await assert.rejects(command({b:3}),pause(409,'conflict'));
    assert.equal((await query(DB,'SELECT count(*) AS n FROM posts').first()).n,1);
    assert.equal((await query(DB,'SELECT count(*) AS n FROM outbox').first()).n,1);
    await assert.rejects(idempotent(DB,demoMember,'post.fixture','broken-key',null,now,()=>({
      result:{},statements:[query(DB,'INSERT INTO fictional VALUES (1)')],
    })));
    assert.equal(await query(DB,"SELECT 1 FROM idempotency_keys WHERE request_key='broken-key'").first(),null);
    const deliveries=[];
    const handler=outboxHandler(DB,async event=>{deliveries.push(event.id);},()=>now+1);
    assert.equal(await runJobs(DB,{deliver_outbox:handler},()=>now+1),1);
    assert.equal(await runJobs(DB,{deliver_outbox:handler},()=>now+2),0);
    const row=await query(DB,'SELECT id,job_id FROM outbox').first();
    await handler({eventId:row.id},row.job_id);
    assert.deepEqual(deliveries,[row.id]);
  }));

test('due jobs lease once across instances, fence old leases and retry with exponential backoff',()=>
  withRuntime(async ({DB})=>{
    await enqueue(DB,'reconcile_usage','lease-1',{},now,{maxAttempts:3}).run();
    await enqueue(DB,'reconcile_usage','lease-1',{},now).run();
    const runs=await Promise.all([claim(DB,now),claim(DB,now)]);
    const first=runs.flat()[0];
    assert.equal(runs.flat().length,1);
    assert.equal(await finish(DB,first,now+60_000,true),false);
    const [second]=await claim(DB,now+60_000);
    assert.doesNotMatch(second.lease_token,new RegExp(first.lease_token));
    assert.equal(await finish(DB,first,now+60_001,true),false);
    assert.equal(await finish(DB,second,now+60_001,false,()=>0.5),true);
    assert.equal((await claim(DB,now+62_500)).length,0);
    const [third]=await claim(DB,now+62_501);
    assert.equal(third.attempts,3);
    assert.equal(await finish(DB,third,now+62_502,false),true);
    assert.equal((await query(DB,"SELECT state FROM scheduled_jobs WHERE dedupe_key='lease-1'").first()).state,'dead');
  }));

test('encrypted backup restores a separate database, validates data and reapplies later deletion',()=>
  withRuntime(async ({DB})=>{
    const post=uuid(), independent=uuid();
    await addPost(DB,post,demoMember,now);
    await addPost(DB,independent,demoMember,now);
    const key=await backupKey(globalThis.crypto.getRandomValues(new Uint8Array(32)));
    const sealed=await backup(DB,key,now);
    assert.doesNotMatch(JSON.stringify(sealed),/SYNTH0001|Synthetic/);
    const original=await captureRows(DB);
    await withRuntime(async ({DB:target})=>{
      const corrupt={...sealed,checksum:'0'.repeat(64)};
      await assert.rejects(restore(target,corrupt,key,{through:now,entries:[]}));
      await assert.rejects(restore(target,sealed,key,{through:now-1,entries:[]}),/journal/);
      await restore(target,sealed,key,{through:now,entries:[]});
      const restored = await captureRows(target);
      assert.deepEqual(restored.tables,original.tables);
      assert.deepEqual(schemaIdentity(restored.schema),schemaIdentity(original.schema));
      assert.equal(await migrate(target),11);
      await assert.rejects(restore(target,sealed,key,{through:now,entries:[]}),/empty/);
    },false);
    await withRuntime(async ({DB:target})=>{
      await restore(target,sealed,key,{through:now+10,entries:[{memberId:demoMember,at:now+5},{kind:'post',id:independent,at:now+6}]});
      assert.equal((await query(target,'SELECT state FROM members WHERE id=?',demoMember).first()).state,'deleting');
      assert.equal((await query(target,'SELECT state FROM posts WHERE id=?',post).first()).state,'hidden');
      assert.equal((await query(target,'SELECT state FROM posts WHERE id=?',independent).first()).state,'deleted');
      assert.equal((await query(target,'SELECT state FROM deletion_requests WHERE member_id=?',demoMember).first()).state,'requested');
    },false);
  }));

test('R2 quarantine survives a D1 commit failure and the same bytes can resume',()=>
  withRuntime(async env=>{
    const owner=await addMember(env.DB,1);
    const store=new MediaStore(env,()=>now);
    const r=await store.reserve(owner,'db-recovery-test',12,'image/png');
    const broken=new MediaStore({...env,DB:{
      prepare:env.DB.prepare.bind(env.DB),
      batch:async()=>{throw new Error('synthetic commit failure');},
    }},()=>now);
    await assert.rejects(broken.quarantine(owner,r.id,body('retriable')),/synthetic commit failure/);
    assert.equal((await env.QUARANTINE.head('objects/'+r.id)).size,9);
    assert.equal(await env.PRIVATE_MEDIA.head('objects/'+r.id),null);
    await assert.rejects(store.approved(owner,r.id),pause(404,'not_found'));
    await store.quarantine(owner,r.id,body('retriable'));
    await store.approve(owner,r.id,async()=>true);
    assert.equal((await store.approved(owner,r.id)).actual_bytes,9);
    assert.equal((await query(env.DB,'SELECT pending FROM media_owner_capacity WHERE owner_id=?',owner.id).first()).pending,0);
  }));

test('local scheduled entrypoint runs expiry and leaves unconfigured application jobs queued',()=>
  withRuntime(async env=>{
    const time=Date.now();
    const actor=await addMember(env.DB,1);
    const store=new MediaStore(env,()=>time-900_001);
    const held=await store.reserve(actor,'cron-fixture',12,'image/png');
    await enqueue(env.DB,'publish_notice','future-adapter',{},time-10).run();
    await worker.scheduled({scheduledTime:time},env);
    assert.equal((await query(env.DB,'SELECT state FROM media_reservations WHERE id=?',held.id).first()).state,'expired');
    assert.equal((await query(env.DB,"SELECT state FROM scheduled_jobs WHERE dedupe_key='future-adapter'").first()).state,'ready');
    await worker.scheduled({scheduledTime:time},env);
    assert.equal((await query(env.DB,"SELECT count(*) AS n FROM scheduled_jobs WHERE kind='expire_uploads'").first()).n,1);
  }));

test('every supplied cost dimension can independently protect the essential ceiling',()=>
  withRuntime(async ({DB})=>{
    for (const name of ['requests','d1Reads','d1Writes','d1IndexWrites','d1DatabaseBytes',
      'd1AccountBytes','r2A','r2B','r2StoredBytes','reservedBytes','signatures','jobRuns','notificationWork','backupWork']) {
      await query(DB,"UPDATE usage_windows SET counters='{}'").run();
      await query(DB,'UPDATE media_capacity SET held_bytes=?',name==='reservedBytes'?98:0).run();
      const budget=new Budget(DB,costConfiguration({limits:{[name]:100}}));
      const requested=await budget.admit('essential',name==='reservedBytes'?{}:{[name]:98},now);
      assert.equal(requested.allowed,false,name);
    }
    await query(DB,'UPDATE media_capacity SET held_bytes=0').run();
  }));
