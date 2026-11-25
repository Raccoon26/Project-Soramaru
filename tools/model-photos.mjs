import process from 'node:process';
import { pathToFileURL } from 'node:url';
import { communityCost } from './model-community.mjs';

const scales = [100,500,1000,5000];
const periods = [1,6,12,24,36,60];
const profiles = {
  ordinary: { baseline:'ordinary', shots:.040, avatars:.004, views:12, full:1, albums:0 },
  photos: { baseline:'posting', shots:.245, avatars:.012, views:27, full:3, albums:0 },
  album: { baseline:'announcement', shots:.052, avatars:.006, views:42, full:6, albums:10 },
};

// Decimal MB and GB. Budget sizes are conservative relative to three local
// synthetic photo samples averaging 127 kB full and 16 kB thumbnail.
const pairMB = .36;
const avatarMB = .08;
const monthlyOfficialMB = 40*.40;
const monthlyVoiceMB = (40*1+30/3+2*30)*.72;
const mb = value => value/1000;

export function photoDay(mau,scenario) {
  const load=profiles[scenario];
  const base=communityCost(mau,load.baseline);
  const {dau}=base;
  const shots=Math.ceil(mau*load.shots);
  const avatars=Math.ceil(mau*load.avatars);
  const variants=2*(shots+load.albums)+avatars;
  const thumbnailReads=Math.ceil(.75*dau*load.views);
  const fullReads=Math.ceil(.85*dau*load.full);
  const galleries=Math.ceil(.5*dau);
  const grants=Math.ceil(fullReads/2);
  const mediaReads=thumbnailReads+fullReads;
  const photoRequests=3*variants+mediaReads+galleries+grants;
  // Local mixed photo fixture includes auth, budgets and rate counters. Use
  // rounded headroom per step to model account and index changes conservatively.
  const requests=800+20*dau+base.requests+photoRequests;
  const reads=base.totalReads+240*variants+62*mediaReads+90*(galleries+grants);
  const writes=base.totalWrites+62*variants+Math.ceil(mediaReads/4)*10+10*grants+3*galleries;
  return {dau,peakConcurrent:Math.ceil(dau*.18*8/60),shots,avatars,requests,reads,writes,
    r2A:45+Math.ceil(2.2*variants),r2B:200+10*dau+Math.ceil(1.25*variants)+mediaReads};
}

export function photoStorage(mau,month) {
  const monthlyFan=mau*1.2*pairMB;
  const accumulated=(monthlyFan+monthlyOfficialMB+monthlyVoiceMB)*month;
  const avatars=.6*mau*avatarMB;
  const quarantine=32+.08*mau;
  const unused=20+monthlyFan*2/30;
  const d1=30+(1.5+.006*mau)*month;
  const backup=2*d1 + 1.5*(monthlyFan+monthlyOfficialMB+monthlyVoiceMB);
  const end=mb(300+accumulated+avatars+quarantine+unused+backup);
  const avg=end-mb((monthlyFan+monthlyOfficialMB+monthlyVoiceMB+2*(1.5+.006*mau))/2);
  return {end,avg,d1,backup,quarantine,unused,avatars};
}

export function photoBill(mau,month) {
  const ordinary=photoDay(mau,'ordinary');
  const photos=photoDay(mau,'photos');
  const launch=photoDay(mau,'album');
  const storage=photoStorage(mau,month);
  const a=28*ordinary.r2A+photos.r2A+launch.r2A;
  const b=28*ordinary.r2B+photos.r2B+launch.r2B;
  const extra=(value,unit,free)=>Math.max(0,Math.ceil(value/unit)-free);
  const usd=extra(storage.avg,1,10)*.015+extra(a,1_000_000,1)*4.50+extra(b,1_000_000,10)*.36;
  return {...storage,a,b,usd,jpy:Math.ceil(160*usd)};
}

if (process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href) {
  globalThis.console.log('| MAU | 부하 | DAU / 동시 | Worker 일 | D1 읽기 일 | D1 쓰기 일 | R2 A 일 | R2 B 일 |');
  globalThis.console.log('|---:|---|---:|---:|---:|---:|---:|---:|');
  for(const n of scales)for(const name of Object.keys(profiles)){
    const r=photoDay(n,name);
    globalThis.console.log('| '+[n,{ordinary:'일반',photos:'사진 집중',album:'갤러리 공개'}[name],r.dau+' / '+r.peakConcurrent,r.requests,r.reads,r.writes,r.r2A,r.r2B].join(' | ')+' |');
  }
  globalThis.console.log('\n| MAU | 1개월 | 6개월 | 12개월 | 24개월 | 36개월 | 60개월 | A / B 월 | 60개월 D1 MB | 60개월 R2 엔/월 |');
  globalThis.console.log('|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|');
  for(const n of scales){
    const b=photoBill(n,60);
    globalThis.console.log('| '+[n,...periods.map(m=>{const s=photoStorage(n,m);return s.end.toFixed(2)+' / '+s.avg.toFixed(2);}),
      b.a+' / '+b.b,b.d1.toFixed(1),b.jpy].join(' | ')+' |');
  }
}
