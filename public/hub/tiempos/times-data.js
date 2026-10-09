(function(root){
'use strict';
function validate(row){
 if(!row||typeof row!=='object')throw Error('Invalid record');
 const out={};
 if(row.contentType!==undefined&&row.contentType!==''){
  if(!['Letras','Imagen'].includes(row.contentType))throw Error('Invalid type');out.contentType=row.contentType;
  if(row.contentType==='Letras'){if(!['Fill','Line'].includes(row.mode))throw Error('Choose Fill or Line');out.mode=row.mode;}
 }

 for(const [key,max] of Object.entries({id:100,title:120,notes:2000})){
  if(typeof row[key]!=='string'||row[key].length>max)throw Error('Invalid field: '+key);
  out[key]=row[key].trim();
 }
 if(!out.id||!out.title)throw Error('Enter a title');
 for(const key of ['letters','letterHeight','frameWidth','frameHeight','seconds']){
  const value=row[key];
  if(row.contentType==='Imagen'&&['letters','letterHeight'].includes(key)&&(value===undefined||value===''))continue;
  if(!['number','string'].includes(typeof value)||String(value).trim()===''||!Number.isFinite(Number(value))||Number(value)<=0)throw Error('Review the measurements, quantity, and time');
  out[key]=Number(value);
 }
 if((out.letters!==undefined&&!Number.isSafeInteger(out.letters))||!Number.isSafeInteger(out.seconds))throw Error('Character count and seconds must be whole numbers');
 return out;
}
function parse(text){const data=JSON.parse(text);if(!data||data.app!=='tooltag-times'||data.version!==1||!Array.isArray(data.rows)||data.rows.length>5000)throw Error('Invalid Times backup');const rows=data.rows.map(validate);if(new Set(rows.map(r=>r.id)).size!==rows.length)throw Error('Duplicate IDs');return rows;}
function encode(rows){return JSON.stringify({app:'tooltag-times',version:1,rows},null,2);}
function duration(minutes,seconds){
 const m=minutes===''?0:Number(minutes),s=seconds===''?0:Number(seconds);
 if(!Number.isSafeInteger(m)||m<0||!Number.isSafeInteger(s)||s<0||s>59||!Number.isSafeInteger(m*60+s)||m*60+s<=0)throw Error('Time must use whole minutes and seconds from 0 to 59, with a total greater than zero');
 return m*60+s;
}
const api={validate,parse,encode,duration};if(typeof module!=='undefined')module.exports=api;else root.TimesData=api;
})(typeof window!=='undefined'?window:globalThis);
