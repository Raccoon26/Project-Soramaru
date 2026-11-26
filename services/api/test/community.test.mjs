import assert from 'node:assert/strict';
import test from 'node:test';
import { migrate,migrations,simulator } from '../../../tools/local-backend.mjs';
import { CommunityStore } from '../src/community-store.ts';
import { MembershipStore } from '../src/membership-store.ts';
import { createApi } from '../src/index.ts';
import { policyDocuments,policyVersion } from '../src/membership-policy.ts';
import { query } from '../src/platform.ts';

const crypto=globalThis.crypto;
const uuid=()=>crypto.randomUUID();
const requestKey=()=>uuid().replaceAll('-','');
const time=1_795_578_000_000;
const error=(status,code)=>e=>e.status===status&&e.code===code;

async function check(action,version=9) {
  const machine=simulator();
  try {
    const DB=await machine.getD1Database('DB');
    const path=await migrations();
    await migrate(DB,path.slice(0,version));
    const env={DB,APP_ENV:'test',PRIVATE_MEDIA:await machine.getR2Bucket('PRIVATE_MEDIA'),QUARANTINE:await machine.getR2Bucket('QUARANTINE')};
    const key=await crypto.subtle.importKey('raw',crypto.getRandomValues(new Uint8Array(32)),{name:'HMAC',hash:'SHA-256'},false,['sign','verify']);
    const members=new MembershipStore(DB,time,key);
    async function make(label) {
      const identity={uid:'fixture-'+label,verifiedEmail:true,authAt:time-1000};
      const issued=await members.issue(identity,globalThis.Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('base64url'),'Fixture','other');
      const get=()=>members.context(identity,issued.sessionToken);
      await members.accept(await get(),{version:policyVersion,documents:policyDocuments.map(item=>item.kind)});
      if(version>=8) await members.edit(await get(),{nickname:label},1);
      return {identity,issued,ctx:await get(),get};
    }
    await action({DB,env,key,make,path});
  } finally {await machine.dispose();}
}

const sentence=(body,tags=[],quoteId)=>({body,tags,...(quoteId?{quoteId}:{})});
const params=values=>new globalThis.URLSearchParams(values);

test('v6 migration preserves post, quote, comments, tag relation, reactions and media references',()=>check(async({DB,make,path})=>{
  const user=await make('空');
  const id=uuid(),other=uuid(),tag=uuid(),comment=uuid();
  const member=user.ctx.member.id,media=uuid();
  await DB.batch([
    query(DB,"INSERT INTO posts(id,author_id,body,state,created_at,updated_at,publish_at) VALUES (?,?,'以前の投稿','approved',0,0,0)",id,member),
    query(DB,"INSERT INTO posts(id,author_id,body,state,created_at,updated_at,publish_at,quote_post_id) VALUES (?,?,'引用','approved',0,0,0,?)",other,member,id),
    query(DB,"INSERT INTO comments(id,post_id,author_id,body,state,created_at,updated_at) VALUES (?,?,?,'合成','approved',0,0)",comment,id,member),
    query(DB,"INSERT INTO reactions VALUES (?,?,NULL,0)",member,id),
    query(DB,"INSERT INTO tags VALUES (?,'朝','朝')",tag),
    query(DB,'INSERT INTO post_tags VALUES (?,?)',id,tag),
    query(DB,"INSERT INTO media_reservations VALUES (?,?,'fixture-media',45,'image/png','reserved',0,30000,0)",media,member),
    query(DB,"INSERT INTO media_objects(id,owner_id,object_key,actual_bytes,mime,sha256) VALUES (?,?,?,45,'image/png',?)",
      media,member,'objects/'+media,'a'.repeat(64)),
    query(DB,"UPDATE media_reservations SET state='quarantined' WHERE id=?",media),
    query(DB,"UPDATE media_reservations SET state='approved' WHERE id=?",media),
    query(DB,'INSERT INTO post_media VALUES (?,?,0)',id,media),
  ]);
  assert.equal(await migrate(DB,path.slice(0,7)),7);
  assert.equal((await query(DB,'SELECT body FROM posts WHERE id=?',id).first()).body,'以前の投稿');
  assert.equal((await query(DB,'SELECT quote_post_id FROM posts WHERE id=?',other).first()).quote_post_id,id);
  for(const table of ['comments','reactions','post_tags','post_media']) {
    assert.equal((await query(DB,'SELECT post_id FROM '+table).first()).post_id,id);
  }
  assert.equal((await query(DB,'PRAGMA foreign_key_check').all()).results.length,0);
},6));

test('actual D1 writes accept Unicode 16 boundaries and enforce normalized tags atomically',()=>check(async({DB,make})=>{
  const author=await make('空');
  const forum=new CommunityStore(DB,author.ctx,time);
  const long='か\u3099👨‍👩‍👧‍👦🇯🇵👍🏽한'.repeat(2000);
  const exact=await forum.save(null,sentence(long,['朝',' 한글 ','#ＦＯＯ','foo']),requestKey(),null);
  assert.equal(exact.body,long);
  assert.equal(exact.tags.length,3);
  const below=await forum.save(null,sentence('空'.repeat(9999)),requestKey(),null);
  assert.equal(below.body.length,9999);
  await assert.rejects(forum.save(null,sentence(long+'雪'),requestKey(),null),error(400,'invalid_post_length'));
  await assert.rejects(forum.save(null,sentence('空'+'\u3099'.repeat(64)),requestKey(),null),error(400,'invalid_post_length'));
  await assert.rejects(forum.save(null,sentence('試験',Array.from({length:11},(_,i)=>'朝'+i)),requestKey(),null),error(400,'invalid_request'));
  assert.equal((await forum.save(null,sentence('タグ試験',Array.from({length:10},(_,i)=>'朝'+i)),requestKey(),null)).tags.length,10);
  for (const value of ['<script>alert(1)</script>','javascript:alert(1)','x\u0000','contact@example.invalid']) {
    await assert.rejects(forum.save(null,sentence(value),requestKey(),null),error(400,'content_rejected'));
  }
  assert.equal((await forum.save(null,sentence("正常な日本語の文章・式 2 < 3 と '引用'"),requestKey(),null)).version,1);
}));

test('conditional write races roll back tags, deduplication and outbox; replay rechecks visibility',()=>check(async({DB,make})=>{
  const user=await make('鳥');
  const other=await make('星');
  const forum=new CommunityStore(DB,user.ctx,time), stranger=new CommunityStore(DB,other.ctx,time);
  const submitted=requestKey();
  const input=sentence('花の散歩',['花']);
  const attempts=await Promise.all([forum.save(null,input,submitted,null),forum.save(null,input,submitted,null)]);
  const id=attempts[0].id;
  assert.equal(attempts[1].id,id);
  await assert.rejects(stranger.save(id,sentence('異なる所有者'),requestKey(),1),error(409,'conflict'));
  const edits=await Promise.allSettled([
    forum.save(id,sentence('初回の変更',['第一']),requestKey(),1),
    forum.save(id,sentence('別端末の変更',['第二']),requestKey(),1),
  ]);
  assert.equal(edits.filter(x=>x.status==='fulfilled').length,1);
  assert.equal(edits.find(x=>x.status==='rejected').reason.status,409);
  assert.equal((await query(DB,"SELECT count(*) AS n FROM tags WHERE normalized IN ('第一','第二')").first()).n,1);
  const removeKey=requestKey();
  const final=await Promise.allSettled([forum.remove(id,removeKey,2),forum.save(id,sentence('競争する投稿'),requestKey(),2)]);
  assert.equal(final.filter(x=>x.status==='fulfilled').length,1);
  if(final[0].status==='fulfilled') {
    await forum.remove(id,removeKey,2);
    await assert.rejects(forum.save(null,input,submitted,null),error(404,'not_found'));
  }
  assert.equal((await query(DB,'SELECT count(*) AS n FROM outbox').first()).n,3);
  await query(DB,"DELETE FROM policy_acceptances WHERE member_id=? AND kind='guidelines'",user.ctx.member.id).run();
  await assert.rejects(forum.save(null,sentence('規約同意が更新された'),requestKey(),null),error(409,'conflict'));
  await query(DB,'INSERT INTO policy_acceptances VALUES (?,?,?,?)',user.ctx.member.id,'guidelines',policyVersion,time).run();
  await query(DB,'UPDATE member_sessions SET revoked_at=? WHERE id=?',time,user.ctx.session.id).run();
  await assert.rejects(forum.save(null,sentence('失効した端末'),requestKey(),null),error(409,'conflict'));
  await query(DB,"UPDATE members SET state='suspended' WHERE id=?",other.ctx.member.id).run();
  await assert.rejects(stranger.save(null,sentence('停止中'),requestKey(),null),error(409,'conflict'));
}));

test('real D1 cursors, policies, pinned roles and bidirectional visibility survive changes',()=>check(async({DB,key,make})=>{
  const one=await make('空'),two=await make('月'),artist=await make('鳥');
  const admin=await make('街');
  const a=new CommunityStore(DB,one.ctx,time), b=new CommunityStore(DB,two.ctx,time);
  const first=await a.save(null,sentence('朝の話',['朝']),requestKey(),null);
  const quote=await b.save(null,sentence('引用します',[],first.id),requestKey(),null);
  const artistId=artist.ctx.member.id,officialId=uuid(),postId=uuid();
  await DB.batch([
    query(DB,"INSERT INTO official_identities VALUES (?,?,'合成アーティスト',1)",officialId,artistId),
    query(DB,"INSERT INTO role_grants VALUES (?,?,'artist',?,?,0,NULL,NULL)",uuid(),artistId,one.ctx.member.id,admin.ctx.member.id),
    query(DB,"INSERT INTO posts(id,author_id,displayed_identity_id,body,state,created_at,updated_at,publish_at,pin_rank) VALUES (?,?,?,'合成の公式投稿','approved',?,?,?,5)",
      postId,artistId,officialId,time,time,time),
  ]);
  const firstPage=await a.list(params({limit:'1'}),key);
  assert.equal(firstPage.pinned[0].id,postId);
  assert.equal((await a.list(params({category:'artist'}),key)).items[0].id,postId);
  const next=firstPage.nextCursor;
  assert.ok(next);
  assert.equal((await a.list(params({limit:'1',cursor:next}),key)).items.length,1);
  await assert.rejects(b.list(params({cursor:next}),key),error(400,'invalid_request'));
  await assert.rejects(a.list(params({category:'official',cursor:next}),key),error(400,'invalid_request'));
  await assert.rejects(a.list(params({cursor:next+'x'}),key),error(400,'invalid_request'));
  const later=new CommunityStore(DB,one.ctx,time+900_000);
  await assert.rejects(later.list(params({cursor:next}),key),error(400,'invalid_request'));
  assert.equal((await a.list(params({tag:first.tags[0].id}),key)).items[0].id,first.id);
  await b.report({kind:'post',targetId:first.id,category:'spam'});
  await b.report({kind:'post',targetId:first.id,category:'spam'});
  assert.equal((await query(DB,'SELECT count(*) AS n FROM community_reports').first()).n,1);
  await b.block(one.ctx.member.id);
  assert.equal((await b.detail(quote.id)).quote,null);
  await assert.rejects(a.detail(quote.id),error(404,'not_found'));
  await assert.rejects(b.member(one.ctx.member.id),error(404,'not_found'));
  assert.ok(!(await a.list(params({cursor:next}),key)).items.some(row=>row.id===quote.id));
}));

test('community HTTP enforces posting policy and measures paged D1 with a large fixture',()=>check(async({DB,env,key,make})=>{
  const user=await make('光');
  const logs=[];
  const handler=createApi({clock:()=>time,log:e=>logs.push(e),membership:{verify:async token=>token==='fixture'?user.identity:null,key,sendCode:async()=>{}}});
  function send(path,method='GET',body) {
    return handler(new globalThis.Request('http://localhost'+path,{method,headers:{
      authorization:'Bearer fixture','x-app-session':user.issued.sessionToken,'idempotency-key':requestKey(),
      ...(body?{'content-type':'application/json'}:{}),
    },body:body?JSON.stringify(body):undefined}),env);
  }
  for(let at=0;at<2200;at+=100){
    await DB.batch(Array.from({length:100},(_,i)=>query(DB,
      "INSERT INTO posts(id,author_id,body,state,created_at,updated_at,publish_at) VALUES (?,?,'合成','approved',?,?,?)",
      uuid(),user.ctx.member.id,time-at-i,time-at-i,time-at-i)));
  }
  for(let i=0;i<12;i++) assert.equal((await send('/v1/posts')).status,200);
  assert.equal((await send('/v1/posts?limit=51')).status,400);
  const d1=logs.slice(0,12).reduce((a,row)=>({reads:a.reads+row.d1.reads,writes:a.writes+row.d1.writes}),{reads:0,writes:0});
  globalThis.console.log('Community 12 reads, local D1:',d1);
  const plan=await query(DB,"EXPLAIN QUERY PLAN SELECT id FROM posts WHERE state='approved' ORDER BY created_at DESC,id DESC LIMIT 20").all();
  assert.match(JSON.stringify(plan.results),/posts_feed/);
  const all=new Set();
  const forum=new CommunityStore(DB,user.ctx,time);
  let cursor=null;
  do {
    const page=await forum.list(params({limit:'50',...(cursor?{cursor}:{})}),key);
    for (const item of page.items) {
      assert.ok(!all.has(item.id),'duplicate cursor entry');
      all.add(item.id);
    }
    cursor=page.nextCursor;
  } while(cursor);
  assert.equal(all.size,2200);
  await query(DB,"UPDATE feature_flags SET enabled=0 WHERE name='posting_enabled'").run();
  assert.equal((await send('/v1/posts','POST',sentence('停止中の投稿'))).status,503);
  await query(DB,"UPDATE feature_flags SET enabled=1 WHERE name='posting_enabled'").run();
  const long=await send('/v1/posts','POST',sentence('か\u3099'.repeat(10000)));
  assert.equal(long.status,201);
  assert.equal((await long.json()).body,'か\u3099'.repeat(10000));
  assert.equal((await send('/v1/posts','POST',sentence('あ'.repeat(10001)))).status,400);
}));
