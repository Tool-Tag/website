(function(root){
'use strict';
const options={operation:['No registrado','Grabado','Marcado','Corte','Otra'],unit:['mm/min','mm/s'],air:['No registrado','Activada','Desactivada'],status:['Por probar','Probado','Validado','Referencia']};
function validateLegacy(row){
 if(!row||typeof row!=='object')throw Error('Invalid record');
 const out={};
 if(row.contentType!==undefined&&row.contentType!==''){if(!['Imagen','Letras'].includes(row.contentType))throw Error('Invalid content type');out.contentType=row.contentType;}
 if(row.title!==undefined){if(typeof row.title!=='string'||!row.title.trim()||row.title.length>120)throw Error('Invalid title');out.title=row.title.trim();}
 for(const [key,max] of Object.entries({id:100,material:120,machine:120,focus:120,notes:2000,date:10})){
  if(typeof row[key]!=='string'||row[key].length>max)throw Error('Invalid field: '+key);
  out[key]=row[key].trim();
 }
 if(!out.id||!out.material||(out.date!==''&&(!/^\d{4}-\d{2}-\d{2}$/.test(out.date)||Number.isNaN(Date.parse(out.date))||new Date(out.date).toISOString().slice(0,10)!==out.date)))throw Error('Missing data or invalid date');
 for(const key of ['power','speed','passes','thickness']){
  const value=row[key];
  if(key==='thickness'&&value===''){out[key]='';continue;}
  if((typeof value!=='string'&&typeof value!=='number')||value===''||!Number.isFinite(Number(value)))throw Error('Invalid number: '+key);
  out[key]=Number(value);
 }
 if(out.power<0||out.power>100||out.speed<=0||!Number.isInteger(out.passes)||out.passes<1||(out.thickness!==''&&out.thickness<0))throw Error('Parameters are out of range');
 out.interval=row.interval===undefined?'':String(row.interval);
 if(out.interval!==''&&(!Number.isFinite(Number(out.interval))||Number(out.interval)<=0))throw Error('Invalid interval');
 out.scan=row.scan||'No registrado';
 if(!['No registrado','Unidireccional','Bidireccional'].includes(out.scan))throw Error('Invalid scan mode');
 for(const [key,values] of Object.entries(options)){if(!values.includes(row[key]))throw Error('Invalid option: '+key);out[key]=row[key];}
 for(const key of ['letterHeight','frameWidth','frameHeight']){
  const value=row[key];
  if(value===undefined||value==='')continue;
  if(!['string','number'].includes(typeof value)||String(value).trim()===''||!Number.isFinite(Number(value))||Number(value)<=0)throw Error('Invalid measurement: '+key);
  out[key]=Number(value);
 }
 if(row.dimensionsApprox!==undefined&&row.dimensionsApprox!==''){
  if(row.dimensionsApprox!=='Aproximado')throw Error('Invalid measurement precision');
  out.dimensionsApprox=row.dimensionsApprox;
 }
 return out;
}
const generalKeys=['id','title','material','thickness','machine','status','date','notes'];
const elementKeys=['contentType','operation','power','speed','unit','passes','interval','scan','air','focus','letterHeight','frameWidth','frameHeight','dimensionsApprox','notes'];
function validateElement(element){
 if(!element||!['Imagen','Letras'].includes(element.contentType))throw Error('Choose Image/Logo or Text');
 if(typeof element.name!=='string'||element.name.length>120)throw Error('Invalid element name');
 const checked=validateLegacy({...element,id:'element',material:'element',machine:'',thickness:'',status:'Por probar',date:''});
 const out={name:element.name.trim()};
 for(const key of elementKeys)if(checked[key]!==undefined&&(key!=='letterHeight'||element.contentType==='Letras'))out[key]=checked[key];
 return out;
}
function validate(row){
 if(!row||row.elements===undefined)return validateLegacy(row);
 if(!Array.isArray(row.elements)||row.elements.length<1||row.elements.length>100)throw Error('Add between 1 and 100 elements');
 // Validate shared fields using the established rules; no placeholder parameters are stored.
 const checked=validateLegacy({...row,power:1,speed:1,passes:1,unit:'mm/min',operation:'No registrado',air:'No registrado',scan:'No registrado',interval:'',focus:''});
 if(!checked.title)throw Error('Add a title');
 const out={};for(const key of generalKeys)if(checked[key]!==undefined)out[key]=checked[key];
 out.elements=row.elements.map(validateElement);return out;
}
function parse(text){const data=JSON.parse(text);if(data.app!=='tooltag-falcon'||data.version!==1||!Array.isArray(data.rows)||data.rows.length>5000)throw Error('This is not a valid ToolTag Falcon backup');const rows=data.rows.map(validate);if(new Set(rows.map(r=>r.id)).size!==rows.length)throw Error('Duplicate IDs');return rows;}
const api={validate,validateElement,parse,encode:rows=>JSON.stringify({app:'tooltag-falcon',version:1,rows},null,2)};
if(typeof module!=='undefined')module.exports=api;else root.FalconData=api;
})(typeof window!=='undefined'?window:globalThis);
