(() => {
'use strict';
const falconLabels={
  'Por probar':'To Test','Probado':'Tested','Validado':'Validated','Referencia':'Reference',
  'Imagen':'Image','Letras':'Text','No registrado':'Not Recorded','Grabado':'Engraving',
  'Marcado':'Marking','Corte':'Cutting','Otra':'Other','Unidireccional':'Unidirectional',
  'Bidireccional':'Bidirectional','Activada':'Enabled','Desactivada':'Disabled'
};
const falconDisplay=value=>falconLabels[value]||value;
window.falconElementSummary = element => [
 element.contentType==='Imagen'?'Image / Logo':'Text',
 `${element.power} % · ${element.speed} ${element.unit} · ${element.passes} pass(es)`,
 `Operation: ${falconDisplay(element.operation)}`,
 ...(element.contentType==='Letras'?[`Text Height: ${element.letterHeight?element.letterHeight+' mm':'—'}`]:[]),
 `Frame: ${element.frameWidth||'—'} × ${element.frameHeight||'—'} mm${element.dimensionsApprox?' (± approx.)':''}`,
 `Interval: ${element.interval?element.interval+' mm':'—'} · Scan: ${falconDisplay(element.scan)}`,
 `Air Assist: ${falconDisplay(element.air)} · Focus: ${element.focus||'—'}`,
 ...(element.notes?[element.notes]:[])
].join('\n');
window.createFalconWizard = ({onSave,onClose}) => {
 const $=s=>document.querySelector(s),dialog=$('#wizard'),piece=$('#piece-form'),form=$('#element-form');
 let originalId=null,general={},elements=[],currentType='',elementIndex=null,step='general',dirty=false;
 const steps=['general','list','choice','element'];
 const message=text=>{$('#wizard-notice').textContent=text;};
 const fill=(target,values)=>{for(const [key,value] of Object.entries(values))if(target.elements.namedItem(key))target.elements.namedItem(key).value=value;};
 function show(next){step=next;for(const name of steps)$('#wizard-'+name).hidden=name!==next;message('');$('#wizard-title').textContent=next==='element'?(elementIndex===null?'Add Element':'Edit Element'):(originalId?'Edit Test':'New Test');dialog.scrollTop=0;$('#wizard-title').focus();}
 function list(){
  $('#wizard-piece-name').textContent=general.title||'';$('#wizard-items').replaceChildren();
  for(const [index,element] of elements.entries()){
   const li=document.createElement('li'),title=document.createElement('h3'),summary=document.createElement('p'),actions=document.createElement('div');
   title.textContent=`${index+1}. ${element.name|| (element.contentType==='Imagen'?'Image / Logo':'Text')}`;
   summary.textContent=window.falconElementSummary(element);actions.className='wizard-item-actions';
   const edit=document.createElement('button');edit.type='button';edit.className='button secondary';edit.textContent='Edit';edit.setAttribute('aria-label','Edit '+title.textContent);edit.addEventListener('click',()=>editElement(element.contentType,index));
   const remove=document.createElement('button');remove.type='button';remove.className='button danger';remove.textContent='Remove';remove.setAttribute('aria-label','Remove '+title.textContent);remove.addEventListener('click',()=>{if(confirm('Remove this element from the test?')){elements.splice(index,1);dirty=true;list();$('#wizard-add').focus();}});
   actions.append(edit);actions.append(remove);li.append(title);li.append(summary);li.append(actions);$('#wizard-items').append(li);
  }
  $('#wizard-empty').hidden=elements.length>0;$('#wizard-finish').disabled=!elements.length;show('list');
 }
 function editElement(type,index=null){
  currentType=type;elementIndex=index;form.reset();if(index!==null)fill(form,elements[index]);
  form.elements.letterHeight.disabled=type!=='Letras';$('#wizard-letter-fields').hidden=type!=='Letras';
  $('#wizard-element-type').textContent=type==='Imagen'?'IMAGE / LOGO':'TEXT';show('element');
 }
 function cancel(){
  if(dirty&&!confirm('Discard changes to this test?'))return;
  dialog.close();onClose(originalId);
 }
 piece.addEventListener('input',()=>{dirty=true;});form.addEventListener('input',()=>{dirty=true;});
 piece.addEventListener('submit',event=>{event.preventDefault();if(!piece.reportValidity())return;general=Object.fromEntries(new FormData(piece));if(!general.title.trim()||!general.material.trim()){message('Add the piece title and material.');return;}list();});
 form.addEventListener('submit',event=>{event.preventDefault();if(!form.reportValidity())return;try{
  const element=window.FalconData.validateElement({...Object.fromEntries(new FormData(form)),contentType:currentType});
  if(elementIndex===null){if(elements.length>=100)throw Error('Maximum 100 elements per test.');elements.push(element);}else elements[elementIndex]=element;
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
