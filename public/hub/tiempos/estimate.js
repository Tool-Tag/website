(function(root){
'use strict';
function positive(value){return (typeof value==='number'||typeof value==='string')&&String(value).trim()!==''&&Number.isFinite(Number(value))&&Number(value)>0;}
function letterSettings(input){if(!input||!Number.isSafeInteger(Number(input.letters))||!positive(input.letters)||!positive(input.letterHeight)||!['Fill','Line'].includes(input.mode))throw Error('Complete character count, height, and Fill / Line mode');return {letters:Number(input.letters),letterHeight:Number(input.letterHeight),mode:input.mode};}
function estimate(input,rows){
 if(!['Imagen','Letras'].includes(input.contentType)||!positive(input.frameWidth)||!positive(input.frameHeight))throw Error('Choose the type and complete the frame dimensions');
 const q={...input,frameWidth:Number(input.frameWidth),frameHeight:Number(input.frameHeight)};
 if(q.contentType==='Letras')Object.assign(q,letterSettings(q));
 const keys=q.contentType==='Imagen'?['frameWidth','frameHeight']:['frameWidth','frameHeight','letters','letterHeight'];
 const matching=rows.filter(r=>r.contentType===q.contentType&&(q.contentType!=='Letras'||r.mode===q.mode)&&positive(r.seconds)&&keys.every(k=>positive(r[k])));
 const candidates=matching.map(r=>({r,ratios:keys.map(k=>Number(q[k])/Number(r[k]))})).filter(x=>x.ratios.every(v=>v>=.25&&v<=4)).map(x=>({...x,distance:x.ratios.reduce((sum,v)=>sum+Math.abs(Math.log(v)),0)})).sort((a,b)=>a.distance-b.distance);
 if(!candidates.length)return {available:false,reason:matching.length?'No records have sufficiently similar dimensions.':'There are no records of the same type and mode yet.'};
 const exact=candidates.filter(x=>x.distance<1e-10);const selected=exact.length?exact:candidates.slice(0,3);
 const work=r=>q.contentType==='Imagen'?Number(r.frameWidth)*Number(r.frameHeight):Number(r.letters)*Number(r.letterHeight)**(q.mode==='Fill'?2:1);
 let total=0,weights=0;const projections=[];
 for(const {r,distance} of selected){const seconds=Number(r.seconds)*work(q)/work(r),weight=1/(1+distance);if(!Number.isFinite(seconds)||seconds<=0)throw Error('The dimensions are too large to calculate');total+=seconds*weight;weights+=weight;projections.push(seconds);}
 return {available:true,seconds:Math.max(1,Math.round(total/weights)),low:Math.max(1,Math.round(Math.min(...projections))),high:Math.max(1,Math.round(Math.max(...projections))),count:selected.length,exact:!!exact.length};
}
const api={estimate,letterSettings};if(typeof module!=='undefined')module.exports=api;else root.TimeEstimate=api;
})(typeof window!=='undefined'?window:globalThis);
