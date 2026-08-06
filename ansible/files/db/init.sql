-- Esquema inicial: usuarios con rol (usuario/admin/analytics) y el sitio de
-- cada uno, guardado tal cual el JSON único que ya arma el frontend (ver
-- src/utils/siteSchema.js). "analytics" es un rol acotado (Admin > Leads y
-- Admin > Analytics nada más, ver requireAnyRole en middleware/auth.js) para
-- alguien de marketing/ventas que necesita consultar y sacar reportes sin
-- acceso al resto del panel (páginas, plantillas, usuarios, etc).
CREATE TYPE user_role AS ENUM ('usuario', 'admin', 'analytics');

CREATE TABLE users (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  email TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  role user_role NOT NULL DEFAULT 'usuario',
  -- Cuentas de prueba a las que les regalamos el servicio (Admin > Usuarios):
  -- cuántas de sus páginas publicadas no se cobran. Con una sola página por
  -- cuenta hoy, alcanza con que sea >= 1 para que esa página sea gratis.
  free_subscriptions INTEGER NOT NULL DEFAULT 0,
  -- Última vez que este admin entró a Admin > Soporte (Admin.jsx) — de ahí
  -- sale cuántos tickets/mensajes son "nuevos" para su propio contador
  -- (cada admin tiene el suyo, no es un estado global compartido).
  support_last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Cuándo esta cuenta aceptó los Términos y Condiciones (ver TermsGate.jsx)
  -- — mientras sea NULL, se le sigue mostrando el gate al entrar. Se completa
  -- solo (nunca hay que tocarlo a mano): al registrarse (ya pasó por el
  -- gate para llegar ahí) o al aceptar estando logueado (POST
  -- /api/terms/accept, ver terms.js). No reemplaza terms_acceptances (que
  -- sigue registrando cada aceptación anónima por session_id, para poder
  -- probar que un lead sin cuenta también aceptó) — esto es solo el atajo
  -- "esta cuenta puntual ya firmó, no le vuelvas a preguntar".
  terms_accepted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE sites (
  id SERIAL PRIMARY KEY,
  user_id INTEGER NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  data JSONB NOT NULL,
  published BOOLEAN NOT NULL DEFAULT false,
  -- Subdominio elegido por el dueño (Dashboard > Configuración), ej.
  -- "panaderia-sur" para panaderia-sur.sitiowebdigital.com.ar. NULL hasta que
  -- lo define — Postgres permite múltiples NULL bajo UNIQUE, así que no
  -- bloquea a quien todavía no lo eligió. Es identidad pública de la cuenta:
  -- vive como columna propia, no duplicada dentro de `data` (a diferencia de
  -- `published`, que sí se duplica porque el propio dueño la lee al hidratar
  -- su sitio) — el lookup público (GET /api/public/sites/:subdomain) consulta
  -- esta columna directo.
  subdomain TEXT UNIQUE,
  -- Bloqueo de edición desde soporte (Admin > Páginas): mientras esté en true,
  -- PUT /api/sites/me lo rechaza — el dueño no puede editar/guardar, pero un
  -- admin sí (usa /api/admin/sites/:id, que no chequea este campo).
  locked BOOLEAN NOT NULL DEFAULT false,
  -- Suscripción real de Mercado Pago (un "preapproval" por página, todas
  -- contra el mismo plan compartido — ver server/src/utils/mercadopago.js).
  -- 'none' hasta que se manda a pagar; 'pending_redirect' apenas se lo manda
  -- al checkout de Mercado Pago (antes de saber si de verdad va a pagar);
  -- 'pending' | 'authorized' | 'paused' | 'cancelled' reflejan el estado real
  -- que informa Mercado Pago (por webhook o al consultar la API).
  mp_preapproval_id TEXT,
  mp_subscription_status TEXT NOT NULL DEFAULT 'none',
  mp_pending_since TIMESTAMPTZ,
  mp_payer_email TEXT,
  -- Próximo cobro real que informa Mercado Pago (next_payment_date del
  -- preapproval) — se completa en applyPreapprovalToSite (webhook o
  -- /me/refresh), nunca calculado a mano acá.
  mp_next_payment_date TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Visitas y clics en WhatsApp de la página PUBLICADA de cada cliente (no
-- confundir con analytics_events, que es telemetría de NUESTRA propia app
-- SaaS) — lo llena PublicSite.jsx en cada visita real, anónima, de un
-- cliente final (ver server/src/routes/publicSites.js). Alimenta los KPIs
-- reales del Dashboard y de Estadísticas (antes hardcodeados).
CREATE TABLE site_analytics_events (
  id SERIAL PRIMARY KEY,
  site_id INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
  event_type TEXT NOT NULL CHECK (event_type IN ('visita', 'whatsapp_click')),
  -- Solo tiene sentido en 'visita' — de dónde vino esa visita, clasificado
  -- grueso a partir de document.referrer del lado del cliente.
  referrer_bucket TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_site_analytics_events_site_id ON site_analytics_events (site_id, event_type, created_at);

-- Consultas a soporte (Dashboard > Soporte). `adjuntos` guarda las capturas
-- como data URLs (ya validadas y redimensionadas en el cliente) — a esta
-- escala de prototipo alcanza con JSONB, sin un storage de archivos aparte.
-- `user_id` queda pensado para que un admin pueda listar las de todos los
-- usuarios más adelante (todavía no implementado).
CREATE TABLE support_tickets (
  id SERIAL PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  asunto TEXT NOT NULL,
  mensaje TEXT NOT NULL,
  adjuntos JSONB NOT NULL DEFAULT '[]',
  -- Un ticket cerrado sigue pudiéndose visitar (queda todo el historial), pero
  -- ni el cliente ni un admin pueden mandar mensajes nuevos ahí (ver
  -- server/src/routes/support.js) hasta que quede sin uso el estado.
  status TEXT NOT NULL DEFAULT 'abierto' CHECK (status IN ('abierto', 'cerrado')),
  -- Qué admin lo "tomó" — solo informativo (cualquier admin puede seguir
  -- respondiendo igual, esto no bloquea a nadie más), se muestra en la lista
  -- de Soporte de Admin.
  claimed_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
  claimed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Respuestas del chat de una consulta (el mensaje inicial vive en
-- support_tickets.mensaje; acá van todas las réplicas, tanto del dueño de la
-- consulta como de cualquier admin que la conteste).
CREATE TABLE support_messages (
  id SERIAL PRIMARY KEY,
  ticket_id INTEGER NOT NULL REFERENCES support_tickets(id) ON DELETE CASCADE,
  sender_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  mensaje TEXT NOT NULL,
  adjuntos JSONB NOT NULL DEFAULT '[]',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Telemetría de producto (Admin > Analytics): vistas de página, pasos del
-- quiz y clics en botones clave, para armar el embudo de conversión y el
-- ranking de clics. `session_id` es un id anónimo generado en el navegador
-- (ver src/utils/analytics.js) — no requiere estar logueado, así se puede
-- seguir a alguien desde que entra a la landing hasta que se registra.
-- `user_id` se completa recién cuando esa sesión ya tiene cuenta.
CREATE TABLE analytics_events (
  id SERIAL PRIMARY KEY,
  session_id TEXT NOT NULL,
  user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
  event_type TEXT NOT NULL,
  event_name TEXT NOT NULL,
  path TEXT,
  metadata JSONB NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_analytics_events_created_at ON analytics_events(created_at);
CREATE INDEX idx_analytics_events_name ON analytics_events(event_name);
CREATE INDEX idx_analytics_events_session ON analytics_events(session_id);

-- Registro de consentimiento (Términos y Condiciones, ver TermsGate.jsx):
-- como guardamos datos de gente que ni se registró (los leads de abajo),
-- necesitamos poder demostrar que esa persona aceptó los términos antes de
-- que empezáramos a guardar nada suyo. Se inserta una fila cada vez que
-- tocan "Acepto y continúo" (no hace upsert a propósito: cada aceptación es
-- su propia prueba, con su propia fecha). `session_id` es el id anónimo
-- persistente del navegador (`sitiowebdigital.analyticsSession`, ver
-- src/utils/analytics.js) — el mismo que se manda junto con cada lead para
-- poder cruzarlos.
CREATE TABLE terms_acceptances (
  id SERIAL PRIMARY KEY,
  session_id TEXT NOT NULL,
  user_agent TEXT,
  accepted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_terms_acceptances_session ON terms_acceptances(session_id);

-- Texto vigente de los Términos y Condiciones (Admin > Términos y
-- Condiciones), fila única (id fijo en 1) — lo edita un admin como texto
-- plano, y `updated_at` se pisa solo en cada guardado para mostrar "Última
-- actualización" tanto en el admin como en TermsGate.jsx, que lo lee público
-- (sin auth, lo ve cualquier visitante antes de aceptar).
CREATE TABLE site_terms (
  id INT PRIMARY KEY DEFAULT 1,
  content TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT site_terms_singleton CHECK (id = 1)
);

-- Leads del quiz (Admin > Leads): lo que cada visitante va completando en el
-- quiz (negocio, rubro, frase/necesidad, teléfono) se guarda solo, aunque
-- nunca termine el quiz ni se registre (ver src/pages/Quiz.jsx) — así se
-- puede estudiar qué rubros y qué necesidades pide la gente, no solo a
-- quienes terminan pagando. `session_id` identifica cada PASADA por el quiz
-- (se genera de nuevo cada vez que se entra a /quiz, no es el id de
-- analytics) y hace de upsert: si sigue completando esa misma pasada, se
-- actualiza el mismo lead en vez de crear uno nuevo por cada tecla; una
-- pasada distinta (otro negocio) sí queda como lead aparte.
-- `telefono` puede faltar: se guarda desde que escribe el nombre del
-- negocio en el paso 1, mucho antes de llegar al teléfono en el paso 3.
-- `last_step` queda en el punto más lejano al que llegó (1-4 = pasos del
-- formulario, 5 = vio el resultado). `terms_accepted_at` se completa
-- buscando la aceptación de términos más reciente de esa sesión de
-- analytics (ver POST /api/leads) — si es NULL, no tenemos cómo probar que
-- esa persona aceptó los términos antes de que guardáramos su dato.
CREATE TABLE leads (
  id SERIAL PRIMARY KEY,
  session_id TEXT NOT NULL UNIQUE,
  user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
  nombre_negocio TEXT,
  telefono TEXT,
  rubro TEXT,
  frase TEXT,
  referrer TEXT,
  last_step INTEGER NOT NULL DEFAULT 1,
  terms_accepted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_leads_updated_at ON leads(updated_at);

-- Rubros creados por el admin (Admin > Plantillas), además de los 6 fijos
-- del código (RUBROS en src/data/mockData.js) — se combinan en tiempo de
-- ejecución (ver AppContext) para que el quiz/galería los traten igual que
-- a los de fábrica. `id` es un slug (ej. "panaderias"), no un serial, para
-- poder usarlo tal cual en `custom_templates.rubros` y en las plantillas
-- de fábrica sin tener que traducir ids.
CREATE TABLE custom_rubros (
  id TEXT PRIMARY KEY,
  label TEXT NOT NULL,
  icon TEXT NOT NULL DEFAULT '✨',
  accent TEXT NOT NULL,
  created_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Plantillas creadas por el admin (Admin > Plantillas): arma una página de
-- ejemplo en el editor de siempre (secciones, contenido, colores) y la
-- guarda acá como plantilla reutilizable — mismo formato que las de fábrica
-- (TEMPLATES en mockData.js: sections/demo/seeds), para que ambas se puedan
-- tratar exactamente igual en el resto de la app una vez combinadas. `rubros`
-- es un array (una plantilla puede servir para más de un rubro, o ninguno
-- todavía si la guardaron sin publicar). Solo se ofrecen a los usuarios
-- reales (Gallery/quiz) las que tengan `published = true`.
CREATE TABLE custom_templates (
  id TEXT PRIMARY KEY,
  nombre TEXT NOT NULL,
  tagline TEXT NOT NULL DEFAULT '',
  rubros JSONB NOT NULL DEFAULT '[]',
  tags JSONB NOT NULL DEFAULT '[]',
  accent TEXT NOT NULL,
  -- Miniatura para la tarjeta de la galería (ver TemplateCard) — se deriva
  -- sola de la primera foto de la galería del sitio de ejemplo al guardar
  -- (ver AppContext.saveAsTemplate), no la carga el admin a mano.
  image TEXT,
  image_fallback TEXT,
  sections JSONB NOT NULL DEFAULT '[]',
  demo JSONB NOT NULL DEFAULT '{}',
  seeds JSONB NOT NULL DEFAULT '{}',
  -- Estilos de texto puntuales (ej. una tipografía distinta para los títulos)
  -- que la plantilla trae de fábrica — mismo formato que el `textStyles` de
  -- un sitio (ver siteSchema.js), aplicado por chooseTemplate al elegirla.
  text_styles JSONB NOT NULL DEFAULT '{}',
  -- Paleta completa (fondo/texto/bordes) que reemplaza a la derivada del
  -- rubro (ver getTemplatePalette en el frontend) — nula para casi todas
  -- las plantillas, que siguen heredando la escala clara de su rubro. Sin
  -- UI propia para armarla a mano (no es un campo del modal de "Guardar
  -- como plantilla"): se setea aparte, por ahora solo para plantillas con
  -- una identidad de marca tan propia que no encaja en ningún rubro (ej.
  -- Estudio Lumen, fondo oscuro).
  palette_override JSONB,
  published BOOLEAN NOT NULL DEFAULT false,
  created_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_custom_templates_published ON custom_templates(published);
