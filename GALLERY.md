# Galería ToolTag

## Estado de entrega

Implementada después de What We Tag y antes de How It Works. `dist/gallery-data.js` contiene `photos: []`: la sección queda oculta, no ocupa espacio y no carga imágenes. No se publican ejemplos ni mockups como trabajos reales. El resto del sitio conserva su estructura y estilos.

## Agregar trabajos reales

1. Copiar las fotos reales en `dist/assets/work/`. Se recomiendan miniaturas WebP/JPEG de 800–1200 px y una versión grande si es necesaria.
2. Editar solamente `dist/gallery-data.js`. Reemplazar la lista vacía con objetos como este, usando archivos reales existentes:

```js
window.TOOLTAG_GALLERY = {
  homeLimit: 4,
  enableViewMore: false,
  photos: [
    {
      src: 'assets/work/battery-01.webp',
      full: 'assets/work/battery-01-full.webp', // Opcional; si falta se usa src.
      real: true, // Solo confirmar para una foto de un trabajo real terminado.
      featured: true,
      label: {
        en: 'Battery · Name + Phone',
        es: 'Batería · Nombre y teléfono'
      },
      alt: {
        en: 'Battery showing the customer’s engraved name and phone number',
        es: 'Batería con el nombre y teléfono del cliente grabados'
      }
    }
  ]
};
```

Las descripciones deben corresponder a cada fotografía. Ambos textos alternativos EN/ES y `real: true` son obligatorios. Las etiquetas son opcionales. El orden de la lista define el orden visible. Confirmar que se pueden mostrar los datos personales que aparezcan en las fotos antes de agregarlas.

## Selección y crecimiento

- La Home muestra las primeras fotos destacadas, hasta `homeLimit` (entre 4 y 6; si hay menos, muestra las disponibles).
- `featured: false` reserva una foto para la galería ampliada, sin mostrarla en Home.
- Desktop usa cuatro columnas visibles de proporción 4:3; si se configuran 5–6, se recorren horizontalmente en la misma fila.
- Móvil usa una foto al 86% del ancho y una parte de la siguiente, desplazamiento nativo y scroll-snap.
- `enableViewMore: true` habilita “View More / Ver más trabajos” cuando hay más fotos que las mostradas en Home. Abre la colección en el mismo modal, sin ampliar la página.

## Interacción

Botones accesibles para cada foto. Enter/espacio abre el lightbox. Escape, X o click en el fondo exterior lo cierra. Flechas izquierda/derecha cambian de foto; en la fila permiten mover el foco y desplazarla (también Home/End). El diálogo nativo mantiene el foco dentro y el cierre lo devuelve al disparador. Se conserva el scroll y el estilo de overflow previo de la página. Los títulos, controles, etiquetas y descripciones cambian con EN/ES.

## Verificación pendiente en navegador

Se comprobaron sintaxis, ubicación, configuración vacía y aislamiento de cambios. La política de seguridad del navegador de esta sesión bloqueó abrir la copia de pruebas, por lo que NO se afirma haber validado layout, swipe táctil o scroll del modal en un navegador real.

Antes de activar las fotos, revisar en la vista de Vercel:

- 320, 390, 768 y 1366 px: el documento no debe desplazarse horizontalmente; solo la fila de fotos.
- 1, 4 y 6 fotos: proporciones estables, sin estirar las fotos.
- En teléfono: deslizar la fila, comprobar la imagen siguiente parcialmente visible.
- Abrir/cerrar con X, fondo exterior y Escape; la página debe volver a la misma posición.
- Tab queda dentro del modal; al cerrar vuelve a la foto original. Flechas y Home/End recorren la fila.
- EN/ES traduce título, controles, etiquetas y textos alternativos.
- Activar View More con más fotos y comprobar la colección ampliada.

## GitHub / Vercel

Reemplazar el proyecto conservando `dist/` como directorio publicado. No hay instalación de dependencias ni compilación. Conservar `gallery-data.js` y `gallery.js` junto a `index.html`, `app.js` y `styles.css`. El ZIP de sitio listo contiene directamente esos archivos, con `index.html` en la raíz; el ZIP de proyecto incluye documentación y la carpeta `dist/`.
