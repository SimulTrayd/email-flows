# Knack Outreach Frontend (PARTE 5 del monolito)

Integración frontend del módulo de Outreach Inbox en la app de Knack. Renderiza replies de email (servidas por n8n → Supabase) **sin consumir Knack API quota**.

> Doc complementario al backend spec: [`supabase-knack-flow.md`](./supabase-knack-flow.md) · Estado actual del sistema: [`setup-progress.md`](./setup-progress.md)

---

## Tabla de contenidos

- [Dónde vive el código](#dónde-vive-el-código)
- [Estado actual](#estado-actual)
- [Arquitectura del flow](#arquitectura-del-flow)
- [API pública (`window._stydOutreach`)](#api-pública-window_stydoutreach)
- [DOM contract](#dom-contract)
- [Auth flow paso a paso](#auth-flow-paso-a-paso)
- [Robustness features](#robustness-features)
- [Cómo debuggear](#cómo-debuggear)
- [Lessons learned](#lessons-learned)

---

## Dónde vive el código

| Item | Valor |
|---|---|
| Repo | `SimulTrayd/Trade-Platform` |
| Archivo | `knack/Simultrayd_NextGen.js` |
| Sección | `PARTE 5 — OUTREACH INBOX` (al final del archivo) |
| Línea inicial | ~26135 |
| Versión actual | `6.6.9-outreach-static-status-path-2026-05-21` |
| Deploy | Paste manual al Knack Builder JS settings + hard refresh |

---

## Estado actual

✅ **Desplegado y operativo** — smoke test pasa (`POST /auth/exchange` → 200, `GET /inbox` → 200, render "No new replies.").

| Item | Status |
|---|---|
| Scene Outreach Inbox | `scene_607` (child de Admin Dashboard `scene_603`) |
| Rich Text view del inbox | `view_1385` — container `<div>` se inyecta dinámicamente |
| Versión deployed | `6.6.9-outreach-static-status-path-2026-05-21` |
| Trade detail UI | _(deferred)_ — no existe page admin de trade detail aún |

Para detalle por componente ver [`setup-progress.md`](./setup-progress.md).

---

## Arquitectura del flow

```
Knack page render (scene_607 con view_1385 Rich Text)
   │ view:render:view_1385 event
   ▼
Knack.on() handler (bypass _stydOnAuthed — AuthGate tiene bug)
   │
   ▼
_getKnackUser() — query Knack.getUser() directo (sin AuthGate)
   │ user object con id + profileObjects
   ▼
_resolveStaffRole() — chequea Admin (object_10) o Manager (object_9)
   │ {role, object_key} o null
   ▼
_ensureContainer() — busca o crea <div id="styd-outreach-inbox"> dentro de view_1385
   │ HTMLElement
   ▼
_getN8nToken() — devuelve JWT cacheado o dispara exchange
   ├─ Cache hit (fresh + user_id match)          → reuse
   ├─ Concurrent exchange in-flight              → await same promise
   └─ Fresh exchange:
        ↓ _getKnackToken() escanea localStorage por refreshToken-<APP_ID>
        ↓ POST /webhook/auth/exchange {knack_token, user_id, user_object_key, user_role}
        ↓ n8n A2 simplificado: valida payload + firma JWT con role del JS (HS256 puro JS)
        ↓ guarda JWT en localStorage.styd_n8n_token
   │
   ▼
_n8nFetch(path, opts) → GET /inbox con Authorization: Bearer <JWT>
   │ n8n C verifica firma (HMAC puro JS) + claims → query Supabase
   │ JSON response { replies, count }
   ▼
_renderInbox() o _renderTradeReplies()
   │ innerHTML con XSS escaping
   ▼
Container muestra inbox / "No new replies."
```

---

## API pública (`window._stydOutreach`)

```javascript
window._stydOutreach = {
  reloadInbox: () => Promise<void>,
  loadTradeReplies: (tradeId: string) => Promise<void>,
  exchangeToken: (user: KnackUser) => Promise<string|null>,
  isAdmin: () => Promise<boolean>,           // accepta Admin Y Manager (back-compat name)
  resolveStaffRole: () => Promise<{role, object_key}|null>,
  config: { N8N_BASE, SCENES, VIEWS, TARGET_IDS, STAFF_OBJECTS }
}
```

Útil desde console:

```javascript
// ¿Cuál es mi rol?
await window._stydOutreach.resolveStaffRole();
// → { role: "Manager", object_key: "object_9" } o Admin/object_10

// ¿Tengo acceso?
await window._stydOutreach.isAdmin();
// → true (si Manager o Admin)

// Forzar reload
window._stydOutreach.reloadInbox();

// Config actual
window._stydOutreach.config;
```

---

## DOM contract

El frontend solo requiere que **el Rich Text view `view_1385` exista** en la página `scene_607`. El `<div>` container se inyecta dinámicamente.

| Element | Cómo se crea |
|---|---|
| `<div id="styd-outreach-inbox">` | Inyectado por `_ensureContainer()` dentro de `#view_1385` cuando se entra a scene_607 |
| `<div id="styd-outreach-trade-replies">` | _(deferred)_ — para futura página admin de trade detail |

> Anteriormente la spec pedía pegar el `<div>` literal en el Rich Text editor. **Eso no funciona** porque Knack escapa el HTML como texto. La inyección dinámica vía JS reemplazó ese approach.

---

## Auth flow paso a paso

1. Usuario se loguea a Knack normalmente → Knack puebla la sesión
2. Usuario navega a `scene_607` (Outreach Inbox)
3. Knack renderiza la scene y el view `view_1385` (Rich Text)
4. `view:render:view_1385` dispara → mi handler (registrado vía `Knack.on()` directo, no `_stydOnAuthed`)
5. **`_maybeInitInboxNow()`** corre proactivamente al cargar PARTE 5 si ya estamos en la scene del inbox (para casos donde JS carga DESPUÉS del view render)
6. `_getKnackUser()` query directo a `Knack.getUser()` → obtiene user
7. `_resolveStaffRole()` mapea profileObjects a `{role, object_key}`:
   - `object_10` → Admin
   - `object_9` → Manager
   - cualquier otro → null (access denied)
8. `_ensureContainer()` busca o crea el `<div id="styd-outreach-inbox">` dentro de `#view_1385`
9. `_getN8nToken()` revisa cache:
   - Cache hit fresh + user_id match → usa cache
   - Si miss → `_exchangeToken(user)`:
     - `_getKnackToken(user)` busca token: primero `user.token`, después escanea localStorage por `refreshToken-<APP_ID>`
     - POST `/webhook/auth/exchange` con `{knack_token, user_id, user_name, user_email, user_object_key, user_role}`
     - n8n A2 (simplificado): valida campos + firma JWT con `role` del payload (HMAC-SHA256 puro JS, 8h exp)
     - JS guarda JWT en `localStorage.styd_n8n_token`
10. `_n8nFetch('/inbox')` con `Authorization: Bearer <JWT>`
11. n8n C: `Verify JWT` (HMAC puro JS) + Postgres SELECT → JSON response
12. `_renderInbox(container, replies)` con innerHTML XSS-escaped

**Quota Knack consumida:** Cero por page render del inbox. El exchange usa el Knack token existente (no llama a Knack API).

---

## Robustness features

Cada feature responde a un edge case identificado durante deployment:

| Feature | Función / variable | Edge case que mitiga |
|---|---|---|
| Init guard | `window._stydOutreachInit` | Doble paste del monolito al Knack Builder |
| **AuthGate bypass** | `_getKnackUser()` (no usa `_stydAuthGate`) | Bug pre-existente: AuthGate cuelga 60s y resuelve null en algunas sesiones |
| **Direct Knack.on** | No usa `_stydOnAuthed` wrapper | Mismo bug — `_stydOnAuthed` silently skips si AuthGate falla |
| **Proactive init** | `_maybeInitInboxNow()` IIFE | view:render no fire si JS carga DESPUÉS del primer render del view |
| **Dynamic container** | `_ensureContainer()` inyecta `<div>` | Knack Rich Text escapa raw HTML → div literal no existe en DOM |
| **Multi-source token** | `_getKnackToken(user)` con fallback a localStorage | `user.token` ausente cuando AuthGate falla → token está en `refreshToken-<APP_ID>` |
| Multi-role support | `STAFF_OBJECTS = {Admin: object_10, Manager: object_9}` | Manager y Admin son ambos staff interno; alinea con `_stydIsPermanentManager` del monolito |
| Async admin fallback | `_resolveStaffRole()` consulta profileObjects | `_stydMyRole` no está set cuando el scene renderiza (race con presence/notifications init) |
| Exchange dedup | `_pendingExchange` promise | Múltiples fetches concurrentes sin cache disparaban N exchanges en paralelo |
| Stale fetch bail | `_currentInboxRequestId`, `_currentTradeRequestId` | Usuario navega rápido entre páginas; respuesta vieja no sobrescribe render fresco |
| Listener idempotency | `containerEl._stydOutreachWired` flag | Re-render del inbox apilaba listeners duplicados que multiplicaban writes |
| localStorage safety | `_safeGet/_safeSet/_safeRemove` | Private browsing / quota exceeded throws no rompen el flow |
| 401 retry | `_n8nFetch` reintenta 1 vez con exchange fresco | JWT_SECRET rotation en n8n invalida tokens previos |
| JWT user_id match | `_getN8nToken` invalida cache si user_id no coincide | Admin A logout → Admin B login mismo browser; B no debe usar JWT de A |
| Button busy state | `disabled` + clase `styd-outreach-btn-busy` | Doble-click en mark-read disparaba doble PATCH |
| Trade ID extractor | `_extractTradeIdFromUrl()` con find 24-hex | URL con varios IDs (e.g. trade nested en partner page) → toma el primero |
| Date format fallback | try/catch en `Intl` V3 opciones | Browser viejo sin `dateStyle/timeStyle` cae a `toLocaleString()` base |
| XSS escaping | `_esc/_attr/_escMultiline` | Subject o body con HTML hostil no se renderiza como markup |

---

## Cómo debuggear

### "Access denied" pero soy Admin/Manager

```javascript
// ¿Cuál es mi rol detectado?
window._stydMyRole;
// Si null o no Admin/Manager, la detección async aún no corrió

// Forzar resolución
await window._stydOutreach.resolveStaffRole();
// Debe devolver {role, object_key}; si null → ver profileObjects

// Raw profileObjects de Knack
(await Knack.getUser()).profileObjects;
// Debe contener "object_10" (Admin) o "object_9" (Manager)
```

### El inbox no carga / queda en "Loading…"

```javascript
// 1. Container existe? (Knack debe haber renderizado view_1385)
document.getElementById('styd-outreach-inbox');
// Si null pero estás en outreach-inbox, view_1385 no se renderizó
document.getElementById('view_1385');

// 2. ¿JWT en cache?
localStorage.getItem('styd_n8n_token');

// 3. Decodificar payload del JWT
JSON.parse(atob(localStorage.getItem('styd_n8n_token').split('.')[1].replace(/-/g,'+').replace(/_/g,'/').padEnd(Math.ceil(localStorage.getItem('styd_n8n_token').split('.')[1].length/4)*4,'=')));

// 4. Forzar fresh exchange
localStorage.removeItem('styd_n8n_token');
window._stydOutreach.reloadInbox();
```

### Network → 401 después del exchange

- Verificar que `JWT_SECRET` en n8n Variables (UI) coincide con el que firmó el JWT
- El retry interno automático debería recuperarse si solo es desincronización momentánea

### Network → 500 en `/webhook/auth/exchange`

- Workflow A2 inactive — activar en n8n
- O bug en Code node — revisar el último execution log en n8n UI

### PATCH /status no llega a n8n

**Sospecha #1: CORS preflight fail.** DevTools → Network → buscar `OPTIONS` a `/webhook/replies/<id>/status`:
- Debe responder 200/204
- Debe incluir `Access-Control-Allow-Methods: PATCH`
- Debe incluir `Access-Control-Allow-Origin: https://dashboard.simultrayd.com`

**Sospecha #2: Browser extension blocking** (Brave Shields, uBlock, etc.). Probar con shields off para ver si pasa.

### Quiero ver el response raw del exchange

```javascript
const user = await Knack.getUser();
const token = await window._stydOutreach.exchangeToken(user);
console.log('Got JWT:', token);
console.log('Payload:', JSON.parse(atob(token.split('.')[1].replace(/-/g,'+').replace(/_/g,'/').padEnd(Math.ceil(token.split('.')[1].length/4)*4,'='))));
```

---

## Lessons learned

Documentación de surprises técnicas que justifican algunas decisiones de arquitectura. Útil para futuros maintainers.

### 1. n8n Code sandbox bloquea TODO crypto

`require('crypto')` está bloqueado, `globalThis.crypto` también no existe, `await import('node:crypto')` también bloqueado. **Solución:** los workflows que firman/verifican JWTs (A2, B, C, D) incluyen implementación pure JS de HMAC-SHA256 inline (~70 líneas por nodo). Usa `Buffer` que sí está disponible.

### 2. Knack Rich Text escapa raw HTML

Pegar `<div id="styd-outreach-inbox"></div>` en un Rich Text view de Knack se renderiza como texto literal, no como elemento DOM. **Solución:** El JS detecta esto y crea el `<div>` dinámicamente vía `_ensureContainer()` dentro del wrapper `#view_1385`.

### 3. `_stydAuthGate` tiene bug de 60s hang

Bug pre-existente del monolito ([[project_knack_login_bugs]]): para algunas sesiones, AuthGate nunca resuelve y queda colgado 60 segundos antes de devolver `null`. PARTE 5 **bypassa AuthGate completamente** — usa `Knack.getUser()` directo via `_getKnackUser()`.

### 4. Knack token vive en localStorage

El monolito espera que `user.token` venga del `Knack.getUser()` response. Pero en algunas sesiones está vacío. **Solución:** `_getKnackToken()` busca primero `user.token`, después escanea localStorage por keys `refreshToken-<APP_ID>` (formato Knack Next Gen).

### 5. A2 simplificado: NO valida knack_token contra Knack API

Originalmente A2 hacía `GET /v1/objects/object_10/records/{user_id}` con el knack_token. Pero el refreshToken de Knack Next Gen no funciona como Bearer en su REST API. **Solución:** A2 confía en el payload del JS (que solo ejecuta en contextos autenticados de Knack) y firma directamente. La validación de role queda client-side (`_resolveStaffRole`) + server-side downstream (cada Verify JWT chequea claim `role`).

### 6. Manager + Admin acceso equivalente

El monolito ya trata `object_9` (Manager) y `object_10` (Admin) como equivalentes vía `_stydIsPermanentManager` (líneas 2553+). PARTE 5 sigue el mismo patrón con `STAFF_OBJECTS = { Admin: 'object_10', Manager: 'object_9' }`.

### 7. CORS preflight required

n8n no devuelve `Access-Control-Allow-Origin` por default. Sin configurar el reverse proxy, todo POST/PATCH desde browser falla con CORS error.

### 8. Proactive init para race con Knack lifecycle

Si el monolito (PARTE 5) carga DESPUÉS de que Knack ya renderizó la view, el evento `view:render:view_1385` no dispara para mi handler. **Solución:** `_maybeInitInboxNow()` IIFE corre al cargar PARTE 5, detecta si estamos en la scene del inbox, y dispara el flujo proactivamente.

### 9. n8n CORS no maneja webhook paths con parámetros dinámicos

`/webhook/replies/:id/status` (path con `:id`) fallaba en el preflight OPTIONS porque n8n no devolvía los headers CORS para esos paths. `/webhook/auth/exchange` e `/inbox` (estáticos) sí funcionan. **Solución:** D usa path estático `/webhook/replies-status` con `id` en el body del POST.

### 10. CORS Allow-Methods limitado a OPTIONS + POST

El reverse proxy advertise solo `OPTIONS, POST` en `Access-Control-Allow-Methods`. PATCH preflight fallaba. **Solución:** D usa POST en lugar de PATCH. Menos REST, mismo resultado.

---

## Referencias

- Backend spec: [`supabase-knack-flow.md`](./supabase-knack-flow.md)
- Estado del sistema: [`setup-progress.md`](./setup-progress.md)
- Deploy workflow del monolito: memoria interna `feedback_knack_monolith_paste_deploy`
- Estrategia de quota Knack: memoria interna `feedback_knack_quota_strategic_framing`
- Bug del AuthGate: memoria interna `project_knack_login_bugs`
- Existing inbox panel de Ably (no relacionado, solo para no confundir naming): monolito líneas 20825-22500
