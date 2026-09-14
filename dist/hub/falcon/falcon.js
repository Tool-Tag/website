(() => {
'use strict';
const $=s=>document.querySelector(s),key='tooltag-falcon-v1',data=window.FalconData;
let records=[],editing=null,storageReady=true;
const notice=message=>{$('#notice').textContent=message;};
try{const saved=localStorage.getItem(key);if(saved!==null){records=data.parse(saved);}else{records=(window.FALCON_INITIAL_ROWS||[]).map(data.validate);localStorage.setItem(key,data.encode(records));}}catch{storageReady=false;notice('No se pudo leer el almacenamiento. No sobrescribiremos tus datos. Revisa los permisos del navegador.');}
const dialog=$('#editor'),form=$('#form');
function save(next){try{localStorage.setItem(key,data.encode(next));records=next;render();return true;}catch{notice('No se pudo guardar. Libera espacio o permite almacenamiento; tus cambios no fueron guardados.');return false;}}
function cell(tr,text){const td=document.createElement('td');td.textContent=text;tr.append(td);return td;}
function render(){
 const q=$('#search').value.trim().toLocaleLowerCase(),state=$('#filter').value;
 const shown=records.filter(r=>(!state||r.status===state)&&[r.material,r.machine,r.notes,r.operation].join(' ').toLocaleLowerCase().includes(q)).sort((a,b)=>b.date.localeCompare(a.date));
 $('#rows').replaceChildren();
 for(const row of shown){const tr=document.createElement('tr');cell(tr,row.material+(row.thickness!==''?' · '+row.thickness+' mm':''));cell(tr,row.machine||'—');cell(tr,row.operation);cell(tr,row.power+' %');cell(tr,row.speed+' '+row.unit+(row.unit==='mm/min'?' ('+Number((row.speed/60).toFixed(3))+' mm/s)':''));cell(tr,row.interval?row.interval+' mm':'—');cell(tr,row.passes);cell(tr,row.scan==='No registrado'?'—':row.scan);cell(tr,row.air+(row.focus?' · '+row.focus:''));cell(tr,row.notes||'—');cell(tr,row.status).className='state';cell(tr,row.date||'—');
 const actions=cell(tr,'');const edit=document.createElement('button');edit.textContent='Editar';edit.setAttribute('aria-label','Editar '+row.material);edit.addEventListener('click',()=>open(row));actions.append(edit);
 const remove=document.createElement('button');remove.textContent='Eliminar';remove.setAttribute('aria-label','Eliminar '+row.material);remove.addEventListener('click',()=>{if(confirm('¿Eliminar la prueba de '+row.material+'?'))if(save(records.filter(r=>r.id!==row.id)))notice('Prueba eliminada.');});actions.append(remove);$('#rows').append(tr);}
 $('#count').textContent=`${shown.length} de ${records.length} pruebas`;
 $('#table-wrap').hidden=!shown.length;$('#empty').hidden=!!shown.length;
 $('#empty h2').textContent=records.length?'Sin coincidencias.':'Tu primera prueba empieza aquí.';
 $('#empty p').textContent=records.length?'Prueba otra búsqueda o filtro.':'Agrega una prueba o importa tu respaldo de parámetros.';
 $('#add').disabled=!storageReady;$('#import').disabled=!storageReady;
}
function open(row){editing=row?.id||null;form.reset();$('#form-notice').textContent='';if(row){for(const [k,v] of Object.entries(row)){if(form.elements.namedItem(k))form.elements.namedItem(k).value=v;}}
 $('#editor-title').textContent=row?'Editar prueba':'Nueva prueba';dialog.showModal();}
$('#add').addEventListener('click',()=>open());for(const selector of ['#close','#cancel'])$(selector).addEventListener('click',()=>dialog.close());
form.addEventListener('submit',e=>{e.preventDefault();if(!form.reportValidity())return;try{const record=data.validate({...Object.fromEntries(new FormData(form)),id:editing||('r-'+Date.now()+'-'+Math.random().toString(36).slice(2))});const next=editing?records.map(r=>r.id===editing?record:r):[...records,record];if(next.length>5000)throw Error('Máximo 5000 pruebas por respaldo.');if(save(next)){dialog.close();notice('Prueba guardada en este navegador.');}else{$('#form-notice').textContent='No se pudo guardar en el navegador. Revisa el almacenamiento.';}}catch(err){$('#form-notice').textContent=err.message;}});
$('#search').addEventListener('input',render);$('#filter').addEventListener('change',render);
$('#export').addEventListener('click',()=>{if(!storageReady){notice('No se exportó: el almacenamiento no se pudo leer.');return;}const url=URL.createObjectURL(new Blob([data.encode(records)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download='ToolTag-Falcon-'+new Date().toISOString().slice(0,10)+'.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);notice('Respaldo exportado.');});
$('#import').addEventListener('click',()=>$('#file').click());$('#file').addEventListener('change',async e=>{const f=e.target.files[0];if(!f)return;try{if(f.size>5*1024*1024)throw Error('El respaldo supera 5 MB.');const imported=data.parse(await f.text()),ids=new Set(records.map(r=>r.id)),added=imported.filter(r=>!ids.has(r.id));if(records.length+added.length>5000)throw Error('El total supera 5000 pruebas.');if(save([...records,...added]))notice(`${added.length} pruebas importadas. ${imported.length-added.length} duplicadas omitidas.`);}catch(err){notice('No se importó ningún registro: '+err.message);}finally{e.target.value='';}});
render();
})();
