(() => {
'use strict';
const $=s=>document.querySelector(s),key='tooltag-falcon-v1',data=window.FalconData;
let records=[],editing=null,storageReady=true;
const labels={
  'Por probar':'To Test','Probado':'Tested','Validado':'Validated','Referencia':'Reference',
  'Imagen':'Image','Letras':'Text','No registrado':'Not Recorded','Grabado':'Engraving',
  'Marcado':'Marking','Corte':'Cutting','Otra':'Other','Unidireccional':'Unidirectional',
  'Bidireccional':'Bidirectional','Activada':'Enabled','Desactivada':'Disabled',
  'Aproximado':'Approximate'
};
const display=value=>labels[value]||value;
const notice=message=>{$('#notice').textContent=message;};
try{const saved=localStorage.getItem(key);if(saved!==null){records=data.parse(saved);}else{records=(window.FALCON_INITIAL_ROWS||[]).map(data.validate);localStorage.setItem(key,data.encode(records));}}catch{storageReady=false;notice('Storage could not be read. Your data will not be overwritten. Check browser permissions.');}
const dialog=$('#editor'),form=$('#form');
function updateLetterFields(){const show=form.elements.contentType.value==='Letras';$('#letter-fields').hidden=!show;form.elements.letterHeight.disabled=!show;}
$('#content-type').addEventListener('change',updateLetterFields);
function save(next){try{localStorage.setItem(key,data.encode(next));records=next;render();return true;}catch{notice('Could not save. Free up space or allow storage; your changes were not saved.');return false;}}
const wizard=window.createFalconWizard({
 onSave(record){const next=records.some(r=>r.id===record.id)?records.map(r=>r.id===record.id?record:r):[...records,record];if(next.length>5000)throw Error('Maximum 5000 tests per backup.');if(!save(next))throw Error('Could not save in the browser. Your draft remains open.');notice('Test saved in this browser.');},
 onClose(id){const row=records.find(r=>r.id===id);if(row)showDetails(row);else $('#add').focus();}
});
const details=$('#details');let selected=null;const triggers=new Map();
function showDetails(row){
 selected=row.id;$('#details-title').textContent=row.title||row.material;$('#details-fields').replaceChildren();
 let fields;if(row.elements){fields=[['Material',row.material],['Thickness',row.thickness!==''?row.thickness+' mm':'—'],['Falcon Model / Module',row.machine||'—'],['Status',display(row.status)],['Date',row.date||'—'],['Piece Notes',row.notes||'—']];for(const [i,element] of row.elements.entries())fields.push([`${i+1}. ${element.name||element.contentType}`,window.falconElementSummary(element)]);}else fields=[['Material',row.material],['Content Type',display(row.contentType||'No registrado')],['Thickness',row.thickness!==''?row.thickness+' mm':'—'],['Falcon Model / Module',row.machine||'—'],['Operation',display(row.operation)],['Power',row.power+' %'],['Speed',row.speed+' '+row.unit+(row.unit==='mm/min'?' ('+Number((row.speed/60).toFixed(3))+' mm/s)':'')],...((row.contentType==='Letras'||(!row.contentType&&row.letterHeight))?[['Text Height',row.letterHeight?row.letterHeight+' mm':'—']]:[]),['Frame: Width × Height',row.frameWidth||row.frameHeight?(row.frameWidth||'—')+' × '+(row.frameHeight||'—')+' mm':'—'],['Approximate Dimensions',row.dimensionsApprox?'Yes (±)':'Not indicated'],['Interval',row.interval?row.interval+' mm':'—'],['Passes',row.passes],['Scan',display(row.scan)],['Air Assist',display(row.air)],['Focus',row.focus||'—'],['Status',display(row.status)],['Date',row.date||'—'],['Result / Notes',row.notes||'—']];
 for(const [label,value] of fields){const group=document.createElement('div'),dt=document.createElement('dt'),dd=document.createElement('dd');dt.textContent=label;dd.textContent=value;group.append(dt);group.append(dd);$('#details-fields').append(group);}
 $('#details-edit').disabled=!storageReady;$('#details-delete').disabled=!storageReady;
 details.showModal();
}
function closeDetails(){details.close();triggers.get(selected)?.focus();}
$('#details-close').addEventListener('click',closeDetails);
details.addEventListener('cancel',e=>{e.preventDefault();closeDetails();});
$('#details-edit').addEventListener('click',()=>{const row=records.find(r=>r.id===selected);if(row){details.close();open(row);}});
$('#details-delete').addEventListener('click',()=>{const row=records.find(r=>r.id===selected);if(row&&confirm('Delete the test for '+(row.title||row.material)+'?')&&save(records.filter(r=>r.id!==row.id))){details.close();$('#add').focus();notice('Test deleted.');}});
function finishEditor(){dialog.close();const row=records.find(r=>r.id===editing);if(row)showDetails(row);else $('#add').focus();}
function render(){
 const q=$('#search').value.trim().toLocaleLowerCase(),state=$('#filter').value;
 const shown=records.filter(r=>(!state||r.status===state)&&[r.title,r.material,r.machine,r.notes,r.operation,...(r.elements||[]).flatMap(e=>[e.name,e.contentType,e.notes])].join(' ').toLocaleLowerCase().includes(q)).sort((a,b)=>b.date.localeCompare(a.date));
 $('#rows').replaceChildren();
 triggers.clear();
 for(const row of shown){const item=document.createElement('li'),button=document.createElement('button');button.type='button';button.className='record-title';button.textContent=row.title||row.material;button.setAttribute('aria-haspopup','dialog');button.addEventListener('click',()=>showDetails(row));item.append(button);$('#rows').append(item);triggers.set(row.id,button);}
 $('#count').textContent=`${shown.length} of ${records.length} tests`;
 $('#table-wrap').hidden=!shown.length;$('#empty').hidden=!!shown.length;
 $('#empty h2').textContent=records.length?'No matches.':'Your first test starts here.';
 $('#empty p').textContent=records.length?'Try another search or filter.':'Add a test or import your parameter backup.';
 $('#add').disabled=!storageReady;$('#import').disabled=!storageReady;
}
function open(row){if(!row||row.elements){wizard.open(row);return;}editing=row?.id||null;form.reset();$('#form-notice').textContent='';if(row){for(const [k,v] of Object.entries(row)){if(form.elements.namedItem(k))form.elements.namedItem(k).value=v;}}
 if(row)form.elements.title.value=row.title||row.material;
 updateLetterFields();
 $('#editor-title').textContent=row?'Edit Test':'New Test';dialog.showModal();}
$('#add').addEventListener('click',()=>open());for(const selector of ['#close','#cancel'])$(selector).addEventListener('click',finishEditor);
dialog.addEventListener('cancel',e=>{e.preventDefault();finishEditor();});
form.addEventListener('submit',e=>{e.preventDefault();if(!form.reportValidity())return;try{const values=Object.fromEntries(new FormData(form));if(form.elements.letterHeight.disabled){const previous=records.find(r=>r.id===editing);if(previous?.letterHeight!==undefined)values.letterHeight=previous.letterHeight;}const record=data.validate({...values,id:editing||('r-'+Date.now()+'-'+Math.random().toString(36).slice(2))});const next=editing?records.map(r=>r.id===editing?record:r):[...records,record];if(next.length>5000)throw Error('Maximum 5000 tests per backup.');if(save(next)){finishEditor();notice('Test saved in this browser.');}else{$('#form-notice').textContent='Could not save in the browser. Check storage access.';}}catch(err){$('#form-notice').textContent=err.message;}});
$('#search').addEventListener('input',render);$('#filter').addEventListener('change',render);
$('#export').addEventListener('click',()=>{if(!storageReady){notice('Backup was not exported because storage could not be read.');return;}const url=URL.createObjectURL(new Blob([data.encode(records)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download='ToolTag-Falcon-'+new Date().toISOString().slice(0,10)+'.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);notice('Backup exported.');});
$('#import').addEventListener('click',()=>$('#file').click());$('#file').addEventListener('change',async e=>{const f=e.target.files[0];if(!f)return;try{if(f.size>5*1024*1024)throw Error('The backup exceeds 5 MB.');const imported=data.parse(await f.text()),ids=new Set(records.map(r=>r.id)),added=imported.filter(r=>!ids.has(r.id));if(records.length+added.length>5000)throw Error('The total exceeds 5000 tests.');if(save([...records,...added]))notice(`${added.length} tests imported. ${imported.length-added.length} duplicates skipped.`);}catch(err){notice('No records were imported: '+err.message);}finally{e.target.value='';}});
render();
})();
