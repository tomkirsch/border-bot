#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_JSON="${ROOT_DIR}/status.json"
TMP_JSON="$(mktemp)"
trap 'rm -f "${TMP_JSON}"' EXIT

openclaw status --json > "${TMP_JSON}"

jq '
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
