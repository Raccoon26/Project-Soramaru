import process from 'node:process';
import { performance } from 'node:perf_hooks';
import { readdir,stat } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath,URL } from 'node:url';
import { simulator } from './local-backend.mjs';
import { normalizeSearch } from '../services/api/src/search-index.ts';

const limit=160;
const short='東京';
const term='夜空観察';
const samples=['東京の公園を歩く','白い雲と夜空観察の計画','カフェで日本語のノートを書く','夜空観察のしおり','静かな朝に한글を読む','ＣＡＦＥで話す'];
const sizes=process.argv.slice(2).map(Number);
const words=text=>{
  const points=[...text];
  return [...new Set(points.slice(0,-2).map((_,i)=>points.slice(i,i+3).join('')))].slice(0,32);
};
const variants={
  prefix:{
    setup:['CREATE TABLE item(id INTEGER PRIMARY KEY, text TEXT NOT NULL, active INTEGER NOT NULL)',
      'CREATE INDEX item_text ON item(text,id)'],
    index:[],
    match:"SELECT id FROM item WHERE active=1 AND text>=? AND text<? ORDER BY text,id LIMIT "+limit,
    parameters:[term,term+'\u{10ffff}'],
    inspect:'SELECT i.text FROM item i WHERE i.id=?',
    update:[],
    remove:[],
  },
  trigram:{
    setup:['CREATE TABLE item(id INTEGER PRIMARY KEY, text TEXT NOT NULL, active INTEGER NOT NULL)',
      'CREATE VIRTUAL TABLE search_text USING fts5(text,tokenize=trigram)'],
    index:["INSERT INTO search_text(rowid,text) SELECT value->>0,value->>1 FROM json_each(?)"],
    match:"SELECT s.rowid AS id FROM search_text s JOIN item i ON i.id=s.rowid WHERE search_text MATCH ? AND i.active=1 ORDER BY s.rowid DESC LIMIT "+limit,
    parameters:['"'+term+'"'],
    inspect:'SELECT text FROM search_text WHERE rowid=?',
    update:['DELETE FROM search_text WHERE rowid=?','INSERT INTO search_text(rowid,text) VALUES (?,?)'],
    remove:['DELETE FROM search_text WHERE rowid=?'],
  },
  grams:{
    setup:['CREATE TABLE item(id INTEGER PRIMARY KEY, text TEXT NOT NULL, active INTEGER NOT NULL)',
      'CREATE TABLE gram(fragment TEXT NOT NULL,id INTEGER NOT NULL,PRIMARY KEY(fragment,id)) WITHOUT ROWID',
      'CREATE INDEX gram_post ON gram(id)'],
    index:['INSERT INTO gram SELECT gram.value,post.value->>0 FROM json_each(?) post JOIN json_each(post.value->2) gram'],
    match:"SELECT g.id FROM gram g JOIN item i ON i.id=g.id WHERE g.fragment=? AND instr(i.text,?)>0 AND i.active=1 ORDER BY g.id DESC LIMIT "+limit,
    parameters:[[...term].slice(0,3).join(''),term],
    inspect:'SELECT fragment FROM gram WHERE id=?',
    update:['DELETE FROM gram WHERE id=?','INSERT INTO gram SELECT value,?1 FROM json_each(?2)'],
    remove:['DELETE FROM gram WHERE id=?'],
  },
};
const total=(rows,field)=>rows.reduce((sum,row)=>sum+(row.meta[field]??0),0);
const percentile=(samples,p)=>Math.round(samples.toSorted((a,b)=>a-b)[Math.ceil(samples.length*p)-1]*100)/100;

async function run(size,mode,config) {
  const slot=globalThis.crypto.randomUUID();
  const root=fileURLToPath(new URL('../.local/backend/test-'+slot+'/v3/',import.meta.url));
  const runtime=simulator('test',{persist:true,slot});
  let closed=false;
  try {
    const db=await runtime.getD1Database('DB');
    const prepare=(sql,...args)=>db.prepare(sql).bind(...args);
    const start=performance.now();
    await db.batch(config.setup.map(sql=>prepare(sql)));
    let writes=0;
    for(let base=0;base<size;base+=200) {
      const part=Array.from({length:Math.min(200,size-base)},(_,i)=>{
        const index=base+i;
        const text=normalizeSearch(samples[index%samples.length]+' 合成記録 '+index);
        return [index+1,text,words(text),index%13!==0?1:0];
      });
      const body=JSON.stringify(part);
      const insert=prepare('INSERT INTO item SELECT value->>0,value->>1,value->>3 FROM json_each(?)',body);
      writes+=total(await db.batch([insert,...config.index.map(sql=>prepare(sql,body))]),'rows_written');
    }
    const buildMs=Math.round(performance.now()-start);
    const timings=[];
    let hit=0,readRows=0,interior=false;
    const baseline=(await prepare("SELECT count(*) AS n FROM item WHERE active=1 AND instr(text,?)>0",term).first()).n;
    for(let i=0;i<15;i++) {
      const tick=performance.now();
      const result=await prepare(config.match,...config.parameters).all();
      timings.push(performance.now()-tick);
      hit=result.results.length;
      readRows=result.meta.rows_read;
      if(!interior) {
        const candidates=await prepare("SELECT id FROM item WHERE active=1 AND instr(text,?)>1 ORDER BY id DESC LIMIT ?",term,limit).all();
        const ids=new Set(candidates.results.map(row=>row.id));
        interior=result.results.some(row=>ids.has(row.id));
      }
    }
    const revised='東京の朝は静かです';
    const cpu=process.cpuUsage();
    const edited=await db.batch([
      prepare('UPDATE item SET text=? WHERE id=4',revised),
      ...config.update.map((sql,i)=>i===0?prepare(sql,4):prepare(sql,4,mode==='grams'?JSON.stringify(words(revised)):revised)),
    ]);
    const found=(await prepare(config.inspect,4).all()).results.length;
    const deleted=await db.batch([prepare('DELETE FROM item WHERE id=4'),...config.remove.map(sql=>prepare(sql,4))]);
    const deletedClean=(await prepare(config.inspect,4).all()).results.length===0;
    const used=process.cpuUsage(cpu);
    const prefixSample=(await prepare('SELECT count(*) AS n FROM item WHERE active=1 AND instr(text,?)=1',short).first()).n;
    await runtime.dispose();
    closed=true;
    const shards=(await readdir(root,{recursive:true})).filter(file=>/\.sqlite(?:-wal)?$/.test(file));
    const dbBytes=(await Promise.all(shards.map(file=>stat(join(root,file))))).reduce((total,file)=>total+file.size,0);
    return {size,mode,expectedMatches:baseline,firstWindowHits:hit,interiorMatch:interior,shortPrefixFixtures:prefixSample,
      readRows,writeRows:writes,dbBytes,buildMs,
      p50ms:percentile(timings,.5),p95ms:percentile(timings,.95),updateRows:total(edited,'rows_written'),
      deleteRows:total(deleted,'rows_written'),updateRecorded:found>0,deletedClean,
      harnessEditDeleteCpuMs:Math.round((used.user+used.system)/100)/10};
  } finally { if(!closed) await runtime.dispose(); }
}

for(const size of sizes.length?sizes:[2000,10000,50000]) {
  if(!Number.isInteger(size)||size<100||size>50000)throw new Error('Use dataset sizes from 100 to 50,000');
  for(const [mode,config] of Object.entries(variants)) globalThis.console.log(JSON.stringify(await run(size,mode,config)));
}
