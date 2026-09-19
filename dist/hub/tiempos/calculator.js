(() => {
'use strict';
const $=s=>document.querySelector(s),form=$('#calc-form'),letterForm=$('#calc-letter-form'),dialog=$('#calc-letters'),key='tooltag-times-calculator-v1';
let settings=null,storageOK=true;
try{const saved=localStorage.getItem(key);if(saved!==null)settings=window.TimeEstimate.letterSettings(JSON.parse(saved));}catch{storageOK=false;}
const clear=()=>{$('#calc-result').textContent='';};
const format=n=>`${Math.floor(n/60)} min ${n%60} s`;
function editLetters(){letterForm.reset();if(settings)for(const [k,v]of Object.entries(settings))letterForm.elements.namedItem(k).value=v;$('#calc-letter-notice').textContent=storageOK?'':'No se pudo leer la configuración guardada. Puedes usarla solo en esta sesión.';dialog.showModal();}
function typeChanged(){const letters=form.elements.contentType.value==='Letras';$('#calc-configure').hidden=!letters;clear();if(letters)editLetters();}
$('#calc-type').addEventListener('change',typeChanged);
$('#calc-configure').addEventListener('click',editLetters);
for(const id of ['#calc-letter-close','#calc-letter-cancel'])$(id).addEventListener('click',()=>dialog.close());
letterForm.addEventListener('submit',e=>{e.preventDefault();if(!letterForm.reportValidity())return;try{settings=window.TimeEstimate.letterSettings(Object.fromEntries(new FormData(letterForm)));clear();let message='';if(storageOK){try{localStorage.setItem(key,JSON.stringify(settings));}catch{message='Configuración disponible solo en esta sesión; no se pudo guardar en el navegador.';}}else message='Configuración disponible solo en esta sesión.';dialog.close();$('#calc-result').textContent=message;}catch(error){$('#calc-letter-notice').textContent=error.message;}});
form.addEventListener('input',clear);
window.refreshTimeEstimate=clear;
form.addEventListener('submit',e=>{e.preventDefault();if(!form.reportValidity())return;try{
 const query=Object.fromEntries(new FormData(form));if(query.contentType==='Letras'){if(!settings){editLetters();return;}Object.assign(query,settings);}
 const records=window.getTimeRecords();if(records===null)throw Error('No se pueden leer los registros guardados para calcular.');
 const result=window.TimeEstimate.estimate(query,records);
 $('#calc-result').textContent=result.available?`Tiempo estimado: ${format(result.seconds)}. Basado en ${result.count} registro(s) comparable(s).${result.low!==result.high?' Rango de las referencias ajustadas: '+format(result.low)+' – '+format(result.high)+'.':''}${result.count===1?' Referencia única: estimación preliminar.':''}`:result.reason;
 }catch(error){$('#calc-result').textContent=error.message;}});
})();
