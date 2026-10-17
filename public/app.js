document.querySelector('#year').textContent = new Date().getFullYear();
// The public site is strictly English; Spanish is available only on driver policies.
document.documentElement.lang = 'en';
try { localStorage.setItem('tooltag-language', 'en'); } catch {}
document.dispatchEvent(new CustomEvent('tooltag:language', {detail: 'en'}));
const menuButton = document.querySelector('.menu-toggle');
const navigation = document.querySelector('#navigation');
function closeMenu() { menuButton.setAttribute('aria-expanded','false'); navigation.classList.remove('is-open'); }
menuButton.addEventListener('click', () => { const open = menuButton.getAttribute('aria-expanded') !== 'true'; menuButton.setAttribute('aria-expanded',String(open)); navigation.classList.toggle('is-open',open); });
navigation.querySelectorAll('a').forEach(a => a.addEventListener('click',closeMenu));
document.addEventListener('keydown', e => { if(e.key==='Escape') closeMenu(); });
document.addEventListener('click',e=>{ if(!navigation.contains(e.target) && !menuButton.contains(e.target)) closeMenu(); });


const getTaggedDialog = document.querySelector('#get-tagged-dialog');
const getTaggedFrame = document.querySelector('#get-tagged-frame');
const getTaggedClose = document.querySelector('#get-tagged-close');
const desktopGetTagged = window.matchMedia('(min-width: 1024px)');

function closeGetTaggedModal() {
  if (getTaggedDialog?.open) getTaggedDialog.close();
}

function openGetTaggedModal(event) {
  if (!desktopGetTagged.matches || !getTaggedDialog || !getTaggedFrame) return;
  event.preventDefault();
  closeMenu();
  if (!getTaggedFrame.getAttribute('src')) {
    getTaggedFrame.setAttribute('src', getTaggedFrame.dataset.src || '/get-tagged/modal');
  }
  if (!getTaggedDialog.open) getTaggedDialog.showModal();
}

document.querySelectorAll('a[href="/get-tagged"]').forEach(link => {
  link.addEventListener('click', openGetTaggedModal);
});

getTaggedClose?.addEventListener('click', closeGetTaggedModal);
getTaggedDialog?.addEventListener('click', event => {
  if (event.target === getTaggedDialog) closeGetTaggedModal();
});
desktopGetTagged.addEventListener('change', event => {
  if (!event.matches) closeGetTaggedModal();
});
window.addEventListener('message', event => {
  if (
    event.origin === window.location.origin &&
    event.data?.type === 'tooltag:get-tagged-close'
  ) {
    closeGetTaggedModal();
  }
});
