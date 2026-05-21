-- ============================================================
-- OUTREACH SCHEMA — SimulTrayd
-- Proyecto Supabase: pfmnqetthotzpeticfko
-- Ejecutar en SQL Editor de Supabase
-- ============================================================

-- 1. Extensión CITEXT (case-insensitive text para emails)
CREATE EXTENSION IF NOT EXISTS citext;

-- ============================================================
-- 2. TABLA: outreach_queue
--    Master list de contactos para outreach
-- ============================================================
CREATE TABLE IF NOT EXISTS public.outreach_queue (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email                 CITEXT UNIQUE NOT NULL,
  name                  TEXT,
  company               TEXT,
  knack_contact_id      TEXT,
  knack_contact_object  TEXT CHECK (knack_contact_object IN ('exporter', 'importer')),
  knack_trade_id        TEXT,
  knack_trade_name      TEXT,
  instantly_lead_id     TEXT,
  instantly_campaign_id TEXT,
  status                TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending','sent','failed','bounced','unsubscribed','replied','completed')),
  sent_at               TIMESTAMPTZ,
  got_reply             BOOLEAN NOT NULL DEFAULT FALSE,
  reply_count           INTEGER NOT NULL DEFAULT 0,
  last_activity_at      TIMESTAMPTZ,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Índices outreach_queue
CREATE INDEX IF NOT EXISTS idx_oq_status_created
  ON public.outreach_queue (status, created_at);

CREATE INDEX IF NOT EXISTS idx_oq_instantly_lead
  ON public.outreach_queue (instantly_lead_id)
  WHERE instantly_lead_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_oq_knack_trade
  ON public.outreach_queue (knack_trade_id)
  WHERE knack_trade_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_oq_got_reply
  ON public.outreach_queue (got_reply)
  WHERE got_reply = TRUE;

-- ============================================================
-- 3. TABLA: email_replies
--    Replies recibidos vía webhook de Instantly
-- ============================================================
CREATE TABLE IF NOT EXISTS public.email_replies (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  instantly_message_id     TEXT UNIQUE,
  outreach_id              UUID REFERENCES public.outreach_queue(id) ON DELETE SET NULL,
  knack_trade_id           TEXT,
  knack_contact_id         TEXT,
  contact_email            CITEXT NOT NULL,
  contact_name             TEXT,
  instantly_lead_id        TEXT,
  instantly_campaign_id    TEXT,
  instantly_campaign_name  TEXT,
  subject                  TEXT,
  body_text                TEXT,
  body_html                TEXT,
  received_at              TIMESTAMPTZ NOT NULL,
  status                   TEXT NOT NULL DEFAULT 'new'
                           CHECK (status IN ('new','read','replied','archived')),
  raw_payload              JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Índices email_replies
CREATE INDEX IF NOT EXISTS idx_er_status_received
  ON public.email_replies (status, received_at DESC);

CREATE INDEX IF NOT EXISTS idx_er_knack_trade
  ON public.email_replies (knack_trade_id)
  WHERE knack_trade_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_er_contact_email
  ON public.email_replies (contact_email);

CREATE INDEX IF NOT EXISTS idx_er_outreach
  ON public.email_replies (outreach_id)
  WHERE outreach_id IS NOT NULL;

-- ============================================================
-- 4. TRIGGER: auto-update updated_at
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_oq_updated_at
  BEFORE UPDATE ON public.outreach_queue
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER trg_er_updated_at
  BEFORE UPDATE ON public.email_replies
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- ============================================================
-- 5. ROW LEVEL SECURITY
--    Activo sin policies = solo service_role tiene acceso
--    (n8n usa service_role, frontend nunca pega directo)
-- ============================================================
ALTER TABLE public.outreach_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.email_replies ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- DONE. Verifica con:
--   SELECT count(*) FROM public.outreach_queue;
--   SELECT count(*) FROM public.email_replies;
-- Ambos deben devolver 0 rows sin error.
-- ============================================================
