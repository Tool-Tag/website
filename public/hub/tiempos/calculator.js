(() => {
'use strict';
const $=s=>document.querySelector(s),form=$('#calc-form'),letterForm=$('#calc-letter-form'),dialog=$('#calc-letters'),key='tooltag-times-calculator-v1';
let settings=null,storageOK=true;
try{const saved=localStorage.getItem(key);if(saved!==null)settings=window.TimeEstimate.letterSettings(JSON.parse(saved));}catch{storageOK=false;}
const clear=()=>{$('#calc-result').textContent='';};
const format=n=>`${Math.floor(n/60)} min ${n%60} s`;
function editLetters(){letterForm.reset();if(settings)for(const [k,v]of Object.entries(settings))letterForm.elements.namedItem(k).value=v;$('#calc-letter-notice').textContent=storageOK?'':'Saved settings could not be read. You can use them for this session only.';dialog.showModal();}
function typeChanged(){const letters=form.elements.contentType.value==='Letras';$('#calc-configure').hidden=!letters;clear();if(letters)editLetters();}
$('#calc-type').addEventListener('change',typeChanged);
$('#calc-configure').addEventListener('click',editLetters);
for(const id of ['#calc-letter-close','#calc-letter-cancel'])$(id).addEventListener('click',()=>dialog.close());
letterForm.addEventListener('submit',e=>{e.preventDefault();if(!letterForm.reportValidity())return;try{settings=window.TimeEstimate.letterSettings(Object.fromEntries(new FormData(letterForm)));clear();let message='';if(storageOK){try{localStorage.setItem(key,JSON.stringify(settings));}catch{message='Settings are available for this session only; they could not be saved in the browser.';}}else message='Settings are available for this session only.';dialog.close();$('#calc-result').textContent=message;}catch(error){$('#calc-letter-notice').textContent=error.message;}});
form.addEventListener('input',clear);
window.refreshTimeEstimate=clear;
form.addEventListener('submit',e=>{e.preventDefault();if(!form.reportValidity())return;try{
 const query=Object.fromEntries(new FormData(form));if(query.contentType==='Letras'){if(!settings){editLetters();return;}Object.assign(query,settings);}
 const records=window.getTimeRecords();if(records===null)throw Error('Saved records cannot be read for calculation.');
 const result=window.TimeEstimate.estimate(query,records);
 $('#calc-result').textContent=result.available?`Estimated Time: ${format(result.seconds)}. Based on ${result.count} comparable record(s).${result.low!==result.high?' Adjusted reference range: '+format(result.low)+' – '+format(result.high)+'.':''}${result.count===1?' Single reference: preliminary estimate.':''}`:result.reason;
 }catch(error){$('#calc-result').textContent=error.message;}});
})();
