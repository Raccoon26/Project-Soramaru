import process from 'node:process';
import { pathToFileURL } from 'node:url';
import { encode } from 'jpeg-js';
import { migrate,simulator } from './local-backend.mjs';
import { MediaStore } from '../services/api/src/media.ts';
import { inspectPhoto } from '../services/api/src/photo-format.ts';
import { indexedText } from '../services/api/src/search-index.ts';
import { query,digest } from '../services/api/src/platform.ts';

export function syntheticJpeg(width=128,height=84,shade=0,quality=86) {
  const data=new Uint8Array(width*height*4);
  for(let y=0;y<height;y++)for(let x=0;x<width;x++){
    const i=(y*width+x)*4;
    data[i]=(x+2*y+shade)%256;
    data[i+1]=(3*x+y+shade)%256;
    data[i+2]=(x*y+shade)%256;
    data[i+3]=255;
  }
  const coded=encode({width,height,data},quality).data;
  return Uint8Array.from(coded).buffer;
}

const base='06900000-0000-4000-8000-';
export const syntheticAlbum=base+'000000000006';

export async function seedPhotos(env,now=Date.now()) {
  const DB=env.DB;
  const ids=[1,2,3].map(n=>base+String(n).padStart(12,'0'));
  const [artist,grantor,reviewer]=ids;
  const identity=base+'000000000004';
  const role=base+'000000000005';
  if((await query(DB,'SELECT id FROM content_items WHERE id=?',syntheticAlbum).first())!==null)return {id:syntheticAlbum};
  await DB.batch(ids.flatMap((id,i)=>[
    query(DB,'INSERT INTO member_numbers VALUES (?,0) ON CONFLICT DO NOTHING','PICFIX000'+i),
    query(DB,"INSERT INTO members(id,auth_uid,member_no,state,joined_at,updated_at) VALUES (?,NULL,?,'active',0,0) ON CONFLICT DO NOTHING",id,'PICFIX000'+i),
    query(DB,"INSERT INTO member_profiles(member_id,nickname,updated_at,configured_at) VALUES (?,'合成写真担当',0,0) ON CONFLICT DO NOTHING",id),
  ]));
  await DB.batch([
    query(DB,"INSERT INTO official_identities VALUES (?,?,'合成アーティスト',1) ON CONFLICT DO NOTHING",identity,artist),
    query(DB,"INSERT INTO role_grants VALUES (?,?,'artist',?,?,0,NULL,NULL) ON CONFLICT DO NOTHING",role,artist,grantor,reviewer),
  ]);
  const owner={id:artist,sessionId:artist,role:'artist'};
  const store=new MediaStore(env,()=>now);
  const attach=[];
  for(let i=0;i<3;i++){
    let variant=null;
    for(const purpose of ['gallery','thumbnail']){
      const bytes=syntheticJpeg(purpose==='gallery'?320:180,purpose==='gallery'?240:135,i*54);
      const meta=await store.reserve(owner,'fixture-gallery-'+i+'-'+purpose,bytes.byteLength,'image/jpeg',
        {purpose,hash:await digest(bytes),variant});
      if(meta.state==='reserved')await store.quarantine(owner,meta.id,bytes);
      await store.approve(owner,meta.id,async data=>inspectPhoto(data,purpose));
      if(purpose==='gallery'){variant=meta.id;attach.push(meta.id);}
    }
  }
  await DB.batch([
    query(DB,"INSERT INTO content_items VALUES (?,?,'gallery','光と色のサンプル','approved','members',?,?,?,1)",
      syntheticAlbum,artist,now,now,now),
    query(DB,"INSERT INTO photo_albums VALUES (?,?,'synthetic')",syntheticAlbum,identity),
    indexedText(DB,'album',syntheticAlbum,'光と色のサンプル',1),
    ...attach.map((id,i)=>query(DB,'INSERT INTO photo_album_items VALUES (?,?,?)',syntheticAlbum,id,i)),
  ]);
  return {id:syntheticAlbum,photos:attach,artist};
}

if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href) {
  const runtime=simulator('local',{persist:true});
  try {
    const DB=await runtime.getD1Database('DB');
    await migrate(DB);
    await seedPhotos({APP_ENV:'local',DB,PRIVATE_MEDIA:await runtime.getR2Bucket('PRIVATE_MEDIA'),QUARANTINE:await runtime.getR2Bucket('QUARANTINE')});
    globalThis.console.log('Local synthetic gallery ready');
  } finally {await runtime.dispose();}
}
