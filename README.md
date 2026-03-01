# border-bot telegram app

Compact dark-mode status panel for Telegram Web App.

## Design intent

- Phone-first, compact, high-contrast dark theme.
- No in-page refresh button.
- Snapshot updates are manual (triggered by ButlerBot request), then published.
- **Linux host status is primary** (uptime/load/disk/memory/failed units/reboot + latest host report + health-watch cron status).
- Top project section shows verbose project-management status for every agent (including main): summary, pending, recently completed, issues/watch.

## Manual refresh & publish flow

1. Regenerate redacted snapshot:

```bash
cd /home/borderland/.openclaw/workspace/telegram-app
./scripts/refresh-status-json.sh
```

2. Commit + push to publish:

```bash
git add index.html status.json scripts/refresh-status-json.sh README.md
git commit -m "Refresh Telegram status panel"
git push origin main
```

No auto updates by design.
