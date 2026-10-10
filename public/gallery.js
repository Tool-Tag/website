(() => {
  'use strict';
  const config = window.TOOLTAG_GALLERY || {};
  const photos = (Array.isArray(config.photos) ? config.photos : []).filter(p =>
    p && p.real === true && typeof p.src === 'string' && p.src.trim() && p.alt?.en && p.alt?.es);
  const limit = Math.max(4, Math.min(6, Number(config.homeLimit) || 4));
  const featured = photos.filter(p => p.featured !== false).slice(0, limit);
  const section = document.querySelector('#work');
  if (!featured.length) return;
  const track = document.querySelector('#work-track');
  const modal = document.querySelector('#work-dialog');
  const expanded = document.querySelector('#work-expanded');
  const figure = document.querySelector('#work-figure');
  const full = document.querySelector('#work-full');
  const caption = document.querySelector('#work-caption');
  const count = document.querySelector('#work-count');
  const error = document.querySelector('#work-error');
  const controls = modal.querySelector('.work-controls');
  const more = document.querySelector('#work-more');
  let lang = document.documentElement.lang === 'es' ? 'es' : 'en';
  let selected = 0, mode = 'photo', opener, previousOverflow, previousPadding, scrollY;
  const words = () => lang === 'es' ? {title:'Así dejamos tu marca.',close:'Cerrar galería',prev:'Foto anterior',next:'Foto siguiente',more:'Ver más trabajos',open:'Ampliar foto',error:'No se pudo cargar esta foto.'} : {title:'See the Mark.',close:'Close gallery',prev:'Previous photo',next:'Next photo',more:'View More',open:'Enlarge photo',error:'This photo could not be loaded.'};
  const localized = value => value?.[lang] || value?.en || '';
  function tile(photo, parent) {
    const item = document.createElement('div'); item.className='work-item'; item.setAttribute('role','listitem');
    const button = document.createElement('button'); button.type='button'; button.className='work-photo';
    const img = document.createElement('img'); img.src=photo.src; img.alt=localized(photo.alt); img.loading='lazy'; img.decoding='async'; img.width=640; img.height=480;
    button.setAttribute('aria-label', `${words().open}: ${localized(photo.alt)}`);
    button.append(img);
    const label = localized(photo.label);
    if(label){const text=document.createElement('span');text.className='work-label';text.textContent=label;button.append(text);}
    button.addEventListener('click',()=>{selected=photos.indexOf(photo);mode='photo';showPhoto();open(button);});
    item.append(button);parent.append(item);
  }
  function showPhoto() {
    mode='photo'; expanded.hidden=true;figure.hidden=false;controls.hidden=photos.length<2;error.hidden=true;
    const p=photos[selected]; full.alt=localized(p.alt);full.src=p.full || p.src;
    caption.textContent=localized(p.label);count.textContent=`${selected+1} / ${photos.length}`;
  }
  full.addEventListener('error',()=>{error.textContent=words().error;error.hidden=false;});
  full.addEventListener('load',()=>{error.hidden=true;});
  function open(button) {
    if(modal.open) return;
    opener=button;scrollY=window.scrollY;previousOverflow=document.body.style.overflow;previousPadding=document.body.style.paddingRight;
    const gap=window.innerWidth-document.documentElement.clientWidth;
    if(gap>0) document.body.style.paddingRight=`${parseFloat(getComputedStyle(document.body).paddingRight)+gap}px`;
    document.body.style.overflow='hidden';modal.showModal();document.querySelector('#work-close').focus();
  }
  modal.addEventListener('close',()=>{
    document.body.style.overflow=previousOverflow;document.body.style.paddingRight=previousPadding;
    window.scrollTo({top:scrollY,behavior:'instant'});opener?.focus({preventScroll:true});
  });
  document.querySelector('#work-close').addEventListener('click',()=>modal.close());
  let outsideDown=false;
  const outside = e => {const r=modal.getBoundingClientRect();return e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom;};
  modal.addEventListener('pointerdown',e=>{outsideDown=outside(e);});
  modal.addEventListener('click',e=>{if(outsideDown&&outside(e))modal.close();outsideDown=false;});
  function step(delta){selected=(selected+delta+photos.length)%photos.length;showPhoto();}
  document.querySelector('#work-prev').addEventListener('click',()=>step(-1));
  document.querySelector('#work-next').addEventListener('click',()=>step(1));
  modal.addEventListener('keydown',e=>{if(mode==='photo'&&['ArrowLeft','ArrowRight'].includes(e.key)){e.preventDefault();step(e.key==='ArrowRight'?1:-1);}});
  track.addEventListener('keydown',e=>{
    const buttons=[...track.querySelectorAll('button')],i=buttons.indexOf(e.target);
    if(i<0||!['ArrowLeft','ArrowRight','Home','End'].includes(e.key))return;
    e.preventDefault(); const next=e.key==='Home'?0:e.key==='End'?buttons.length-1:Math.max(0,Math.min(buttons.length-1,i+(e.key==='ArrowRight'?1:-1)));
    buttons[next].focus({preventScroll:true});buttons[next].scrollIntoView({block:'nearest',inline:'nearest',behavior:'instant'});
  });
  more.addEventListener('click',()=>{mode='all';expanded.hidden=false;figure.hidden=true;controls.hidden=true;error.hidden=true;open(more);});
  function translate() {
    const w=words();track.replaceChildren();featured.forEach(p=>tile(p,track));expanded.replaceChildren();photos.forEach(p=>tile(p,expanded));
    document.querySelector('#work-dialog-title').textContent=w.title;
    document.querySelector('#work-close').setAttribute('aria-label',w.close);
    document.querySelector('#work-prev').setAttribute('aria-label',w.prev);
    document.querySelector('#work-next').setAttribute('aria-label',w.next);
    more.textContent=w.more;more.hidden=!(config.enableViewMore===true&&photos.length>featured.length);
    if(modal.open&&mode==='photo')showPhoto();
  }
  document.addEventListener('tooltag:language',e=>{lang=e.detail==='es'?'es':'en';translate();});
  expanded.setAttribute('role','list');translate();section.hidden=false;
})();
