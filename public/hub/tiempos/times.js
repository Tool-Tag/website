(() => {
'use strict';
const $=s=>document.querySelector(s),data=window.TimesData,key='tooltag-times-v1';
let rows=[],ready=true,editing=null,selected=null;const triggers=new Map();const typeLabel=v=>v==='Imagen'?'Image':v==='Letras'?'Text':v;
window.getTimeRecords=()=>ready?rows:null;
const form=$('#form'),editor=$('#editor'),details=$('#details');
function updateType(){const letters=form.elements.contentType.value==='Letras',image=form.elements.contentType.value==='Imagen';form.elements.mode.disabled=!letters;form.elements.mode.required=letters;for(const key of ['letters','letterHeight']){form.elements[key].disabled=image;form.elements[key].required=!image;}}
$('#content-type').addEventListener('change',updateType);
const notice=text=>{$('#notice').textContent=text;};
const format=seconds=>`${Math.floor(seconds/60)} min ${seconds%60} s`;
try{const saved=localStorage.getItem(key);if(saved!==null)rows=data.parse(saved);}catch{ready=false;notice('Storage could not be read. Your data will not be overwritten.');}
function save(next){if(!ready)return false;try{if(next.length>5000)throw Error('Maximum 5000 records');localStorage.setItem(key,data.encode(next));rows=next;render();return true;}catch(error){notice('Could not save: '+error.message);return false;}}
function render(){
 window.refreshTimeEstimate?.();
 const q=$('#search').value.trim().toLocaleLowerCase();const shown=rows.filter(r=>[r.title,r.notes].join(' ').toLocaleLowerCase().includes(q));
 $('#rows').replaceChildren();triggers.clear();
 for(const row of shown){const li=document.createElement('li'),button=document.createElement('button');button.type='button';button.className='record-title';button.setAttribute('aria-haspopup','dialog');button.textContent=row.title;button.addEventListener('click',()=>show(row));li.append(button);$('#rows').append(li);triggers.set(row.id,button);}
 $('#count').textContent=`${shown.length} of ${rows.length} records`;
 $('#empty').hidden=shown.length>0;$('#empty').textContent=rows.length?'No matches.':'Add your first engraving time.';
 for(const id of ['#add','#import','#export'])$(id).disabled=!ready;
}
function show(row){selected=row.id;$('#details-title').textContent=row.title;$('#details-fields').replaceChildren();
 for(const [label,value] of [['Type',typeLabel(row.contentType)||'Not Recorded'],['Mode',row.contentType==='Imagen'?'Not Applicable':row.mode||'Not Recorded'],...(row.contentType==='Imagen'?[]:[['Character Count',row.letters],['Text Height',row.letterHeight+' mm']]),['Frame: Width × Height',`${row.frameWidth} × ${row.frameHeight} mm`],['Engraving Time',format(row.seconds)],['Notes',row.notes||'—']]){const group=document.createElement('div'),dt=document.createElement('dt'),dd=document.createElement('dd');dt.textContent=label;dd.textContent=value;group.append(dt);group.append(dd);$('#details-fields').append(group);}details.showModal();
}
function closeDetails(){details.close();triggers.get(selected)?.focus();}
function open(row){editing=row?.id||null;form.reset();$('#form-notice').textContent='';if(row){for(const [k,v] of Object.entries(row))if(form.elements.namedItem(k))form.elements.namedItem(k).value=v;form.elements.minutes.value=Math.floor(row.seconds/60);form.elements.remainder.value=row.seconds%60;}updateType();$('#editor-title').textContent=row?'Edit Time':'New Time';editor.showModal();}
function closeEditor(){editor.close();const row=rows.find(r=>r.id===editing);if(row)show(row);else $('#add').focus();}
$('#add').addEventListener('click',()=>open());$('#details-close').addEventListener('click',closeDetails);details.addEventListener('cancel',e=>{e.preventDefault();closeDetails();});
$('#details-edit').addEventListener('click',()=>{const row=rows.find(r=>r.id===selected);if(row){details.close();open(row);}});
$('#details-delete').addEventListener('click',()=>{const row=rows.find(r=>r.id===selected);if(row&&confirm('Delete the time record for '+row.title+'?')&&save(rows.filter(r=>r.id!==selected))){details.close();$('#add').focus();notice('Record deleted.');}});
for(const id of ['#close','#cancel'])$(id).addEventListener('click',closeEditor);editor.addEventListener('cancel',e=>{e.preventDefault();closeEditor();});
form.addEventListener('submit',e=>{e.preventDefault();if(!form.reportValidity())return;try{const values=Object.fromEntries(new FormData(form));if(values.contentType==='Imagen'){const previous=rows.find(r=>r.id===editing);for(const key of ['letters','letterHeight'])if(previous?.[key]!==undefined)values[key]=previous[key];}const row=data.validate({...values,id:editing||('t-'+Date.now()+'-'+Math.random().toString(36).slice(2)),seconds:data.duration(values.minutes,values.remainder)});const next=editing?rows.map(r=>r.id===editing?row:r):[row,...rows];if(save(next)){closeEditor();notice('Time saved in this browser.');}else $('#form-notice').textContent='Could not save. The form still contains your data.';}catch(error){$('#form-notice').textContent=error.message;}});
$('#search').addEventListener('input',render);
$('#export').addEventListener('click',()=>{if(!ready)return;const url=URL.createObjectURL(new Blob([data.encode(rows)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download='ToolTag-Times.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);notice('Backup exported.');});
$('#import').addEventListener('click',()=>$('#file').click());$('#file').addEventListener('change',async e=>{const file=e.target.files[0];if(!file||!ready)return;try{if(file.size>5*1024*1024)throw Error('Maximum 5 MB');const incoming=data.parse(await file.text()),ids=new Set(rows.map(r=>r.id)),added=incoming.filter(r=>!ids.has(r.id));if(save([...rows,...added]))notice(`${added.length} records imported; ${incoming.length-added.length} duplicates skipped.`);}catch(error){notice('Import failed: '+error.message);}finally{e.target.value='';}});
render();
})();
