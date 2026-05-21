# Knack Outreach Frontend (PARTE 5 del monolito)

Integración frontend del módulo de Outreach Inbox en la app de Knack. Renderiza replies de email (servidas por n8n → Supabase) **sin consumir Knack API quota**.

> Doc complementario al backend spec: [`supabase-knack-flow.md`](./supabase-knack-flow.md)

---

## Tabla de contenidos

- [Dónde vive el código](#dónde-vive-el-código)
- [Por qué en el monolito y no como módulo separado](#por-qué-en-el-monolito-y-no-como-módulo-separado)
- [Arquitectura del flow](#arquitectura-del-flow)
- [API pública (`window._stydOutreach`)](#api-pública-window_stydoutreach)
- [DOM contract](#dom-contract)
- [Auth flow paso a paso](#auth-flow-paso-a-paso)
- [Robustness features](#robustness-features)
- [Cómo debuggear](#cómo-debuggear)
- [Activation checklist](#activation-checklist)

---

## Dónde vive el código

| Item | Valor |
|---|---|
| Repo | `SimulTrayd/Trade-Platform` |
| Archivo | `knack/Simultrayd_NextGen.js` |
| Sección | `PARTE 5 — OUTREACH INBOX` (al final del archivo) |
| Línea inicial | ~26135 |
| Versión | `6.6.1-outreach-inbox-view1385-2026-05-21` |
| Deploy | Paste manual al Knack Builder JS settings + hard refresh |

---

## Por qué en el monolito y no como módulo separado

El `CLAUDE.md` del repo describe un sistema modular con loader.js + jsDelivr CDN. **Pero ese sistema no existe en el checkout actual**: `knack/modules/` solo tiene 3 archivos (Classic, support-chat, knack.css), no hay loader ni configuración. El deploy real es copy/paste del monolito completo al Knack Builder.

Por eso PARTE 5 sigue la misma convención que PARTE 1-4: bloque IIFE al final del archivo, namespace `_styd*`, integración con helpers globales existentes (`_stydAuthGate`, `_stydOnAuthed`, `_stydMyRole`).

---

## Arquitectura del flow

```
Knack page render (con <div id="styd-outreach-..."></div>)
   │ view:render:view_X event (inbox) / page:render:scene_X (trade detail)
   ▼
window._stydOnAuthed wrapper (await _stydAuthGate)
   │
   ▼
Async admin check — _isCurrentUserAdmin()
   ├─ Si window._stydMyRole === 'Admin'           → true
   ├─ Si window._stydMyRole === otro              → false
   └─ Si null → Knack.getUser().profileObjects    → check object_10
   │
   ▼
Get n8n JWT — _getN8nToken()
   ├─ Cache hit (fresh + user_id match)           → reuse
   ├─ Concurrent exchange in-flight               → await same promise
   └─ Fresh exchange POST /auth/exchange
        ↓
       n8n valida: GET /objects/object_10/records/{user_id} con knack_token
        ↓
       Si 200 → n8n firma JWT (HS256, role:'Admin', 8h exp)
   │
   ▼
Fetch data — _n8nFetch(path, opts)
   ├─ Authorization: Bearer <JWT>
   ├─ Si 401: 1 retry con exchange fresco
   └─ JSON response
   │
   ▼
Render en DOM (innerHTML con valores XSS-escaped)
```

---

## API pública (`window._stydOutreach`)

```javascript
window._stydOutreach = {
  reloadInbox: () => Promise<void>,
  loadTradeReplies: (tradeId: string) => Promise<void>,
  exchangeToken: (user: KnackUser) => Promise<string|null>,
  isAdmin: () => Promise<boolean>,
  config: { N8N_BASE, SCENES, TARGET_IDS }
}
```

Útil desde console para debugging:

```javascript
// ¿Soy admin según la lógica?
await window._stydOutreach.isAdmin();

// Ver config actual
window._stydOutreach.config;

// Forzar reload del inbox
window._stydOutreach.reloadInbox();

// Cargar replies de un trade específico
window._stydOutreach.loadTradeReplies('abc123...');
```

---

## DOM contract

Estos elementos deben existir en el HTML de la página Knack para que el render ocurra. Se pueden agregar via Knack Rich Text view o cualquier mecanismo que inyecte HTML:

| Element | Scene | Propósito |
|---|---|---|
| `<div id="styd-outreach-inbox"></div>` | INBOX (admin-only) | Container del listado global de replies |
| `<div id="styd-outreach-trade-replies"></div>` | TRADE_DETAIL | Container del thread de replies del trade |

Si el container no existe en la página, el handler retorna silenciosamente — no rompe nada.

---

## Auth flow paso a paso

1. Usuario se loguea a Knack normalmente → Knack puebla `Knack.session.user`
2. Usuario navega a la página del inbox (`scene_607`) → Knack renderiza el scene, después el Rich Text view `view_1385` → `view:render:view_1385` dispara (usamos view:render en vez de page:render para garantizar que el container `<div>` ya está en el DOM)
3. `_stydOnAuthed` espera a `_stydAuthGate` (resuelve con user authenticated)
4. Mi handler corre: chequea `_isCurrentUserAdmin()`
   - Primero intenta `window._stydMyRole === 'Admin'` (set por presence/notifications init)
   - Fallback: `Knack.getUser().profileObjects` → busca `object_10`
5. Si admin → `_getN8nToken()`:
   - Cache hit si JWT fresh **Y** `payload.user_id === currentUser.id`
   - Si miss, dispara exchange (deduped contra concurrentes)
6. Exchange = POST a `n8n /auth/exchange` con `{knack_token, user_id, user_name, user_email}`
7. n8n valida el knack_token llamando a Knack: `GET /v1/objects/object_10/records/{user_id}` con `Authorization: <knack_token>`
8. Si Knack devuelve 200 (token válido + usuario es admin) → n8n firma JWT HS256, 8h TTL
9. JS guarda JWT en `localStorage.styd_n8n_token`
10. Todas las fetches subsecuentes incluyen `Authorization: Bearer <jwt>`

**Quota Knack consumida:** 1 call por sesión de admin (en exchange). Cero por page render del inbox o trade detail.

---

## Robustness features

Cada feature responde a un edge case identificado durante el audit:

| Feature | Variable / función | Edge case que mitiga |
|---|---|---|
| Init guard | `window._stydOutreachInit` | Doble paste del monolito al Knack Builder |
| Async admin fallback | `_isCurrentUserAdmin()` consulta `profileObjects` | `_stydMyRole` no está set cuando el scene renderiza (race con presence/notifications init) |
| Exchange dedup | `_pendingExchange` promise | Múltiples fetches concurrentes sin cache disparaban N exchanges en paralelo |
| Stale fetch bail | `_currentInboxRequestId`, `_currentTradeRequestId` | Usuario navega trade A → B rápido; respuesta de A no debe sobrescribir render de B |
| Listener idempotency | `containerEl._stydOutreachWired` flag | Re-render del inbox ya no apila listeners duplicados que multiplicaban writes |
| localStorage safety | `_safeGet/_safeSet/_safeRemove` | Private browsing / quota exceeded throws no rompen el flow |
| 401 retry | `_n8nFetch` reintenta 1 vez con exchange fresco | JWT_SECRET rotation en n8n invalida tokens previos |
| JWT user_id match | `_getN8nToken` invalida cache si user_id no coincide | Admin A logout → Admin B login mismo browser; B no debe usar JWT de A |
| Button busy state | `disabled` + clase `styd-outreach-btn-busy` | Doble-click en mark-read disparaba doble PATCH |
| Trade ID extractor | `_extractTradeIdFromUrl()` con find 24-hex | URL con varios IDs (e.g. trade nested en partner page) → tomar el primero, no el último |
| Date format fallback | try/catch en `Intl` V3 opciones | Browser viejo sin `dateStyle/timeStyle` cae a `toLocaleString()` base |
| XSS escaping | `_esc/_attr/_escMultiline` | Subject o body de reply con HTML hostil no se renderiza como markup |

---

## Cómo debuggear

### "Access denied" pero sí soy Admin

```javascript
// Ver qué dice el monolito
window._stydMyRole;
// Si null o no "Admin", la detección async aún no corrió

// Forzar el chequeo
await window._stydOutreach.isAdmin();
// Debe ser true; si false → revisar profileObjects

// Ver raw profileObjects de Knack
(await Knack.getUser()).profileObjects;
// Debe contener "object_10" (string) o {key: "object_10"}
```

### El inbox no carga / queda en "Loading…"

```javascript
// 1. Container existe?
document.getElementById('styd-outreach-inbox');

// 2. JWT cache?
localStorage.getItem('styd_n8n_token');

// 3. Decodificar payload del JWT
JSON.parse(atob(localStorage.getItem('styd_n8n_token').split('.')[1]));

// 4. Forzar fresh exchange
localStorage.removeItem('styd_n8n_token');
window._stydOutreach.reloadInbox();
```

### Network → 401 incluso después del exchange

- Verificar que `JWT_SECRET` en n8n env vars **coincide** con el que firmó el JWT
- Si rotaste el secret, el retry interno debería recuperarse automáticamente; si persiste, hay otro issue

### PATCH /status no llega a n8n

**Sospecha #1: CORS preflight fail.** DevTools → Network → buscar la request `OPTIONS` a `/webhook/replies/<id>/status`:
- Debe responder 200
- Debe incluir `Access-Control-Allow-Methods: PATCH`
- Debe incluir `Access-Control-Allow-Headers: Authorization, Content-Type`

Si falta, configurar CORS en el reverse proxy de `n8n.simultrayd.com`.

### Quiero ver el response raw del exchange

```javascript
// Trigger manual y log
const user = await Knack.getUser();
const token = await window._stydOutreach.exchangeToken(user);
console.log('Got JWT:', token);
```

---

## Activation checklist

- [ ] Crear nueva scene admin-only para inbox en Knack → anotar `scene_id`
- [ ] ~~Identificar `scene_id` del Trade detail page existente~~ **DEFERRED** — Admin no tiene página propia de trade detail aún (existen solo Manager pages; Admin tendrá UX distinta)
- [ ] **Reemplazar placeholder en monolito:**
  - `SCENES.INBOX` → `scene_607` ✅ ya hecho
  - `SCENES.TRADE_DETAIL` → queda como `scene_NONE_YET_admin_trade_detail` (handler registra pero nunca dispara)
- [ ] **Insertar container HTML** en scene_607 (Rich Text view en HTML mode):
  - `<div id="styd-outreach-inbox"></div>`
- [ ] Verificar `SimulTrayd_Version` bumpeada (actualmente `6.6.0-outreach-inbox-2026-05-21`)
- [ ] **Backend prereqs** (ver [`supabase-knack-flow.md`](./supabase-knack-flow.md)):
  - Env vars `JWT_SECRET` + `KNACK_APP_ID` en n8n
  - Credencial Postgres apuntada a Supabase Transaction Pooler
  - Asignar la credencial a workflows B, C, D
  - CORS configurado en reverse proxy
  - Activar workflows A, A2, B, C, D
- [ ] **Deploy frontend:**
  - Copy del monolito completo
  - Paste al Knack Builder → JS settings → Save
  - Hard refresh (Ctrl+Shift+R)
- [ ] **Smoke test desde console como admin:**
  ```javascript
  console.log('SimulTrayd_Version:', SimulTrayd_Version);
  console.log('isAdmin:', await window._stydOutreach.isAdmin());
  window._stydOutreach.reloadInbox();
  ```
  Esperado: version `6.6.0-outreach-inbox-...`, isAdmin `true`, log `[Outreach] n8n JWT issued for <name>`, inbox renderiza (vacío si no hay replies todavía).

---

## Referencias

- Backend spec: [`supabase-knack-flow.md`](./supabase-knack-flow.md)
- Deploy workflow del monolito: memoria `feedback_knack_monolith_paste_deploy`
- Estrategia de quota Knack: memoria `feedback_knack_quota_strategic_framing`
- Existing inbox panel de Ably (no relacionado, solo para no confundir naming): monolito líneas 20825-22500
