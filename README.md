# ToolTag V1

Sitio one-page responsive EN/ES. HTML, CSS y JavaScript sin dependencias de producción, sin compilación y sin servicios de terceros en el navegador.

## Revisar

Abra `dist/index.html` en un navegador, o sirva `dist/` con cualquier servidor estático. Para vista local: `python3 -m http.server 4173 --directory dist` y abra http://localhost:4173.

## Archivos

- `dist/index.html`: contenido, navegación, servicios, formulario modal y footer legal.
- `dist/styles.css`: diseño responsive negro, azul eléctrico, dorado y blanco.
- `dist/app.js`: traducciones EN/ES, preferencia de idioma y revisión local del formulario.
- `dist/assets/tooltag-logo.png`: copia sin modificaciones del logo real proporcionado.
- `dist/assets/favicon.svg`: favicon simple con la paleta de ToolTag.
- `.openai/hosting.json`: identificación del sitio y salida estática para Sites.

## Comportamiento de V1

Los CTA abren Get Tagged. El formulario valida nombre, email, ZIP estadounidense de cinco dígitos, cantidad y texto a marcar. “Review request / Revisar solicitud” muestra un resumen local; NO envía solicitudes. El botón de envío está deshabilitado. No hay endpoint, base de datos, analítica, uploads ni almacenamiento de datos personales. Solo la preferencia EN/ES se conserva en el navegador; un bloqueo de almacenamiento no impide usar la página.

El diálogo soporta teclado y Escape. El idioma también cambia etiquetas del formulario y descripción de la página; el slogan, los nombres comerciales de modalidades y la declaración legal se conservan.

## Pendientes deliberados

- Pricing y paquetes: Coming soon, sin enlace de precios ni importes activos.
- Teléfono y correo comercial: Coming soon, sin datos inventados.
- Canal de recepción: por definir; conectar un backend real antes de habilitar envío. Validar también en servidor y definir tratamiento de datos antes de recibir información personal.
- Fotos y logos del cliente: Coming soon, sin carga simulada.
- Tiempo de entrega: sin promesas de “fast turnaround”.
- Dirección y horario exactos: coordinar por solicitud; no se inventa una ubicación de drop-off.

## Referencia visual actual

Adaptación basada únicamente en la lectura del código de `index oficial.html` de BOFT, sin modificar ni ejecutar ese archivo. Se adopta su portada centrada, ancho contenido, fondo oscuro continuo, separadores finos, bloques simples y uso discreto de azul y dorado. Se conserva el slogan y logo real de ToolTag; no se copian servicios, contactos, textos legales ni contenido comercial de BOFT.

La foto protagonista, la franja blanca y las imágenes de producto de la revisión anterior ya no se cargan en la página. Sus archivos se conservan para referencia, sin uso activo. La V1 mantiene EN/ES, formulario local, servicios y pendientes deshabilitados.

## Publicación

`dist/` se puede alojar en cualquier hosting estático, incluido el dominio definitivo cuando se decida. No hacen falta variables de entorno para esta versión de revisión. El enlace Sites se mantiene privado.
