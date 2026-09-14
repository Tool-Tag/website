# ToolTag Hub — esqueleto y Falcon

## Rutas

- `dist/hub/index.html` → `/hub/`: entrada del hub con un solo módulo activo.
- `dist/hub/falcon/index.html` → `/hub/falcon/`: tabla editable de parámetros.
- `dist/hub/hub.css`: estilo compartido, negro, azul, dorado y blanco.
- `dist/hub/falcon/falcon-data.js`: esquema y validación de datos.
- `dist/hub/falcon/falcon.js`: formulario, tabla, filtros, guardado y respaldo.

La página pública existente no se modifica. No se agregan módulos BOFT ni enlaces vacíos. Para crecer, agregar otra carpeta de módulo y un enlace en `hub/index.html`. Este esqueleto no implementa login, API ni sincronización.

## Datos de Falcon

La primera apertura incluye las siete filas proporcionadas por el usuario. No son recomendaciones generadas. Si ya existe almacenamiento, se conserva intacto: importar ToolTag-Falcon-Parametros.json para agregar las filas. Los IDs evitan duplicarlas. Intervalo y escaneo se conservan, incluyendo 0.050 mm y Unidireccional. Modelo y fecha quedan vacíos porque no se proporcionaron. Registra material, espesor opcional, modelo/módulo Falcon, operación, potencia %, velocidad y unidad explícita mm/min o mm/s, pasadas, aire, enfoque con unidad, estado, fecha y notas. Los estados son registros del usuario, no certificaciones automáticas.

Se guarda en localStorage bajo `tooltag-falcon-v1`, separado del idioma y demás datos del sitio. Los datos pertenecen al navegador y al origen: file://, la vista de Vercel y el dominio definitivo no comparten almacenamiento. No usar como único respaldo. Exportar JSON y después importarlo en el dominio definitivo. Importar agrega registros sin reemplazar los existentes; IDs duplicados se omiten. Archivos inválidos se rechazan completos antes de escribir. Máximo 5000 pruebas / 5 MB por archivo importado.

La página no tiene protección de acceso. `noindex` solo desaconseja indexación y NO es autenticación. Los registros locales no se transmiten a un servidor.

## Integración

Copiar exclusivamente la carpeta `hub/` entregada dentro de `dist/` del repositorio `Tool-Tag/website`. Debe existir `dist/assets/favicon.svg`, ya presente en ToolTag. Mantener la configuración actual de Vercel para publicar `dist/`. No reemplazar la Home ni modificar la raíz de publicación. El despliegue de Vercel debe completarse antes de visitar `/hub/` y `/hub/falcon/`.

## Referencia y límites

Se pudo consultar el árbol público de https://github.com/Boftbuild/Boftbuild (hub y módulos separados en carpetas). No fue posible obtener el código interno de hub ni cargar https://tooltag.martinlab.studio/hub desde esta sesión; esta entrega no afirma ser una réplica de ese interior. Se conserva la separación de módulos y se aplica el estilo local vigente de ToolTag.

## Validación de esta integración

- Integrado en el repositorio local Tool-Tag/website, dentro de `dist/hub/`.
- La Home y todos sus archivos existentes permanecen intactos. El cambio previo de `.DS_Store` se conserva y no forma parte del Hub.
- ZIP comprobado contra los archivos preparados. Rutas relativas a Home, Hub, Falcon, CSS, scripts y favicon comprobadas en disco.
- Siete pruebas automatizadas de lógica aprobadas: semillas exactas; almacenamiento existente y tabla vacía; almacenamiento corrupto/bloqueado; búsqueda y filtro combinados; alta/edición/eliminación y recarga; exportación/importación con duplicados y rechazo atómico; validación de parámetros.
- Ejecutar desde la raíz del repositorio: `node --test tests/falcon.test.cjs`. Usa Node y dobles del DOM; no instala dependencias ni cambia datos del navegador.
- Nueva prueba deja la fecha vacía hasta que el usuario la registre.
- **Validación visual pendiente:** el navegador integrado negó acceso a la vista local porque no pudo verificar una política de seguridad administrada. No se ha verificado escritorio, móvil, interacción táctil, foco ni descarga/subida mediante los controles nativos del navegador. Las pruebas de lógica no sustituyen esa revisión.

## Publicar desde GitHub Desktop / Vercel

1. Revisar `dist/hub/`, `HUB.md`, `ToolTag-Falcon-Parametros.json` y `tests/falcon.test.cjs`. Dejar `.DS_Store` fuera del commit de esta integración.
2. Crear el commit, por ejemplo `Add ToolTag Hub and Falcon parameters`, y hacer Push origin cuando se decida publicar. Esta entrega no crea commits ni hace push.
3. Comprobar en el proyecto Vercel conectado a Tool-Tag/website que se sirve la carpeta `dist`. El repositorio no contiene `vercel.json` ni `.vercel/project.json`; no se pudieron confirmar los valores del panel ni la conexión/ramificación de producción. Si Root Directory es la raíz del repositorio, Output Directory debe ser `dist`; si Root Directory ya es `dist`, servir esa raíz. Este sitio estático no necesita instalación ni compilación; usar Other y Build Command vacío si se requiere configurar el proyecto. Conservar la configuración que ya funciona.
4. Si el despliegue automático está conectado a la rama publicada, esperar el estado Ready después del push; en caso contrario iniciar el despliegue desde Vercel.
5. Revisar `/`, `/hub/` y `/hub/falcon/` en la URL del despliegue. Confirmar que no haya una regla global que reescriba el Hub a la Home.
6. Completar la revisión visual en anchos 320, 390, 768 y 1366 px. Solo la tabla debe desplazarse horizontalmente. Abrir/cerrar el formulario con teclado, comprobar campos y botones, agregar/editar/eliminar una prueba desechable y recargar. Exportar JSON e importarlo en otra vista de prueba; repetir importación y comprobar que no duplique filas. No borrar datos reales para probar.

Documentación de Vercel: https://vercel.com/docs/builds/configure-a-build

Después del despliegue, las rutas previstas son https://tooltag.martinlab.studio/hub/ y https://tooltag.martinlab.studio/hub/falcon/. Esta entrega no afirma que estén publicadas.
