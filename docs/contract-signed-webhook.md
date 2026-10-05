# Contract Signed Webhook

> An n8n workflow that sees when a creator contract is fully signed in DocuSeal, updates the contract and creator records in PostgreSQL, writes an audit entry, and tells the team in Slack.

| | |
|---|---|
| **Workflow ID** | `tDPYWCAkh9G2nnGW` |
| **Platform** | n8n |
| **Trigger** | DocuSeal `form.completed` event |
| **Integrations** | DocuSeal, PostgreSQL, Slack |

---

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Workflow Diagram](#workflow-diagram)
4. [Node Reference](#node-reference)
5. [Prerequisites](#prerequisites)
6. [Database Schema Requirements](#database-schema-requirements)
7. [Setup & Configuration](#setup--configuration)
8. [Idempotency & Data Integrity](#idempotency--data-integrity)
9. [Testing](#testing)

---

## Overview

This workflow is part of the **Creator Ops Autopilot** system. It handles the last step of the creator onboarding pipeline: when a creator finishes signing their contract in DocuSeal, the workflow does the following automatically:

- Changes the contract status from `sent` to `signed` and records the signing time.
- Changes the matching creator's status to `contracted`.
- Adds an entry to the audit log.
- Posts a confirmation message to a Slack channel.

No one has to update anything by hand, the creator's status in the database stays in sync with DocuSeal, and every change has an audit record.

![contract-signed-workflow-screenshot](/docs/workflow-screenshots/contract-signed-webhook.png)
---

## How It Works

1. **DocuSeal sends an event.** When a signer completes a form, DocuSeal sends a `form.completed` event to the workflow's webhook.
2. **Completion check.** The workflow continues only when the payload's `status` is exactly `completed`.
3. **Contract update.** The `contracts` row whose `envelope_id` matches the DocuSeal `submission_id` changes to `signed`, but only if its current status is `sent`.
4. **Duplicate check.** If no row was updated (for example, the contract was already signed or doesn't exist), the run stops here. This keeps repeated or replayed webhook events from causing side effects.
5. **Creator update.** The creator linked to the contract's `channel_id` changes to `contracted`.
6. **Audit entry.** A `contract_signed` event is written to `audit_log`, with the channel ID and envelope ID as JSON details.
7. **Slack message.** A message goes to the team channel, e.g. *"Contract signed by MyChannelName"*.

---

## Workflow Diagram

```
┌──────────────────┐   ┌────────────────────┐   ┌──────────────────────┐
│ DocuSeal Trigger │──▶│ Is document        │──▶│ Mark contract signed │
│ (form.completed) │   │ completed (filter) │   │ (Postgres UPDATE)    │
└──────────────────┘   └────────────────────┘   └──────────┬───────────┘
                                                           │
                                                           ▼
┌──────────────────────┐   ┌────────────────────────┐   ┌──────────────────┐
│ Audit contract       │◀──│ Mark creator contracted│◀──│ Was newly signed │
│ signed (INSERT)      │   │ (Postgres UPDATE)      │   │ (filter)         │
└──────────┬───────────┘   └────────────────────────┘   └──────────────────┘
           │
           ▼
┌──────────────────────────────┐
│ Notify Slack: contract signed│
└──────────────────────────────┘
```

---

## Node Reference

| # | Node | Type | Purpose |
|---|------|------|---------|
| 1 | **DocuSeal Trigger** | `@docuseal/n8n-nodes-docuseal.docusealTrigger` | Receives DocuSeal `form.completed` webhook events. |
| 2 | **Is document completed** | Filter | Passes only items where `status == "completed"` (case-sensitive, strict type check). |
| 3 | **Mark contract signed** | Postgres (Execute Query) | `UPDATE contracts SET status='signed', signed_at=now() WHERE envelope_id=$1 AND status='sent' RETURNING id, channel_id;` where `$1` is the DocuSeal `submission_id`. |
| 4 | **Was newly signed** | Filter | Continues only if the previous update returned a row with a `channel_id`. |
| 5 | **Mark creator contracted** | Postgres (Execute Query) | `UPDATE creators SET status='contracted' WHERE channel_id=$1 RETURNING channel_id, channel_title;` |
| 6 | **Audit contract signed** | Postgres (Execute Query) | `INSERT INTO audit_log (entity_type, entity_id, action, details) VALUES ('contract', $1, 'contract_signed', $2::jsonb);` |
| 7 | **Notify Slack: contract signed** | Slack (OAuth2) | Posts `Contract signed by <channel_title or channel_id>` to the configured channel. |

---

## Prerequisites

- An **n8n** instance (Cloud or self-hosted) with the community node **`@docuseal/n8n-nodes-docuseal`** installed.
- A **DocuSeal** account with API access.
- A **PostgreSQL** database containing the tables described below.
- A **Slack** workspace and an OAuth2 app that can post messages to the target channel.

### Required Credentials

| Credential | Used by |
|------------|---------|
| DocuSeal API | DocuSeal Trigger |
| PostgreSQL | Mark contract signed, Mark creator contracted, Audit contract signed |
| Slack OAuth2 | Notify Slack: contract signed |

---

## Database Schema Requirements

The workflow needs these tables and columns. Here is a minimal reference schema:

```sql
CREATE TABLE creators (
  channel_id     TEXT PRIMARY KEY,
  channel_title  TEXT,
  status         TEXT          -- e.g. 'prospect', 'contacted', 'contracted'
  -- ...other columns
);

CREATE TABLE contracts (
  id           SERIAL PRIMARY KEY,
  channel_id   TEXT REFERENCES creators(channel_id),
  envelope_id  TEXT UNIQUE,    -- DocuSeal submission ID
  status       TEXT,           -- 'sent' | 'signed' | ...
  signed_at    TIMESTAMPTZ
  -- ...other columns
);

CREATE TABLE audit_log (
  id           SERIAL PRIMARY KEY,
  entity_type  TEXT NOT NULL,
  entity_id    TEXT NOT NULL,
  action       TEXT NOT NULL,
  details      JSONB,
  created_at   TIMESTAMPTZ DEFAULT now()
);
```

> **Important:** `contracts.envelope_id` must hold the DocuSeal **submission ID** that was saved when the contract was sent. Otherwise, completed signatures won't match any contract.

---

## Setup & Configuration

1. **Import or open** the workflow in n8n.
2. **Assign credentials** to the DocuSeal, Postgres, and Slack nodes.
3. **Slack channel:** in *Notify Slack: contract signed*, choose the channel that should get notifications. The current channel is `all-salma-bensaida39s-workspace`.
4. **Publish** the workflow. When it's published, the DocuSeal Trigger registers its webhook with DocuSeal automatically.
5. **Check the upstream process:** make sure the workflow that sends contracts saves the DocuSeal submission ID in `contracts.envelope_id` with `status = 'sent'`.

---

## Idempotency & Data Integrity

The workflow is built to be safe when the same event arrives more than once:

- **Conditional update:** the contract changes only if its status is `sent`. A second delivery of the same event updates zero rows.
- **Short-circuit filter:** *Was newly signed* stops the run when no row came back. Duplicate events can't re-mark the creator, write a second audit entry, or send a second Slack message.
- **Parameterized queries:** every SQL statement takes its values as query parameters (`$1`, `$2`), not string concatenation. This prevents SQL injection.

---

## Testing

1. In the database, create a test creator and a contract with `status = 'sent'` and a known `envelope_id`.
2. Run the workflow manually (or send a DocuSeal test event) with a payload like this:
   ```json
   {
     "status": "completed",
     "submission_id": "<your-test-envelope-id>"
   }
   ```
3. Check that:
   - `contracts.status` is `signed` and `signed_at` is filled in.
   - `creators.status` is `contracted`.
   - `audit_log` has a new `contract_signed` row.
   - The Slack message appeared.
4. Send the same payload again and confirm **nothing else happens** (idempotency check).



