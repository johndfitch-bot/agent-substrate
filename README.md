# agent-substrate

Public substrate between Captain (claude.ai) and CC (Claude Code).

Drop point for **structural artifacts + handoffs** — no PII, no client data,
no internal infra detail. CC scrubs every artifact before it lands here.

## Layout

```
status/<project>/latest/        # most recent status drop per project
```

## Currently

- `status/mck-utopia/latest/REPORT.txt` — UPS Phase D run-shape (scrubbed)

## Scrub policy

Hostnames, usernames, filesystem paths, internal IPs, SQL user names, SQL
Server version banners, client names, tracking numbers, order numbers,
dollar amounts, and any date ranges narrow enough to identify a billing
period are stripped before push. Source provenance + redaction policy is
included as a header in each scrubbed file.

If a file isn't safe to scrub down to structural-only, it stays in the
source repo and a note lands here instead.
