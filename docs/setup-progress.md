# Setup Progress — Outreach Email Flows

Estado de implementacion del sistema Instantly → Supabase → n8n → Knack.

> Ultima actualizacion: 2026-05-21

---

## Resumen de arquitectura

```
Instantly (campanas outreach)
   │ webhook reply
   ▼
n8n (5 workflows)
   │ service_role
   ▼
Supabase Postgres (outreach_queue + email_replies)
   │ JWT auth
   ▼
Knack UI (custom JS en monolito, zero Knack API quota)
```

---

## Paso 1: Schema Supabase — COMPLETADO

**Fecha:** 2026-05-21
**Proyecto Supabase:** `pfmnqetthotzpeticfko` · region `us-west-1` · Postgres 17

Se ejecuto el SQL en el SQL Editor de Supabase. Archivo: [`../sql/001_outreach_initial_schema.sql`](../sql/001_outreach_initial_schema.sql)

### Que se creo:

| Objeto | Descripcion |
|---|---|
| Extension `citext` | Emails case-insensitive |
| Tabla `public.outreach_queue` | Master list de contactos para outreach |
| Tabla `public.email_replies` | Replies recibidos via webhook de Instantly |
| 4 indices en `outreach_queue` | status+created, instantly_lead, knack_trade, got_reply |
| 4 indices en `email_replies` | status+received, knack_trade, contact_email, outreach_id |
| Funcion `update_updated_at()` | Trigger que auto-actualiza `updated_at` en UPDATE |
| 2 triggers | `trg_oq_updated_at`, `trg_er_updated_at` |
| RLS habilitado (sin policies) | Solo `service_role` tiene acceso (n8n). `anon`/`authenticated` bloqueados |

### Verificacion:

```sql
SELECT count(*) FROM public.outreach_queue;   -- debe dar 0
SELECT count(*) FROM public.email_replies;     -- debe dar 0
```

Ambas queries corrieron exitosamente con 0 rows.

---

## Paso 2: Workflows n8n — COMPLETADOS (pero inactivos)

**Host n8n:** `https://n8n.simultrayd.com`

Los 5 workflows estan creados con todos los nodos, codigo y conexiones. Todos tienen MCP access habilitado.

| # | Workflow | ID | Endpoint | Estado |
|---|---|---|---|---|
| A | Auth Login (JWT issuer) | `t51xq2zgY0np1eQx` | `POST /webhook/auth/login` | Completo, inactivo |
| A2 | Auth Exchange (Knack token → JWT) | `SC2iFF8nnECCIWQH` | `POST /webhook/auth/exchange` | Completo, inactivo |
| B | GET Replies by Trade | `0hvF00Q1bniPu5fl` | `GET /webhook/replies?trade_id=X` | Completo, **necesita credencial Postgres** |
| C | GET Inbox (Global) | `kmhDhz3lTowr8LkN` | `GET /webhook/inbox` | Completo, **necesita credencial Postgres** |
| D | PATCH Reply Status | `7YL2aZZRz2eZk0TO` | `PATCH /webhook/replies/:id/status` | Completo, **necesita credencial Postgres** |

### Detalle de cada workflow:

**A — Auth Login:**
`Webhook → HTTP Request (Knack /session) → IF (user exists?) → Code (Sign JWT HS256) → Respond`
- Valida email+password contra Knack session API
- Si valido y rol Admin/Staff, firma JWT con `$env.JWT_SECRET` (8h TTL)
- Si rol User → 403, si credenciales invalidas → 401

**A2 — Auth Exchange (path de produccion):**
`Webhook → Code (Verify Input) → IF (valid?) → HTTP Request (Knack GET object_10) → IF (is admin?) → Code (Sign JWT) → Respond`
- Recibe `{knack_token, user_id, user_name, user_email}`
- Valida el knack_token llamando a Knack API: `GET /v1/objects/object_10/records/{user_id}`
- Si Knack devuelve 200 → firma JWT con role:'Admin'
- Consume solo 1 Knack API call por sesion

**B — GET Replies by Trade:**
`Webhook → Code (Verify JWT) → IF (authorized?) → Postgres (SELECT email_replies WHERE knack_trade_id=$1) → Code (Wrap) → Respond`
- Requiere `?trade_id=X` en query params
- Devuelve array de replies ordenados por `received_at DESC`, max 100

**C — GET Inbox (Global):**
`Webhook → Code (Verify JWT) → IF (authorized?) → Postgres (SELECT email_replies JOIN outreach_queue) → Code (Wrap) → Respond`
- Query params opcionales: `?status=new&limit=100`
- Status default: `new`, limit max: 500

**D — PATCH Reply Status:**
`Webhook → Code (Verify JWT + validate UUID + validate status) → IF (authorized?) → Postgres (UPDATE RETURNING) → Code (Wrap/404) → Respond`
- Path: `/replies/:id/status`
- Body: `{"status": "read|replied|archived|new"}`
- Valida UUID format y status whitelist

---

## Paso 3: Credencial Postgres en n8n — PENDIENTE (BLOQUEANTE)

Los workflows B, C y D usan nodos `n8n-nodes-base.postgres` nativos que requieren una credencial guardada en n8n.

### Datos de conexion:

| Campo | Valor |
|---|---|
| Host | `aws-0-us-west-1.pooler.supabase.com` |
| Port | `6543` (Transaction Pooler) |
| Database | `postgres` |
| User | `postgres.pfmnqetthotzpeticfko` |
| Password | *(database password del proyecto Supabase)* |
| SSL | `Require` |

### Como crearla:

1. En n8n: **Settings → Credentials → Add Credential**
2. Buscar **"Postgres"**
3. Llenar los campos de arriba
4. Nombrarla algo como `Supabase Outreach`
5. Click **Save**
6. Abrir cada workflow (B, C, D) → click en el nodo Postgres → seleccionar la credencial recien creada → guardar workflow

> **Importante:** Usar Transaction Pooler (puerto 6543), NO Session Pooler ni Direct Connection.

### Alternativa si no se puede crear credencial:

Reemplazar los nodos Postgres nativos por nodos Code que conecten directamente usando la connection string. Esto evita la necesidad de credencial guardada pero requiere modificar los 3 workflows.

---

## Paso 4: Variables de entorno en n8n — PENDIENTE

Agregar al `.env` o `docker-compose.yml` del servidor de n8n:

```bash
KNACK_APP_ID=64d6ba88d3ca8200285f80ae
JWT_SECRET=<generar con: openssl rand -base64 48>
```

**Despues de agregar: reiniciar n8n** para que las lea.

> El `KNACK_APP_ID` se obtuvo del monolito `Simultrayd_NextGen.js` donde aparece hardcodeado como `"64d6ba88d3ca8200285f80ae"`.

> El `JWT_SECRET` debe guardarse en password manager. Si se pierde/regenera, todos los JWTs existentes se invalidan.

---

## Paso 5: CORS — PENDIENTE

Configurar en el reverse proxy de `n8n.simultrayd.com` para permitir requests desde Knack:

```
Access-Control-Allow-Origin: https://*.knack.com
Access-Control-Allow-Methods: GET, POST, PATCH, OPTIONS
Access-Control-Allow-Headers: Authorization, Content-Type
```

O en la config de n8n si es self-hosted (`~/.n8n/config`):
```json
{
  "endpoints": { "rest": "rest", "webhook": "webhook" },
  "cors": { "enabled": true, "allowedOrigins": ["https://*.knack.com"] }
}
```

---

## Paso 6: Activar workflows — PENDIENTE

Una vez completados pasos 3, 4, y 5:

1. Abrir cada workflow en n8n
2. Toggle **"Active"** arriba a la derecha
3. Activar en este orden: A → A2 → B → C → D

---

## Paso 7: Frontend Knack (PARTE 5 monolito) — PENDIENTE

El codigo frontend ya esta especificado en [`knack-outreach-frontend.md`](./knack-outreach-frontend.md). Requiere:

1. Crear scene admin-only para inbox en Knack → obtener `scene_id`
2. Identificar `scene_id` del Trade detail page existente
3. Reemplazar placeholders `scene_TBD_INBOX` y `scene_TBD_TRADE` en el monolito
4. Insertar containers HTML en las paginas Knack:
   - Inbox: `<div id="styd-outreach-inbox"></div>`
   - Trade detail: `<div id="styd-outreach-trade-replies"></div>`
5. Paste del monolito al Knack Builder → JS settings → Save → Hard refresh

---

## Smoke test (cuando todo este listo)

Desde browser console estando logueado como Admin en Knack:

```javascript
// 1. Verificar version
console.log('SimulTrayd_Version:', SimulTrayd_Version);

// 2. Verificar admin
console.log('isAdmin:', await window._stydOutreach.isAdmin());

// 3. Test exchange token
const user = await Knack.getUser();
const token = await window._stydOutreach.exchangeToken(user);
console.log('JWT:', token);

// 4. Reload inbox
window._stydOutreach.reloadInbox();
```

Esperado: version `6.6.0-outreach-inbox-...`, isAdmin `true`, JWT no null, inbox renderiza.

---

## Archivos del repositorio

```
email-flows/
├── docs/
│   ├── supabase-knack-flow.md      # Spec tecnico completo del backend
│   ├── knack-outreach-frontend.md  # Spec del frontend (PARTE 5 monolito)
│   └── setup-progress.md           # ESTE ARCHIVO — progreso de implementacion
└── sql/
    └── 001_outreach_initial_schema.sql  # SQL ejecutado en Supabase
```
