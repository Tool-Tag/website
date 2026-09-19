const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');const vm=require('node:vm');
const dir=path.resolve(__dirname,'../dist/hub/tiempos');const data=require(path.join(dir,'times-data.js'));
const row={id:'sample',title:'Batería',letters:10,letterHeight:4,frameWidth:40,frameHeight:12,seconds:90,notes:''};
function app(saved=null){
 class El{constructor(){this.value='';this.children=[];this.listeners={};}addEventListener(k,f){this.listeners[k]=f;}setAttribute(){}append(x){this.children.push(x);}replaceChildren(){this.children=[];}click(){return this.listeners.click?.({target:this});}showModal(){this.open=true;}close(){this.open=false;}focus(){}}
 const els=new Map(),$=k=>{if(!els.has(k))els.set(k,new El());return els.get(k);},form=$('#form');const names=['title','letters','letterHeight','frameWidth','frameHeight','minutes','remainder','notes','contentType','mode'];
 form.elements=Object.fromEntries(names.map(k=>[k,new El()]));form.elements.namedItem=k=>form.elements[k];form.reset=()=>names.forEach(k=>form.elements[k].value='');form.reportValidity=()=>true;
 let stored=saved,blob,fail=false;const context=vm.createContext({document:{querySelector:$,createElement:()=>new El()},localStorage:{getItem:()=>stored,setItem:(k,v)=>{assert.equal(k,'tooltag-times-v1');if(fail)throw Error('full');stored=v;}},Blob,URL:{createObjectURL:b=>{blob=b;return 'blob:test';},revokeObjectURL(){}},setTimeout:f=>f(),confirm:()=>true,FormData:class{constructor(){return names.filter(k=>!form.elements[k].disabled).map(k=>[k,form.elements[k].value]);}}});context.window=context;
 for(const file of ['times-data.js','times.js'])vm.runInContext(fs.readFileSync(path.join(dir,file),'utf8'),context);
 const event=(id,k)=>$(id).listeners[k]({target:$(id),preventDefault(){}});
 return {$,event,stored:()=>stored,blob:()=>blob,fill:values=>Object.entries(values).forEach(([k,v])=>form.elements[k].value=v),block:()=>{fail=true;},async import(text){$('#file').files=[{size:Buffer.byteLength(text),text:async()=>text}];await event('#file','change');}};
}
test('duration and dimensions validate without inventing values',()=>{
 assert.equal(data.duration('1','30'),90);assert.equal(data.duration('','45'),45);
 for(const pair of [['',''],['0','60'],['-1','5'],['1.5','0']])assert.throws(()=>data.duration(...pair));
 for(const change of [{letters:1.5},{letterHeight:0},{frameWidth:-2},{seconds:0},{title:' '},{letters:true}])assert.throws(()=>data.validate({...row,...change}));
 assert.deepEqual(data.parse(data.encode([row])),[row]);assert.throws(()=>data.parse(data.encode([row,row])));
});
test('create, detail, edit, persistence, search, export, import, delete',async()=>{
 const a=app();assert.equal(a.stored(),null);a.$('#add').click();a.fill({title:'Batería',letters:'10',letterHeight:'4',frameWidth:'40',frameHeight:'12',minutes:'1',remainder:'30',notes:'Prueba'});a.event('#form','submit');
 assert.equal(JSON.parse(a.stored()).rows[0].seconds,90);a.$('#rows').children[0].children[0].click();assert.equal(a.$('#details-title').textContent,'Batería');a.$('#details-edit').click();a.fill({remainder:'45'});a.event('#form','submit');
 const b=app(a.stored());assert.equal(JSON.parse(b.stored()).rows[0].seconds,105);b.$('#search').value='no match';b.event('#search','input');assert.equal(b.$('#rows').children.length,0);b.$('#search').value='';b.event('#search','input');
 b.$('#export').click();const text=await b.blob().text(),c=app();await c.import(text);await c.import(text);assert.equal(JSON.parse(c.stored()).rows.length,1);
 c.$('#rows').children[0].children[0].click();c.$('#details-delete').click();assert.equal(JSON.parse(c.stored()).rows.length,0);
});
test('bad imports, corrupt storage and failed saves preserve data',async()=>{
 const a=app(data.encode([row])),before=a.stored();await a.import(data.encode([{...row,id:'new'}, {...row,id:'bad',letters:0}]));assert.equal(a.stored(),before);
 await a.import('{bad');assert.equal(a.stored(),before);
 const b=app('{bad');assert.equal(b.$('#add').disabled,true);assert.equal(b.stored(),'{bad');
 a.$('#rows').children[0].children[0].click();a.$('#details-edit').click();a.fill({title:'Changed'});a.block();a.event('#form','submit');assert.equal(a.stored(),before);assert.equal(a.$('#editor').open,true);
});
test('root-relative routes work with and without trailing slash',()=>{
 const html=fs.readFileSync(path.join(dir,'index.html'),'utf8'),root=path.resolve(dir,'../..');
 for(const base of ['/hub/tiempos','/hub/tiempos/'])for(const [,ref]of html.matchAll(/(?:src|href)="([^"]+)"/g)){assert.ok(ref.startsWith('/'));assert.ok(fs.existsSync(path.join(root,new URL(ref,'https://example.com'+base).pathname)));}
});


test('Letras enables Fill/Line; Imagen disables mode and saves without letter dimensions',async()=>{
 const a=app();a.$('#add').click();assert.equal(a.$('#form').elements.mode.disabled,true);
 a.fill({title:'Texto',contentType:'Letras',mode:'Line',letters:'5',letterHeight:'4',frameWidth:'30',frameHeight:'10',minutes:'1'});a.event('#content-type','change');assert.equal(a.$('#form').elements.mode.disabled,false);a.event('#form','submit');
 assert.equal(JSON.parse(a.stored()).rows[0].mode,'Line');a.$('#rows').children[0].children[0].click();a.$('#details-edit').click();assert.equal(a.$('#form').elements.mode.value,'Line');
 a.fill({contentType:'Imagen'});a.event('#content-type','change');assert.equal(a.$('#form').elements.mode.disabled,true);a.event('#form','submit');assert.equal(JSON.parse(a.stored()).rows[0].mode,undefined);
 a.$('#add').click();a.fill({title:'Logo',contentType:'Imagen',frameWidth:'20',frameHeight:'20',remainder:'45'});a.event('#content-type','change');a.event('#form','submit');assert.equal(JSON.parse(a.stored()).rows[0].letters,undefined);
 a.$('#export').click();const b=app();await b.import(await a.blob().text());assert.deepEqual(JSON.parse(b.stored()),JSON.parse(a.stored()));
 assert.throws(()=>data.validate({...row,contentType:'Letras',mode:'Other'}));assert.equal(data.validate({...row,contentType:'Letras',mode:'Fill'}).mode,'Fill');
});
