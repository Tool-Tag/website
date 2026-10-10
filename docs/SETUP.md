# ToolTag Phase 1 — puesta en marcha

## Estado y alcance

La Home y `public/hub` se conservan como archivos estáticos versionados. `public/` es la fuente canónica del sitio público y Next.js la sirve directamente durante desarrollo y build; no existe un paso de copia desde `dist/`. La aplicación privada vive en `/app`, las capacidades del cliente en `/accept/<token>` y `/completion/<token>`. Los enlaces privados se almacenan como SHA-256 en la base; no hay acceso anónimo general a tablas.

No se ha migrado ni modificado BOFT. Los registros de sus hojas no se importan en esta fase. La cuenta física arranca sin saldo conciliado; las asignaciones arrancan en cero. Nunca se presenta un cero de BOFT como saldo real.

## Desarrollo

1. Node 22+ y `npm ci`.
2. Copiar `.env.example` a `.env.local`. Usar Project URL y Publishable Key de **boft-core**. `.env.local` está ignorado y nunca debe subirse.
3. `npm run dev`, abrir `http://localhost:3000/app`.
4. `npm run typecheck`, `npm run lint`, `npm test`, `npm run test:db`, `npm run build`.

Las pruebas SQL ejecutan las migraciones completas con PostgreSQL embebido (PGlite), funciones `auth` mínimas de prueba y roles separados. No sustituyen la verificación final de Auth/SSR/PostgREST contra Supabase real.

## Supabase remoto

Project ref proporcionado por el usuario: `eoldyqqupkuggyyfhqkg`.

Estado: proyecto vinculado con el baseline consolidado aplicado. Las migraciones nuevas posteriores al baseline se mantienen forward-only y deben pasar CI/pruebas antes de aplicarse al remoto. No editar una migración que ya figure aplicada en Supabase.

Desde este repositorio:

```sh
npx supabase login
npx supabase projects list
npx supabase link --project-ref eoldyqqupkuggyyfhqkg
npx supabase db push --dry-run
npx supabase db push
```

Antes de aplicar: verificar que el proyecto listado sea **MartinLAB / boft-core** y que no haya tablas o migraciones ajenas. Si pide contraseña de base, introducirla en Terminal; no enviarla por chat ni guardarla en Git. No usar `db reset` contra producción.

Las migraciones bajo `supabase/migrations` crean esquema, seed de unidades/cuentas/categorías, RLS, funciones atómicas, vistas, auditoría y tareas. No hace falta crear tablas a mano.

## Primer administrador

1. En Supabase Auth crear/invitar el usuario real y definir su contraseña mediante el flujo de Supabase. Deshabilitar el registro público. Configurar Site URL y redirect URL `/auth/callback` del dominio de Vercel.
2. Ejecutar **una vez** el siguiente SQL en el proyecto correcto, sustituyendo el correo. No crea usuarios: exige una cuenta Auth existente.

```sql
DO $$
DECLARE admin_id uuid;
BEGIN
  SELECT id INTO admin_id FROM auth.users WHERE lower(email) = lower('REEMPLAZAR_EMAIL');
  IF admin_id IS NULL THEN RAISE EXCEPTION 'Crear primero el usuario en Auth'; END IF;
  INSERT INTO public.memberships (unit_id, user_id, role)
  SELECT id, admin_id, 'admin' FROM public.business_units
  ON CONFLICT (unit_id,user_id) DO UPDATE SET role='admin';
END $$;
```

Para tester: crear otra cuenta Auth y asignar `viewer` únicamente a ToolTag. Nunca otorgar permisos desde el navegador ni autoascender al primer usuario.

## Vercel

Conservar el dominio existente. Cambiar el proyecto de hosting estático a **Next.js**, Root Directory = raíz del repo; Build = `npm run build`; Output Directory = `.next` (sin el antiguo override `dist`). `vercel.json` versiona estas opciones. La configuración remota histórica no fue accesible desde los archivos locales: verificar sus overrides antes de publicar.

Agregar las variables públicas y server-only de `.env.example`. Probar primero un Preview Deployment. Verificar `/`, `/hub/`, `/hub/falcon/`, `/hub/tiempos/`, `/login` y `/app`.

### Review & Accept: logística y pagos

- Zelle y Venmo se configuran desde **Settings → Payments & Logistics**. No hay identificadores de negocio hardcodeados en el repo.
- La capacidad de Pickup de los sábados se configura con `max_pickup_stops_per_saturday`; el default de base es 10.
- El fee logístico de Review & Accept acepta Card, Zelle o Venmo; Cash no se presenta ni se acepta en ese paso.
- Zelle/Venmo quedan en verificación manual hasta que staff confirme el `payment_request`.
- Card usa Stripe Checkout mediante la abstracción de pagos. Configurar en Vercel:
  - `STRIPE_SECRET_KEY=sk_test_...` durante pruebas y `sk_live_...` sólo al activar producción.
  - `STRIPE_WEBHOOK_SECRET=whsec_...`.
  - webhook HTTPS: `/api/payments/stripe/webhook`, con los eventos de Checkout configurados en Stripe.
- Sin ambas claves Stripe, la opción Card queda deshabilitada; nunca se marca un pago de tarjeta como confirmado sólo por el retorno del navegador.
- `STRIPE_API_BASE` existe únicamente como override opcional para pruebas/integración; producción debe dejarlo vacío para usar el endpoint oficial.
- Los quotes ya aceptados antes de esta migración conservan su flujo histórico.

Para trabajo programado y entrega segura de archivos privados a clientes: configurar `SUPABASE_SECRET_KEY` o `SUPABASE_SERVICE_ROLE_KEY`, además de un `CRON_SECRET` aleatorio **solo en el entorno del servidor**. Nunca usar prefijo `NEXT_PUBLIC` para secretos. La ruta `/api/cron` devuelve 503 sin ellos y 401 sin autorización. Vercel invoca diariamente a las 08:00 UTC; el worker cierra el mes anterior de ToolTag una sola vez, con zona local configurable. Nunca cierra BOFT. El proceso es recuperable si una ejecución no ocurre el día 1.

## Primera prueba funcional

1. Entrar como admin. Publicar en Settings el texto real aprobado del acuerdo; no usar un texto de prueba con clientes reales.
2. Crear un cliente. Crear cotización con varios artículos/precios manuales.
3. Preparar enlace y abrir en ventana privada. Aprobar cotización y acuerdo con datos del aceptante.
4. Confirmar un solo Job y Sale con la misma secuencia. Reintentar aceptación no duplica.
5. Registrar cobros parciales hasta Paid; revisar recibo de cada cobro.
6. Registrar gasto pagado por Owner, comprobar saldo pendiente; reembolsarlo sin duplicar gasto.
7. Registrar compra de equipo y crear su Asset vinculado.
8. Subir evidencia real desde ToolTag; confirmar que el binario quedó en Supabase Storage y puede abrirse/descargarse antes de avanzar el trabajo.
9. Probar cliente: aceptar entrega o reportar problema. No se registra una aceptación expresa al autocerrar.
10. Cerrar un mes anterior. Cambiar fecha/descripción con motivo y verificar Reclose Required; adjuntar comprobante y verificar Documentation Updated.
11. Entrar como tester y comprobar que no puede escribir ni ver unidades ajenas.

## Integraciones pendientes (reales, no simuladas)

- Storage: Supabase Postgres conserva metadata/relaciones y Supabase Storage conserva todos los binarios nuevos. Google Drive queda únicamente como respaldo futuro; la app no crea ni actualiza archivos en Drive.
- Email/SMS: cola persistente, sin envíos. Enlaces se entregan manualmente. El plazo de 3 días solo empieza después de confirmar entrega del enlace; `completion_email_sent_at` permanece vacío sin email real.
- Recibos: snapshot consultable del pago (importe, método, fecha, total, cobrado, saldo, venta/trabajo); exportación PDF y copia al cliente pendientes del adaptador documental/mensajería.
- Términos legales definitivos: requeridos antes de compartir cotizaciones. No hay texto legal inventado.
- Primer usuario: crear la cuenta en Auth y asignar membresías. El proyecto remoto ya quedó vinculado y migrado.

## Decisiones y límites explícitos de esta fase

- Dinero: `numeric(14,2)` en SQL; centavos `bigint` para cálculos de cotización en UI. Los resúmenes se calculan en SQL, no sumando páginas descargadas.
- Venta = ingreso comercial; cobro = efectivo. Equipo separado del gasto operativo; no depreciación automática. Net Position = utilidad acumulada menos inversión neta en equipo. Available = efectivo atribuido menos deuda al dueño; otras cuentas por pagar no se modelan todavía.
- Los importes ya publicados se corrigen por revisiones/devoluciones; el formulario permite corregir fecha/descripción/estado con motivo, no reescribir libremente un cobro histórico.
- Revisión de venta debajo de lo ya cobrado se bloquea para resolución administrativa. Devoluciones a proveedores de gastos Owner ya reembolsados se bloquean por el saldo pendiente; hace falta definir cómo devuelve el dueño ese dinero antes de habilitar ese caso.
- Cierres guardan números, movimientos y advertencias versionados. Un cambio material marca recierre, no destruye el snapshot anterior.
- Preferencia Fuel/Mileage preserva ambos historiales, pero el reporte selecciona uno. Tarifa de millaje configurable; no se asume tarifa fiscal.
- Los listados iniciales muestran hasta 200 registros (20 movimientos en Hub). Los agregados financieros se calculan sobre todos los movimientos. Paginación avanzada/exportes amplios son una extensión pendiente.
- Quote Sent significa enlace preparado para compartir manualmente; la cola muestra Pending Integration, nunca email enviado.
- La aceptación usa posesión de enlace privado de alta entropía y datos del aceptante; no es identidad verificada por OTP ni firma certificada.
