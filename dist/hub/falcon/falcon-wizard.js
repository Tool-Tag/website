(() => {
'use strict';
window.falconElementSummary = element => [
 element.contentType==='Imagen'?'Imagen / Logo':'Letras',
 `${element.power} % · ${element.speed} ${element.unit} · ${element.passes} pasada(s)`,
 `Operación: ${element.operation}`,
 ...(element.contentType==='Letras'?[`Altura de letras: ${element.letterHeight?element.letterHeight+' mm':'—'}`]:[]),
 `Frame: ${element.frameWidth||'—'} × ${element.frameHeight||'—'} mm${element.dimensionsApprox?' (± aprox.)':''}`,
 `Intervalo: ${element.interval?element.interval+' mm':'—'} · Escaneo: ${element.scan}`,
 `Aire: ${element.air} · Enfoque: ${element.focus||'—'}`,
 ...(element.notes?[element.notes]:[])
].join('\n');
window.createFalconWizard = ({onSave,onClose}) => {
 const $=s=>document.querySelector(s),dialog=$('#wizard'),piece=$('#piece-form'),form=$('#element-form');
 let originalId=null,general={},elements=[],currentType='',elementIndex=null,step='general',dirty=false;
 const steps=['general','list','choice','element'];
 const message=text=>{$('#wizard-notice').textContent=text;};
 const fill=(target,values)=>{for(const [key,value] of Object.entries(values))if(target.elements.namedItem(key))target.elements.namedItem(key).value=value;};
 function show(next){step=next;for(const name of steps)$('#wizard-'+name).hidden=name!==next;message('');$('#wizard-title').textContent=next==='element'?(elementIndex===null?'Agregar elemento':'Editar elemento'):(originalId?'Editar prueba':'Nueva prueba');dialog.scrollTop=0;$('#wizard-title').focus();}
 function list(){
  $('#wizard-piece-name').textContent=general.title||'';$('#wizard-items').replaceChildren();
  for(const [index,element] of elements.entries()){
   const li=document.createElement('li'),title=document.createElement('h3'),summary=document.createElement('p'),actions=document.createElement('div');
   title.textContent=`${index+1}. ${element.name|| (element.contentType==='Imagen'?'Imagen / Logo':'Letras')}`;
   summary.textContent=window.falconElementSummary(element);actions.className='wizard-item-actions';
   const edit=document.createElement('button');edit.type='button';edit.className='button secondary';edit.textContent='Editar';edit.setAttribute('aria-label','Editar '+title.textContent);edit.addEventListener('click',()=>editElement(element.contentType,index));
   const remove=document.createElement('button');remove.type='button';remove.className='button danger';remove.textContent='Quitar';remove.setAttribute('aria-label','Quitar '+title.textContent);remove.addEventListener('click',()=>{if(confirm('¿Quitar este elemento de la prueba?')){elements.splice(index,1);dirty=true;list();$('#wizard-add').focus();}});
   actions.append(edit);actions.append(remove);li.append(title);li.append(summary);li.append(actions);$('#wizard-items').append(li);
  }
  $('#wizard-empty').hidden=elements.length>0;$('#wizard-finish').disabled=!elements.length;show('list');
 }
 function editElement(type,index=null){
  currentType=type;elementIndex=index;form.reset();if(index!==null)fill(form,elements[index]);
  form.elements.letterHeight.disabled=type!=='Letras';$('#wizard-letter-fields').hidden=type!=='Letras';
  $('#wizard-element-type').textContent=type==='Imagen'?'IMAGEN / LOGO':'LETRAS';show('element');
 }
 function cancel(){
  if(dirty&&!confirm('¿Descartar los cambios de esta prueba?'))return;
  dialog.close();onClose(originalId);
 }
 piece.addEventListener('input',()=>{dirty=true;});form.addEventListener('input',()=>{dirty=true;});
 piece.addEventListener('submit',event=>{event.preventDefault();if(!piece.reportValidity())return;general=Object.fromEntries(new FormData(piece));if(!general.title.trim()||!general.material.trim()){message('Agrega el título y el material de la pieza.');return;}list();});
 form.addEventListener('submit',event=>{event.preventDefault();if(!form.reportValidity())return;try{
  const element=window.FalconData.validateElement({...Object.fromEntries(new FormData(form)),contentType:currentType});
  if(elementIndex===null){if(elements.length>=100)throw Error('Máximo 100 elementos por prueba.');elements.push(element);}else elements[elementIndex]=element;
  dirty=true;list();$('#wizard-add').focus();
 }catch(error){message(error.message);}});
 $('#wizard-add').addEventListener('click',()=>show('choice'));
 $('#wizard-image').addEventListener('click',()=>editElement('Imagen'));
 $('#wizard-text').addEventListener('click',()=>editElement('Letras'));
 $('#wizard-choice-back').addEventListener('click',list);
 $('#wizard-element-cancel').addEventListener('click',list);
 $('#wizard-back').addEventListener('click',()=>show('general'));
 $('#wizard-finish').addEventListener('click',()=>{try{
  const record=window.FalconData.validate({...general,id:originalId||('r-'+Date.now()+'-'+Math.random().toString(36).slice(2)),elements});
  onSave(record);dialog.close();onClose(record.id);
 }catch(error){message(error.message);}});
 for(const id of ['#wizard-close','#wizard-cancel'])$(id).addEventListener('click',cancel);
 dialog.addEventListener('cancel',event=>{event.preventDefault();if(step==='element'||step==='choice')list();else cancel();});
 return {open(row){originalId=row?.id||null;general=row?{...row}:{};elements=row?JSON.parse(JSON.stringify(row.elements)):[];dirty=false;piece.reset();if(row)fill(piece,row);dialog.showModal();show('general');}};
};
})();
