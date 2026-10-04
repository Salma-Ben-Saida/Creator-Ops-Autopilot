# Creator Discovery Autopilot (YouTube → Postgres → Slack)

An n8n workflow that searches YouTube for creators in certain niches, keeps the channels that pass size and activity checks, scores them, and saves them to Postgres. It writes an audit log entry for each new creator and posts a summary to Slack.

---

## What it does

1. **Starts** on a schedule, or by hand from the editor.
2. **Searches YouTube** for channels that match a list of keywords (up to 50 per keyword, English).
3. **Gets channel details** (snippet and statistics) for every channel found.
4. **Keeps only channels that:**
   - show their subscriber count
   - have between **5,000 and 1,000,000** subscribers
   - have at least **20 videos**
5. **Scores each channel** from 0 to 100.
6. **Saves each channel to Postgres** (adds new channels, updates existing ones).
7. **Adds an audit log row** for each newly found creator.
8. **Posts a summary to Slack**: how many are new, how many were updated, and the total.

---

## Flow overview

Schedule Trigger ─┐
├─► Keywords ─► YouTube Search ─► Prep IDs ─► YouTube Channels
Manual Trigger ───┘ │
▼
Split Out ─► Filter ─► Score ─► Upsert Creator
│
┌─────────────────┴────────────┐
▼ ▼
If (inserted?) Summary
│ true │
▼ ▼
Audit Log Slack message


---

## Nodes

| Node | Type | Purpose |
|---|---|---|
| Schedule Trigger | Schedule | Runs on the default interval (once a day) |
| When clicking 'Execute workflow' | Manual | Lets you test by hand |
| Keywords | Code | Lists the search keywords: `AI voiceover`, `video editing tutorial`, `podcast tips` |
| HTTP Request | HTTP | `GET youtube/v3/search`: searches channels for each keyword (`type=channel`, `maxResults=50`, `relevanceLanguage=en`) |
| Prep IDs | Code | Removes duplicate channel IDs from the search results and joins them into one comma-separated list for each keyword |
| HTTP Request1 | HTTP | `GET youtube/v3/channels`: gets the snippet and statistics for those IDs |
| Split Out | Split Out | Turns the `items` array into one item per channel |
| Filter | Filter | Applies the subscriber visibility, subscriber range and video count rules above |
| Score | Code | Works out the score and builds the creator record |
| Upsert Creator | Postgres | `INSERT ... ON CONFLICT (channel_id) DO UPDATE`, returning `inserted` (`xmax = 0`) |
| If | If | Lets through only rows where `inserted = true` |
| Audit Log | Postgres | Adds a `discovered` event to `audit_log` |
| Summary | Code | Counts new and updated creators |
| Send a message | Slack | Posts the summary to the Slack channel `#all-salma-bensaida39s-workspace` |

---

## Scoring

score = viewRatio * 50 + keywordFit * 30 + sizeFit * 20


| Part | How it's calculated | Weight |
|---|---|---|
| **viewRatio** | Average views per video ÷ subscribers, capped at 1. Stands in for engagement. | 50 |
| **keywordFit** | Share of the keyword's words (longer than 2 characters) that appear in the channel title or description | 30 |
| **sizeFit** | `1` if subscribers are between 25k and 250k, otherwise `0.5` | 20 |

The score is rounded to 2 decimal places.

---

## Output record

```json
{
  "channel_id": "UC...",
  "channel_title": "...",
  "channel_url": "https://youtube.com/channel/UC...",
  "country": "US",
  "subscribers": 120000,
  "total_views": 8500000,
  "video_count": 240,
  "matched_keyword": "podcast tips",
  "score": 72.5,
  "contact_email": "creator+xxxxxxxx@example.com"
}
Note: contact_email is a made-up placeholder set on purpose. The workflow does not find real contact details.

Requirements
Credentials
Postgres, used by Upsert Creator and Audit Log
Slack OAuth2, used by Send a message
n8n Variables
youtube_api_key: a YouTube Data API v3 key, read as $vars.youtube_api_key


Notes and limitations
YouTube API quota: each search call costs 100 units, so one run with 3 keywords uses about 300+ units. The default daily quota is 10,000 units.

If the same channel shows up for several keywords in one run, it's saved once for each keyword. On conflict, matched_keyword is not updated, so the first keyword stays.
matched_keyword is saved in lowercase.

On an update, only the title, subscribers, views, video count, score and last_seen_at change.
The workflow has no error handling. A failed API or database call stops the run.
