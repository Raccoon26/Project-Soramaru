import assert from 'node:assert/strict';
import test from 'node:test';
import { migrate,migrations,simulator } from '../../../tools/local-backend.mjs';
import { seedPhotos,syntheticAlbum,syntheticJpeg } from '../../../tools/photo-fixtures.mjs';
import { createApi } from '../src/index.ts';
import { MembershipStore } from '../src/membership-store.ts';
import { policyDocuments,policyVersion } from '../src/membership-policy.ts';
import { jpegDimensions,inspectPhoto } from '../src/photo-format.ts';
import { photoBytes } from '../src/photo-api.ts';
import { MediaStore } from '../src/media.ts';
import { digest,query } from '../src/platform.ts';

const crypt=globalThis.crypto;
const now=1_795_578_000_000;
const rand=()=>globalThis.Buffer.from(crypt.getRandomValues(new Uint8Array(32))).toString('base64url');
const jpeg=syntheticJpeg();
const mime='image/jpeg';

function spliced(source,segment) {
  const original=new Uint8Array(source);
  const result=new Uint8Array(original.length+segment.length);
  result.set(original.slice(0,2));
  result.set(segment,2);
  result.set(original.slice(2),2+segment.length);
  return result.buffer;
}

test('JPEG gate decodes pixels, rejects metadata segments, overlarge dimensions and trailing or truncated bytes',()=>{
  assert.deepEqual(inspectPhoto(jpeg,'post'),{width:128,height:84});
  assert.equal(inspectPhoto(jpeg,'avatar'),false);
  assert.equal(inspectPhoto(jpeg.slice(0,-15),'post'),false);
  const trailing=new Uint8Array(jpeg.byteLength+2);
  trailing.set(new Uint8Array(jpeg));
  assert.equal(inspectPhoto(trailing.buffer,'post'),false);
  for(const marker of [225,226,237,254]) {
    assert.equal(inspectPhoto(spliced(jpeg,[255,marker,0,8,69,120,105,102,0,0]),'post'),false);
  }
  const huge=new Uint8Array(jpeg.slice(0));
  const frame=huge.findIndex((value,i)=>value===255&&huge[i+1]===192);
  huge[frame+5]=31;
  assert.equal(jpegDimensions(huge.buffer,'post'),null);
  assert.equal(inspectPhoto(new Uint8Array([137,80,78,71,0,0]).buffer,'post'),false);
});

test('raw body limit checks declared and streamed length without trusting content type alone',async()=>{
  const request=(body,headers)=>new globalThis.Request('http://localhost/v1/uploads/file/body',{method:'PUT',body,headers});
  assert.equal((await photoBytes(request(jpeg,{'content-type':mime}),jpeg.byteLength)).byteLength,jpeg.byteLength);
  await assert.rejects(photoBytes(request(jpeg,{'content-type':mime,'content-length':'0'}),jpeg.byteLength),{status:400});
  await assert.rejects(photoBytes(request(jpeg,{'content-type':mime,'content-length':'12'}),jpeg.byteLength),{status:400});
  await assert.rejects(photoBytes(request(jpeg,{'content-type':mime}),12),{status:413});
  await assert.rejects(photoBytes(request(jpeg,{'content-type':'image/svg+xml'}),jpeg.byteLength),{status:415});
});

async function check(action) {
  const runtime=simulator();
  try{
    const DB=await runtime.getD1Database('DB');
    const path=await migrations();
    await migrate(DB,path.slice(0,7));
    const uid='fixture-upgrade-member',id=crypt.randomUUID();
    await DB.batch([
      query(DB,"INSERT INTO member_numbers VALUES ('PICTEST0001',0)"),
      query(DB,"INSERT INTO members(id,auth_uid,member_no,state,joined_at,updated_at) VALUES (?,?,'PICTEST0001','active',0,0)",id,uid),
    ]);
    assert.equal(await migrate(DB,path.slice(0,8)),8);
    assert.equal(await migrate(DB,path),9);
    assert.equal((await query(DB,'SELECT id FROM members WHERE auth_uid=?',uid).first()).id,id);
    const plan=await query(DB,'EXPLAIN QUERY PLAN SELECT id FROM media_objects WHERE variant_of=? AND owner_id=?',id,id).all();
    assert.ok(plan.results.some(row=>row.detail.includes('media_thumbnail')));
    const operations={put:0,list:0,get:0,head:0,delete:0};
    async function measured(name) {
      const bucket=await runtime.getR2Bucket(name);
      return Object.fromEntries(Object.keys(operations).map(method=>[method,(...args)=>{
        operations[method]++;
        return bucket[method](...args);
      }]));
    }
    const env={DB,APP_ENV:'test',PRIVATE_MEDIA:await measured('PRIVATE_MEDIA'),QUARANTINE:await measured('QUARANTINE')};
    const key=await crypt.subtle.importKey('raw',crypt.getRandomValues(new Uint8Array(32)),{name:'HMAC',hash:'SHA-256'},false,['sign','verify']);
    const tokens=new Map(),logs=[];
    let clock=now;
    const api=createApi({clock:()=>clock,log:e=>logs.push(e),membership:{verify:async token=>tokens.get(token)??null,key,sendCode:async()=>{}}});
    async function member(name) {
      const token=rand(),identity={uid:'fixture-pic-'+name,verifiedEmail:true,authAt:now-1000};
      tokens.set(token,identity);
      const store=new MembershipStore(DB,clock,key);
      const issued=await store.issue(identity,rand(),'Fixture','other');
      const context=()=>store.context(identity,issued.sessionToken);
      await store.accept(await context(),{version:policyVersion,documents:policyDocuments.map(x=>x.kind)});
      await store.edit(await context(),{nickname:name},1);
      return {id:issued.profile.id,sessionId:issued.session.id,role:'member',
        auth:{authorization:'Bearer '+token,'x-app-session':issued.sessionToken}};
    }
    function req(actor,path,method='GET',body,headers={}) {
      return api(new globalThis.Request('http://localhost'+path,{method,
        headers:{...actor.auth,...(body?{'content-type':body instanceof ArrayBuffer?mime:'application/json'}:{}),...headers},
        body:body instanceof ArrayBuffer?body:body?JSON.stringify(body):undefined}),env);
    }
    async function reserve(actor,purpose='post',bytes=jpeg,variantOf){
      const response=await req(actor,'/v1/uploads','POST',{
        purpose,bytes:bytes.byteLength,sha256:await digest(bytes),mime,variantOf,
      },{'idempotency-key':rand()});
      assert.equal(response.status,201);
      return (await response.json()).id;
    }
    async function upload(actor,purpose='post',bytes=jpeg,variant){
      const id=await reserve(actor,purpose,bytes,variant);
      assert.equal((await req(actor,'/v1/uploads/'+id+'/body','PUT',bytes)).status,200);
      assert.equal((await req(actor,'/v1/uploads/'+id+'/complete','POST')).status,200);
      return id;
    }
    await action({DB,env,req,reserve,upload,member,logs,operations,advance:n=>{clock+=n;}});
  } finally {await runtime.dispose();}
}

test('R2 quarantine and actual bytes, atomic post reference, ordered thumbnail grants, block and delete',()=>check(async({DB,env,member,req,reserve,upload,logs,operations})=>{
  const a=await member('空'),b=await member('海');
  const id=await reserve(a);
  assert.equal((await req(b,'/v1/uploads/'+id)).status,404);
  assert.equal((await req(b,'/v1/uploads/'+id+'/body','PUT',jpeg)).status,404);
  const altered=jpeg.slice(0);
  new Uint8Array(altered)[18]^=1;
  assert.equal((await req(a,'/v1/uploads/'+id+'/body','PUT',altered)).status,409);
  assert.equal((await req(a,'/v1/uploads/'+id+'/body','PUT',jpeg)).status,200);
  assert.equal((await req(a,'/v1/uploads/'+id+'/body','PUT',jpeg)).status,200);
  assert.equal((await req(a,'/v1/uploads/'+id)).status,200);
  assert.ok(await env.QUARANTINE.head('objects/'+id));
  assert.equal(await env.PRIVATE_MEDIA.head('objects/'+id),null);
  assert.equal((await req(a,'/v1/uploads/'+id+'/complete','POST')).status,200);
  assert.equal((await req(a,'/v1/uploads/'+id+'/complete','POST')).status,200);
  assert.equal(await env.QUARANTINE.head('objects/'+id),null);
  assert.equal((await query(DB,'SELECT held_bytes FROM media_capacity').first()).held_bytes,jpeg.byteLength);
  const thumb=await upload(a,'thumbnail',syntheticJpeg(64,42,2),id);
  const other=await upload(a,'post',syntheticJpeg(128,84,3));
  await upload(a,'thumbnail',syntheticJpeg(64,42,4),other);
  const postHeader={'idempotency-key':rand()};
  const eleven=Array.from({length:11},()=>crypt.randomUUID());
  assert.equal((await req(a,'/v1/posts','POST',{body:'',tags:[],attachments:eleven},postHeader)).status,400);
  assert.equal((await req(a,'/v1/posts','POST',{body:'',tags:[],attachments:[id,id]},postHeader)).status,400);
  assert.equal((await req(b,'/v1/posts','POST',{body:'',tags:[],attachments:[id]},postHeader)).status,409);
  const posted=await req(a,'/v1/posts','POST',{body:'',tags:[],attachments:[id,other]},postHeader);
  assert.equal(posted.status,201);
  const post=await posted.json();
  assert.deepEqual(post.photos,[id,other]);
  const path='/v1/media/'+id+'?parent=post&parent_id='+post.id+'&variant=full';
  const binary=await req(b,path);
  assert.equal(binary.status,200);
  assert.deepEqual(await binary.arrayBuffer(),jpeg);
  const grant=await req(b,'/v1/media/grants','POST',{parent:'post',parentId:post.id,ids:[id,other],variant:'thumb'});
  assert.equal(grant.status,200);
  assert.deepEqual((await grant.json()).items.map(x=>x.id),[id,other]);
  assert.equal((await req(b,path,'GET',undefined,{range:'bytes=0-31'})).status,206);
  assert.equal((await req(b,path,'GET',undefined,{range:'bytes=0-2,4-6'})).status,416);
  assert.equal((await req(b,path,'GET',undefined,{range:'bytes=0-9999999'})).status,416);
  assert.equal((await req(b,path.replace(id,thumb))).status,404);
  assert.equal((await req(a,'/v1/uploads/'+id,'DELETE')).status,409);
  assert.equal((await req(a,'/v1/posts/'+post.id,'PATCH',{body:'',tags:[],attachments:[other,id]},
    {'if-match':'"1"','idempotency-key':rand()})).status,200);
  assert.deepEqual((await (await req(a,'/v1/posts/'+post.id)).json()).photos,[other,id]);
  assert.equal((await req(b,'/v1/me/blocks/'+a.id,'PUT')).status,204);
  assert.equal((await req(b,path)).status,404);
  assert.equal((await req(a,'/v1/posts/'+post.id,'DELETE',undefined,{'if-match':'"2"','idempotency-key':rand()})).status,204);
  assert.equal((await req(a,path)).status,404);
  assert.doesNotMatch(JSON.stringify(logs),/objects\/|sha256|image\/jpeg|bytes=/);
  globalThis.console.log('Photo request metrics (local D1)',logs.filter(e=>e.operation==='photo').reduce(
    (sum,e)=>[sum[0]+e.d1.reads,sum[1]+e.d1.writes],[0,0]), 'R2 calls',operations);
}));

test('synthetic official album and profile are scoped to visibility and real attachment, no URL on local direct mode',()=>check(async({DB,env,member,req,upload})=>{
  const a=await member('光'),b=await member('星');
  const seeded=await seedPhotos(env,now-1000);
  const gallery=await req(a,'/v1/gallery?limit=1');
  assert.equal(gallery.status,200);
  assert.equal((await gallery.json()).items[0].id,syntheticAlbum);
  const album=await (await req(a,'/v1/gallery/'+syntheticAlbum)).json();
  assert.deepEqual(album.photos,seeded.photos);
  const first=album.photos[0];
  const path='/v1/media/'+first+'?parent=album&parent_id='+syntheticAlbum+'&variant=thumb';
  assert.equal((await req(b,path)).status,200);
  await query(DB,"UPDATE feature_flags SET enabled=0 WHERE name='media_grants_enabled'").run();
  assert.equal((await req(b,path)).status,503);
  await query(DB,"UPDATE feature_flags SET enabled=1 WHERE name='media_grants_enabled'").run();
  assert.equal((await req(a,'/v1/media/grants','POST',{parent:'album',parentId:syntheticAlbum,ids:[first],variant:'full',mode:'direct'})).status,503);
  for(const state of ['draft','hidden','deleted']){
    await query(DB,'UPDATE content_items SET state=? WHERE id=?',state,syntheticAlbum).run();
    assert.equal((await req(b,path)).status,404);
  }
  await query(DB,"UPDATE content_items SET state='approved',publish_at=? WHERE id=?",now+10000,syntheticAlbum).run();
  assert.equal((await req(b,path)).status,404);
  const avatar=await upload(a,'avatar',syntheticJpeg(64,64,20));
  const patch=(actor,nickname)=>req(actor,'/v1/me','PATCH',{nickname,avatarMediaId:avatar},{'if-match':'"2"'});
  assert.equal((await patch(b,'星')).status,409);
  assert.equal((await patch(a,'光')).status,200);
  const avatarUrl='/v1/media/'+avatar+'?parent=profile&parent_id='+a.id+'&variant=thumb';
  assert.equal((await req(b,avatarUrl)).status,200);
  await env.PRIVATE_MEDIA.delete('objects/'+avatar);
  const scanner=new MediaStore(env,()=>now);
  const firstPage=await scanner.verifyApproved();
  assert.ok(firstPage.cursor);
  const secondPage=await scanner.verifyApproved(firstPage.cursor);
  assert.equal(firstPage.missing+secondPage.missing,1);
  assert.equal(secondPage.cursor,null);
  assert.equal((await req(b,avatarUrl)).status,404);
  assert.equal((await query(DB,'SELECT avatar_media_id FROM member_profiles WHERE member_id=?',a.id).first()).avatar_media_id,avatar);
  await query(DB,"UPDATE member_profiles SET avatar_media_id=NULL WHERE member_id=?",a.id).run();
  assert.equal((await req(b,avatarUrl)).status,404);
}));

test('revoked, expired and abandoned uploads stay private and capacity is released after cleanup',()=>check(async({DB,env,member,req,reserve,upload,advance})=>{
  const a=await member('春'),b=await member('冬');
  const held=await reserve(a);
  const cancelled=await reserve(b);
  assert.equal((await req(b,'/v1/uploads/'+cancelled,'DELETE')).status,204);
  assert.equal((await req(b,'/v1/uploads/'+cancelled,'DELETE')).status,204);
  await query(DB,'UPDATE member_sessions SET revoked_at=? WHERE id=?',now,a.sessionId).run();
  assert.equal((await req(a,'/v1/uploads/'+held+'/body','PUT',jpeg)).status,401);
  const abandoned=await upload(b);
  const thumb=await upload(b,'thumbnail',syntheticJpeg(64,42,6),abandoned);
  advance(172_900_000);
  const gc=new MediaStore(env,()=>now+172_900_000);
  await gc.expire();
  await gc.prunePhotos();
  assert.equal(await env.PRIVATE_MEDIA.head('objects/'+abandoned),null);
  assert.equal(await env.PRIVATE_MEDIA.head('objects/'+thumb),null);
  assert.equal((await query(DB,'SELECT held_bytes FROM media_capacity').first()).held_bytes,0);
  assert.equal((await query(DB,'SELECT state FROM media_reservations WHERE id=?',held).first()).state,'expired');
}));
