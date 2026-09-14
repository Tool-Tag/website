(function(root){
'use strict';
const options={operation:['No registrado','Grabado','Marcado','Corte','Otra'],unit:['mm/min','mm/s'],air:['No registrado','Activada','Desactivada'],status:['Por probar','Probado','Validado','Referencia']};
function validate(row){
 if(!row||typeof row!=='object')throw Error('Registro inválido');
 const out={};
 if(row.contentType!==undefined&&row.contentType!==''){if(!['Imagen','Letras'].includes(row.contentType))throw Error('Tipo de contenido inválido');out.contentType=row.contentType;}
 if(row.title!==undefined){if(typeof row.title!=='string'||!row.title.trim()||row.title.length>120)throw Error('Título inválido');out.title=row.title.trim();}
 for(const [key,max] of Object.entries({id:100,material:120,machine:120,focus:120,notes:2000,date:10})){
  if(typeof row[key]!=='string'||row[key].length>max)throw Error('Campo inválido: '+key);
  out[key]=row[key].trim();
 }
 if(!out.id||!out.material||(out.date!==''&&(!/^\d{4}-\d{2}-\d{2}$/.test(out.date)||Number.isNaN(Date.parse(out.date))||new Date(out.date).toISOString().slice(0,10)!==out.date)))throw Error('Faltan datos o fecha inválida');
 for(const key of ['power','speed','passes','thickness']){
  const value=row[key];
  if(key==='thickness'&&value===''){out[key]='';continue;}
  if((typeof value!=='string'&&typeof value!=='number')||value===''||!Number.isFinite(Number(value)))throw Error('Número inválido: '+key);
  out[key]=Number(value);
 }
 if(out.power<0||out.power>100||out.speed<=0||!Number.isInteger(out.passes)||out.passes<1||(out.thickness!==''&&out.thickness<0))throw Error('Parámetros fuera de rango');
 out.interval=row.interval===undefined?'':String(row.interval);
 if(out.interval!==''&&(!Number.isFinite(Number(out.interval))||Number(out.interval)<=0))throw Error('Intervalo inválido');
 out.scan=row.scan||'No registrado';
 if(!['No registrado','Unidireccional','Bidireccional'].includes(out.scan))throw Error('Escaneo inválido');
 for(const [key,values] of Object.entries(options)){if(!values.includes(row[key]))throw Error('Opción inválida: '+key);out[key]=row[key];}
 for(const key of ['letterHeight','frameWidth','frameHeight']){
  const value=row[key];
  if(value===undefined||value==='')continue;
  if(!['string','number'].includes(typeof value)||String(value).trim()===''||!Number.isFinite(Number(value))||Number(value)<=0)throw Error('Medida inválida: '+key);
  out[key]=Number(value);
 }
 if(row.dimensionsApprox!==undefined&&row.dimensionsApprox!==''){
  if(row.dimensionsApprox!=='Aproximado')throw Error('Precisión de medidas inválida');
  out.dimensionsApprox=row.dimensionsApprox;
 }
 return out;
}
function parse(text){const data=JSON.parse(text);if(data.app!=='tooltag-falcon'||data.version!==1||!Array.isArray(data.rows)||data.rows.length>5000)throw Error('No es un respaldo válido de ToolTag Falcon');const rows=data.rows.map(validate);if(new Set(rows.map(r=>r.id)).size!==rows.length)throw Error('IDs duplicados');return rows;}
const api={validate,parse,encode:rows=>JSON.stringify({app:'tooltag-falcon',version:1,rows},null,2)};
if(typeof module!=='undefined')module.exports=api;else root.FalconData=api;
})(typeof window!=='undefined'?window:globalThis);
