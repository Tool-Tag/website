const dialog = document.querySelector('#request-dialog');
document.querySelectorAll('[data-open]').forEach(button => button.addEventListener('click', () => { dialog.showModal(); document.body.style.overflow = 'hidden'; }));
document.querySelector('[data-close]').addEventListener('click', () => dialog.close());
dialog.addEventListener('close', () => { document.body.style.overflow = ''; });
document.querySelector('#year').textContent = new Date().getFullYear();
const translations = {
  send:'Envío · Próximamente', skip:'Ir al contenido', eyebrow:'MARCAJE DE HERRAMIENTAS. A TU MEDIDA.', intro:'Pon tu nombre en el equipo que tanto te cuesta ganar. Marcaje personalizado para herramientas, baterías y equipo.', heroCta:'Marca tus herramientas', seeHow:'Cómo funciona ↓', audience:'Para trabajadores de oficio, cuadrillas y empresas.', artCaption:'HAZLO TUYO.', stripModes:'Drop-off / Pick-up + Mobile / On-site', stripDays:'Viernes · Sábado · Domingo', stripArea:'Wasatch Front y alrededores', built:'PARA TU DÍA DE TRABAJO', what:'Qué marcamos.', markOptions:'Nombres. Empresas. Teléfonos.\nIDs de herramientas. Logos.', tools:'Herramientas', toolsText:'Las que usas todos los días. Dale a cada herramienta una marca propia.', toolsMeta:'MANUALES · ELÉCTRICAS', batteries:'Baterías', batteriesText:'Misma batería. Distinto dueño. Que las tuyas se reconozcan.', batteryMeta:'BATERÍAS · CARGADORES', equipment:'Equipo', equipmentText:'Desde una pieza hasta el equipo de toda la cuadrilla. Ponle tu identidad.', equipmentMeta:'EQUIPO PERSONAL · DE CUADRILLA', compatibility:'El marcaje depende del material y la superficie. Confirmamos compatibilidad antes de comenzar.', simple:'TRES PASOS. TU MARCA.', howTitle:'Cómo funciona.', weekend:'Tu fin de semana. Tu equipo.', choose:'Elige tu marca', chooseText:'Dinos qué piezas tienes y qué quieres marcar en ellas.', coordinate:'Elige el servicio', coordinateText:'Entrega tu equipo o pide servicio móvil. Confirmamos los detalles antes de marcar.', own:'Hazlo tuyo', ownText:'Aprueba tu marca, recibe tu equipo marcado y vuelve al trabajo.', dropText:'Trae tu equipo y recógelo cuando esté listo. Confirmamos ubicación y horarios al coordinar.', mobileText:'Vamos a tu ubicación en Wasatch Front y alrededores. Confirmamos disponibilidad y condiciones de traslado para cada solicitud.', days:'Viernes, sábado y domingo · Previa coordinación', pricing:'Precios y paquetes · Próximamente', ready:'TU EQUIPO. TU IDENTIDAD.', readyTitle:'Deja tu marca en tu equipo.', readyText:'Una herramienta o toda una cuadrilla. Empecemos con los detalles.', get:'Get Tagged', contactSoon:'Teléfono y correo · Próximamente', request:'TU SOLICITUD DE MARCAJE', formNotice:'Vista previa: todavía no se envían solicitudes. Puedes llenar y revisar tus datos mientras definimos el canal de contacto.', name:'Tu nombre *', customer:'Tipo de cliente *', individual:'Particular', company:'Empresa / Cuadrilla', companyName:'Empresa (opcional)', contact:'Tu correo electrónico *', phone:'Tu teléfono (opcional)', zip:'Código postal del servicio *', quantity:'Cantidad aproximada de piezas *', itemType:'¿Qué vamos a marcar? *', mix:'Una combinación de piezas', serviceMode:'Modalidad de servicio *', day:'Día de preferencia *', friday:'Viernes', saturday:'Sábado', sunday:'Domingo', mark:'¿Qué quieres marcar en tus piezas? *', uploads:'Fotos y logo · Próximamente', review:'Revisar solicitud', privacy:'Tus datos permanecen en esta página. No se envían ni guardan; se borran al cerrar la página.', services:'Servicios', seeServices:'Ver servicios', how:'Cómo funciona'
};
// Freeze option values before translating their visible labels.
document.querySelectorAll('option').forEach(option => { option.value = option.value; });
Object.assign(translations, {
 eyebrow:'IDENTIFICACIÓN PROFESIONAL DE HERRAMIENTAS',
 intro:'Marcaje láser personalizado\npara cuadrillas, contratistas y particulares.',
 heroCta:'MARCA TUS HERRAMIENTAS', how:'CÓMO FUNCIONA',
 toolsText:'Taladros, sierras, clavadoras,\nherramientas manuales y más.',
 batteriesText:'Tu energía,\ndonde debe estar.',
 equipmentText:'Escaleras, compresores,\ncajas y más.',
 factMark:'TU NOMBRE.\nTU EMPRESA. TU MARCA.',
 factModes:'ENTREGA / RECOGIDA\nO VAMOS A TU UBICACIÓN',
 factDays:'VIERNES – DOMINGO\nWASATCH FRONT Y ALREDEDORES',
 trades:'HECHO PARA\nLOS OFICIOS', namesLabel:'NOMBRES', companyLabel:'EMPRESA', phoneLabel:'TELÉFONO', idsLabel:'IDS DE EQUIPO', logosLabel:'LOGOS'
});
Object.assign(translations, {
 eyebrow:'MARCAJE PERSONALIZADO DE HERRAMIENTAS', intro:'Marcaje láser para tus herramientas, baterías y equipo.',
 heroLocation:'Wasatch Front y alrededores · Viernes–domingo', serviceEyebrow:'01 / EL EQUIPO', howEyebrow:'02 / EL PROCESO',
 how:'Cómo funciona', what:'Qué marcamos.', toolsText:'Taladros, sierras, clavadoras y herramientas manuales.', batteriesText:'Baterías y cargadores.', equipmentText:'Cajas, escaleras y equipo de cuadrilla.',
 markOptions:'Nombres · Empresa · Teléfono · IDs de equipo · Logos', chooseText:'Dinos qué tienes y qué quieres marcar.', coordinate:'Coordina tu servicio', coordinateText:'Confirmamos compatibilidad, precio y horario.', own:'Recibe tu equipo marcado', ownText:'Aprueba el diseño. Dale tu identidad a tu equipo.',
 dropText:'Trae tu equipo y recógelo cuando esté listo. Coordinamos ubicación y horario.', mobileText:'Vamos a tu ubicación. Confirmamos disponibilidad y traslado por solicitud.',
 days:'Viernes, sábado y domingo · Wasatch Front y alrededores', compatibility:'Confirmamos compatibilidad del material y la superficie antes de marcar.', readyTitle:'¿Listo para hacerlo tuyo?', readyText:'Comienza con tus herramientas y tu idea.'
});
Object.assign(translations, {workEyebrow:'NUESTRO TRABAJO', workTitle:'Así dejamos tu marca.'});
const original = new Map();
document.querySelectorAll('[data-i]').forEach(el => original.set(el, el.innerHTML));
let language = 'en';
function setLanguage(next) {
  language = next;
  document.documentElement.lang = next;
  document.querySelectorAll('[data-i]').forEach(el => {
    if(next === 'es' && translations[el.dataset.i]) el.textContent = translations[el.dataset.i];
    else el.innerHTML = original.get(el);
  });
  document.querySelectorAll('[data-language]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.language === next)));
  document.querySelector('[data-close]').setAttribute('aria-label', next === 'es' ? 'Cerrar formulario' : 'Close form');
  document.querySelector('meta[name="description"]').content = next === 'es' ? 'Marcaje personalizado de herramientas en Wasatch Front y alrededores. Entrega y servicio móvil, de viernes a domingo.' : 'Personalized tool marking across the Wasatch Front and surrounding areas. Drop-off and mobile service, Friday through Sunday.';
  document.querySelector('#review').hidden = true;
  try { localStorage.setItem('tooltag-language', next); } catch {}
  document.dispatchEvent(new CustomEvent('tooltag:language', {detail: next}));
}
document.querySelectorAll('.languages button').forEach(button => {
  button.dataset.language = button.textContent.toLowerCase();
  button.addEventListener('click', () => setLanguage(button.dataset.language));
});
try { setLanguage(localStorage.getItem('tooltag-language') === 'es' ? 'es' : 'en'); } catch { setLanguage('en'); }
const form = document.querySelector('#request-form');
form.addEventListener('submit', event => {
  event.preventDefault();
  if(!form.reportValidity()) return;
  const data = new FormData(form);
  const summary = document.querySelector('#review');
  const value = key => String(data.get(key) || '').trim();
  const selected = key => form.elements[key].selectedOptions[0].textContent;
  summary.textContent = language === 'es'
    ? `Solicitud revisada — NO enviada\n\n${value('name')}${value('company') ? ' · ' + value('company') : ''}\n${value('email')}${value('phone') ? ' · ' + value('phone') : ''}\n${value('quantity')} piezas · ${selected('items')}\n${selected('mode')} · ${selected('day')} · ZIP ${value('zip')}\n\nTu marca: ${value('mark')}\n\nEl envío estará disponible cuando se confirme el canal de contacto. La fecha, compatibilidad y precio requieren confirmación.`
    : `Request reviewed — NOT sent\n\n${value('name')}${value('company') ? ' · ' + value('company') : ''}\n${value('email')}${value('phone') ? ' · ' + value('phone') : ''}\n${value('quantity')} items · ${selected('items')}\n${selected('mode')} · ${selected('day')} · ZIP ${value('zip')}\n\nYour mark: ${value('mark')}\n\nSending will be available once the contact channel is confirmed. Date, compatibility and pricing require confirmation.`;
  summary.hidden = false;
  summary.setAttribute('tabindex', '-1');
  summary.focus();
  summary.scrollIntoView({block:'nearest'});
});
form.addEventListener('input', () => { document.querySelector('#review').hidden = true; });

const menuButton = document.querySelector('.menu-toggle');
const navigation = document.querySelector('#navigation');
function closeMenu() { menuButton.setAttribute('aria-expanded','false'); navigation.classList.remove('is-open'); }
menuButton.addEventListener('click', () => { const open = menuButton.getAttribute('aria-expanded') !== 'true'; menuButton.setAttribute('aria-expanded',String(open)); navigation.classList.toggle('is-open',open); });
navigation.querySelectorAll('a').forEach(a => a.addEventListener('click',closeMenu));
document.addEventListener('keydown', e => { if(e.key==='Escape') closeMenu(); });
document.addEventListener('click',e=>{ if(!navigation.contains(e.target) && !menuButton.contains(e.target)) closeMenu(); });
