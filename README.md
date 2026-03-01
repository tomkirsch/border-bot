# border-bot telegram app

Compact dark-mode status panel for Telegram Web App.

## Manual refresh flow

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

No auto updates by design. Snapshot changes only when manually requested.
