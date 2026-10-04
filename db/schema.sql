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