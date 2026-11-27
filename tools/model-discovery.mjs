import process from 'node:process';
import { pathToFileURL } from 'node:url';
import { day as interactionsDay,storage as interactionsStorage } from './model-interactions.mjs';
import { photoStorage } from './model-photos.mjs';

export const scenarios={
  ordinary:['일반','ordinary',.30,[.22,.10,.60,.12,.10,.06]],
  official:['공식 게시물 공개','official',.72,[.65,.30,1.30,.30,.22,.07]],
  occasion:['기념일','occasion',.75,[.72,.36,1.60,.40,.35,.14]],
  comments:['댓글 집중','comments',.64,[.38,.18,.90,.22,.12,.06]],
  likes:['좋아요 집중','likes',.64,[.30,.14,1.30,.35,.12,.05]],
  photos:['사진 댓글 집중','photos',.62,[.50,.18,1.10,.24,.18,.30]],
  search:['검색 집중','ordinary',.62,[6,.3,1.3,.32,.21,.15]],
  popular:['인기 태그 집계','ordinary',.55,[1.2,2,1.2,.32,.15,.12]],
  gallery:['공식 갤러리 공개','official',.72,[1.3,.25,2.2,.65,1.7,3]],
  collections:['컬렉션 이용 집중','ordinary',.55,[.70,.24,4.3,1.9,.45,2.2]],
};
const members=[100,500,1000,5000];
const horizons=[1,6,12,24,36,60];

export function discoveryDay(mau,scenario) {
  const [label,old,activity,coefficients]=scenarios[scenario];
  const active=Math.ceil(activity*mau);
  const base=interactionsDay(mau,old);
  const [search,popular,reads,saves,visits,photos]=coefficients.map(rate=>Math.ceil(active*rate));
  const indexWrites=base.indexWrites+2*saves+visits+Math.ceil(active*.32);
  const admitted=search+popular+saves+visits+Math.ceil((reads+photos)/4);
  return {label,active,concurrent:Math.ceil(active*.18*8/60),
    requests:base.requests+search+popular+reads+saves+visits+2*photos,
    d1Read:base.d1Read+480*search+650*popular+150*reads+170*saves+140*visits+95*photos+96*24,
    d1Write:base.d1Write+11*admitted+4*saves+2*visits+indexWrites-base.indexWrites+100,
    indexWrites,r2A:base.r2A,r2B:base.r2B+2*photos,events:base.events};
}
export function discoveryStorage(mau,month) {
  const base=interactionsStorage(mau,month);
  const media=photoStorage(mau,month);
  const searchGB=.00000072*mau*3*month;
  const privateRefsGB=.00000024*mau*Math.min(4*month,250);
  const recentsGB=.00000016*mau*Math.min(2*month,100);
  const retainedOutboxGB=base.outboxGB/month;
  const d1GB=base.d1-base.outboxGB+retainedOutboxGB+searchGB+privateRefsGB+recentsGB;
  const savingGB=2*(base.outboxGB-retainedOutboxGB);
  const r2Avg=Math.max(0,base.r2Average-savingGB);
  const r2End=r2Avg+(media.end-media.avg)+base.mediaGB/(2*month);
  const usd=.015*Math.max(0,Math.ceil(r2Avg)-10);
  return {searchGB,privateRefsGB,recentsGB,retainedOutboxGB,d1GB,r2Avg,r2End,
    d1PendingGB:d1GB+base.outboxGB-retainedOutboxGB,jpy:Math.ceil(160*usd)};
}

if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url) {
  globalThis.console.log('| MAU | 부하 | DAU/동시 | Workers/일 | D1 읽기/일 | D1 쓰기/일 | 인덱스 쓰기/일 | R2 A/B 일 | Outbox/일 |');
  globalThis.console.log('|---:|---|---:|---:|---:|---:|---:|---:|---:|');
  for(const mau of members) for(const scenario of Object.keys(scenarios)) {
    const d=discoveryDay(mau,scenario);
    globalThis.console.log('| '+[mau,d.label,d.active+'/'+d.concurrent,d.requests,d.d1Read,d.d1Write,d.indexWrites,d.r2A+'/'+d.r2B,d.events].join(' | ')+' |');
  }
  globalThis.console.log('\n| MAU | 월 | R2 월말 GB | R2 평균 GB-month | D1 GB 전달/미전달 | 검색 GB | 즐겨찾기·컬렉션 GB | 최근 GB | 완료 Outbox GB | R2 엔/월 |');
  globalThis.console.log('|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|');
  for(const mau of members) for(const month of horizons) {
    const s=discoveryStorage(mau,month);
    globalThis.console.log('| '+[mau,month,s.r2End.toFixed(3),s.r2Avg.toFixed(3),s.d1GB.toFixed(3)+'/'+s.d1PendingGB.toFixed(3),
      s.searchGB.toFixed(3),s.privateRefsGB.toFixed(3),s.recentsGB.toFixed(4),s.retainedOutboxGB.toFixed(3),s.jpy].join(' | ')+' |');
  }
}
