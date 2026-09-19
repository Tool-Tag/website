(function(root){
'use strict';
function validate(row){
 if(!row||typeof row!=='object')throw Error('Registro inválido');
 const out={};
 if(row.contentType!==undefined&&row.contentType!==''){
  if(!['Letras','Imagen'].includes(row.contentType))throw Error('Tipo inválido');out.contentType=row.contentType;
  if(row.contentType==='Letras'){if(!['Fill','Line'].includes(row.mode))throw Error('Elige Fill o Line');out.mode=row.mode;}
 }

 for(const [key,max] of Object.entries({id:100,title:120,notes:2000})){
  if(typeof row[key]!=='string'||row[key].length>max)throw Error('Campo inválido: '+key);
  out[key]=row[key].trim();
 }
 if(!out.id||!out.title)throw Error('Escribe un título');
 for(const key of ['letters','letterHeight','frameWidth','frameHeight','seconds']){
  const value=row[key];
  if(row.contentType==='Imagen'&&['letters','letterHeight'].includes(key)&&(value===undefined||value===''))continue;
  if(!['number','string'].includes(typeof value)||String(value).trim()===''||!Number.isFinite(Number(value))||Number(value)<=0)throw Error('Revisa las medidas, cantidad y tiempo');
  out[key]=Number(value);
 }
 if((out.letters!==undefined&&!Number.isSafeInteger(out.letters))||!Number.isSafeInteger(out.seconds))throw Error('Cantidad de letras y segundos deben ser enteros');
 return out;
}
function parse(text){const data=JSON.parse(text);if(!data||data.app!=='tooltag-times'||data.version!==1||!Array.isArray(data.rows)||data.rows.length>5000)throw Error('Respaldo de Tiempos inválido');const rows=data.rows.map(validate);if(new Set(rows.map(r=>r.id)).size!==rows.length)throw Error('IDs duplicados');return rows;}
function encode(rows){return JSON.stringify({app:'tooltag-times',version:1,rows},null,2);}
function duration(minutes,seconds){
 const m=minutes===''?0:Number(minutes),s=seconds===''?0:Number(seconds);
 if(!Number.isSafeInteger(m)||m<0||!Number.isSafeInteger(s)||s<0||s>59||!Number.isSafeInteger(m*60+s)||m*60+s<=0)throw Error('Tiempo: minutos enteros y segundos de 0 a 59, mayor que cero');
 return m*60+s;
}
const api={validate,parse,encode,duration};if(typeof module!=='undefined')module.exports=api;else root.TimesData=api;
})(typeof window!=='undefined'?window:globalThis);
