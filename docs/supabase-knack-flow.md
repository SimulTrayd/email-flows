# Supabase → Knack via n8n

Spec del flujo de **lectura** de Supabase para alimentar las páginas de Knack sin consumir Knack API quota.

> Este doc cubre solo la pieza **Supabase → Knack**. Las piezas separadas son:
> - CSV import → Supabase (workflow #1, ver `csv-import.md` cuando exista)
> - Supabase → Instantly daily push (workflow #2)
> - Instantly webhook → Supabase replies (workflow #3)

---

## Tabla de contenidos

- [Objetivo](#objetivo)
- [Arquitectura](#arquitectura)
- [Schema Supabase](#schema-supabase)
- [Workflows n8n](#workflows-n8n)
  - [A. POST /auth/login — JWT issuer](#a-post-authlogin--jwt-issuer)
  - [B. GET /replies — por trade](#b-get-replies--por-trade)
  - [C. GET /inbox — global](#c-get-inbox--global)
  - [D. PATCH /replies/:id/status — mark read/replied](#d-patch-repliesidstatus--mark-readreplied)
- [Contrato frontend (Knack custom JS)](#contrato-frontend-knack-custom-js)
- [Setup / Requisitos](#setup--requisitos)
- [Decisiones pendientes](#decisiones-pendientes)

---

## Objetivo

Mostrar replies de outreach (capturadas desde Instantly) dentro de páginas de Knack **sin consumir Knack API quota**.

**Por qué importa:**
- Knack tiene quota de 300k API calls/día (techo estructural, ver memoria interna `project_knack_quota_consumption_audit`).
- Vistas nativas de Knack (grids, tables) siempre pegan al Knack API → consume quota.
- Workaround: páginas de Knack con custom JS que hace `fetch()` a endpoints n8n → n8n lee Supabase → devuelve JSON → JS renderiza en el DOM.
- Resultado: **0 calls a Knack API por page load** del módulo de outreach.

---

## Arquitectura

```
┌────────────────────────────────────────────┐
│  Knack Page (cualquier página con JS)      │
│  ┌──────────────────────────────────────┐  │
│  │ Custom JS lee JWT de localStorage    │  │
│  │ fetch('/webhook/replies?trade_id=X', │  │
│  │   { headers: { Authorization: JWT }})│  │
│  └──────────────────────────────────────┘  │
└─────────────────────┬──────────────────────┘
                      │ HTTPS + JWT Bearer
                      ▼
┌────────────────────────────────────────────┐
│  n8n (4 webhooks)                          │
│  ┌──────────────────────────────────────┐  │
│  │ POST   /auth/login                   │  │
│  │ GET    /replies?trade_id=X           │  │
│  │ GET    /inbox                        │  │
│  │ PATCH  /replies/:id/status           │  │
│  └──────────────────────────────────────┘  │
└─────────────────────┬──────────────────────┘
                      │ Postgres connection
                      ▼
┌────────────────────────────────────────────┐
│  Supabase Postgres                         │
│  ├── public.email_replies                  │
│  └── public.outreach_queue                 │
└────────────────────────────────────────────┘
```

**Quota Knack consumida:**
- 1 call al login (validación de credenciales contra Knack `/session`)
- 0 calls por page load del módulo
- 0 calls por interacción (read/reply/archive)

---

## Schema Supabase

Ya aplicado en project `pfmnqetthotzpeticfko` mediante migration `outreach_initial_schema`.

### `public.outreach_queue`

Master list de contactos a los que se les manda outreach.

| Columna | Tipo | Notas |
|---|---|---|
| `id` | UUID PK | `gen_random_uuid()` |
| `email` | CITEXT UNIQUE NOT NULL | dedup case-insensitive |
| `name` | TEXT | |
| `company` | TEXT | |
| `knack_contact_id` | TEXT | ID del Exporter/Importer en Knack |
| `knack_contact_object` | TEXT | check: `'exporter'` o `'importer'` |
| `knack_trade_id` | TEXT | trade más reciente como contexto |
| `knack_trade_name` | TEXT | título legible |
| `instantly_lead_id` | TEXT | después de crear en Instantly |
| `instantly_campaign_id` | TEXT | |
| `status` | TEXT | `pending`, `sent`, `failed`, `bounced`, `unsubscribed`, `replied`, `completed` |
| `sent_at` | TIMESTAMPTZ | |
| `got_reply` | BOOLEAN | default `FALSE` |
| `reply_count` | INT | default `0` |
| `last_activity_at` | TIMESTAMPTZ | |
| `created_at`, `updated_at` | TIMESTAMPTZ | trigger auto-actualiza `updated_at` |

**Índices:**
- `(status, created_at)` — daily picker
- `(instantly_lead_id) WHERE NOT NULL` — webhook matching
- `(knack_trade_id) WHERE NOT NULL` — queries por trade
- `(got_reply) WHERE TRUE` — leads con reply

### `public.email_replies`

Replies recibidas vía webhook de Instantly.

| Columna | Tipo | Notas |
|---|---|---|
| `id` | UUID PK | |
| `instantly_message_id` | TEXT UNIQUE | idempotency (evita duplicados en retries) |
| `outreach_id` | UUID FK | → `outreach_queue(id)` ON DELETE SET NULL |
| `knack_trade_id` | TEXT | denormalizado para queries directos |
| `knack_contact_id` | TEXT | |
| `contact_email` | CITEXT NOT NULL | |
| `contact_name` | TEXT | |
| `instantly_lead_id` | TEXT | |
| `instantly_campaign_id` | TEXT | |
| `instantly_campaign_name` | TEXT | UX-friendly |
| `subject` | TEXT | |
| `body_text` | TEXT | |
| `body_html` | TEXT | |
| `received_at` | TIMESTAMPTZ NOT NULL | |
| `status` | TEXT | `new`, `read`, `replied`, `archived` |
| `raw_payload` | JSONB NOT NULL | webhook completo, forensics |
| `created_at`, `updated_at` | TIMESTAMPTZ | |

**Índices:**
- `(status, received_at DESC)` — inbox view
- `(knack_trade_id) WHERE NOT NULL` — replies por trade
- `(contact_email)` — búsquedas
- `(outreach_id) WHERE NOT NULL` — join opcional con queue

### RLS

Ambas tablas tienen `ENABLE ROW LEVEL SECURITY` activo, **sin policies**.

Esto significa:
- `service_role` (la key que usa n8n) → bypass RLS, acceso total ✅
- `anon` y `authenticated` → bloqueados (no hay policies que les den acceso) ✅

**Frontend NUNCA pega directo a Supabase** — siempre pasa por n8n, que usa service_role.

---

## Workflows n8n

### A. POST /auth/login — JWT issuer

Valida credenciales contra Knack y devuelve un JWT firmado por n8n.

**Endpoint:** `POST https://<n8n>/webhook/auth/login`

**Request body:**
```json
{ "email": "manager@simultrayd.com", "password": "..." }
```

**Response (200):**
```json
{
  "token": "eyJhbGc...",
  "user": { "id": "...", "name": "...", "role": "Admin" }
}
```

**Response (401):** `{ "error": "Invalid credentials" }`
**Response (403):** `{ "error": "Forbidden" }` (rol insuficiente)

**Nodos:**

1. **Webhook** (trigger)
   - Path: `auth/login`
   - Method: `POST`
   - Response Mode: `Using "Respond to Webhook" Node`

2. **HTTP Request** → Knack session API
   - URL: `https://api.knack.com/v1/applications/{{$env.KNACK_APP_ID}}/session`
   - Method: `POST`
   - Body: `{ "email": "{{$json.body.email}}", "password": "{{$json.body.password}}" }`
   - Headers: `X-Knack-Application-Id: {{$env.KNACK_APP_ID}}`

3. **IF** — `{{ $json.session?.user }}` truthy?
   - False → Respond `401`

4. **Code** — emitir JWT
   ```javascript
   const jwt = require('jsonwebtoken');
   const user = $input.first().json.session.user;

   const role = user.profile_keys?.includes('Admin') ? 'Admin'
              : user.profile_keys?.includes('Staff') ? 'Staff'
              : 'User';

   if (role === 'User') {
     return [{ json: { error: 'Forbidden' }, statusCode: 403 }];
   }

   const token = jwt.sign({
     user_id: user.id,
     email: user.email,
     name: user.name,
     role,
     exp: Math.floor(Date.now() / 1000) + (8 * 60 * 60)
   }, $env.JWT_SECRET);

   return [{
     json: {
       token,
       user: { id: user.id, name: user.name, role }
     }
   }];
   ```

5. **Respond to Webhook** — `200` con `{ token, user }`

---

### B. GET /replies — por trade

Devuelve los replies de un trade específico.

**Endpoint:** `GET https://<n8n>/webhook/replies?trade_id=<id>`

**Headers:** `Authorization: Bearer <JWT>`

**Response (200):** array de replies ordenados por `received_at DESC`, máx 100.

**Nodos:**

1. **Webhook** (trigger)
   - Path: `replies`
   - Method: `GET`
   - Response Mode: `Using "Respond to Webhook" Node`

2. **Code** — JWT verify middleware (reutilizable)
   ```javascript
   const jwt = require('jsonwebtoken');
   const auth = $input.first().json.headers.authorization || '';
   const token = auth.replace(/^Bearer\s+/i, '');

   try {
     const decoded = jwt.verify(token, $env.JWT_SECRET);
     if (!['Admin', 'Staff'].includes(decoded.role)) {
       return [{ json: { error: 'Forbidden' }, statusCode: 403 }];
     }
     return [{
       json: {
         ...decoded,
         trade_id: $input.first().json.query.trade_id
       }
     }];
   } catch (err) {
     return [{ json: { error: 'Unauthorized' }, statusCode: 401 }];
   }
   ```

3. **IF** — auth válido (`{{ !$json.error }}`)
   - False → Respond con `statusCode` del Code node

4. **Postgres** (Supabase) — Execute Query
   ```sql
   SELECT
     id,
     instantly_message_id,
     knack_trade_id,
     contact_email,
     contact_name,
     instantly_campaign_name,
     subject,
     body_text,
     received_at,
     status
   FROM public.email_replies
   WHERE knack_trade_id = $1
   ORDER BY received_at DESC
   LIMIT 100;
   ```
   - Parámetros: `{{ $json.trade_id }}`

5. **Respond to Webhook** — `200` con `{ replies: [...] }`

---

### C. GET /inbox — global

Inbox de replies sin leer, todos los trades.

**Endpoint:** `GET https://<n8n>/webhook/inbox`

**Headers:** `Authorization: Bearer <JWT>`

**Response (200):** array de replies `status='new'` ordenados por `received_at DESC`.

**Nodos:** idénticos a B, excepto el query del Postgres:

```sql
SELECT
  r.id,
  r.contact_email,
  r.contact_name,
  r.knack_trade_id,
  r.subject,
  r.received_at,
  r.status,
  q.knack_trade_name,
  q.company
FROM public.email_replies r
LEFT JOIN public.outreach_queue q ON q.id = r.outreach_id
WHERE r.status = 'new'
ORDER BY r.received_at DESC
LIMIT 100;
```

---

### D. PATCH /replies/:id/status — mark read/replied

Actualiza el status de un reply (al hacer click "read" / "reply" / "archive" en la UI).

**Endpoint:** `PATCH https://<n8n>/webhook/replies/:id/status`

**Headers:** `Authorization: Bearer <JWT>`

**Request body:**
```json
{ "status": "read" }
```

**Response (200):**
```json
{ "id": "...", "status": "read", "updated_at": "..." }
```

**Nodos:**

1. **Webhook** (trigger)
   - Path: `replies/:id/status`
   - Method: `PATCH`
   - Response Mode: `Using "Respond to Webhook" Node`

2. **Code** — JWT verify (mismo middleware de B)

3. **IF** — auth válido

4. **Postgres** — Update
   ```sql
   UPDATE public.email_replies
   SET status = $1
   WHERE id = $2
   RETURNING id, status, updated_at;
   ```
   - Parámetros: `{{ $json.body.status }}`, `{{ $json.params.id }}`

5. **Respond to Webhook** — `200` con la row actualizada

---

## Contrato frontend (Knack custom JS)

Pega esto en el monolito de Knack. Reutilizable.

```javascript
const N8N_BASE = 'https://n8n.simultrayd.com/webhook'; // ajustar al dominio real
const TOKEN_KEY = 'simultrayd_n8n_token';

// ─────────────── Helper de fetch autenticado ───────────────
async function n8nFetch(path, opts = {}) {
  const token = localStorage.getItem(TOKEN_KEY);
  const res = await fetch(`${N8N_BASE}${path}`, {
    ...opts,
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${token}`,
      ...(opts.headers || {})
    }
  });

  if (res.status === 401) {
    localStorage.removeItem(TOKEN_KEY);
    // TODO: redirect to re-login o trigger silent refresh
  }

  return res.json();
}

// ─────────────── Login (llamar después del login Knack) ───────────────
async function loginToN8n(email, password) {
  const res = await fetch(`${N8N_BASE}/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password })
  });
  const data = await res.json();
  if (data.token) localStorage.setItem(TOKEN_KEY, data.token);
  return data;
}

// ─────────────── Casos de uso ───────────────
// 1) Replies por trade (en página detail de Trade)
const { replies } = await n8nFetch(`/replies?trade_id=${tradeId}`);

// 2) Inbox global
const { replies: inbox } = await n8nFetch('/inbox');

// 3) Marcar como leído
await n8nFetch(`/replies/${replyId}/status`, {
  method: 'PATCH',
  body: JSON.stringify({ status: 'read' })
});
```

---

## Setup / Requisitos

### 1. Variables de entorno en n8n

```bash
JWT_SECRET=<random 64-char string>          # firma de JWTs
KNACK_APP_ID=<knack_application_id>         # para llamadas a /session
```

> Generar `JWT_SECRET`: `openssl rand -base64 48` o equivalente. **Guardar offline**.

### 2. Credencial Postgres → Supabase en n8n

| Campo | Valor |
|---|---|
| Host | Settings → Database → Transaction Pooler |
| Port | `6543` |
| Database | `postgres` |
| User | `postgres.pfmnqetthotzpeticfko` |
| Password | la del project (Database password en Settings) |
| SSL | `Require` |

> **Importante:** usar **Transaction Pooler** (puerto 6543), no Session Pooler ni Direct Connection. Mejor para workflows que abren/cierran conexiones frecuentemente.

### 3. URLs de los webhooks en producción

```
POST   https://<n8n>/webhook/auth/login
GET    https://<n8n>/webhook/replies?trade_id=<id>
GET    https://<n8n>/webhook/inbox
PATCH  https://<n8n>/webhook/replies/<id>/status
```

### 4. CORS

Configurar n8n para permitir el dominio de Knack en CORS. Si self-hosted, en `~/.n8n/config`:
```json
{ "endpoints": { "rest": "rest", "webhook": "webhook" }, "cors": { "enabled": true, "allowedOrigins": ["https://*.knack.com"] } }
```

---

## Decisiones pendientes

- [ ] **Dominio n8n público** — ¿`n8n.simultrayd.com`? Necesario para construir las URLs finales
- [ ] **JWT_SECRET** — generar y guardar
- [ ] **Refresh token** — skip por ahora (8h JWT suficiente). Si los managers necesitan SSO de 30d, agregar workflow `/auth/refresh` con tabla `refresh_tokens` en Supabase
- [ ] **Field de rol en Knack User** — confirmar `profile_keys` vs un field específico. Si tienen field custom, ajustar el Code node del workflow A
- [ ] **Knack login integration** — definir si interceptamos el form actual o pegamos un botón "Sign in" separado para n8n

---

## Referencias

- Supabase project: `pfmnqetthotzpeticfko` (SimulTrayd)
- n8n nodes usados: Webhook, HTTP Request, IF, Code, Postgres, Respond to Webhook
- Migration aplicado: `outreach_initial_schema` (2026-05-20)
