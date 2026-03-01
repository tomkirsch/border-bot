#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_JSON="${ROOT_DIR}/status.json"
TMP_JSON="$(mktemp)"
TMP_CRON="$(mktemp)"
TMP_PROJECT_LINES="$(mktemp)"
TMP_PROJECTS="$(mktemp)"
TMP_FINDINGS="$(mktemp)"
TMP_AUDIT_CRON="$(mktemp)"
trap 'rm -f "${TMP_JSON}" "${TMP_CRON}" "${TMP_PROJECT_LINES}" "${TMP_PROJECTS}" "${TMP_FINDINGS}" "${TMP_AUDIT_CRON}"' EXIT

openclaw status --json > "${TMP_JSON}"
openclaw cron list --all --json > "${TMP_CRON}" 2>/dev/null || echo '{"jobs":[]}' > "${TMP_CRON}"

sanitize_text() {
  local text="$1"
  text="$(echo "${text}" | sed -E 's#`##g')"
  text="$(echo "${text}" | sed -E 's#/home/[A-Za-z0-9._/-]+#<path-redacted>#g')"
  text="$(echo "${text}" | sed -E 's#([0-9]{1,3}\.){3}[0-9]{1,3}#<ip-redacted>#g')"
  text="$(echo "${text}" | sed -E 's#agent:[^ ]+#<session-redacted>#g')"
  text="$(echo "${text}" | sed -E 's/[[:space:]]+/ /g; s/^ +| +$//g')"
  echo "${text}"
}

lines_to_json_array() {
  local file="$1"
  if [ ! -s "${file}" ]; then
    echo '[]'
  else
    jq -Rsc 'split("\n") | map(select(length>0))' < "${file}"
  fi
}

build_project_statuses() {
  : > "${TMP_PROJECT_LINES}"

  while IFS=$'\t' read -r agent_id workspace age_ms; do
    [ -n "${agent_id}" ] || continue

    local project=""
    local summary=""

    local pending_tmp completed_tmp issues_tmp
    pending_tmp="$(mktemp)"
    completed_tmp="$(mktemp)"
    issues_tmp="$(mktemp)"

    if [ -f "${workspace}/PROJECT_PLAN.md" ]; then
      local heading
      heading="$(grep -m1 '^# ' "${workspace}/PROJECT_PLAN.md" || true)"
      project="$(echo "${heading}" | sed -E 's/^#\s*PROJECT_PLAN\.md\s*[—-]\s*//; s/^#\s*//')"
      [ -n "${project}" ] || project="$(basename "${workspace}")"

      grep -E '^- \[( |~)\]' "${workspace}/PROJECT_PLAN.md" \
        | sed -E 's/^- \[[ ~]\]\s*//' \
        | awk 'NF && !seen[$0]++' \
        | head -n 3 > "${pending_tmp}" || true

      grep -E '^- \[x\]|^- ✅|^- [0-9]{4}-[0-9]{2}-[0-9]{2}:' "${workspace}/PROJECT_PLAN.md" \
        | sed -E 's/^- \[x\]\s*//; s/^- ✅\s*//' \
        | awk 'NF && !seen[$0]++' \
        | head -n 3 > "${completed_tmp}" || true

      grep -Ei 'missing|blocked|constraint|risk|warning|issue|failed|error|pending' "${workspace}/PROJECT_PLAN.md" \
        | sed -E 's/^#+\s*//' \
        | awk 'NF && !seen[$0]++' \
        | head -n 3 > "${issues_tmp}" || true

      summary="$(head -n 1 "${pending_tmp}" || true)"
      [ -n "${summary}" ] || summary="$(head -n 1 "${completed_tmp}" || true)"
      [ -n "${summary}" ] || summary="Project plan present"
    else
      case "${agent_id}" in
        main)
          project="OpenClaw Operations"
          summary="Operating command/control and manual status publishing"
          cat > "${pending_tmp}" <<'EOF'
Publish fresh Git page snapshot when requested
Keep agent control panel concise and redacted
Watch service-config health warning
EOF
          cat > "${completed_tmp}" <<'EOF'
Control panel moved to compact dark mobile layout
Manual-update-only snapshot pipeline implemented
Per-agent project cards added to top of page
EOF
          cat > "${issues_tmp}" <<'EOF'
Gateway service currently tied to NVM Node path (upgrade fragility)
EOF
          ;;
        socialbot)
          project="Social Automation"
          summary="Social workflow monitoring and content planning support"
          cat > "${pending_tmp}" <<'EOF'
Track campaign briefs and posting windows
Maintain project/task notes in workspace
Surface approvals needed before posting
EOF
          cat > "${completed_tmp}" <<'EOF'
Agent delegation directive added for heavy tasks
Socialbot workspace remains active and routable
EOF
          cat > "${issues_tmp}" <<'EOF'
No consolidated PROJECT_PLAN.md in workspace (status inferred)
EOF
          ;;
        tkirschbot)
          project="CI4 Development Orchestrator"
          summary="Template/orchestration baseline active"
          cat > "${pending_tmp}" <<'EOF'
Define active target app milestone for next build cycle
Capture concrete task list in PROJECT_PLAN.md for richer tracking
EOF
          cat > "${completed_tmp}" <<'EOF'
CI4 orchestrator baseline and workflow docs are present
EOF
          cat > "${issues_tmp}" <<'EOF'
Status inferred from README because PROJECT_PLAN.md missing at workspace root
EOF
          ;;
        *)
          project="$(echo "${agent_id}" | tr '[:lower:]' '[:upper:]')"
          summary="Baseline workspace detected"
          cat > "${pending_tmp}" <<'EOF'
Establish explicit PROJECT_PLAN.md for this agent
EOF
          : > "${completed_tmp}"
          cat > "${issues_tmp}" <<'EOF'
No PROJECT_PLAN.md found; project status is inferred
EOF
          ;;
      esac
    fi

    if [[ "${age_ms}" =~ ^[0-9]+$ ]] && [ "${age_ms}" -gt 604800000 ]; then
      local stale_days=$(( age_ms / 86400000 ))
      echo "No recent agent activity (${stale_days}d)." >> "${issues_tmp}"
    fi

    awk 'NF && !seen[$0]++' "${pending_tmp}" | head -n 3 | while IFS= read -r line; do sanitize_text "${line}"; done > "${pending_tmp}.clean"
    awk 'NF && !seen[$0]++' "${completed_tmp}" | head -n 3 | while IFS= read -r line; do sanitize_text "${line}"; done > "${completed_tmp}.clean"
    awk 'NF && !seen[$0]++' "${issues_tmp}" | head -n 3 | while IFS= read -r line; do sanitize_text "${line}"; done > "${issues_tmp}.clean"

    local pending_json completed_json issues_json
    pending_json="$(lines_to_json_array "${pending_tmp}.clean")"
    completed_json="$(lines_to_json_array "${completed_tmp}.clean")"
    issues_json="$(lines_to_json_array "${issues_tmp}.clean")"

    project="$(sanitize_text "${project}")"
    summary="$(sanitize_text "${summary}")"

    jq -nc \
      --arg id "${agent_id}" \
      --arg project "${project}" \
      --arg summary "${summary}" \
      --argjson pending "${pending_json}" \
      --argjson completed "${completed_json}" \
      --argjson issues "${issues_json}" \
      '{id:$id, project:$project, summary:$summary, pending:$pending, completed:$completed, issues:$issues}' >> "${TMP_PROJECT_LINES}"

    rm -f "${pending_tmp}" "${completed_tmp}" "${issues_tmp}" "${pending_tmp}.clean" "${completed_tmp}.clean" "${issues_tmp}.clean"
  done < <(jq -r '.agents.agents[] | [.id, .workspaceDir, (.lastActiveAgeMs|tostring)] | @tsv' "${TMP_JSON}")

  jq -s 'sort_by(.id)' "${TMP_PROJECT_LINES}" > "${TMP_PROJECTS}"
}

build_linux_report() {
  local report_status="OK"
  local has_watch=0
  local has_alert=0

  UPTIME_PRETTY="$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo 'unknown')"
  LOAD_AVG="$(uptime 2>/dev/null | sed -n 's/.*load average[s]*: //p' | xargs || true)"
  [ -n "${LOAD_AVG}" ] || LOAD_AVG="unknown"

  local df_line
  df_line="$(df -P / | awk 'NR==2{print $5}' 2>/dev/null || true)"
  ROOT_USE_PCT="$(echo "${df_line}" | sed -E 's/%//g' || true)"
  ROOT_FREE="$(df -h / | awk 'NR==2{print $4}' 2>/dev/null || true)"
  [ -n "${ROOT_USE_PCT}" ] || ROOT_USE_PCT="0"
  [ -n "${ROOT_FREE}" ] || ROOT_FREE="unknown"

  MEM_USED="$(free -h | awk '/^Mem:/{print $3}' 2>/dev/null || true)"
  MEM_AVAIL="$(free -h | awk '/^Mem:/{print $7}' 2>/dev/null || true)"
  [ -n "${MEM_USED}" ] || MEM_USED="unknown"
  [ -n "${MEM_AVAIL}" ] || MEM_AVAIL="unknown"

  FAILED_UNITS_COUNT="$(systemctl --failed --no-pager --plain --no-legend 2>/dev/null | awk 'NF{c++} END{print c+0}')"
  FAILED_UNITS_COUNT="${FAILED_UNITS_COUNT:-0}"

  if [ -f /var/run/reboot-required ]; then
    REBOOT_REQUIRED=true
  else
    REBOOT_REQUIRED=false
  fi

  local journal_sample
  journal_sample="$(journalctl -p 3 -n 80 --no-pager 2>/dev/null || true)"
  JOURNAL_ERR_COUNT="$(echo "${journal_sample}" | sed '/^-- /d;/^$/d' | wc -l | tr -d ' ')"
  JOURNAL_ERR_COUNT="${JOURNAL_ERR_COUNT:-0}"
  CIFS_ERR_COUNT="$(echo "${journal_sample}" | grep -ci 'CIFS' || true)"
  CIFS_ERR_COUNT="${CIFS_ERR_COUNT:-0}"

  local gateway_status
  gateway_status="$(openclaw gateway status 2>/dev/null || true)"
  local svc_issues
  svc_issues="$(echo "${gateway_status}" | grep -i 'Service config issue' | head -n 3 || true)"

  : > "${TMP_FINDINGS}"

  if [[ "${ROOT_USE_PCT}" =~ ^[0-9]+$ ]]; then
    if [ "${ROOT_USE_PCT}" -ge 90 ]; then
      echo "Root disk usage high: ${ROOT_USE_PCT}% used." >> "${TMP_FINDINGS}"
      has_alert=1
    elif [ "${ROOT_USE_PCT}" -ge 80 ]; then
      echo "Root disk usage elevated: ${ROOT_USE_PCT}% used." >> "${TMP_FINDINGS}"
      has_watch=1
    fi
  fi

  if [[ "${FAILED_UNITS_COUNT}" =~ ^[0-9]+$ ]] && [ "${FAILED_UNITS_COUNT}" -gt 0 ]; then
    echo "Systemd failed units detected: ${FAILED_UNITS_COUNT}." >> "${TMP_FINDINGS}"
    has_watch=1
  fi

  if [ "${REBOOT_REQUIRED}" = true ]; then
    echo "System reboot required flag is present." >> "${TMP_FINDINGS}"
    has_watch=1
  fi

  if [[ "${JOURNAL_ERR_COUNT}" =~ ^[0-9]+$ ]] && [ "${JOURNAL_ERR_COUNT}" -gt 0 ]; then
    local journal_note="Recent journal errors (priority<=3): ${JOURNAL_ERR_COUNT}."
    if [[ "${CIFS_ERR_COUNT}" =~ ^[0-9]+$ ]] && [ "${CIFS_ERR_COUNT}" -gt 0 ]; then
      journal_note+=" CIFS-related entries: ${CIFS_ERR_COUNT}."
    fi
    echo "${journal_note}" >> "${TMP_FINDINGS}"
    has_watch=1
  fi

  if [ -n "${svc_issues}" ]; then
    while IFS= read -r line; do
      [ -n "${line}" ] || continue
      echo "$(sanitize_text "${line}")" >> "${TMP_FINDINGS}"
    done <<< "${svc_issues}"
    has_watch=1
  fi

  if [ ! -s "${TMP_FINDINGS}" ]; then
    echo "No major Linux host issues detected in bounded checks." >> "${TMP_FINDINGS}"
  fi

  if [ "${has_alert}" -eq 1 ]; then
    report_status="ALERT"
  elif [ "${has_watch}" -eq 1 ]; then
    report_status="WATCH"
  fi

  REPORT_STATUS="${report_status}"
  REPORT_FINDINGS_JSON="$(lines_to_json_array "${TMP_FINDINGS}")"
}

build_project_statuses
build_linux_report

jq '
  (.jobs[]? | select(.name == "Daily OpenClaw log + agent health watch")) as $job
  | if $job then
      {
        configured: true,
        enabled: ($job.enabled // false),
        name: ($job.name // "Daily OpenClaw log + agent health watch"),
        scheduleExpr: ($job.schedule.expr // null),
        scheduleTz: ($job.schedule.tz // null),
        lastStatus: ($job.state.lastStatus // "unknown"),
        lastRunAtMs: ($job.state.lastRunAtMs // null),
        nextRunAtMs: ($job.state.nextRunAtMs // null),
        lastError: ($job.state.lastError // null)
      }
    else
      {
        configured: false,
        enabled: false,
        name: "Daily OpenClaw log + agent health watch",
        scheduleExpr: null,
        scheduleTz: null,
        lastStatus: "missing",
        lastRunAtMs: null,
        nextRunAtMs: null,
        lastError: null
      }
    end
' "${TMP_CRON}" > "${TMP_AUDIT_CRON}"

PROJECT_ITEMS_JSON="$(cat "${TMP_PROJECTS}" 2>/dev/null || true)"
[ -n "${PROJECT_ITEMS_JSON}" ] || PROJECT_ITEMS_JSON='[]'
AUDIT_CRON_JSON="$(cat "${TMP_AUDIT_CRON}" 2>/dev/null || true)"
[ -n "${AUDIT_CRON_JSON}" ] || AUDIT_CRON_JSON='{"configured":false,"enabled":false,"name":"Daily OpenClaw log + agent health watch","scheduleExpr":null,"scheduleTz":null,"lastStatus":"missing","lastRunAtMs":null,"nextRunAtMs":null,"lastError":null}'

jq \
  --argjson projectItems "${PROJECT_ITEMS_JSON}" \
  --arg uptimePretty "$(sanitize_text "${UPTIME_PRETTY}")" \
  --arg loadAvg "$(sanitize_text "${LOAD_AVG}")" \
  --arg rootFree "$(sanitize_text "${ROOT_FREE}")" \
  --arg memUsed "$(sanitize_text "${MEM_USED}")" \
  --arg memAvail "$(sanitize_text "${MEM_AVAIL}")" \
  --argjson rootUsePct "${ROOT_USE_PCT}" \
  --argjson failedUnits "${FAILED_UNITS_COUNT}" \
  --argjson rebootRequired "${REBOOT_REQUIRED}" \
  --argjson journalErrors "${JOURNAL_ERR_COUNT}" \
  --argjson cifsErrors "${CIFS_ERR_COUNT}" \
  --arg reportStatus "${REPORT_STATUS}" \
  --argjson reportFindings "${REPORT_FINDINGS_JSON}" \
  --argjson auditCron "${AUDIT_CRON_JSON}" '
  def human_age($ms):
    if ($ms == null) then "unknown"
    elif $ms < 60000 then "just now"
    elif $ms < 3600000 then ((($ms / 60000) | floor | tostring) + "m ago")
    elif $ms < 86400000 then ((($ms / 3600000) | floor | tostring) + "h ago")
    else ((($ms / 86400000) | floor | tostring) + "d ago")
    end;

  def ms_to_iso($ms):
    if $ms == null then null else (($ms / 1000) | todateiso8601) end;

  def main_session:
    (.sessions.recent | map(select(.agentId == "main" and (.key | startswith("agent:main:telegram:direct:"))))[0])
    // (.sessions.recent | map(select(.agentId == "main"))[0])
    // {};

  . as $root
  | (main_session) as $main
  | {
      schema: "border-bot-status-v1",
      generatedAt: (now | todateiso8601),
      updateMode: "manual-request-only",
      redaction: {
        note: "Sensitive fields removed before publish.",
        removed: [
          "bot tokens",
          "chat/user ids",
          "session ids",
          "filesystem paths",
          "private IP addresses",
          "auth secrets"
        ]
      },
      assistant: {
        name: "ButlerBot",
        model: ($main.model // $root.sessions.defaults.model // "unknown"),
        think: ($main.thinkingLevel // "unknown"),
        context: {
          usedTokens: ($main.totalTokens // null),
          limitTokens: ($main.contextTokens // $root.sessions.defaults.contextTokens // null),
          percentUsed: ($main.percentUsed // null)
        }
      },
      linux: {
        uptime: $uptimePretty,
        loadAverage: $loadAvg,
        rootDisk: {
          usedPercent: $rootUsePct,
          free: $rootFree
        },
        memory: {
          used: $memUsed,
          available: $memAvail
        },
        failedUnits: $failedUnits,
        rebootRequired: $rebootRequired,
        recentJournalErrors: $journalErrors,
        recentCifsErrors: $cifsErrors
      },
      latestReport: {
        scope: "linux-host-first",
        generatedAt: (now | todateiso8601),
        status: $reportStatus,
        findings: $reportFindings
      },
      auditCron: {
        configured: ($auditCron.configured // false),
        enabled: ($auditCron.enabled // false),
        name: ($auditCron.name // "Daily OpenClaw log + agent health watch"),
        scheduleExpr: ($auditCron.scheduleExpr // null),
        scheduleTz: ($auditCron.scheduleTz // null),
        lastStatus: ($auditCron.lastStatus // "unknown"),
        lastRunAt: ms_to_iso($auditCron.lastRunAtMs),
        nextRunAt: ms_to_iso($auditCron.nextRunAtMs),
        lastError: ($auditCron.lastError // null)
      },
      projects: {
        items: $projectItems
      },
      system: {
        openclawVersion: ($root.gateway.self.version // "unknown"),
        gateway: {
          mode: ($root.gateway.mode // "unknown"),
          reachable: ($root.gateway.reachable // false),
          latencyMs: ($root.gateway.connectLatencyMs // null)
        },
        security: {
          critical: ($root.securityAudit.summary.critical // null),
          warn: ($root.securityAudit.summary.warn // null),
          info: ($root.securityAudit.summary.info // null)
        }
      },
      agents: {
        total: ($root.agents.agents | length),
        totalSessions: ($root.agents.totalSessions // 0),
        items: (
          $root.agents.agents
          | map({
              id,
              sessions: (.sessionsCount // 0),
              lastActive: human_age(.lastActiveAgeMs)
            })
          | sort_by(.id)
        )
      }
    }
' "${TMP_JSON}" > "${OUT_JSON}"

echo "Status snapshot written: ${OUT_JSON}"
