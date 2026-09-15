// Run with: node --test tests/falcon.test.cjs
// DOM doubles test application logic; they do not validate browser layout.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');
const source = name => fs.readFileSync(path.join(root, 'dist/hub/falcon', name), 'utf8');
const backup = JSON.parse(fs.readFileSync(path.join(root, 'ToolTag-Falcon-Parametros.json'), 'utf8'));
const key = 'tooltag-falcon-v1';

function app(saved = null, blocked = false) {
  const fields = [...Object.keys(backup.rows[0]).filter(k => k !== 'id'),'letterHeight','frameWidth','frameHeight','dimensionsApprox','title','contentType'];
  class Element {
    constructor() { this.value = ''; this.textContent = ''; this.children = []; this.listeners = {}; this.hidden = false; }
    addEventListener(name, fn) { this.listeners[name] = fn; }
    setAttribute() {}
    focus() {}
    append(child) { this.children.push(child); }
    replaceChildren() { this.children = []; }
    click() { return this.listeners.click?.({target:this}); }
    showModal() { this.open = true; }
    close() { this.open = false; }
  }
  const elements = new Map();
  const $ = name => { if (!elements.has(name)) elements.set(name, new Element()); return elements.get(name); };
  const form = $('#form');
  form.elements = Object.fromEntries(fields.map(k => [k, new Element()]));
  form.elements.namedItem = k => form.elements[k];
  form.reset = () => {
    for (const k of fields) form.elements[k].value = '';
    for (const k of ['operation','air','scan']) form.elements[k].value = 'No registrado';
    form.elements.unit.value = 'mm/min'; form.elements.status.value = 'Por probar';
  };
  form.reportValidity = () => true;
  function setupForm(selector, names) {
    const target=$(selector);target.elements=Object.fromEntries(names.map(k=>[k,new Element()]));
    target.elements.namedItem=k=>target.elements[k];target.reportValidity=()=>true;
    target.reset=()=>{for(const k of names)target.elements[k].value='';for(const k of ['operation','air','scan'])if(target.elements[k])target.elements[k].value='No registrado';if(target.elements.unit)target.elements.unit.value='mm/min';if(target.elements.status)target.elements.status.value='Por probar';};
  }
  setupForm('#piece-form',['title','material','thickness','machine','status','date','notes']);
  setupForm('#element-form',['name','operation','power','speed','unit','passes','interval','scan','air','focus','letterHeight','frameWidth','frameHeight','dimensionsApprox','notes']);
  let stored = saved, writes = 0, blob;
  const context = vm.createContext({
    document:{querySelector:$, createElement:() => new Element()},
    localStorage:{getItem:() => { if(blocked) throw Error('blocked'); return stored; },setItem:(k,v) => { if(blocked) throw Error('blocked'); stored=v; writes++; }},
    FormData:class { constructor(target) { return Object.keys(target.elements).filter(k=>k!=='namedItem'&&!target.elements[k].disabled&&(k!=='title'||target.elements[k].value!=='')).map(k => [k,target.elements[k].value]); } },
    Blob, URL:{createObjectURL:b => {blob=b;return 'blob:test';},revokeObjectURL(){}},
    setTimeout:fn => fn(), confirm:() => true,
  });
  context.window=context;
  for (const name of ['falcon-data.js','falcon-presets.js','falcon-wizard.js','falcon.js']) vm.runInContext(source(name),context);
  const event = (id,name) => $(id).listeners[name]({target:$(id),preventDefault(){}});
  return {$,context,event, stored:()=>stored, writes:()=>writes, blob:()=>blob,
    rows:()=>JSON.parse(stored).rows,
    async import(text) {$('#file').files=[{size:Buffer.byteLength(text),text:async()=>text}]; await event('#file','change');},
    fillForm(selector,row){for(const [k,v] of Object.entries(row))if($(selector).elements[k])$(selector).elements[k].value=v;},
    fill(row) {for(const [k,v] of Object.entries(row)) if(form.elements[k]) form.elements[k].value=v;},
  };
}

test('seven supplied records, exact values and blank machine/date; seeds only on first visit', () => {
  const a=app(); assert.deepEqual(a.rows(),backup.rows); assert.equal(a.writes(),1);
  const b=app(a.stored()); assert.equal(b.writes(),0); assert.deepEqual(b.rows(),backup.rows);
  assert.equal(a.$('#count').textContent,'7 de 7 pruebas');
});
test('existing records and an intentionally empty table are preserved', () => {
  for(const rows of [[],[{...backup.rows[0],id:'user',notes:'My saved result'}]]) {
    const saved=JSON.stringify({...backup,rows}); const a=app(saved);
    assert.equal(a.stored(),saved); assert.equal(a.writes(),0);
  }
});
test('corrupt or inaccessible storage does not get overwritten', () => {
  for(const a of [app('{bad'),app(null,true)]) {
    assert.equal(a.writes(),0); assert.equal(a.$('#add').disabled,true);
    assert.equal(a.$('#import').disabled,true); a.$('#export').click(); assert.equal(a.blob(),undefined);
  }
});
test('search and status filter combine and expose empty results', () => {
  const a=app(); a.$('#search').value='plástico'; a.event('#search','input');
  assert.equal(a.$('#count').textContent,'5 de 7 pruebas');
  a.$('#filter').value='Validado'; a.event('#filter','change');
  assert.equal(a.$('#count').textContent,'1 de 7 pruebas');
  a.$('#search').value='no match'; a.event('#search','input');
  assert.equal(a.$('#table-wrap').hidden,true); assert.equal(a.$('#empty').hidden,false);
});

test('export preserves all rows; import merges, deduplicates and rejects invalid files atomically', async () => {
  const a=app(); a.$('#export').click(); assert.deepEqual(JSON.parse(await a.blob().text()),backup);
  await a.import(JSON.stringify(backup)); assert.equal(a.rows().length,7);
  await a.import(JSON.stringify({...backup,rows:[{...backup.rows[0],id:'imported'}]})); assert.equal(a.rows().length,8);
  const before=a.stored();
  for(const text of ['{bad',JSON.stringify({...backup,version:2}),JSON.stringify({...backup,rows:[backup.rows[0],backup.rows[0]]}),JSON.stringify({...backup,rows:[{...backup.rows[0],id:'valid-new'},{...backup.rows[1],power:101}]}),' '.repeat(5*1024*1024+1)]) {
    await a.import(text); assert.equal(a.stored(),before);
  }
});
test('schema rejects invalid dates, units, speeds and fractional passes', () => {
  const {context}=app();
  for(const changes of [{date:'2026-02-30'},{unit:'unknown'},{speed:0},{passes:1.5},{interval:-1},{scan:'unknown'}])
    assert.throws(()=>context.FalconData.validate({...backup.rows[0],...changes}));
});


test('optional dimensions survive editing, reload and JSON export/import; old records remain valid', async () => {
  const a=app(); a.$('#rows').children[0].children[0].click(); a.$('#details-edit').click();
  a.fill({contentType:'Letras',letterHeight:'3.5',frameWidth:'40',frameHeight:'12',dimensionsApprox:'Aproximado'});
  a.event('#content-type','change'); a.event('#form','submit');
  const saved=a.rows()[0]; assert.equal(saved.letterHeight,3.5); assert.equal(saved.frameWidth,40); assert.equal(saved.frameHeight,12);
  const b=app(a.stored()); assert.equal(b.rows()[0].dimensionsApprox,'Aproximado');
  b.$('#rows').children[0].children[0].click(); assert.ok(b.$('#details-fields').children.some(c=>String(c.children[1].textContent).includes('40 × 12 mm')));
  b.$('#export').click();
  const c=app(JSON.stringify({...backup,rows:[]})); await c.import(await b.blob().text());
  assert.deepEqual(c.rows(),b.rows());
  c.$('#rows').children[0].children[0].click(); c.$('#details-edit').click();
  c.fill({letterHeight:'',frameWidth:'',frameHeight:'',dimensionsApprox:''}); c.event('#form','submit');
  assert.equal(c.rows()[0].letterHeight,undefined); assert.equal(c.rows()[0].frameWidth,undefined);
  for(const value of [-1,0,'bad',true,' ']) assert.throws(()=>a.context.FalconData.validate({...backup.rows[0],letterHeight:value}));
});


test('title opens details, Edit switches dialogs and cancel restores details without changing data', () => {
 const a=app(),before=a.stored();
 assert.equal(a.$('#rows').children[0].children.length,1);
 assert.equal(a.$('#rows').children[0].children[0].textContent,backup.rows[0].material);
 a.$('#rows').children[0].children[0].click();
 assert.equal(a.$('#details').open,true); assert.equal(a.$('#details-title').textContent,backup.rows[0].material);
 a.$('#details-edit').click(); assert.equal(a.$('#details').open,false); assert.equal(a.$('#editor').open,true);
 a.fill({material:'Unsaved title'}); a.$('#cancel').click();
 assert.equal(a.$('#editor').open,false); assert.equal(a.$('#details').open,true); assert.equal(a.stored(),before);
 a.$('#details-close').click(); assert.equal(a.$('#details').open,false);
});




function startPiece(a){a.$('#add').click();assert.equal(a.$('#wizard').open,true);assert.equal(a.$('#piece-form').elements.date.value,'');a.fillForm('#piece-form',{title:'Batería DeWalt 9Ah FlexVolt',material:'Plástico negro'});a.event('#piece-form','submit');}
function addElement(a,type,values={}){a.$('#wizard-add').click();a.$(type==='Imagen'?'#wizard-image':'#wizard-text').click();a.fillForm('#element-form',{power:'15',speed:'3000',passes:'1',...values});a.event('#element-form','submit');}

test('wizard stores independent logo and text only when finished, and detail/edit/reload/export retain them',async()=>{
 const a=app(),before=a.stored();startPiece(a);assert.equal(a.$('#wizard-finish').disabled,true);
 addElement(a,'Imagen',{name:'Logo',power:'25',frameWidth:'30',frameHeight:'20'});
 assert.equal(a.$('#wizard-letter-fields').hidden,true);assert.equal(a.$('#wizard-items').children.length,1);
 addElement(a,'Letras',{name:'Nombre',letterHeight:'4',power:'12',speed:'2400'});
 assert.equal(a.$('#wizard-letter-fields').hidden,false);assert.equal(a.$('#wizard-items').children.length,2);assert.equal(a.stored(),before);
 a.$('#wizard-finish').click();assert.equal(a.rows().length,8);assert.equal(a.$('#wizard').open,false);
 const row=a.rows().at(-1);assert.equal(row.elements[0].power,25);assert.equal(row.elements[1].power,12);assert.equal(row.elements[1].letterHeight,4);assert.equal(row.power,undefined);
 assert.equal(a.$('#details-title').textContent,row.title);a.$('#details-edit').click();a.event('#piece-form','submit');
 a.$('#wizard-items').children[1].children[2].children[0].click();a.fillForm('#element-form',{power:'10'});a.event('#element-form','submit');a.$('#wizard-finish').click();
 assert.equal(a.rows().at(-1).elements[1].power,10);assert.equal(a.rows().at(-1).elements[0].power,25);
 const b=app(a.stored());b.$('#search').value='Nombre';b.event('#search','input');assert.equal(b.$('#rows').children.length,1);
 b.$('#export').click();const c=app(JSON.stringify({...backup,rows:[]}));await c.import(await b.blob().text());assert.deepEqual(c.rows(),b.rows());
 c.$('#rows').children.at(-1).children[0].click();c.$('#details-delete').click();assert.equal(c.rows().length,7);
});
test('wizard back, canceled element, removal and canceled edit never partially save',()=>{
 const a=app(),before=a.stored();startPiece(a);addElement(a,'Letras',{letterHeight:'3'});
 a.$('#wizard-back').click();assert.equal(a.$('#piece-form').elements.title.value,'Batería DeWalt 9Ah FlexVolt');a.event('#piece-form','submit');
 a.$('#wizard-add').click();a.$('#wizard-image').click();a.$('#wizard-element-cancel').click();assert.equal(a.$('#wizard-items').children.length,1);
 a.$('#wizard-items').children[0].children[2].children[1].click();assert.equal(a.$('#wizard-items').children.length,0);assert.equal(a.$('#wizard-finish').disabled,true);
 a.$('#wizard-close').click();assert.equal(a.stored(),before);
 startPiece(a);addElement(a,'Imagen');a.$('#wizard-finish').click();const saved=a.stored();
 a.$('#details-edit').click();a.fillForm('#piece-form',{title:'Unsaved'});a.event('#piece-form','submit');a.$('#wizard-close').click();assert.equal(a.stored(),saved);
});
test('wizard validation rejects invalid elements and bad imports atomically',async()=>{
 const a=app();startPiece(a);addElement(a,'Imagen',{power:'101'});assert.equal(a.$('#wizard-items').children.length,0);assert.equal(a.rows().length,7);
 a.fillForm('#element-form',{power:'15'});a.event('#element-form','submit');a.$('#wizard-finish').click();const saved=a.stored(),row=a.rows().at(-1);
 for(const elements of [[],[{...row.elements[0],power:101}],[{...row.elements[0],contentType:'Other'}],Array(101).fill(row.elements[0])]){
  await a.import(JSON.stringify({...backup,rows:[{...row,id:'bad',elements}]}));assert.equal(a.stored(),saved);
 }
});
