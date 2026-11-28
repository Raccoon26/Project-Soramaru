import assert from 'node:assert/strict';
import test from 'node:test';
import { migrate,migrations,simulator } from '../../../tools/local-backend.mjs';
import { createApi } from '../src/index.ts';
import { backup,backupKey,restore } from '../../../tools/local-backup.mjs';
import { seedPhotos,syntheticAlbum,syntheticJpeg } from '../../../tools/photo-fixtures.mjs';
import { CommunityStore } from '../src/community-store.ts';
import { Collections } from '../src/collections.ts';
import { Discovery,refreshPopular } from '../src/discovery.ts';
import { pruneDiscoveryData } from '../src/discovery-retention.ts';
import { eventStatements } from '../src/jobs.ts';
import { MembershipStore } from '../src/membership-store.ts';
import { policyDocuments,policyVersion } from '../src/membership-policy.ts';
import { cursorKey } from '../src/paging.ts';
import { digest,query } from '../src/platform.ts';
import { MediaStore } from '../src/media.ts';
import { inspectPhoto } from '../src/photo-format.ts';
import { backfillSearch,indexedText,normalizeSearch } from '../src/search-index.ts';

const clock=1_795_578_000_000;
const crypt=globalThis.crypto;
const id=()=>crypt.randomUUID();
const key=()=>globalThis.Buffer.from(crypt.getRandomValues(new Uint8Array(32))).toString('base64url');
const params=values=>new globalThis.URLSearchParams(values);
const day=86_400_000;

async function withDb(action) {
  const runtime=simulator();
  try {
    const db=await runtime.getD1Database('DB');
    const files=await migrations();
    await migrate(db,files.slice(0,9));
    const legacy=id();
    await db.batch([
      query(db,"INSERT INTO member_numbers VALUES ('LOCALOLD08',0)"),
      query(db,"INSERT INTO members(id,auth_uid,member_no,state,joined_at,updated_at) VALUES (?,NULL,'LOCALOLD08','active',0,0)",legacy),
      query(db,"INSERT INTO member_profiles(member_id,nickname,updated_at,configured_at) VALUES (?,'柊の記録',0,0)",legacy),
    ]);
    assert.equal(await migrate(db,files),11);
    assert.equal((await query(db,'PRAGMA foreign_key_check').all()).results.length,0);
    const signing=await cursorKey(crypt.getRandomValues(new Uint8Array(32)));
    const manager=new MembershipStore(db,clock,signing);
    async function enroll(nickname) {
      const identity={uid:'fixture-'+nickname,verifiedEmail:true,authAt:clock-1000};
      const issued=await manager.issue(identity,key(),'Fixture','other');
      const context=()=>manager.context(identity,issued.sessionToken);
      await manager.accept(await context(),{version:policyVersion,documents:policyDocuments.map(item=>item.kind)});
      await manager.edit(await context(),{nickname},1);
      const store=new CommunityStore(db,await context(),clock);
      return {context,identity,issued,actor:store.actor.member.id,store,search:new Discovery(store,signing),folders:new Collections(store,signing)};
    }
    await action({db,signing,manager,enroll,legacy,runtime});
  } finally {await runtime.dispose();}
}

test('v9 upgrade, Japanese normalization, bounded prefix and trigram with per-account cursors',()=>withDb(async({db,enroll,legacy,signing})=>{
  const member=await enroll('東京ノート');
  const viewer=await enroll('合成読者');
  const one=await member.store.save(null,{body:'今日は カタカナと花を見た',tags:['桜灯']},key(),null);
  const two=await member.store.save(null,{body:'次の日は カタカナ と空を見た',tags:['桜灯']},key(),null);
  const lookup=(who,q,other={})=>who.search.search(params({q,kind:'post',...other}));
  assert.equal(normalizeSearch(' ＣＡＦＥ　ｶﾞｸ  '),'cafe がく');
  assert.equal((await lookup(viewer,'今')).items[0].id,one.id);
  const page=await lookup(viewer,'ｶﾀｶﾅ',{limit:'1'});
  assert.equal(page.items[0].id,two.id);
  assert.ok(page.nextCursor);
  assert.deepEqual((await lookup(viewer,'かたかな',{limit:'1',cursor:page.nextCursor})).items.map(row=>row.id),[one.id]);
  await assert.rejects(lookup(member,'かたかな',{cursor:page.nextCursor}),{status:400});
  await assert.rejects(lookup(viewer,'見た',{cursor:page.nextCursor}),{status:400});
  await assert.rejects(lookup(viewer,'かたかな',{cursor:page.nextCursor+'x'}),{status:400});
  const expired=new Discovery(new CommunityStore(db,await viewer.context(),clock+900001),signing);
  await assert.rejects(expired.search(params({q:'かたかな',cursor:page.nextCursor})),{status:400});
  assert.deepEqual((await lookup(viewer,'「引用」')).items,[]);
  assert.equal((await viewer.search.search(params({q:'東京',kind:'member'}))).items[0].id,member.actor);
  assert.equal((await backfillSearch(db,'member',20)).complete,true);
  assert.equal((await viewer.search.search(params({q:'柊',kind:'member'}))).items[0].id,legacy);
  await member.store.save(one.id,{body:'変更後の文章',tags:['朝']},key(),1);
  assert.deepEqual((await lookup(viewer,'かたかな')).items.map(row=>row.id),[two.id]);
  assert.equal((await lookup(viewer,'更後の')).items[0].id,one.id);
  await member.store.block(viewer.actor);
  assert.equal((await lookup(viewer,'かたかな')).items.length,0);
  assert.equal((await viewer.search.search(params({q:'桜',kind:'tag'}))).items.length,0);
  const plan=await query(db,"EXPLAIN QUERY PLAN SELECT rowid FROM search_documents WHERE kind='member' AND prefix>=? AND prefix<? ORDER BY prefix,rowid LIMIT 160",'東','東\u{10ffff}').all();
  assert.ok(plan.results.some(row=>row.detail.includes('search_prefix')));
  const fts=await query(db,'EXPLAIN QUERY PLAN SELECT rowid FROM search_fts WHERE search_fts MATCH ? ORDER BY rowid DESC LIMIT 160','かたかな').all();
  assert.ok(fts.results.some(row=>row.detail.includes('VIRTUAL TABLE INDEX')));
}));

test('tag snapshot, three typed favorites and bilateral block removal share current source visibility',()=>withDb(async({db,enroll})=>{
  const author=await enroll('青ノート');
  const reader=await enroll('白ノート');
  const unrelated=await enroll('緑ノート');
  const post=await author.store.save(null,{body:'朝の散歩は快適',tags:['朝の散歩']},key(),null);
  const tag=post.tags[0].id;
  assert.equal((await reader.search.popular()).stale,true);
  await refreshPopular(db,clock);
  assert.deepEqual((await reader.search.popular()).items,[{id:tag,label:'朝の散歩',saved:false}]);
  await reader.search.favorite('tag',tag,'PUT');
  await reader.search.favorite('post',post.id,'PUT');
  await reader.search.favorite('member',author.actor,'PUT');
  assert.equal((await reader.search.popular()).items[0].saved,true);
  assert.equal((await reader.search.favorite('tag',tag,'GET')).saved,true);
  assert.equal((await reader.search.favoriteList('post',params({}))).items[0].id,post.id);
  assert.equal((await unrelated.search.favoriteList('post',params({}))).items.length,0);
  assert.equal((await query(db,'SELECT count(*) AS count FROM reactions').first()).count,0);
  await reader.store.block(author.actor);
  await author.store.block(reader.actor);
  await reader.search.unblock(author.actor);
  assert.equal((await reader.search.blocks(params({}))).items.length,0);
  assert.equal((await reader.search.popular()).items.length,0);
  assert.equal((await reader.search.favoriteList('tag',params({}))).items.length,0);
  await author.search.unblock(reader.actor);
  assert.equal((await reader.search.popular()).items.length,1);
  await author.store.remove(post.id,key(),1);
  assert.equal((await reader.search.favoriteList('post',params({}))).items.length,0);
  assert.equal((await reader.search.popular()).items.length,0);
}));

test('private folders, move, optimistic versions and no visibility expansion when publishing folders',()=>withDb(async({enroll,manager,db})=>{
  const owner=await enroll('私のノート');
  const reader=await enroll('隣のノート');
  const author=await enroll('春の雲');
  const a=id(),b=id();
  const create={id:a,title:'読み返すもの'};
  assert.equal((await owner.folders.create(create)).id,a);
  assert.equal((await owner.folders.create(create)).id,a);
  await owner.folders.create({id:b,title:'資料の整理'});
  assert.equal((await owner.folders.update(a,1,{title:'読み返し'})).version,2);
  await assert.rejects(owner.folders.update(a,1,{title:'競合'}),{status:409});
  const post=await author.store.save(null,{body:'はるの写真メモ',tags:[]},key(),null);
  const saved=await owner.folders.add(a,{postId:post.id});
  assert.equal((await owner.folders.add(a,{postId:post.id})).id,saved.id);
  await assert.rejects(reader.folders.items(a,params({})),{status:404});
  assert.equal((await owner.folders.modifyEntries(a,{ids:[saved.id],destination:b})).moved,1);
  await manager.edit(await owner.context(),{nickname:'私のノート',collectionPublic:true},2);
  assert.deepEqual((await reader.folders.folders(owner.actor)).items.map(folder=>folder.id),[b]);
  assert.equal((await reader.folders.items(b,params({}))).items[0].postId,post.id);
  await author.store.block(owner.actor);
  await assert.rejects(reader.folders.items(b,params({})),{status:404});
  await owner.folders.drop(b,1);
  assert.ok(await query(db,'SELECT id FROM posts WHERE id=?',post.id).first());
}));

test('retention releases old delivered outbox, expired idempotency and shared limits only',()=>withDb(async({db,enroll})=>{
  const user=await enroll('保守担当');
  await db.batch([
    ...eventStatements(db,'retention-done','fixture',{},clock-31*day),
    ...eventStatements(db,'retention-pending','fixture',{},clock-31*day),
    query(db,"UPDATE outbox SET delivered_at=? WHERE dedupe_key='retention-done'",clock-31*day),
    query(db,"UPDATE scheduled_jobs SET state='done' WHERE dedupe_key='outbox:retention-done'"),
    query(db,"INSERT INTO idempotency_keys VALUES (?, 'fixture', 'older','a'||printf('%063d',0),'{}',?)",user.actor,clock-2*day),
    query(db,"INSERT INTO rate_limits VALUES ('old:fixture',?,1)",Math.floor((clock-3*day)/60_000)),
    query(db,"INSERT INTO rate_limits VALUES ('mail:fixture',?,1)",clock-30_000),
  ]);
  await pruneDiscoveryData(db,clock);
  assert.deepEqual((await query(db,"SELECT dedupe_key AS key FROM outbox WHERE dedupe_key LIKE 'retention-%'").all()).results,[{key:'retention-pending'}]);
  assert.equal((await query(db,"SELECT scope FROM rate_limits WHERE scope LIKE '%fixture'").all()).results[0].scope,'mail:fixture');
  assert.equal((await query(db,"SELECT count(*) AS count FROM idempotency_keys WHERE operation='fixture'").first()).count,0);
}));


test('search request throttling and paused discovery preserve member safety operations',()=>withDb(async({db,runtime,enroll,signing})=>{
  const reader=await enroll('入力の試験');
  const other=await enroll('試験の相手');
  await reader.store.block(other.actor);
  const env={APP_ENV:'test',DB:db,PRIVATE_MEDIA:await runtime.getR2Bucket('PRIVATE_MEDIA'),QUARANTINE:await runtime.getR2Bucket('QUARANTINE')};
  const app=createApi({clock:()=>clock,log:()=>{},membership:{
    verify:async token=>token==='synthetic'?reader.identity:null,key:signing,sendCode:async()=>{},
  }});
  const call=(path,method='GET')=>app(new globalThis.Request('http://localhost'+path,{
    method,headers:{authorization:'Bearer synthetic','x-app-session':reader.issued.sessionToken},
  }),env);
  for(let i=0;i<16;i++) assert.equal((await call('/v1/search?q=%E6%98%A5')).status,200);
  assert.equal((await call('/v1/search?q=%E6%98%A5')).status,429);
  await query(db,"UPDATE feature_flags SET enabled=0 WHERE name='search_enabled'").run();
  assert.equal((await call('/v1/search?q=%E6%98%A5')).status,503);
  assert.equal((await call('/v1/tags/popular')).status,503);
  assert.equal((await call('/v1/me/blocks/'+other.actor,'DELETE')).status,204);
}));

test('backup rebuilds trigram and applies deletion before the restored search is enabled',()=>withDb(async({db,enroll,signing})=>{
  const author=await enroll('復元の著者');
  const reader=await enroll('復元の読者');
  const visible=await author.store.save(null,{body:'北風の続報を記録',tags:[]},key(),null);
  const removed=await author.store.save(null,{body:'南風の続報を記録',tags:[]},key(),null);
  const envelopeKey=await backupKey(crypt.getRandomValues(new Uint8Array(32)));
  const image=await backup(db,envelopeKey,clock);
  const machine=simulator();
  try {
    const destination=await machine.getD1Database('DB');
    await restore(destination,image,envelopeKey,{through:clock+10,entries:[{kind:'post',id:removed.id,at:clock+3}]});
    const restored=new Discovery(new CommunityStore(destination,await reader.context(),clock+10),signing);
    assert.deepEqual((await restored.search(params({q:'続報を'}))).items.map(row=>row.id),[visible.id]);
  } finally {await machine.dispose();}
}));

test('recent albums cap one hundred and hide previous results after rights withdrawal',()=>withDb(async({db,runtime,enroll,signing})=>{
  const reader=await enroll('最近の読者');
  const env={APP_ENV:'test',DB:db,PRIVATE_MEDIA:await runtime.getR2Bucket('PRIVATE_MEDIA'),QUARANTINE:await runtime.getR2Bucket('QUARANTINE')};
  const official=await seedPhotos(env,clock-10);
  const source=await query(db,'SELECT identity_id FROM photo_albums WHERE content_id=?',syntheticAlbum).first();
  const published=(await reader.search.official(params({}))).items[0];
  assert.equal(published.id,official.artist);
  assert.equal(published.identityId,source.identity_id);
  assert.equal(published.category,'artist');
  const ids=Array.from({length:100},id);
  for(let i=0;i<ids.length;i+=20) await db.batch(ids.slice(i,i+20).flatMap((album,j)=>[
    query(db,"INSERT INTO content_items VALUES (?,?,'gallery','合成資料','approved','members',0,0,0,1)",album,official.artist),
    query(db,"INSERT INTO photo_albums VALUES (?,?,'synthetic')",album,source.identity_id),
    query(db,"INSERT INTO recent_albums VALUES (?,?,?)",reader.actor,album,clock-200+i+j),
  ]));
  await reader.folders.recordRecent(syntheticAlbum);
  await reader.folders.recordRecent(syntheticAlbum);
  assert.equal((await query(db,'SELECT count(*) AS n FROM recent_albums WHERE owner_id=?',reader.actor).first()).n,100);
  assert.equal((await query(db,'SELECT 1 FROM recent_albums WHERE owner_id=? AND album_id=?',reader.actor,ids[0]).first()),null);
  assert.equal((await reader.folders.recent(params({limit:'1'}))).items[0].id,syntheticAlbum);
  await indexedText(db,'album',syntheticAlbum,'光と色のサンプル',1).run();
  assert.equal((await reader.search.search(params({q:'色のさ',kind:'album'}))).items[0].id,syntheticAlbum);
  await query(db,"UPDATE photo_albums SET rights_state='pending' WHERE content_id=?",syntheticAlbum).run();
  assert.equal((await reader.search.search(params({q:'色のさ',kind:'album'}))).items.length,0);
  assert.notEqual((await reader.folders.recent(params({limit:'1'}))).items[0].id,syntheticAlbum);
  const later=new Collections(new CommunityStore(db,await reader.context(),clock+1000),signing);
  await later.clearRecent(null);
  assert.equal((await later.recent(params({}))).items.length,0);
  await query(db,'UPDATE role_grants SET revoked_at=? WHERE member_id=? AND role=\'artist\'',clock,official.artist).run();
  assert.equal((await reader.search.official(params({}))).items.length,0);
}));

test('detached photos finish R2 reclamation when saved references and origin records remain',()=>withDb(async({db,runtime,enroll})=>{
  const author=await enroll('撮影の著者');
  const reader=await enroll('写真の読者');
  const env={APP_ENV:'test',DB:db,PRIVATE_MEDIA:await runtime.getR2Bucket('PRIVATE_MEDIA'),QUARANTINE:await runtime.getR2Bucket('QUARANTINE')};
  const mediaStore=new MediaStore(env,()=>clock);
  const uploader={id:author.actor,sessionId:author.store.actor.session.id,role:'member'};
  const fixtures=[
    ['post',syntheticJpeg(128,84)],
    ['thumbnail',syntheticJpeg(64,42)],
  ];
  const photos=[];
  for(const [purpose,bytes] of fixtures) {
    const file=await mediaStore.reserve(uploader,key(),bytes.byteLength,'image/jpeg',{
      purpose,hash:await digest(bytes),variant:photos[0]??null,
    });
    await mediaStore.quarantine(uploader,file.id,bytes);
    await mediaStore.approve(uploader,file.id,async data=>inspectPhoto(data,purpose));
    photos.push(file.id);
  }
  const [photo]=photos;
  const post=await author.store.save(null,{body:'写真の保管テスト',tags:[],attachments:[photo]},key(),null);
  const folder=id();
  await reader.folders.create({id:folder,title:'元の写真'});
  await reader.folders.add(folder,{postId:post.id,photoId:photo});
  await assert.rejects(mediaStore.cancel(uploader,photo),{status:409});
  await author.store.save(post.id,{body:'画像を外した投稿',tags:[],attachments:[]},key(),1);
  assert.ok(await query(db,'SELECT post_id FROM post_photo_origins WHERE media_id=?',photo).first());
  await mediaStore.cancel(uploader,photo);
  assert.equal((await query(db,'SELECT state FROM media_reservations WHERE id=?',photo).first()).state,'cancelled');
  assert.equal(await env.PRIVATE_MEDIA.head('objects/'+photo),null);
  assert.equal(await query(db,'SELECT 1 FROM post_photo_origins WHERE media_id=?',photo).first(),null);
  assert.deepEqual((await reader.folders.items(folder,params({}))).items,[]);
  assert.equal((await query(db,'PRAGMA foreign_key_check').all()).results.length,0);
}));
