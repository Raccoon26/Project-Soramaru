import assert from 'node:assert/strict';
import test from 'node:test';
import { migrate,migrations,simulator } from '../../../tools/local-backend.mjs';
import { syntheticJpeg } from '../../../tools/photo-fixtures.mjs';
import { backup,backupKey,captureRows,restore } from '../../../tools/local-backup.mjs';
import { createApi } from '../src/index.ts';
import { counts,interactionStillVisible } from '../src/interactions.ts';
import { MembershipStore } from '../src/membership-store.ts';
import { policyDocuments,policyVersion } from '../src/membership-policy.ts';
import { MediaStore } from '../src/media.ts';
import { digest,query } from '../src/platform.ts';

const crypt=globalThis.crypto;
const uuid=()=>crypt.randomUUID();
const randomKey=()=>globalThis.Buffer.from(crypt.getRandomValues(new Uint8Array(32))).toString('base64url');
const base=1_795_578_000_000;

async function verify(action) {
  const runtime=simulator();
  try {
    const DB=await runtime.getD1Database('DB');
    const files=await migrations();
    assert.equal(await migrate(DB,files.slice(0,8)),8);
    const key=await crypt.subtle.importKey('raw',crypt.getRandomValues(new Uint8Array(32)),{name:'HMAC',hash:'SHA-256'},false,['sign','verify']);
    const tokens=new Map(),events=[];
    let now=base;
    const env={APP_ENV:'test',DB,PRIVATE_MEDIA:await runtime.getR2Bucket('PRIVATE_MEDIA'),QUARANTINE:await runtime.getR2Bucket('QUARANTINE')};
    const members=new MembershipStore(DB,now,key);
    async function account(label) {
      const token=randomKey(),identity={uid:'fixture-interaction-'+label,verifiedEmail:true,authAt:now-100};
      tokens.set(token,identity);
      const enrolled=await members.issue(identity,randomKey(),'Fixture','other');
      const context=()=>members.context(identity,enrolled.sessionToken);
      await members.accept(await context(),{version:policyVersion,documents:policyDocuments.map(item=>item.kind)});
      await query(DB,'UPDATE member_profiles SET nickname=?,configured_at=? WHERE member_id=?',label,now,enrolled.profile.id).run();
      return {id:enrolled.profile.id,session:enrolled.session.id,headers:{authorization:'Bearer '+token,'x-app-session':enrolled.sessionToken}};
    }
    const a=await account('空'),b=await account('海'),c=await account('星');
    const p=uuid(),prior=uuid();
    await DB.batch([
      query(DB,"INSERT INTO posts(id,author_id,body,state,created_at,updated_at,publish_at) VALUES (?,?,'合成投稿','approved',?,?,?)",p,a.id,base-100,base-100,base-100),
      query(DB,"INSERT INTO community_reports VALUES (?,?,'post',?,?,1,'other','fixture',?)",prior,b.id,p,a.id,now),
    ]);
    assert.equal(await migrate(DB,files),11);
    assert.equal((await query(DB,'SELECT detail FROM community_reports WHERE id=?',prior).first()).detail,'fixture');
    const app=createApi({clock:()=>now,log:event=>events.push(event),membership:{verify:async token=>tokens.get(token)??null,key,sendCode:async()=>{}}});
    async function request(member,path,method='GET',data,extra={}) {
      const binary=data instanceof ArrayBuffer;
      return app(new globalThis.Request('http://localhost'+path,{method,headers:{
        ...member.headers,...data===undefined?{}:{'content-type':binary?'image/jpeg':'application/json'},...extra,
      },body:data===undefined?undefined:binary?data:JSON.stringify(data)}),env);
    }
    async function call(member,status,path,method='GET',data,headers) {
      const answer=await request(member,path,method,data,headers);
      const body=answer.status===204?null:await answer.json();
      assert.equal(answer.status,status,method+' '+path+' '+JSON.stringify(body));
      return body;
    }
    const comment=(member,input,over={})=>call(member,201,'/v1/posts/'+p+'/comments','POST',input,{'idempotency-key':randomKey(),...over});
    await action({DB,env,events,a,b,c,p,comment,call,request,advance:ms=>{now+=ms;}});
  } finally {await runtime.dispose();}
}

test('comments, stamp catalog, Unicode, version conflicts, scoped cursors and tombstone replies',()=>verify(async({DB,a,b,c,p,comment,call,request,advance})=>{
  const path='/v1/posts/'+p+'/comments';
  const key=randomKey();
  const root=await comment(b,{body:'か\u3099'.repeat(1000)},{'idempotency-key':key});
  assert.equal((await comment(b,{body:root.body},{'idempotency-key':key})).id,root.id);
  await call(b,400,path,'POST',{body:root.body+'空'},{'idempotency-key':randomKey()});
  await call(b,400,path,'POST',{body:''},{'idempotency-key':randomKey()});
  const stamps=await call(c,200,'/v1/stamps');
  assert.equal(stamps.items.length,8);
  const reply=await comment(c,{parentId:root.id,stampId:'thanks'});
  assert.equal(reply.stamp.id,'thanks');
  await call(c,409,path,'POST',{parentId:reply.id,body:'深すぎる'},{'idempotency-key':randomKey()});
  await query(DB,"UPDATE stamp_items SET enabled=0 WHERE id='thanks'").run();
  await call(c,409,path,'POST',{stampId:'thanks'},{'idempotency-key':randomKey()});
  assert.equal((await call(a,200,'/v1/comments/'+reply.id)).stamp.id,'thanks');
  await query(DB,"UPDATE stamp_sets SET rights_state='revoked'").run();
  assert.equal((await call(a,200,'/v1/comments/'+reply.id)).stamp,null);
  const second=await comment(c,{body:'二番目'});
  const one=await call(a,200,path+'?limit=1');
  assert.ok(one.nextCursor);
  const two=await call(a,200,path+'?limit=1&cursor='+one.nextCursor);
  assert.notEqual(one.items[0].id,two.items[0].id);
  assert.deepEqual(new Set([one.items[0].id,two.items[0].id]),new Set([root.id,second.id]));
  await call(b,400,path+'?limit=1&cursor='+one.nextCursor);
  await call(a,400,path+'?limit=1&cursor='+one.nextCursor+'x');
  const edit='/v1/comments/'+root.id;
  const editHeaders={'if-match':'"1"','idempotency-key':randomKey()};
  await call(c,404,edit,'PATCH',{body:'他人'},editHeaders);
  const edits=await Promise.all([
    request(b,edit,'PATCH',{body:'編集'},editHeaders),
    request(b,edit,'PATCH',{body:'競合'},{...editHeaders,'idempotency-key':randomKey()}),
  ]);
  assert.deepEqual(edits.map(r=>r.status).sort(),[200,409]);
  assert.equal((await call(b,200,edit)).version,2);
  await call(b,204,edit,'DELETE',undefined,{'if-match':'"2"','idempotency-key':randomKey()});
  const removed=await call(a,200,edit);
  assert.equal(removed.authorId,null);
  assert.equal(removed.body,'');
  assert.equal(removed.removed,true);
  assert.equal((await call(a,200,path+'?parent='+root.id)).items[0].id,reply.id);
  await call(a,409,path,'POST',{parentId:root.id,body:'新規返信'},{'idempotency-key':randomKey()});
  advance(900_001);
  await call(a,400,path+'?cursor='+one.nextCursor);
}));

test('reactions are explicit, deduplicated, visible in activity and rechecked before outbox delivery',()=>verify(async({DB,a,b,c,p,comment,call,request})=>{
  const root=await comment(b,{body:'活動'});
  const reply=await comment(c,{parentId:root.id,body:'返信'});
  const postLike='/v1/reactions/post/'+p;
  const commentLike='/v1/reactions/comment/'+reply.id;
  const results=await Promise.all([request(b,postLike,'PUT'),request(b,postLike,'PUT')]);
  assert.ok(results.every(r=>r.status===200));
  assert.equal((await call(b,200,postLike,'PUT')).likes,1);
  assert.equal((await call(c,200,commentLike,'PUT')).liked,true);
  assert.equal((await call(c,200,commentLike,'DELETE')).likes,0);
  assert.equal((await call(b,200,postLike,'DELETE')).likes,0);
  assert.equal((await call(b,200,postLike,'PUT')).likes,1);
  const entries=(await call(b,200,'/v1/me/activity?limit=1'));
  assert.ok(entries.nextCursor);
  assert.equal((await call(b,200,'/v1/me/activity?limit=1&cursor='+entries.nextCursor)).items.length,1);
  let mail=(await query(DB,"SELECT event_type,event_payload FROM outbox WHERE event_type IN ('comment.created','reply.created','reaction.added')").all()).results;
  assert.equal(mail.length,3);
  const event=mail.find(x=>x.event_type==='reply.created');
  assert.equal(JSON.parse(event.event_payload).recipientId,b.id);
  assert.equal(await interactionStillVisible(DB,JSON.parse(event.event_payload),event.event_type,base),true);
  await call(a,202,'/v1/reports','POST',{kind:'comment',targetId:root.id,category:'other'});
  await call(a,202,'/v1/reports','POST',{kind:'comment',targetId:root.id,category:'other'});
  assert.equal((await query(DB,"SELECT count(*) n FROM community_reports WHERE target_kind='comment'").first()).n,1);
  await call(b,204,'/v1/me/blocks/'+c.id,'PUT');
  assert.equal(await interactionStillVisible(DB,JSON.parse(event.event_payload),event.event_type,base),false);
  await call(b,404,'/v1/comments/'+reply.id);
  await call(b,404,commentLike,'PUT');
  await query(DB,"UPDATE feature_flags SET enabled=0 WHERE name='comments_enabled'").run();
  await call(b,503,postLike,'DELETE');
  assert.equal((await call(b,200,'/v1/posts/'+p)).commentCount,1);
}));

test('comment photo uses private R2, cannot masquerade as a post attachment, and restoration reapplies deletion',()=>verify(async({DB,env,a,b,c,p,comment,call,request,advance})=>{
  async function upload(purpose,data,variantOf) {
    const reserve=await call(c,201,'/v1/uploads','POST',{
      purpose,bytes:data.byteLength,mime:'image/jpeg',sha256:await digest(data),variantOf,
    },{'idempotency-key':randomKey()});
    await call(c,200,'/v1/uploads/'+reserve.id+'/body','PUT',data);
    await call(c,200,'/v1/uploads/'+reserve.id+'/complete','POST');
    return reserve.id;
  }
  const original=syntheticJpeg(),media=await upload('comment',original);
  await upload('thumbnail',syntheticJpeg(60,40,8),media);
  await call(c,409,'/v1/posts','POST',{body:'別種',tags:[],attachments:[media]},{'idempotency-key':randomKey()});
  const root=await comment(b,{body:'親'});
  const reply=await comment(c,{parentId:root.id,photoId:media});
  const path='/v1/media/'+media+'?parent=comment&parent_id='+reply.id+'&variant=full';
  const asset=await request(a,path);
  assert.equal(asset.status,200);
  assert.deepEqual(await asset.arrayBuffer(),original);
  assert.equal((await request(a,path.replace('variant=full','variant=thumb'))).status,200);
  assert.equal((await request(a,path.replace(reply.id,root.id))).status,404);
  assert.equal((await request(a,path.replace('parent=comment','parent=post').replace(reply.id,p))).status,404);
  await call(a,200,'/v1/media/grants','POST',{parent:'comment',parentId:reply.id,ids:[media],variant:'thumb'});
  await query(DB,"UPDATE comments SET state='hidden' WHERE id=?",root.id).run();
  assert.equal((await request(a,path)).status,404);
  await query(DB,"UPDATE comments SET state='approved' WHERE id=?",root.id).run();
  const key=await backupKey(crypt.getRandomValues(new Uint8Array(32)));
  const saved=await backup(DB,key,base);
  const restored=simulator('test');
  try {
    const target=await restored.getD1Database('DB');
    await restore(target,saved,key,{through:base+1,entries:[{kind:'comment',id:reply.id,at:base+1}]});
    assert.equal((await query(target,'SELECT state FROM comments WHERE id=?',reply.id).first()).state,'deleted');
    assert.equal(await query(target,'SELECT * FROM comment_media WHERE comment_id=?',reply.id).first(),null);
    assert.equal((await captureRows(target)).tables.stamp_items.length,8);
  } finally {await restored.dispose();}
  await call(c,204,'/v1/comments/'+reply.id,'DELETE',undefined,{'if-match':'"1"','idempotency-key':randomKey()});
  assert.equal((await request(a,path)).status,404);
  advance(172_801_000);
  await new MediaStore(env,()=>base+172_801_000).prunePhotos();
  assert.equal(await env.PRIVATE_MEDIA.head('objects/'+media),null);
}));

test('bounded target batch uses reaction and thread indexes on thousands of rows',()=>verify(async({DB,a,b,p,call,events})=>{
  await query(DB,`WITH RECURSIVE tally(n) AS (VALUES(0) UNION ALL SELECT n+1 FROM tally WHERE n<2299)
    INSERT INTO comments(id,post_id,author_id,body,state,created_at,updated_at)
    SELECT printf('06800000-0000-4000-8000-%012d',n),?,?,'合成','approved',?-n,?-n FROM tally`,
    p,b.id,base,base).run();
  const chosen=await query(DB,'EXPLAIN QUERY PLAN SELECT * FROM comments WHERE post_id=? AND parent_id IS NULL ORDER BY created_at,id LIMIT 21',p).all();
  assert.ok(chosen.results.some(row=>row.detail.includes('comments_thread')));
  const page=await call(a,200,'/v1/posts/'+p+'/comments?limit=20');
  assert.equal(page.items.length,20);
  assert.ok(page.nextCursor);
  const tally=await counts(DB,a.id,base,'post',[p]);
  assert.equal(tally.get(p).comments,2300);
  const unindexed=await query(DB,
    "SELECT * FROM comments NOT INDEXED WHERE post_id=? AND parent_id IS NULL ORDER BY created_at,id LIMIT 21",p).all();
  const indexed=await query(DB,
    "SELECT * FROM comments WHERE post_id=? AND parent_id IS NULL ORDER BY created_at,id LIMIT 21",p).all();
  assert.deepEqual(indexed.results,unindexed.results);
  assert.ok(indexed.meta.rows_read<unindexed.meta.rows_read);
  globalThis.console.log('DEV07 local D1 page',events.at(-1).d1,'bare index comparison',
    [unindexed.meta.rows_read,indexed.meta.rows_read]);
}));
