CREATE TABLE creators (
  id              SERIAL PRIMARY KEY,
  channel_id      TEXT UNIQUE NOT NULL,
  channel_title   TEXT,
  channel_url     TEXT,
  country         TEXT,
  subscribers     INTEGER,
  total_views     BIGINT,
  video_count     INTEGER,
  matched_keyword TEXT,
  score           NUMERIC(5,2),
  contact_email   TEXT,            
  status          TEXT NOT NULL DEFAULT 'discovered',
  first_seen_at   TIMESTAMPTZ DEFAULT now(),
  last_seen_at    TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE audit_log (
  id          SERIAL PRIMARY KEY,
  entity_type TEXT,
  entity_id   TEXT,
  action      TEXT,
  details     JSONB,
  created_at  TIMESTAMPTZ DEFAULT now()
);




ALTER TABLE creators
  ADD COLUMN onboarded_at TIMESTAMPTZ,
  ADD COLUMN onboarding_error TEXT;


  CREATE TABLE contracts (
  id            SERIAL PRIMARY KEY,
  channel_id    TEXT NOT NULL REFERENCES creators(channel_id),
  campaign      TEXT NOT NULL,
  payout_amount NUMERIC(10,2) NOT NULL,
  currency      TEXT NOT NULL DEFAULT 'USD',
  post_deadline DATE NOT NULL,
  status        TEXT NOT NULL DEFAULT 'draft',  
  envelope_id   TEXT,
  sent_at       TIMESTAMPTZ,
  signed_at     TIMESTAMPTZ,
  created_at    TIMESTAMPTZ DEFAULT now(),
  UNIQUE (channel_id, campaign)                
);