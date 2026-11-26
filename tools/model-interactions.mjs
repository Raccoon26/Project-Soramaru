import process from 'node:process';
import { pathToFileURL } from 'node:url';
import { photoDay,photoStorage } from './model-photos.mjs';

const scenarios={
  ordinary:['일반','ordinary',.30,[2.8,.28,.18,1.7,.20,.04,.12]],
  official:['공식 공개','album',.72,[5.7,.6,.40,5,.40,.08,.16]],
  occasion:['기념일','album',.75,[6.5,1.8,1.4,6,.80,.18,.30]],
  comments:['댓글 집중','ordinary',.64,[6.5,3.1,2.9,4,.50,.12,.65]],
  likes:['좋아요 집중','ordinary',.64,[4.6,.40,.60,18,2.8,.06,.22]],
  photos:['사진 댓글 집중','photos',.62,[5,1.8,.90,5,.60,.70,.22]],
  stamps:['스탬프 집중','ordinary',.63,[6,2,1.5,4,.60,.08,1.5]],
  events:['알림 이벤트 집중','ordinary',.65,[4,1.8,1.1,8,1.10,.11,.32]],
};

export function day(mau,scenario) {
  const [label,baseCase,active,pattern]=scenarios[scenario];
  const base=photoDay(mau,baseCase),dau=Math.ceil(mau*active);
  const [pages,comments,replies,likes,unlikes,photos,catalog]=pattern.map(factor=>Math.ceil(dau*factor));
  const readRequests=pages+catalog+photos*3;
  const writes=comments+replies;
  const events=Math.ceil((writes+likes)*.75);
  // Calibrated to the indexed local fixture for one 20-row page (248 reads).
  // Rounded mutation assumptions include policy, rate and outbox overhead.
  const indexWrites=2*writes+3*(likes+unlikes)+2*events;
  const d1Write=base.writes+Math.ceil(readRequests/4)*11+24*writes+14*(likes+unlikes)+98*photos+indexWrites;
  const d1Read=base.reads+248*pages+60*catalog+145*writes+128*(likes+unlikes)+580*photos;
  return {label,dau,requests:base.requests+readRequests+writes+likes+unlikes+6*photos,
    d1Read,d1Write,indexWrites,r2A:base.r2A+4*photos,r2B:base.r2B+5*photos,events};
}

export function storage(mau,month) {
  const base=photoStorage(mau,month);
  const comments=.3*mau*(.28+.18)*30;
  const reactions=.3*mau*1.7*30;
  const commentPhotos=.3*mau*.04*30;
  const activityGB=(.00000095*comments+.00000029*reactions)*month;
  const outboxGB=(comments+.72*reactions)*.0000014*month;
  const mediaGB=.00036*commentPhotos*month;
  const r2Average=base.avg+mediaGB*(month-.5)/month+.00054*commentPhotos+
    2*(activityGB+outboxGB);
  const total=r2Average+(base.d1/1000)+activityGB+outboxGB;
  const r2OnlyYen=Math.ceil(160*.015*Math.max(0,Math.ceil(r2Average)-10));
  return {total,r2Average,mediaGB,activityGB,outboxGB,d1:base.d1/1000+activityGB+outboxGB,r2OnlyYen};
}

if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url) {
  const values=[100,500,1000,5000];
  globalThis.console.log('| MAU | 시나리오 | DAU | Workers/일 | D1 읽기/일 | D1 쓰기/일 | 추가 인덱스/일 | R2 A/B 일 | Outbox/일 |');
  globalThis.console.log('|---:|---|---:|---:|---:|---:|---:|---:|---:|');
  for(const size of values) for(const scenario of Object.keys(scenarios)) {
    const d=day(size,scenario);
    globalThis.console.log('| '+[size,d.label,d.dau,d.requests,d.d1Read,d.d1Write,d.indexWrites,d.r2A+'/'+d.r2B,d.events].join(' | ')+' |');
  }
  globalThis.console.log('\n| MAU | 1개월 | 6개월 | 12개월 | 24개월 | 36개월 | 60개월 | 60개월 댓글 미디어 GB | 60개월 Outbox GB | 60개월 R2 과금 예시 |');
  globalThis.console.log('|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|');
  for(const size of values) {
    const end=storage(size,60);
    globalThis.console.log('| '+[size,...[1,6,12,24,36,60].map(month=>storage(size,month).total.toFixed(2)),
      end.mediaGB.toFixed(2),end.outboxGB.toFixed(2),end.r2OnlyYen+'엔'].join(' | ')+' |');
  }
}
