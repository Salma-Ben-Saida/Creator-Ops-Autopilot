# Send Contract Workflow

> An n8n automation that sends campaign contracts for e-signature to onboarded creators. It records every contract in PostgreSQL, keeps an audit trail, and alerts the team in Slack when a send fails.

| | |
|---|---|
| **Workflow name** | `send-contract-workflow` |
| **Workflow ID** | `qUXNyHSQfivfjtSB` |
| **Platform** | n8n (Cloud) |
| **Trigger** | n8n Form (multi-step) |
| **Integrations** | PostgreSQL, DocuSeal, Slack |

---

## Table of Contents

1. [Overview](#overview)
2. [Key Features](#key-features)
3. [Architecture](#architecture)
4. [Workflow Steps](#workflow-steps)
5. [Prerequisites](#prerequisites)
6. [Database Schema](#database-schema)
7. [Configuration](#configuration)
8. [Usage](#usage)
9. [Contract Lifecycle](#contract-lifecycle)
10. [Error Handling and Observability](#error-handling-and-observability)

---

## Overview

The **Send Contract Workflow** lets a team member send a contract to a creator through a simple web form, with no manual paperwork. The operator:

1. Opens the form.
2. Picks an onboarded creator from a dropdown.
3. Enters the campaign name, payout amount, and posting deadline.

The workflow then:

- Creates or reuses a contract record in PostgreSQL. Re-submitting the same creator and campaign does not create a duplicate.
- Checks that the contract has not already been sent.
- Fills a DocuSeal template with the contract details and emails the signing request.
- Saves the outcome (`sent` or `failed`) and writes an entry to an audit log.
- Posts a Slack alert if the e-signature request fails.


![send-contract-workflow-screenshot](/docs/workflow-screenshots/send-contract.png)
---

## Key Features

- **Self-service form:** Non-technical users can start contract sends from a hosted n8n form.
- **Dynamic creator list:** The dropdown is built live from the `creators` table. It only shows creators with `status = 'onboarded'`.
- **Clear creator labels:** Creators appear by channel title. If two creators share a title, or a title is missing, the channel ID is added to the label.
- **No duplicate contracts:** One contract per `(channel_id, campaign)`, enforced with `ON CONFLICT`. A failed contract can be retried and is reset to `draft`.
- **No duplicate sends:** A contract already marked `sent` is never sent again.
- **Template-based e-signature:** DocuSeal pre-fills the creator, campaign, payout, deadline, channel link, and company signature.
- **Full audit trail:** Every send and every failure is written to `audit_log` with JSON details.
- **Failure alerts:** Failed sends post a Slack message with the error details.

---

## Architecture

```
┌──────────────────────┐
│  On form submission  │  (Form Trigger: "Contract form")
└──────────┬───────────┘
           ▼
┌────────────────────────────── Collect contract details ──────────────────────────────┐
│  Select rows from a table ─► Combine creators ─► Form ─► Resolve creator channel ID  │
└──────────────────────────────────────────┬───────────────────────────────────────────┘
                                           ▼
┌──────────── Reserve contract ────────────┐
│           Create contract row            │  (INSERT ... ON CONFLICT ... RETURNING id)
└────────────────────┬─────────────────────┘
                     ▼
            Get creator infos
                     ▼
            Execute a SQL query   (look up the existing contract status)
                     ▼
        If contract not already sent ──(false)──► stop
                     │ (true)
                     ▼
                 DocuSeal
            ┌────────┴─────────┐
       success               error
            ▼                  ▼
   Mark contract sent    Mark contract failed
            ▼                  ▼
   Audit contract sent   Audit contract failed
                               ▼
                   Alert Slack: contract failed
```

---

## Workflow Steps

| # | Node | Type | Purpose |
|---|------|------|---------|
| 1 | **On form submission** | Form Trigger | Entry point. Shows the "Contract form" start page (*"Send contract to onboarded creators"*). |
| 2 | **Select rows from a table** | PostgreSQL – Select | Gets all creators from `public.creators` where `status = 'onboarded'`. |
| 3 | **Combine creators** | Aggregate | Collects `channel_id` values into a single item so the form appears only once. |
| 4 | **Form** | Form (JSON-defined) | Second form page with the fields **Select creator** (dropdown, required), **Campaign name**, **Payout amount**, and **Post deadline**. |
| 5 | **Resolve creator channel ID** | Set | Converts the selected dropdown label back to the creator's `channel_id`. Keeps the original label as `creator_title`. |
| 6 | **Create contract row** | PostgreSQL – Query | Inserts the contract. If one already exists for the same creator and campaign, it is reset to `draft` only when its current status is `failed`. Returns the contract `id`. |
| 7 | **Get creator infos** | PostgreSQL – Query | Loads the full creator record (title, URL, and so on) by `channel_id`. |
| 8 | **Execute a SQL query** | PostgreSQL – Query | Reads the current contract `status` for the creator. |
| 9 | **If contract not already sent** | IF | Continues only when `status` is not `sent`. |
| 10 | **DocuSeal** | DocuSeal | Creates a signing submission from template `6227091`, pre-fills fields, and emails the signing link. Errors go to the error output. |
| 11a | **Mark contract sent** | PostgreSQL – Query | Sets `status = 'sent'`, stores the DocuSeal `envelope_id`, and sets `sent_at = now()`. |
| 12a | **Audit contract sent** | PostgreSQL – Query | Writes a `contract_sent` event to `audit_log`. |
| 11b | **Mark contract failed** | PostgreSQL – Query | Sets `status = 'failed'`. |
| 12b | **Audit contract failed** | PostgreSQL – Query | Writes a `contract_failed` event with the error details to `audit_log`. |
| 13b | **Alert Slack: contract failed** | Slack | Posts a failure alert to the configured Slack channel. |

---

## Prerequisites

### n8n
- An n8n instance (Cloud or self-hosted) that supports Form Trigger v2.6+ and multi-step forms.
- The community node **`@docuseal/n8n-nodes-docuseal`** installed.

### Credentials

| Credential | Type | Used by |
|---|---|---|
| Postgres account | `postgres` | All database nodes |
| DocuSeal account | `docusealApi` | DocuSeal |
| Slack account | `slackOAuth2Api` | Alert Slack: contract failed |

### External services
- **PostgreSQL** database with the tables described below.
- **DocuSeal** account with a contract template (currently ID `6227091`) that includes the fields listed under [Configuration](#configuration).
- **Slack** workspace and a channel for alerts.

---

## Database Schema

The workflow expects the following tables. The DDL below is a **reference** based on the columns the workflow reads and writes. Adjust types and constraints to match your environment.

```sql
-- Creators available for contracting
CREATE TABLE creators (
  channel_id     TEXT PRIMARY KEY,
  channel_title  TEXT,
  channel_url    TEXT,
  status         TEXT NOT NULL            -- e.g. 'onboarded'
  -- ...additional creator fields
);

-- One contract per creator per campaign
CREATE TABLE contracts (
  id             SERIAL PRIMARY KEY,
  channel_id     TEXT NOT NULL REFERENCES creators(channel_id),
  campaign       TEXT NOT NULL,
  payout_amount  NUMERIC,
  post_deadline  DATE,
  status         TEXT NOT NULL DEFAULT 'draft',  -- draft | sent | failed
  envelope_id    TEXT,
  sent_at        TIMESTAMPTZ,
  CONSTRAINT contracts_channel_campaign_uniq UNIQUE (channel_id, campaign)
);

-- Generic audit trail
CREATE TABLE audit_log (
  id           SERIAL PRIMARY KEY,
  entity_type  TEXT NOT NULL,
  entity_id    TEXT NOT NULL,
  action       TEXT NOT NULL,
  details      JSONB,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

> The `UNIQUE (channel_id, campaign)` constraint is **required**. The `ON CONFLICT` clause in *Create contract row* depends on it.

---

## Configuration

### DocuSeal template fields

The DocuSeal template must include these fields. The workflow fills them automatically:

| Template field | Source |
|---|---|
| `sent_date` | Form submission timestamp |
| `deadline_date` | Form → *Post deadline* |
| `company_name` | Form → *Campaign name* |
| `channel_title` | `creators.channel_title` |
| `payout` | Form → *Payout amount* |
| `channel_link` | `creators.channel_url` |
| `company_signature` | Embedded signature image (base64 PNG) |

**Email:** Subject *"E-sign your contract"*. The body greets the creator by channel title and includes a **Review and Sign** link (`{{submitter.link}}`).

**Submitter role:** `First Party`.

### Settings to review before going live

| Setting | Node | Current value | Action |
|---|---|---|---|
| Recipient email | DocuSeal | Hard-coded test address | Replace with the creator's email from `creators`. |
| Template ID | DocuSeal | `6227091` | Confirm it matches your production template. |
| Slack channel | Alert Slack: contract failed | `all-salma-bensaida39s-workspace` | Point to your operations or alerts channel. |
| Form wait limit | Form | Limited (minutes) | Change the timeout if operators need more time. |

---

## Usage

1. **Publish** the workflow in n8n. Production form URLs only work for published workflows.
2. Open the production URL of the **On form submission** trigger:
   `https://<your-instance>/form/<form-path>`
3. Click **Start**.
4. Pick a creator, then enter the **Campaign name**, **Payout amount**, and **Post deadline**.
5. Submit. The creator receives a DocuSeal email to review and sign.

To test without publishing, open the trigger in the editor and use its **Test URL**.

---

## Contract Lifecycle

```
           ┌───────── form submitted ─────────┐
           ▼                                  │
        [draft] ──── DocuSeal OK ────► [sent] │  (terminal: never re-sent)
           │                                  │
           └──── DocuSeal error ───► [failed] ┘  (re-submission resets to draft)
```

- **draft:** The contract was created and is waiting to be sent.
- **sent:** The signing request was delivered. `envelope_id` and `sent_at` are filled in.
- **failed:** The send failed. Submitting the same creator and campaign again retries it.

---

## Error Handling and Observability

- The **DocuSeal** node uses `continueErrorOutput`, so API errors go to a dedicated failure branch instead of stopping the run.
- Every outcome is written to **`audit_log`**:
  - `contract_sent`: `{ channel_id, campaign, envelope_id, recipient }`
  - `contract_failed`: `{ channel_id, campaign, error }`
- Failures post a **Slack** alert with the creator, campaign, contract ID, and error message.
- Execution history is available under **Executions** in n8n.

Example audit query:

```sql
SELECT created_at, action, entity_id, details
FROM audit_log
WHERE entity_type = 'contract'
ORDER BY created_at DESC
LIMIT 50;
```

---

Ps: signer email is currently hardcoded as "salmasaida003@gmail.com" as its for dev/test mode only.