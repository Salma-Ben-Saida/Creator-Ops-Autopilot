# Onboarding Workflow

Sends a personalized welcome message and AI-generated voice note to creators
accepted into the ElevenLabs creator program, then records the result in Postgres.

Part of the **Creator Ops Autopilot** project. It runs after the
**Creator discovery** workflow, which adds creators to the `creators` table.

---

## Overview

| Item           | Value                                              |
|----------------|----------------------------------------------------|
| Trigger        | Manual ("Execute workflow")                        |
| Batch size     | Up to 5 creators per run                           |
| Data store     | Postgres (`creators`, `audit_log`)                 |
| AI text        | OpenAI GPT-4.1                                     |
| Voice          | ElevenLabs Text-to-Speech (`eleven_multilingual_v2`) |
| Delivery       | Gmail                                              |
| Status         | Not published                                      |

---

## Flow

1. **Claim accepted creators** (Postgres)
   Takes up to 5 creators with `status = 'accepted'`, oldest `first_seen_at` first,
   and sets their status to `onboarding`. It uses `FOR UPDATE SKIP LOCKED`, so
   runs that happen at the same time never claim the same creator.
   Returns: `channel_id`, `channel_title`, `matched_keyword`, `contact_email`.

2. **Message a model** (OpenAI GPT-4.1)
   Writes a warm welcome message of 35 words or fewer, meant to be spoken aloud.
   It uses the creator's channel name and content topic. Plain text only, with
   no emojis or hashtags.

3. **Voice note** (HTTP Request → ElevenLabs TTS)
   Turns the message into an audio file using voice ID `PStJ2DzQnh8zxG5PDf1s`.
   - Success → Send onboarding message
   - Error → Failed onboarding status

4. **Send onboarding message** (Gmail)
   Emails the welcome text with the voice note attached.
   - Success → Mark onboarded
   - Error → Failed onboarding status

5. **Mark onboarded** (Postgres)
   Sets `status = 'onboarded'` and `onboarded_at = now()`, and clears
   `onboarding_error`.

6. **Audit Log** (Postgres)
   Adds a row to `audit_log` with `action = 'onboarded'` and the creator's
   email stored in `details` (JSONB).

7. **Failed onboarding status** (Postgres)
   If the voice note or email step fails, sets `status = 'onboarding_failed'`
   and saves the error message in `onboarding_error`.

Manual Trigger
→ Claim accepted creators
→ Message a model
→ Voice note ──(error)──────────────┐
→ Send onboarding message ─(error)──┤
→ Mark onboarded ↓
→ Audit Log Failed onboarding status


---

## Creator status lifecycle

accepted → onboarding → onboarded
↘ onboarding_failed


---

## Prerequisites

### Database

**`creators`** table needs at least these columns:

| Column             | Purpose                              |
|--------------------|--------------------------------------|
| `channel_id`       | Unique creator / YouTube channel ID  |
| `channel_title`    | Channel display name                 |
| `matched_keyword`  | Topic the creator was discovered for |
| `contact_email`    | Creator's contact email              |
| `status`           | Lifecycle status (see above)         |
| `first_seen_at`    | Used to order the queue              |
| `onboarded_at`     | Set on success                       |
| `onboarding_error` | Set on failure                       |

**`audit_log`** table needs: `entity_type`, `entity_id`, `action`, `details` (JSONB).

### Credentials

- **Postgres**: used by all database nodes
- **OpenAI API**: used by "Message a model"
- **ElevenLabs**: used by "Voice note" (`elevenLabsMcpOAuth2Api`)
- **Gmail OAuth2**: used by "Send onboarding message"

---

## How to run

1. Make sure the creators you want to onboard have `status = 'accepted'`.
2. Open the workflow and click **Execute workflow**.
3. Each run handles up to 5 creators. Run it again to work through the rest
   of the queue.
4. Check the results in `creators.status` and `audit_log`.

To retry failed creators:

```sql
UPDATE creators SET status = 'accepted' WHERE status = 'onboarding_failed';
Customization
Batch size: change LIMIT 5 in "Claim accepted creators".
Voice: change the voice ID in the "Voice note" URL.
Message tone/length: edit the prompt in "Message a model".
Schedule: replace the Manual Trigger with a Schedule Trigger to run it
automatically.
Known limitations
Fixed recipient: emails currently go to salmasaida003@gmail.com
(test mode), not to each creator's contact_email. Change the Gmail
To field to {{ $('Claim accepted creators').item.json.contact_email }}
to send to real creators.

