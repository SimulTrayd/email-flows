# Setup Progress — Outreach Email Flows

Estado del sistema Outreach Inbox: Instantly → Supabase → n8n → Knack.

> Última actualización: 2026-05-21

---

## Resumen

End-to-end **funcional** para el flujo Supabase → Knack (inbox vacío renderiza correctamente). Falta solo configurar Instantly Dashboard + insertar data real para validar el render con replies.

```
Instantly (campañas outreach) ⏳ pendiente
   │ webhook reply
   ▼
n8n (8 workflows: 5 backbone + 3 outreach lifecycle)
   │ JWT auth + Postgres pooler
   ▼
Supabase Postgres (outreach_queue + email_replies) ✅
   │ JWT verify por workflow
   ▼
Knack UI (custom JS en monolito, version 6.6.7) ✅
```

---

## Estado por componente

| Componente | Status | Detalle |
|---|---|---|
| Supabase schema | ✅ DEPLOYED | `outreach_queue` + `email_replies` con RLS, índices, triggers |
| n8n workflows | ✅ 4 active, 4 inactive | Ver tabla abajo |
| Postgres credential | ✅ ASSIGNED | 8 nodos Postgres conectados via Transaction Pooler |
| n8n Variables (UI) | ✅ 3/4 | JWT_SECRET, KNACK_APP_ID, INSTANTLY_API_KEY · falta INSTANTLY_CAMPAIGN_ID |
| CORS reverse proxy | ✅ CONFIGURED | Allow origin `https://dashboard.simultrayd.com` |
| Frontend monolito | ✅ DEPLOYED | PARTE 5 en `Simultrayd_NextGen.js`, version `6.6.7-outreach-token-from-localstorage-2026-05-21` |
| Knack scene_607 (Outreach Inbox) | ✅ CREATED | Child de Admin Dashboard scene_603 (login + role gate) |
| Knack view_1385 (Rich Text container) | ✅ CREATED | Container `<div>` se inyecta dinámicamente vía JS |
| Smoke test end-to-end | ✅ PASA | Inbox renderiza "No new replies." correctamente |
| Instantly Dashboard webhook | ❌ PENDIENTE | Apuntar a `/webhook/instantly-reply` |
| INSTANTLY_CAMPAIGN_ID | ❌ PENDIENTE | Definir con equipo después de crear campaña |
| CSV de Knack | ❌ PENDIENTE | Export manual desde Knack Builder |

---

## Workflows n8n (8 total)

Host: `https://n8n.simultrayd.com`

### Backbone (Knack ↔ n8n ↔ Supabase)

| # | Nombre | ID | Endpoint | Active | Notas |
|---|---|---|---|---|---|
| A | Auth Login (fallback) | `t51xq2zgY0np1eQx` | `POST /webhook/auth/login` | ❌ | Email+password fallback, no usado en producción |
| **A2** | **Auth Exchange** | `SC2iFF8nnECCIWQH` | `POST /webhook/auth/exchange` | ✅ | Path de producción — recibe knack_token, firma JWT |
| **B** | **GET Replies by Trade** | `0hvF00Q1bniPu5fl` | `GET /webhook/replies?trade_id=X` | ✅ | Para futura vista de trade detail |
| **C** | **GET Inbox (Global)** | `kmhDhz3lTowr8LkN` | `GET /webhook/inbox` | ✅ | Inbox global admin/manager |
| **D** | **PATCH Reply Status** | `7YL2aZZRz2eZk0TO` | `PATCH /webhook/replies/:id/status` | ✅ | Mark read/replied/archived |

### Outreach lifecycle (Instantly ↔ n8n ↔ Supabase)

| # | Nombre | ID | Trigger | Active | Notas |
|---|---|---|---|---|---|
| #1 | CSV Import → outreach_queue | `LWLC1gxUUrTOVUqC` | Form Upload | ❌ | Esperando CSV de Knack |
| #2 | Daily Push outreach_queue → Instantly | `Y248GBppVAfkSoBx` | Cron diario 14:00 UTC | ❌ | NO activar hasta tener INSTANTLY_CAMPAIGN_ID |
| #3 | Instantly Reply Webhook → email_replies | `MfRAUFc7KwGsMdqz` | Webhook | ❌ | Activar + configurar URL en Instantly Dashboard |

---

## Configuración aplicada

### Variables n8n (UI — `Settings → Variables` con scope Global)

```
JWT_SECRET             = ya+hHglpJ2B7OWdgMa9murEqRUuA6y8n4MWRLNCHf6zQEXUO8S+dF1n+cEzYw4l3
KNACK_APP_ID           = 64d6ba88d3ca8200285f80ae
INSTANTLY_API_KEY      = <Instantly Dashboard → Settings → Integrations → API>
INSTANTLY_CAMPAIGN_ID  = ⏳ pendiente — UUID del campaign cuando se cree
```

> Los workflows leen estas variables via `$vars.X` (n8n Variables UI, no env vars del runtime).

### Credencial Postgres Supabase

n8n → `Credentials → "Postgres account"`:

| Campo | Valor |
|---|---|
| Host | `aws-1-us-west-1.pooler.supabase.com` |
| Database | `postgres` |
| User | `postgres.pfmnqetthotzpeticfko` |
| Password | (database password del Supabase project) |
| Port | `6543` (Transaction Pooler) |
| Maximum Number of Connections | `15` |
| SSL | `require` |
| Ignore SSL Issues | ON |
| SSH Tunnel | OFF |

> `Ignore SSL Issues = ON` es necesario porque n8n no tiene el CA chain de Supabase en su trust store. La conexión sigue siendo TLS-encriptada.

Asignada a 8 nodos Postgres distribuidos en B, C, D, #1, #2, #3.

### CORS en reverse proxy

Configurado para permitir:
- `Access-Control-Allow-Origin: https://dashboard.simultrayd.com`
- `Access-Control-Allow-Methods: GET, POST, PATCH, OPTIONS`
- `Access-Control-Allow-Headers: Authorization, Content-Type`

---

## Frontend Knack

| Item | Valor |
|---|---|
| Archivo monolito | `Trade-Platform/knack/Simultrayd_NextGen.js` |
| Sección | `PARTE 5 — OUTREACH INBOX` (final del archivo, ~líneas 26135+) |
| Versión actual | `6.6.7-outreach-token-from-localstorage-2026-05-21` |
| Scene Outreach Inbox | `scene_607` (child de scene_603 Admin Dashboard) |
| Rich Text view | `view_1385` (container `<div>` inyectado dinámicamente) |
| Trade detail scene | _(deferred)_ — no existe page admin de trade detail aún |

Ver [`knack-outreach-frontend.md`](./knack-outreach-frontend.md) para detalle técnico.

---

## Gotchas y decisiones técnicas

Lecciones aprendidas durante el deployment (registradas para evitar repetir):

### 1. n8n Code sandbox bloquea TODO acceso a `crypto`

Ni `require('crypto')` ni `globalThis.crypto` están disponibles. Tampoco `await import('node:crypto')`. **Solución:** Implementación pure JS de HMAC-SHA256 inline en cada Code node que firma/verifica JWTs (A2, B, C, D). ~70 líneas de bitwise ops por nodo. Usa `Buffer` (sí disponible).

### 2. Knack Rich Text escapa HTML raw

Pegar `<div id="styd-outreach-inbox"></div>` en un Rich Text view se convierte en texto literal, no en elemento DOM. **Solución:** El JS inyecta el div dinámicamente vía `_ensureContainer()` buscando el wrapper `#view_1385` y agregando el `<div>` como child.

### 3. `_stydAuthGate` del monolito tiene bug de 60s hang

Para algunas sesiones (incluyendo la del dev principal), AuthGate cuelga 60 segundos y resuelve `null`. **Solución:** PARTE 5 bypassa AuthGate completamente. Usa `Knack.getUser()` directo via `_getKnackUser()` helper.

### 4. Knack token vive en localStorage como `refreshToken-<APP_ID>`

El `user.token` que el monolito espera de `Knack.getUser()` no siempre está disponible (relacionado al bug AuthGate). **Solución:** `_getKnackToken()` busca primero `user.token`, después escanea localStorage por keys `refreshToken-*`.

### 5. A2 simplificado: NO valida knack_token contra Knack API

Originalmente A2 hacía `GET /v1/objects/object_10/records/{user_id}` con el knack_token para validar. Pero el refreshToken de Knack Next Gen no funciona como Bearer en su REST API. **Solución:** A2 confía en el payload del JS (que solo ejecuta en contextos autenticados de Knack) y firma el JWT. La validación de role queda en client-side (`_resolveStaffRole`) + en cada Verify JWT downstream.

### 6. Manager + Admin tienen acceso (no solo Admin)

El monolito ya trata Manager (`object_9`) y Admin (`object_10`) como equivalentes via `_stydIsPermanentManager`. PARTE 5 sigue el mismo patrón: `STAFF_OBJECTS = { Admin: object_10, Manager: object_9 }`.

### 7. CORS preflight requiere OPTIONS responder 200/204 con headers correctos

Sin configuración, OPTIONS preflight devolvía 500 y bloqueaba el POST real. Se configuró en el reverse proxy.

### 8. Brave Shields puede bloquear fetches cross-subdomain

Brave bloqueó la primera tanda de fetches a `n8n.simultrayd.com` desde `dashboard.simultrayd.com`. Se resolvió bajando shields para el dominio (no es solución general — usuarios finales no deberían enfrentar esto).

---

## Smoke test (validar en cualquier momento)

Desde browser console logueado como Admin/Manager en Knack, en la página `outreach-inbox`:

```javascript
console.log('Version:', SimulTrayd_Version);
// Esperado: "6.6.7-outreach-token-from-localstorage-2026-05-21"

await window._stydOutreach.resolveStaffRole();
// Esperado: { role: "Manager", object_key: "object_9" } o { role: "Admin", object_key: "object_10" }

await window._stydOutreach.isAdmin();
// Esperado: true (función accepta Manager + Admin a pesar del nombre)

window._stydOutreach.reloadInbox();
// Esperado en console: "[Outreach] n8n JWT issued for <name>"
// Esperado en página: "No new replies." (inbox vacío)
// Esperado en Network: POST /auth/exchange 200, GET /inbox 200
```

---

## Lo que sigue

### Para ver replies reales en el inbox

1. **Definir Instantly campaign** (con equipo) → setear `INSTANTLY_CAMPAIGN_ID` variable
2. **Configurar webhook en Instantly Dashboard** → URL: `https://n8n.simultrayd.com/webhook/instantly-reply`
3. **Activar Workflow #3** (Instantly Reply Webhook) en n8n
4. Cuando llegue un reply real, se inserta en `public.email_replies` y aparece en el inbox

### Para empezar outreach activo

5. **Exportar CSV de Knack** con contactos Exporter/Importer
6. **Subir CSV** vía form: `https://n8n.simultrayd.com/form/outreach-csv-upload`
7. **Activar Workflow #1** (CSV Import)
8. **Activar Workflow #2** (Daily Push) — cron diario a las 14:00 UTC empieza a pushear 200 leads/día a Instantly

### Futura UX

9. Cuando se construya una página admin de detalle de trade → reemplazar `SCENES.TRADE_DETAIL = 'scene_NONE_YET_admin_trade_detail'` con el scene_id real y agregar Rich Text con `<div id="styd-outreach-trade-replies">`. El workflow B ya está listo para servir esos replies.

---

## Archivos del repositorio

```
email-flows/
├── docs/
│   ├── supabase-knack-flow.md      # Spec técnico del backend (workflows, schema)
│   ├── knack-outreach-frontend.md  # Spec del frontend (PARTE 5 monolito)
│   └── setup-progress.md           # ESTE ARCHIVO — estado y gotchas
└── sql/
    └── 001_outreach_initial_schema.sql  # SQL ejecutado en Supabase
```
