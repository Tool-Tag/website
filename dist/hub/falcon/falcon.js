(() => {
'use strict';
const $=s=>document.querySelector(s),key='tooltag-falcon-v1',data=window.FalconData;
let records=[],editing=null,storageReady=true;
const notice=message=>{$('#notice').textContent=message;};
try{const saved=localStorage.getItem(key);if(saved!==null){records=data.parse(saved);}else{records=(window.FALCON_INITIAL_ROWS||[]).map(data.validate);localStorage.setItem(key,data.encode(records));}}catch{storageReady=false;notice('No se pudo leer el almacenamiento. No sobrescribiremos tus datos. Revisa los permisos del navegador.');}
const dialog=$('#editor'),form=$('#form');
function updateLetterFields(){const show=form.elements.contentType.value==='Letras';$('#letter-fields').hidden=!show;form.elements.letterHeight.disabled=!show;}
$('#content-type').addEventListener('change',updateLetterFields);
function save(next){try{localStorage.setItem(key,data.encode(next));records=next;render();return true;}catch{notice('No se pudo guardar. Libera espacio o permite almacenamiento; tus cambios no fueron guardados.');return false;}}
const wizard=window.createFalconWizard({
 onSave(record){const next=records.some(r=>r.id===record.id)?records.map(r=>r.id===record.id?record:r):[...records,record];if(next.length>5000)throw Error('Máximo 5000 pruebas por respaldo.');if(!save(next))throw Error('No se pudo guardar en el navegador. Tu borrador sigue abierto.');notice('Prueba guardada en este navegador.');},
 onClose(id){const row=records.find(r=>r.id===id);if(row)showDetails(row);else $('#add').focus();}
});
const details=$('#details');let selected=null;const triggers=new Map();
function showDetails(row){
 selected=row.id;$('#details-title').textContent=row.title||row.material;$('#details-fields').replaceChildren();
 let fields;if(row.elements){fields=[['Material',row.material],['Espesor',row.thickness!==''?row.thickness+' mm':'—'],['Equipo / módulo',row.machine||'—'],['Estado',row.status],['Fecha',row.date||'—'],['Notas de la pieza',row.notes||'—']];for(const [i,element] of row.elements.entries())fields.push([`${i+1}. ${element.name||element.contentType}`,window.falconElementSummary(element)]);}else fields=[['Material',row.material],['Tipo de contenido',row.contentType||'Sin registrar'],['Espesor',row.thickness!==''?row.thickness+' mm':'—'],['Equipo / módulo',row.machine||'—'],['Operación',row.operation],['Potencia',row.power+' %'],['Velocidad',row.speed+' '+row.unit+(row.unit==='mm/min'?' ('+Number((row.speed/60).toFixed(3))+' mm/s)':'')],...((row.contentType==='Letras'||(!row.contentType&&row.letterHeight))?[['Altura de letras',row.letterHeight?row.letterHeight+' mm':'—']]:[]),['Frame: ancho × alto',row.frameWidth||row.frameHeight?(row.frameWidth||'—')+' × '+(row.frameHeight||'—')+' mm':'—'],['Medidas aproximadas',row.dimensionsApprox?'Sí (±)':'Sin indicación'],['Intervalo',row.interval?row.interval+' mm':'—'],['Pasadas',row.passes],['Escaneo',row.scan],['Aire',row.air],['Enfoque',row.focus||'—'],['Estado',row.status],['Fecha',row.date||'—'],['Resultado / notas',row.notes||'—']];
 for(const [label,value] of fields){const group=document.createElement('div'),dt=document.createElement('dt'),dd=document.createElement('dd');dt.textContent=label;dd.textContent=value;group.append(dt);group.append(dd);$('#details-fields').append(group);}
 $('#details-edit').disabled=!storageReady;$('#details-delete').disabled=!storageReady;
 details.showModal();
}
function closeDetails(){details.close();triggers.get(selected)?.focus();}
$('#details-close').addEventListener('click',closeDetails);
details.addEventListener('cancel',e=>{e.preventDefault();closeDetails();});
$('#details-edit').addEventListener('click',()=>{const row=records.find(r=>r.id===selected);if(row){details.close();open(row);}});
$('#details-delete').addEventListener('click',()=>{const row=records.find(r=>r.id===selected);if(row&&confirm('¿Eliminar la prueba de '+(row.title||row.material)+'?')&&save(records.filter(r=>r.id!==row.id))){details.close();$('#add').focus();notice('Prueba eliminada.');}});
function finishEditor(){dialog.close();const row=records.find(r=>r.id===editing);if(row)showDetails(row);else $('#add').focus();}
function render(){
 const q=$('#search').value.trim().toLocaleLowerCase(),state=$('#filter').value;
 const shown=records.filter(r=>(!state||r.status===state)&&[r.title,r.material,r.machine,r.notes,r.operation,...(r.elements||[]).flatMap(e=>[e.name,e.contentType,e.notes])].join(' ').toLocaleLowerCase().includes(q)).sort((a,b)=>b.date.localeCompare(a.date));
 $('#rows').replaceChildren();
 triggers.clear();
 for(const row of shown){const item=document.createElement('li'),button=document.createElement('button');button.type='button';button.className='record-title';button.textContent=row.title||row.material;button.setAttribute('aria-haspopup','dialog');button.addEventListener('click',()=>showDetails(row));item.append(button);$('#rows').append(item);triggers.set(row.id,button);}
 $('#count').textContent=`${shown.length} de ${records.length} pruebas`;
 $('#table-wrap').hidden=!shown.length;$('#empty').hidden=!!shown.length;
 $('#empty h2').textContent=records.length?'Sin coincidencias.':'Tu primera prueba empieza aquí.';
 $('#empty p').textContent=records.length?'Prueba otra búsqueda o filtro.':'Agrega una prueba o importa tu respaldo de parámetros.';
 $('#add').disabled=!storageReady;$('#import').disabled=!storageReady;
}
function open(row){if(!row||row.elements){wizard.open(row);return;}editing=row?.id||null;form.reset();$('#form-notice').textContent='';if(row){for(const [k,v] of Object.entries(row)){if(form.elements.namedItem(k))form.elements.namedItem(k).value=v;}}
 if(row)form.elements.title.value=row.title||row.material;
 updateLetterFields();
 $('#editor-title').textContent=row?'Editar prueba':'Nueva prueba';dialog.showModal();}
$('#add').addEventListener('click',()=>open());for(const selector of ['#close','#cancel'])$(selector).addEventListener('click',finishEditor);
dialog.addEventListener('cancel',e=>{e.preventDefault();finishEditor();});
form.addEventListener('submit',e=>{e.preventDefault();if(!form.reportValidity())return;try{const values=Object.fromEntries(new FormData(form));if(form.elements.letterHeight.disabled){const previous=records.find(r=>r.id===editing);if(previous?.letterHeight!==undefined)values.letterHeight=previous.letterHeight;}const record=data.validate({...values,id:editing||('r-'+Date.now()+'-'+Math.random().toString(36).slice(2))});const next=editing?records.map(r=>r.id===editing?record:r):[...records,record];if(next.length>5000)throw Error('Máximo 5000 pruebas por respaldo.');if(save(next)){finishEditor();notice('Prueba guardada en este navegador.');}else{$('#form-notice').textContent='No se pudo guardar en el navegador. Revisa el almacenamiento.';}}catch(err){$('#form-notice').textContent=err.message;}});
$('#search').addEventListener('input',render);$('#filter').addEventListener('change',render);
$('#export').addEventListener('click',()=>{if(!storageReady){notice('No se exportó: el almacenamiento no se pudo leer.');return;}const url=URL.createObjectURL(new Blob([data.encode(records)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download='ToolTag-Falcon-'+new Date().toISOString().slice(0,10)+'.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);notice('Respaldo exportado.');});
$('#import').addEventListener('click',()=>$('#file').click());$('#file').addEventListener('change',async e=>{const f=e.target.files[0];if(!f)return;try{if(f.size>5*1024*1024)throw Error('El respaldo supera 5 MB.');const imported=data.parse(await f.text()),ids=new Set(records.map(r=>r.id)),added=imported.filter(r=>!ids.has(r.id));if(records.length+added.length>5000)throw Error('El total supera 5000 pruebas.');if(save([...records,...added]))notice(`${added.length} pruebas importadas. ${imported.length-added.length} duplicadas omitidas.`);}catch(err){notice('No se importó ningún registro: '+err.message);}finally{e.target.value='';}});
render();
})();
