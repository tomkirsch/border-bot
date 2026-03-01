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
  text="$(echo "${text}" | sed -E 's#/home/[A-Za-z0-9._/-]+#<path-redacted>#g')"
  text="$(echo "${text}" | sed -E 's/[[:space:]]+/ /g; s/^ +| +$//g')"
  echo "${text}"
}

build_project_statuses() {
  : > "${TMP_PROJECT_LINES}"

  while IFS=$'\t' read -r agent_id workspace; do
    [ -n "${agent_id}" ] || continue

    local project=""
    local status=""

    if [ -f "${workspace}/PROJECT_PLAN.md" ]; then
      local heading
      heading="$(grep -m1 '^# ' "${workspace}/PROJECT_PLAN.md" || true)"
      project="$(echo "${heading}" | sed -E 's/^#\s*PROJECT_PLAN\.md\s*[—-]\s*//; s/^#\s*//')"
      [ -n "${project}" ] || project="$(basename "${workspace}")"

      local line
      line="$(grep -m1 '^- \[~\]' "${workspace}/PROJECT_PLAN.md" || true)"
      if [ -z "${line}" ]; then
        line="$(grep -m1 '^- \[ \]' "${workspace}/PROJECT_PLAN.md" || true)"
      fi
      if [ -z "${line}" ]; then
        line="$(grep -m1 '^- \[x\]' "${workspace}/PROJECT_PLAN.md" || true)"
      fi
      status="$(echo "${line}" | sed -E 's/^- \[[x~ ]\]\s*//')"
      [ -n "${status}" ] || status="Project plan present"
    else
      case "${agent_id}" in
        main)
          project="OpenClaw Operations"
          status="Running control panel + manual Git page snapshot updates"
          ;;
        socialbot)
          project="Social Automation"
          status="Monitoring social workflow; no single PROJECT_PLAN.md in workspace"
          ;;
        tkirschbot)
          project="CI4 Development Orchestrator"
          status="Template/orchestration agent baseline active"
          ;;
        *)
          project="$(echo "${agent_id}" | tr '[:lower:]' '[:upper:]')"
          status="No PROJECT_PLAN.md found; status inferred from workspace baseline"
          ;;
      esac
    fi

    project="$(sanitize_text "${project}")"
    status="$(sanitize_text "${status}")"

    jq -nc \
      --arg id "${agent_id}" \
      --arg project "${project}" \
      --arg status "${status}" \
      '{id:$id, project:$project, status:$status}' >> "${TMP_PROJECT_LINES}"
  done < <(jq -r '.agents.agents[] | [.id, .workspaceDir] | @tsv' "${TMP_JSON}")

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
