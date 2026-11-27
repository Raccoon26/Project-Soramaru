import assert from 'node:assert/strict';
import { syntheticJpeg,seedPhotos,syntheticAlbum } from '../../../tools/photo-fixtures.mjs';
import { digest } from '../src/platform.ts';
import process from 'node:process';
import { URL,fileURLToPath } from 'node:url';
import { createServer } from 'vite';
import { simulator,migrate } from '../../../tools/local-backend.mjs';
import { demoProject } from '../src/firebase.ts';

const h='http://127.0.0.1:9099';
const fetch=globalThis.fetch;
if(process.env.FIREBASE_AUTH_EMULATOR_HOST!=='127.0.0.1:9099') throw new Error('Use npm run test:membership');
const random=()=>globalThis.Buffer.from(globalThis.crypto.getRandomValues(new Uint8Array(32))).toString('base64url');
const json={'content-type':'application/json'};
const route=h+'/identitytoolkit.googleapis.com/v1/accounts:';
const email='fixture-'+globalThis.crypto.randomUUID()+'@example.invalid';
const otherMail='fixture-'+globalThis.crypto.randomUUID()+'@example.invalid';
const password='Synthetic-'+random();
const timer=globalThis.AbortSignal;
const slot=globalThis.crypto.randomUUID();

async function ask(url,init) {
  const response=await fetch(url,{...init,signal:timer.timeout(12000)});
  return {status:response.status,result:response.status===204?null:await response.json()};
}
const firebase=(action,input)=>ask(route+action+'?key=demo-local-key',{method:'POST',headers:json,body:JSON.stringify(input)});
const refresh=token=>ask(h+'/securetoken.googleapis.com/v1/token?key=demo-local-key',{
  method:'POST',headers:{'content-type':'application/x-www-form-urlencoded'},
  body:new globalThis.URLSearchParams({grant_type:'refresh_token',refresh_token:token}).toString(),
});
async function oob(kind) {
  const {result}=await ask(h+'/emulator/v1/projects/'+demoProject+'/oobCodes');
  const code=result.oobCodes.find(item=>item.email===email&&item.requestType===kind)?.oobCode;
  assert.ok(code,'expected disposable emulator code');
  return code;
}

const dbServer=simulator('test',{persist:true,slot});
try {
  const DB=await dbServer.getD1Database('DB');
  await migrate(DB);
  await seedPhotos({DB,APP_ENV:'test',PRIVATE_MEDIA:await dbServer.getR2Bucket('PRIVATE_MEDIA'),QUARANTINE:await dbServer.getR2Bucket('QUARANTINE')});
}
finally { await dbServer.dispose(); }
process.env.SORAMARU_RUNTIME='test';
process.env.SORAMARU_TEST_SLOT=slot;
process.env.SORAMARU_LOCAL_AUTH_KEY=globalThis.Buffer.from(globalThis.crypto.getRandomValues(new Uint8Array(32))).toString('hex');

const worker=await createServer({root:fileURLToPath(new URL('../',import.meta.url)),server:{host:'127.0.0.1',port:0},clearScreen:false});
try {
  await worker.listen();
  const port=worker.httpServer?.address()?.port;
  assert.ok(port);
  const base='http://127.0.0.1:'+port;
  const api=(path,{token,session,method='GET',body,headers={}}={})=>ask(base+path,{
    method,headers:{...(body?json:{}),...(token?{authorization:'Bearer '+token}:{}),
      ...(session?{'x-app-session':session}:{}),...headers},
    ...(body?{body:JSON.stringify(body)}:{}),
  });
  const issue=(token,nonce,alias='Fixture')=>api('/v1/sessions',{token,method:'POST',
    headers:{'idempotency-key':nonce,'x-role':'administrator'},body:{alias,os:'other',role:'administrator'}});
  assert.equal((await api('/v1/ready')).status,200);
  const signup=await firebase('signUp',{email,password,returnSecureToken:true});
  assert.equal(signup.status,200);
  assert.equal((await firebase('signInWithPassword',{email,password:'wrong-synthetic'})).status,400);
  const initialToken=signup.result.idToken;
  const protectedOptions={token:initialToken};
  assert.equal((await api('/v1/me/session',protectedOptions)).status,401);
  const k=random(),k2=random();
  const [first,replay,second]=await Promise.all([issue(initialToken,k),issue(initialToken,k),issue(initialToken,k2)]);
  assert.deepEqual([first.status,replay.status,second.status],[201,201,201]);
  assert.equal(first.result.phase,'unverified');
  assert.equal(first.result.profile.memberNumber,second.result.profile.memberNumber);
  assert.equal(first.result.sessionToken,replay.result.sessionToken);
  assert.equal(first.result.role,'member');
  assert.notEqual(first.result.session.id,second.result.session.id);
  assert.equal((await issue(initialToken,k,'Changed')).status,409);
  const primary=first.result.sessionToken;
  assert.equal((await api('/v1/sessions',{token:initialToken,session:primary})).status,403);
  const verify=()=>api('/v1/auth/email',{token:initialToken,method:'POST',body:{kind:'verify'}});
  assert.equal((await verify()).status,202);
  assert.equal((await verify()).status,429);
  assert.equal((await firebase('update',{oobCode:'invalid-emulator-code'})).status,400);
  const verifyCode=await oob('VERIFY_EMAIL');
  assert.equal((await firebase('update',{oobCode:verifyCode})).status,200);
  assert.equal((await firebase('update',{oobCode:verifyCode})).status,400);
  assert.equal((await api('/v1/me/session',{token:initialToken,session:primary})).result.phase,'unverified');
  const provider=await refresh(signup.result.refreshToken);
  assert.equal(provider.status,200);
  const token=provider.result.id_token;
  const auth={token,session:primary};
  const phase=()=>api('/v1/me/session',auth);
  assert.equal((await phase()).result.phase,'terms_required');
  const policy=(await api('/v1/auth/policies')).result;
  const documents=policy.documents.map(doc=>doc.kind);
  const accept=version=>api('/v1/me/terms',{...auth,method:'POST',body:{version,documents}});
  assert.equal((await accept('expired-version')).status,409);
  const accepted=await accept(policy.version);
  assert.equal(accepted.result.phase,'profile_required');
  assert.equal((await accept(policy.version)).status,200);
  const edit=(body,version=1)=>api('/v1/me',{...auth,method:'PATCH',headers:{'if-match':'"'+version+'"'},body});
  for (const nickname of ['  ','x\u0001','<script>','公式サポート','a'.repeat(33)]) {
    assert.equal((await edit({nickname})).status,400);
  }
  assert.equal((await edit({nickname:'空',birthMonth:2,birthDay:30})).status,400);
  const updated=await edit({nickname:'空 한글 🐾 e\u0301',biography:'合成',birthMonth:2,birthDay:29});
  assert.equal(updated.status,200);
  assert.equal(updated.result.phase,'active');
  assert.equal(updated.result.profile.birthDay,29);
  const concurrent=await Promise.all([edit({nickname:'空の日'},2),edit({nickname:'星の日'},2)]);
  assert.deepEqual(concurrent.map(item=>item.status).sort(),[200,409]);
  const sessions=await api('/v1/sessions',auth);
  assert.equal(sessions.result.items.length,2);
  assert.equal(sessions.result.items[0].current,true);
  const outsider=await firebase('signUp',{email:otherMail,password,returnSecureToken:true});
  assert.equal((await api('/v1/me/session',{token:outsider.result.idToken,session:primary})).status,401);
  assert.equal((await api('/v1/sessions/'+second.result.session.id,{...auth,method:'DELETE'})).status,204);
  assert.equal((await api('/v1/me/session',{token,session:second.result.sessionToken})).status,401);
  assert.equal((await api('/v1/sessions/renew',{...auth,method:'POST'})).status,200);
  const outsiderToken=outsider.result.idToken;
  const outsiderIssue=await issue(outsiderToken,random());
  const outsiderAuth={token:outsiderToken,session:outsiderIssue.result.sessionToken};
  assert.equal((await api('/v1/posts',outsiderAuth)).status,403);
  await firebase('sendOobCode',{requestType:'VERIFY_EMAIL',idToken:outsiderToken});
  const otherCodes=(await ask(h+'/emulator/v1/projects/'+demoProject+'/oobCodes')).result.oobCodes;
  const otherCode=otherCodes.find(item=>item.email===otherMail&&item.requestType==='VERIFY_EMAIL').oobCode;
  assert.equal((await firebase('update',{oobCode:otherCode})).status,200);
  outsiderAuth.token=(await refresh(outsider.result.refreshToken)).result.id_token;
  assert.equal((await api('/v1/me/terms',{...outsiderAuth,method:'POST',body:{version:policy.version,documents}})).status,200);
  assert.equal((await api('/v1/me',{...outsiderAuth,method:'PATCH',headers:{'if-match':'"1"'},body:{nickname:'青いノート'}})).status,200);
  const create=(actor,body,key=random())=>api('/v1/posts',{...actor,method:'POST',headers:{'idempotency-key':key},body});
  const postInput={body:'か\u3099'.repeat(10000),tags:['朝','ＣＡＦＥ','cafe']};
  const keyForPost=random();
  const post=await create(auth,postInput,keyForPost);
  assert.equal(post.status,201);
  assert.equal(post.result.body,postInput.body);
  assert.equal((await create(auth,postInput,keyForPost)).result.id,post.result.id);
  assert.equal((await create(auth,{body:'あ'.repeat(10001),tags:[]})).status,400);
  assert.equal((await create(outsiderAuth,{body:'不正な公式指定',tags:[],displayedIdentity:post.result.id})).status,400);
  const quoted=await create(outsiderAuth,{body:'合成の引用',tags:['朝'],quoteId:post.result.id});
  assert.equal(quoted.status,201);
  assert.equal(quoted.result.quote.id,post.result.id);
  assert.equal((await api('/v1/posts?limit=20',outsiderAuth)).result.items.length,2);
  const report=()=>api('/v1/reports',{...outsiderAuth,method:'POST',body:{kind:'post',targetId:post.result.id,category:'other'}});
  assert.equal((await report()).status,202);
  assert.equal((await report()).status,202);
  async function fixtureUpload(purpose,bytes,variantOf,actor=auth){
    const result=await api('/v1/uploads',{...actor,method:'POST',headers:{'idempotency-key':random()},
      body:{purpose,mime:'image/jpeg',bytes:bytes.byteLength,sha256:await digest(bytes),variantOf}});
    assert.equal(result.status,201);
    const id=result.result.id;
    const put=await fetch(base+'/v1/uploads/'+id+'/body',{method:'PUT',body:bytes,headers:{
      authorization:'Bearer '+actor.token,'x-app-session':actor.session,'content-type':'image/jpeg',
    }});
    assert.equal(put.status,200);
    assert.equal((await api('/v1/uploads/'+id+'/complete',{...actor,method:'POST'})).status,200);
    return id;
  }
  const fixtureBytes=syntheticJpeg(128,84,25);
  const media=await fixtureUpload('post',fixtureBytes);
  await fixtureUpload('thumbnail',syntheticJpeg(64,42,25),media);
  const withPhoto=await create(auth,{body:'写真の投稿',tags:['光の記録'],attachments:[media]});
  assert.equal(withPhoto.status,201);
  const photoPath='/v1/media/'+media+'?parent=post&parent_id='+withPhoto.result.id+'&variant=full';
  const fromSecond=await fetch(base+photoPath,{headers:{
    authorization:'Bearer '+outsiderAuth.token,'x-app-session':outsiderAuth.session,
  }});
  assert.equal(fromSecond.status,200);
  assert.deepEqual(await fromSecond.arrayBuffer(),fixtureBytes);
  const thirdMail='third-'+random().toLowerCase()+'@example.invalid';
  const third=await firebase('signUp',{email:thirdMail,password,returnSecureToken:true});
  assert.equal(third.status,200);
  assert.equal((await firebase('sendOobCode',{requestType:'VERIFY_EMAIL',idToken:third.result.idToken})).status,200);
  const thirdCodes=(await ask(h+'/emulator/v1/projects/'+demoProject+'/oobCodes')).result.oobCodes;
  const thirdCode=thirdCodes.find(item=>item.email===thirdMail&&item.requestType==='VERIFY_EMAIL').oobCode;
  assert.equal((await firebase('update',{oobCode:thirdCode})).status,200);
  const thirdToken=(await refresh(third.result.refreshToken)).result.id_token;
  const thirdIssued=await issue(thirdToken,random());
  const thirdAuth={token:thirdToken,session:thirdIssued.result.sessionToken};
  assert.equal((await api('/v1/me/terms',{...thirdAuth,method:'POST',body:{version:policy.version,documents}})).status,200);
  assert.equal((await api('/v1/me',{...thirdAuth,method:'PATCH',headers:{'if-match':'"1"'},body:{nickname:'合成の読者'}})).status,200);
  const favorite=async(actor,kind,id,method='PUT')=>api('/v1/favorites/'+kind+'/'+id,{...actor,method});
  const search=async(actor,kind,q)=>api('/v1/search?kind='+kind+'&q='+encodeURIComponent(q),actor);
  const makeFolder=async(actor,title)=>{
    const result=await api('/v1/collections',{...actor,method:'POST',body:{id:globalThis.crypto.randomUUID(),title}});
    assert.equal(result.status,201,JSON.stringify(result));
    return result.result.id;
  };
  const save=async(actor,folder,body)=>api('/v1/collections/'+folder+'/entries',{...actor,method:'POST',body});
  const album=syntheticAlbum;
  const discoveryPost=withPhoto.result.id;
  const secondFolder=await makeFolder(outsiderAuth,'写真のしおり');
  assert.equal((await search(outsiderAuth,'post','真の投')).result.items[0].id,discoveryPost);
  assert.equal((await search(outsiderAuth,'tag','ｃａ')).result.items[0].label.toLowerCase(),'cafe');
  assert.equal((await search(thirdAuth,'member','青い')).result.items[0].id,outsiderIssue.result.profile.id);
  assert.equal((await search(outsiderAuth,'album','色のさ')).result.items[0].id,album);
  const sameFavorite=await Promise.all([favorite(outsiderAuth,'post',discoveryPost),favorite(outsiderAuth,'post',discoveryPost)]);
  assert.ok(sameFavorite.every(value=>value.result.saved===true&&value.result.createdAt===sameFavorite[0].result.createdAt));
  assert.equal((await favorite(outsiderAuth,'member',post.result.authorId)).result.saved,true);
  assert.equal((await favorite(outsiderAuth,'tag',withPhoto.result.tags[0].id)).result.saved,true);
  assert.equal((await api('/v1/favorites?kind=post',outsiderAuth)).result.items.length,1);
  const favoriteFeed=(await api('/v1/posts?category=favorites',outsiderAuth)).result.items;
  assert.equal(favoriteFeed.filter(row=>row.id===discoveryPost).length,1);
  const saved=await save(outsiderAuth,secondFolder,{postId:discoveryPost,photoId:media});
  assert.equal(saved.status,201,JSON.stringify(saved));
  assert.equal((await save(outsiderAuth,secondFolder,{postId:discoveryPost,photoId:media})).result.id,saved.result.id);
  const whole=await save(outsiderAuth,secondFolder,{postId:discoveryPost});
  assert.equal(whole.status,201);
  const moveTo=await makeFolder(outsiderAuth,'投稿の保管');
  assert.equal((await api('/v1/collections/'+secondFolder+'/entries',{...outsiderAuth,method:'PATCH',
    body:{ids:[whole.result.id],destination:moveTo}})).result.moved,1);
  assert.equal((await api('/v1/collections/'+moveTo,outsiderAuth)).result.items[0].postId,discoveryPost);
  assert.equal((await save(thirdAuth,secondFolder,{postId:discoveryPost})).status,404);
  assert.equal((await api('/v1/collections/'+secondFolder,thirdAuth)).status,404);
  assert.equal((await api('/v1/me',{...outsiderAuth,method:'PATCH',headers:{'if-match':'"2"'},
    body:{nickname:'青いノート',collectionPublic:true}})).status,200);
  assert.equal((await api('/v1/collections/'+secondFolder,thirdAuth)).result.items[0].photoId,media);
  assert.equal((await api('/v1/collections/'+secondFolder,outsiderAuth)).result.items[0].attachable,false);
  const ownerFolder=await makeFolder(auth,'作った写真');
  assert.equal((await save(auth,ownerFolder,{postId:discoveryPost,photoId:media})).status,201);
  assert.equal((await api('/v1/collections/'+ownerFolder,auth)).result.items[0].attachable,true);
  const reused=await create(auth,{body:'同じ写真の参照',tags:[],attachments:[media]});
  assert.equal(reused.status,201,JSON.stringify(reused));
  assert.equal((await save(outsiderAuth,secondFolder,{albumId:album})).status,201);
  assert.equal((await api('/v1/gallery/'+album+'/collectors',thirdAuth)).result.items[0].id,outsiderIssue.result.profile.id);
  const albumQuote=await create(thirdAuth,{body:'',tags:[],quoteAlbumId:album});
  assert.equal(albumQuote.status,201,JSON.stringify(albumQuote));
  assert.equal(albumQuote.result.albumQuote.id,album);
  assert.equal((await api('/v1/posts?album='+album,thirdAuth)).result.items[0].id,albumQuote.result.id);
  assert.equal((await api('/v1/me/recents/'+album,{...outsiderAuth,method:'PUT'})).status,204);
  assert.equal((await api('/v1/me/recents',outsiderAuth)).result.items[0].id,album);
  assert.equal((await api('/v1/me/recents',thirdAuth)).result.items.length,0);
  assert.equal((await api('/v1/me/recents/'+album,{...outsiderAuth,method:'DELETE'})).status,204);

  const commentPath='/v1/posts/'+withPhoto.result.id+'/comments';
  const root=await api(commentPath,{...outsiderAuth,method:'POST',headers:{'idempotency-key':random()},body:{body:'合成のコメント'}});
  assert.equal(root.status,201);
  const replyMedia=await fixtureUpload('comment',fixtureBytes,undefined,thirdAuth);
  await fixtureUpload('thumbnail',syntheticJpeg(64,42,82),replyMedia,thirdAuth);
  const reply=await api(commentPath,{...thirdAuth,method:'POST',headers:{'idempotency-key':random()},
    body:{parentId:root.result.id,photoId:replyMedia}});
  assert.equal(reply.status,201);
  const replyPath='/v1/comments/'+reply.result.id;
  const replyAsset='/v1/media/'+replyMedia+'?parent=comment&parent_id='+reply.result.id+'&variant=thumb';
  const thumb=await fetch(base+replyAsset,{headers:{authorization:'Bearer '+auth.token,'x-app-session':auth.session}});
  assert.equal(thumb.status,200);
  assert.ok((await thumb.arrayBuffer()).byteLength>0);
  assert.equal((await api('/v1/reactions/post/'+withPhoto.result.id,{...thirdAuth,method:'PUT'})).result.liked,true);
  assert.equal((await api('/v1/reactions/comment/'+root.result.id,{...thirdAuth,method:'PUT'})).result.likes,1);
  assert.equal((await api('/v1/reactions/comment/'+root.result.id,{...thirdAuth,method:'DELETE'})).result.likes,0);
  assert.equal((await api('/v1/comments/'+root.result.id,{...outsiderAuth,method:'PATCH',
    headers:{'if-match':'"1"','idempotency-key':random()},body:{body:'編集済み'}})).status,200);
  assert.equal((await api('/v1/reports',{...auth,method:'POST',body:{kind:'comment',targetId:reply.result.id,category:'other'}})).status,202);
  assert.equal((await api('/v1/me/blocks/'+thirdIssued.result.profile.id,{...auth,method:'PUT'})).status,204);
  assert.equal((await api(replyPath,auth)).status,404);
  assert.equal((await api(replyAsset,auth)).status,404);
  assert.equal((await api(replyPath,{...thirdAuth,method:'DELETE',
    headers:{'if-match':'"1"','idempotency-key':random()}})).status,409);
  assert.equal((await api(replyPath,outsiderAuth)).status,200);

  assert.equal((await api('/v1/me/blocks/'+post.result.authorId,{...outsiderAuth,method:'PUT'})).status,204);
  assert.equal((await api('/v1/posts/'+post.result.id,outsiderAuth)).status,404);
  assert.equal((await api('/v1/posts/'+quoted.result.id,outsiderAuth)).result.quote,null);
  assert.equal((await api('/v1/posts/'+quoted.result.id,auth)).status,404);
  assert.equal((await api(photoPath,outsiderAuth)).status,404);
  assert.equal((await api('/v1/favorites?kind=post',outsiderAuth)).result.items.length,0);
  assert.equal((await api('/v1/collections/'+secondFolder,thirdAuth)).result.items.some(row=>row.photoId===media),false);
  assert.equal((await api('/v1/me/blocks',outsiderAuth)).result.items[0].id,post.result.authorId);
  assert.equal((await api('/v1/me/blocks/'+outsiderIssue.result.profile.id,{...auth,method:'PUT'})).status,204);
  assert.equal((await api('/v1/me/blocks/'+post.result.authorId,{...outsiderAuth,method:'DELETE'})).status,204);
  assert.equal((await api('/v1/posts/'+discoveryPost,outsiderAuth)).status,404);
  assert.equal((await search(outsiderAuth,'post','真の投')).result.items.length,0);
  assert.equal((await api('/v1/me/blocks/'+outsiderIssue.result.profile.id,{...auth,method:'DELETE'})).status,204);
  assert.equal((await fetch(base+photoPath,{headers:{authorization:'Bearer '+outsiderAuth.token,'x-app-session':outsiderAuth.session}})).status,200);
  assert.equal((await api('/v1/posts/'+withPhoto.result.id,{...auth,method:'DELETE',
    headers:{'if-match':'"1"','idempotency-key':random()}})).status,204);
  assert.equal((await api(photoPath,auth)).status,404);
  const reusedPath='/v1/media/'+media+'?parent=post&parent_id='+reused.result.id+'&variant=full';
  assert.equal((await api(reusedPath,outsiderAuth)).status,404);
  assert.deepEqual((await api('/v1/posts/'+reused.result.id,outsiderAuth)).result.photos,[]);
  assert.equal((await create(auth,{body:'利用できない写真の再登録',tags:[],attachments:[media]})).status,409);
const seeded=await api('/v1/gallery/'+syntheticAlbum,outsiderAuth);
  assert.equal(seeded.status,200);
  assert.equal(seeded.result.photos.length,3);
  const albumJpeg=await fetch(base+'/v1/media/'+seeded.result.photos[0]+'?parent=album&parent_id='+syntheticAlbum+'&variant=thumb',{headers:{
    authorization:'Bearer '+outsiderAuth.token,'x-app-session':outsiderAuth.session,
  }});
  assert.equal(albumJpeg.status,200);
  assert.ok((await albumJpeg.arrayBuffer()).byteLength>0);
  const deleteKey=random();
  const remove=()=>api('/v1/posts/'+post.result.id,{...auth,method:'DELETE',headers:{'idempotency-key':deleteKey,'if-match':'"1"'}});
  assert.equal((await remove()).status,204);
  assert.equal((await remove()).status,204);
  assert.equal((await create(auth,postInput,keyForPost)).status,404);
  const reset=()=>api('/v1/auth/email',{method:'POST',body:{kind:'reset',email}});
  const unrelated=await api('/v1/auth/email',{method:'POST',body:{kind:'reset',email:'unknown@example.invalid'}});
  assert.equal(unrelated.status,202);
  const sent=await reset();
  assert.deepEqual(sent,unrelated);
  assert.equal((await reset()).status,429);
  const resetCode=await oob('PASSWORD_RESET');
  assert.equal((await firebase('resetPassword',{oobCode:'not-valid'})).status,400);
  assert.equal((await firebase('resetPassword',{oobCode:resetCode})).status,200);
  await new Promise(resolve=>globalThis.setTimeout(resolve,1100));
  const replacement='New-synthetic-'+random();
  assert.equal((await firebase('resetPassword',{oobCode:resetCode,newPassword:replacement})).status,200);
  assert.equal((await firebase('resetPassword',{oobCode:resetCode,newPassword:replacement})).status,400);
  assert.equal((await phase()).status,401);
  const fresh=await firebase('signInWithPassword',{email,password:replacement,returnSecureToken:true});
  assert.equal(fresh.status,200);
  assert.equal((await api('/v1/me/session',{token:fresh.result.idToken,session:primary})).status,401);
  const freshApp=await issue(fresh.result.idToken,random());
  assert.equal(freshApp.result.profile.memberNumber,first.result.profile.memberNumber);
  assert.equal((await api('/v1/sessions/'+freshApp.result.session.id,{
    token:fresh.result.idToken,session:freshApp.result.sessionToken,method:'DELETE',
  })).status,204);
  assert.equal((await api('/v1/me/session',{
    token:fresh.result.idToken,session:freshApp.result.sessionToken,
  })).status,401);
  globalThis.console.log('Firebase / workerd / D1: concurrent enrollment, OOB and renewals, account isolation, profile conflicts, password-reset, device revocation, community, R2 photo visibility, three-member interactions, discovery, folder privacy and original-photo revocation passed');
} finally {
  await worker.close();
}
