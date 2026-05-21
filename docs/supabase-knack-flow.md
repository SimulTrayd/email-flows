# Supabase → Knack via n8n

Spec del backend del sistema Outreach Inbox: workflows n8n + schema Supabase.

> Sistema completo end-to-end: Instantly → Supabase → n8n → Knack. Estado actual del deployment: [`setup-progress.md`](./setup-progress.md). Spec del frontend: [`knack-outreach-frontend.md`](./knack-outreach-frontend.md).

## Estado actual (2026-05-21)

✅ **Sistema operativo end-to-end** para el flujo Knack-side (auth + inbox). Inbox vacío renderiza correctamente. Falta solo data real de Instantly.

### Workflows desplegados (8 total) en `https://n8n.simultrayd.com`

**Backbone Knack ↔ n8n ↔ Supabase:**

| # | Workflow | ID | Endpoint | Active |
|---|---|---|---|---|
| A | Auth Login (fallback) | `t51xq2zgY0np1eQx` | `POST /webhook/auth/login` | ❌ |
| **A2** | **Auth Exchange (prod path)** | `SC2iFF8nnECCIWQH` | `POST /webhook/auth/exchange` | ✅ |
| **B** | **GET Replies by Trade** | `0hvF00Q1bniPu5fl` | `GET /webhook/replies?trade_id=X` | ✅ |
| **C** | **GET Inbox (Global)** | `kmhDhz3lTowr8LkN` | `GET /webhook/inbox` | ✅ |
| **D** | **PATCH Reply Status** | `7YL2aZZRz2eZk0TO` | `PATCH /webhook/replies/:id/status` | ✅ |

**Outreach lifecycle Instantly ↔ n8n ↔ Supabase:**

| # | Workflow | ID | Trigger | Active |
|---|---|---|---|---|
| #1 | CSV Import → outreach_queue | `LWLC1gxUUrTOVUqC` | Form Upload | ❌ |
| #2 | Daily Push outreach_queue → Instantly | `Y248GBppVAfkSoBx` | Cron diario 14:00 UTC | ❌ |
| #3 | Instantly Reply Webhook → email_replies | `MfRAUFc7KwGsMdqz` | Webhook POST | ❌ |

**Frontend code:** Trade-Platform monolito `knack/Simultrayd_NextGen.js` → PARTE 5. Versión actual `6.6.7-outreach-token-from-localstorage-2026-05-21`. Deploy = paste al Knack Builder — ver [[feedback_knack_monolith_paste_deploy]] en memory.

**Supabase project:** `pfmnqetthotzpeticfko` · región `us-west-1` · Postgres 17
**Migration aplicado:** `outreach_initial_schema` (2026-05-20)

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
- [Activation checklist](#activation-checklist)
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

**Endpoint:** `POST https://n8n.simultrayd.com/webhook/auth/login`

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

4. **Code** — emitir JWT (HMAC-SHA256 manual con `crypto` nativo, sin librerías externas)
   ```javascript
   try {
     const crypto = require('crypto');
     const user = $input.first().json.session.user;

     const role = user.profile_keys && user.profile_keys.includes('Admin') ? 'Admin'
                : user.profile_keys && user.profile_keys.includes('Staff') ? 'Staff'
                : 'User';

     if (role === 'User') {
       return [{ json: { error: 'Forbidden — admin/staff only', statusCode: 403 } }];
     }

     function base64url(input) {
       return Buffer.from(input).toString('base64')
         .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
     }

     const header = { alg: 'HS256', typ: 'JWT' };
     const payload = {
       user_id: user.id,
       email: user.email,
       name: user.name,
       role,
       exp: Math.floor(Date.now() / 1000) + (8 * 60 * 60)
     };

     const headerB64 = base64url(JSON.stringify(header));
     const payloadB64 = base64url(JSON.stringify(payload));
     const signingInput = headerB64 + '.' + payloadB64;
     const signature = crypto.createHmac('sha256', $env.JWT_SECRET)
       .update(signingInput).digest('base64')
       .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
     const token = signingInput + '.' + signature;

     return [{ json: { token, user: { id: user.id, name: user.name, role }, statusCode: 200 } }];
   } catch (err) {
     return [{ json: { error: 'Sign JWT failed: ' + err.message, statusCode: 500 } }];
   }
   ```

5. **Respond to Webhook** — `responseCode: {{$json.statusCode || 200}}`, body `{{$json}}`

---

### B. GET /replies — por trade

Devuelve los replies de un trade específico.

**Endpoint:** `GET https://n8n.simultrayd.com/webhook/replies?trade_id=<id>`

**Headers:** `Authorization: Bearer <JWT>`

**Response (200):** array de replies ordenados por `received_at DESC`, máx 100.

**Nodos:**

1. **Webhook** (trigger)
   - Path: `replies`
   - Method: `GET`
   - Response Mode: `Using "Respond to Webhook" Node`

2. **Code** — JWT verify middleware (HMAC-SHA256 manual, reutilizable en C y D)
   ```javascript
   try {
     const crypto = require('crypto');
     const headers = $input.first().json.headers || {};
     const auth = headers.authorization || headers.Authorization || '';
     const token = auth.replace(/^Bearer\s+/i, '');
     const query = $input.first().json.query || {};

     function base64urlDecode(str) {
       const pad = str.length % 4;
       if (pad) str += '='.repeat(4 - pad);
       return Buffer.from(str.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString();
     }

     if (!token) return [{ json: { authorized: false, error: 'Missing token', statusCode: 401 } }];

     const parts = token.split('.');
     if (parts.length !== 3) return [{ json: { authorized: false, error: 'Invalid token format', statusCode: 401 } }];

     const [headerB64, payloadB64, signature] = parts;
     const signingInput = headerB64 + '.' + payloadB64;
     const expected = crypto.createHmac('sha256', $env.JWT_SECRET)
       .update(signingInput).digest('base64')
       .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');

     if (signature !== expected) return [{ json: { authorized: false, error: 'Invalid signature', statusCode: 401 } }];

     let payload;
     try { payload = JSON.parse(base64urlDecode(payloadB64)); }
     catch (err) { return [{ json: { authorized: false, error: 'Invalid payload', statusCode: 401 } }]; }

     if (payload.exp && payload.exp < Math.floor(Date.now() / 1000)) {
       return [{ json: { authorized: false, error: 'Token expired', statusCode: 401 } }];
     }

     if (!['Admin', 'Staff'].includes(payload.role)) {
       return [{ json: { authorized: false, error: 'Forbidden', statusCode: 403 } }];
     }

     if (!query.trade_id) {
       return [{ json: { authorized: false, error: 'Missing trade_id query param', statusCode: 400 } }];
     }

     return [{ json: { authorized: true, user_id: payload.user_id, role: payload.role, trade_id: query.trade_id } }];
   } catch (err) {
     return [{ json: { authorized: false, error: 'Verify failed: ' + err.message, statusCode: 500 } }];
   }
   ```

3. **IF** — `{{ $json.authorized }}` equals `true`
   - True → Postgres
   - False → Respond directo con `statusCode` del Code node

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
   - Parámetros: `{{ $('Verify JWT').first().json.trade_id }}`

5. **Code "Wrap Replies"** — empaqueta filas en `{ replies, count, statusCode: 200 }`

6. **Respond to Webhook** — `responseCode: {{$json.statusCode || 200}}`, body `{{$json}}`

---

### C. GET /inbox — global

Inbox de replies sin leer, todos los trades.

**Endpoint:** `GET https://n8n.simultrayd.com/webhook/inbox`

**Headers:** `Authorization: Bearer <JWT>`

**Query params opcionales:**
- `status` — `new` (default) · `read` · `replied` · `archived`
- `limit` — default 100, max 500

**Response (200):** array de replies ordenados por `received_at DESC`.

**Nodos:** idénticos a B, excepto el query del Postgres usa el `status` y `limit` recibidos del Verify JWT:

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
WHERE r.status = $1
ORDER BY r.received_at DESC
LIMIT $2;
```
- Parámetros: `{{ $('Verify JWT').first().json.status_filter }}, {{ $('Verify JWT').first().json.limit }}`

---

### D. PATCH /replies/:id/status — mark read/replied

Actualiza el status de un reply (al hacer click "read" / "reply" / "archive" en la UI).

**Endpoint:** `PATCH https://n8n.simultrayd.com/webhook/replies/:id/status`

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

2. **Code "Verify JWT"** — mismo middleware de B + extrae `params.id` y `body.status`. Valida:
   - JWT firma + exp + rol Admin/Staff
   - `id` con regex UUID
   - `status` en whitelist `['new','read','replied','archived']`

3. **IF** — `{{ $json.authorized }}` equals `true`

4. **Postgres** — Update
   ```sql
   UPDATE public.email_replies
   SET status = $1
   WHERE id = $2
   RETURNING id, status, updated_at;
   ```
   - Parámetros: `{{ $('Verify JWT').first().json.new_status }}, {{ $('Verify JWT').first().json.reply_id }}`

5. **Code "Wrap Result"** — devuelve 404 si Postgres no encontró la row; sino la row con `statusCode: 200`

6. **Respond to Webhook** — `responseCode: {{$json.statusCode || 200}}`, body `{{$json}}`

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

Edita el `.env` (o `docker-compose.yml`) del host de n8n y agrega:

```bash
JWT_SECRET=<64-char base64 string>          # firma de JWTs
KNACK_APP_ID=<knack_application_id>         # para llamadas a /session
```

**Generar `JWT_SECRET` en PowerShell** (Windows 5.1 compatible):
```powershell
$bytes = New-Object byte[] 48
(New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($bytes)
[Convert]::ToBase64String($bytes)
```

**O en bash:** `openssl rand -base64 48`

> **Guarda el secret en password manager**. Si se pierde, todos los JWTs emitidos se invalidan al regenerarlo (managers tendrán que volver a loguearse).

**`KNACK_APP_ID`:** Knack Builder → Settings → API & Code → Application ID.

Después de editar las env vars: **reiniciar n8n** para que las lea.

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
POST   https://n8n.simultrayd.com/webhook/auth/login
GET    https://n8n.simultrayd.com/webhook/replies?trade_id=<id>
GET    https://n8n.simultrayd.com/webhook/inbox[?status=new&limit=100]
PATCH  https://n8n.simultrayd.com/webhook/replies/<id>/status
```

### 4. CORS

Configurar n8n para permitir el dominio de Knack en CORS. Si self-hosted, en `~/.n8n/config`:
```json
{ "endpoints": { "rest": "rest", "webhook": "webhook" }, "cors": { "enabled": true, "allowedOrigins": ["https://*.knack.com"] } }
```

---

## Activation checklist

### ✅ Completado (smoke test pasa)

- [x] **n8n Variables (UI):** `JWT_SECRET` ✅, `KNACK_APP_ID` ✅, `INSTANTLY_API_KEY` ✅
- [x] **Credencial Postgres "Postgres account"** creada en n8n UI (Transaction Pooler `aws-1-us-west-1.pooler.supabase.com:6543`, SSL require, Ignore SSL Issues ON)
- [x] **Asignar credencial Postgres** a los 8 nodos Postgres (B, C, D, #1, #2 x2, #3 x2)
- [x] **CORS** configurado en reverse proxy de `n8n.simultrayd.com` (allow `https://dashboard.simultrayd.com`)
- [x] **Activate workflows backbone:** A2, B, C, D
- [x] **Crear scene en Knack:** `scene_607` (Outreach Inbox, child de `scene_603` Admin Dashboard)
- [x] **Reemplazar placeholder INBOX en monolito:** `SCENES.INBOX = 'scene_607'`
- [x] **Bumpear `SimulTrayd_Version`:** actualmente `6.6.7-outreach-token-from-localstorage-2026-05-21`
- [x] **Paste monolito al Knack Builder** + hard refresh
- [x] **Smoke test:** inbox renderiza "No new replies." con 200 OK en `/auth/exchange` y `/inbox`

### ⏳ Pendiente para activar outreach lifecycle completo

- [ ] **Definir Instantly campaign** con equipo → setear `INSTANTLY_CAMPAIGN_ID` en n8n Variables
- [ ] **Activate Workflow #3** (Instantly Reply Webhook)
- [ ] **Configurar webhook en Instantly Dashboard** → URL: `https://n8n.simultrayd.com/webhook/instantly-reply`, eventos: reply_received
- [ ] **Exportar CSV** de Knack con contactos Exporter/Importer
- [ ] **Activate Workflow #1** (CSV Import) y subir el CSV vía form: `https://n8n.simultrayd.com/form/outreach-csv-upload`
- [ ] **Activate Workflow #2** (Daily Push) — cron diario empieza a enviar 200 leads/día a Instantly

### 🟡 Deferred (no urgente)

- [ ] **Admin trade detail page** — no existe en Knack aún. Cuando se construya:
  - Reemplazar `SCENES.TRADE_DETAIL = 'scene_NONE_YET_admin_trade_detail'` con scene_id real
  - Agregar Rich Text con `<div id="styd-outreach-trade-replies"></div>` (o el container se inyecta dinámico via JS)
  - Workflow B ya está listo y activo para servirlo

---

## Decisiones técnicas

### Workflows usan HMAC puro JS (no `crypto` module)

n8n Code sandbox bloquea `require('crypto')`, `globalThis.crypto` y `await import('node:crypto')`. Los workflows A2 (Sign JWT) y B/C/D (Verify JWT) implementan HMAC-SHA256 inline en pure JavaScript (~70 líneas usando `Buffer`).

### A2 simplificado: no valida knack_token contra Knack API

Originalmente A2 hacía `GET /v1/objects/object_10/records/{user_id}` para validar el token. Pero el `refreshToken-<APP_ID>` (que es lo que Knack Next Gen guarda en localStorage) no funciona como Bearer en su REST API. **A2 confía en el payload del JS** (que solo ejecuta en contextos autenticados de Knack) y firma directo. La validación de role queda client-side (`_resolveStaffRole`) + server-side downstream (Verify JWT chequea claim `role`).

### Manager + Admin tienen acceso

Workflows verifican `payload.role in ['Admin', 'Manager']` (no solo Admin). Sigue el patrón del monolito que trata ambos como staff interno via `_stydIsPermanentManager`.

### Variables como UI Variables (no env vars del runtime)

Las 4 variables (`JWT_SECRET`, `KNACK_APP_ID`, `INSTANTLY_API_KEY`, `INSTANTLY_CAMPAIGN_ID`) viven en n8n UI Settings → Variables (Scope: Global), accedidas vía `$vars.X`. NO en el `.env` del runtime de n8n.

---

## Decisiones pendientes

- [ ] **Refresh token** — skip por ahora (8h JWT suficiente). Si los managers necesitan SSO de 30d, agregar workflow `/auth/refresh` con tabla `refresh_tokens` en Supabase
- [ ] **Knack login integration UX** — actualmente cualquier admin/manager que entre a `scene_607` se autentica transparentemente (sin form de login adicional)

---

## Referencias

- Supabase project: `pfmnqetthotzpeticfko` (SimulTrayd) · region `us-west-1` · Postgres 17
- n8n host: `https://n8n.simultrayd.com`
- n8n nodes usados: Webhook, HTTP Request, IF, Code, Postgres, Set, Respond to Webhook
- Migration aplicado: `outreach_initial_schema` (2026-05-20)
- JWT spec: HS256 firmado con `crypto.createHmac` nativo (sin librerías externas), payload `{user_id, email, name, role, exp}`, lifetime 8h
