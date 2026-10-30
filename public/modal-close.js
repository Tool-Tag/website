/* Keep existing close handlers; only move each X outside its scrolling panel. */
(()=>{
 const seen=new WeakSet();
 const position=()=>document.querySelectorAll('dialog[open]').forEach(dialog=>{
  const r=dialog.getBoundingClientRect();dialog.querySelectorAll('.floating-modal-close').forEach(button=>{
   const outside=r.right+42<=innerWidth;
   button.style.setProperty('--close-top',`${outside?Math.max(6,r.top-18):Math.max(6,r.top-42)}px`);
   button.style.setProperty('--close-left',`${outside?r.right+6:Math.max(6,Math.min(innerWidth-42,r.right-36))}px`);
  });
 });
 const resize=new ResizeObserver(position);
 const refresh=()=>{
  document.querySelectorAll('dialog').forEach(dialog=>{
   if(!seen.has(dialog)){seen.add(dialog);resize.observe(dialog);}
   dialog.querySelectorAll('button.close,button[aria-label^="Close"]').forEach(button=>button.classList.add('floating-modal-close'));
  });position();
 };
 new MutationObserver(refresh).observe(document.body,{childList:true,subtree:true,attributes:true,attributeFilter:['open']});
 addEventListener('resize',position);addEventListener('scroll',position,true);refresh();
})();
