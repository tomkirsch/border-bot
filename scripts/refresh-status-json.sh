#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_JSON="${ROOT_DIR}/status.json"
TMP_JSON="$(mktemp)"
TMP_PROJECT_LINES="$(mktemp)"
TMP_PROJECTS="$(mktemp)"
trap 'rm -f "${TMP_JSON}" "${TMP_PROJECT_LINES}" "${TMP_PROJECTS}"' EXIT

openclaw status --json > "${TMP_JSON}"

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

    local pending_tmp
    local completed_tmp
    local issues_tmp
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

      grep -Ei 'missing|blocked|constraint|risk|warning|issue|failed|error' "${workspace}/PROJECT_PLAN.md" \
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
Per-agent project section added to top of page
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

    # sanitize + de-dup + cap per section
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

build_project_statuses

jq --argjson projectItems "$(cat "${TMP_PROJECTS}")" '
  def human_age($ms):
    if ($ms == null) then "unknown"
    elif $ms < 60000 then "just now"
    elif $ms < 3600000 then ((($ms / 60000) | floor | tostring) + "m ago")
    elif $ms < 86400000 then ((($ms / 3600000) | floor | tostring) + "h ago")
    else ((($ms / 86400000) | floor | tostring) + "d ago")
    end;

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
      projects: {
        items: $projectItems
      },
      system: {
        openclawVersion: ($root.gateway.self.version // "unknown"),
        runtimePlatform: (($root.gateway.self.platform // "unknown") | split(" ")[0]),
        gateway: {
          mode: ($root.gateway.mode // "unknown"),
          reachable: ($root.gateway.reachable // false),
          latencyMs: ($root.gateway.connectLatencyMs // null),
          serviceState: (
            ($root.gatewayService.runtimeShort // "") as $s
            | if ($s | test("running"; "i")) then "running"
              elif ($s | test("stopped|inactive"; "i")) then "stopped"
              else "unknown"
              end
          )
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
