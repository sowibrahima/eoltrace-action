#!/usr/bin/env bash
set -euo pipefail

TMP_BASE="${RUNNER_TEMP:-$(mktemp -d)}"
INPUT_PATH="${INPUT_PATH:-.}"
INPUT_MODE="${INPUT_MODE:-local}"
INPUT_CI_MODE="${INPUT_CI_MODE:-report}"
INPUT_FAIL_ON_PARTIAL="${INPUT_FAIL_ON_PARTIAL:-false}"
INPUT_MANIFEST_PATH="${INPUT_MANIFEST_PATH:-$TMP_BASE/eoltrace-manifest.json}"
INPUT_JSON_PATH="${INPUT_JSON_PATH:-$TMP_BASE/eoltrace-result.json}"
INPUT_SARIF_PATH="${INPUT_SARIF_PATH:-}"
INPUT_CLI_VERSION="${INPUT_CLI_VERSION:-source}"
INPUT_CLI_BINARY="${INPUT_CLI_BINARY:-}"
INPUT_RELEASE_REPO="${INPUT_RELEASE_REPO:-sowibrahima/eoltrace}"
INPUT_THREADS="${INPUT_THREADS:-4}"
INPUT_REPOSITORY="${INPUT_REPOSITORY:-}"
INPUT_SERVER="${INPUT_SERVER:-}"

if [ "$INPUT_MODE" != "local" ] && [ "$INPUT_MODE" != "ci" ]; then
  echo "ERROR: unsupported mode '$INPUT_MODE' (expected 'local' or 'ci')" >&2
  exit 2
fi

if [ "$INPUT_MODE" = "ci" ]; then
  EFFECTIVE_SERVER="${INPUT_SERVER:-${EOLTRACE_SERVER:-}}"
  if [ -z "$EFFECTIVE_SERVER" ]; then
    echo "ERROR: mode 'ci' requires 'server' input or EOLTRACE_SERVER environment variable" >&2
    exit 2
  fi
  export EOLTRACE_SERVER="$EFFECTIVE_SERVER"
fi

resolve_target_triple() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "${os}:${arch}" in
    Linux:x86_64) echo "x86_64-unknown-linux-gnu" ;;
    Linux:aarch64|Linux:arm64) echo "aarch64-unknown-linux-gnu" ;;
    Darwin:x86_64) echo "x86_64-apple-darwin" ;;
    Darwin:arm64|Darwin:aarch64) echo "aarch64-apple-darwin" ;;
    *)
      echo "ERROR: unsupported runner platform ${os}/${arch}" >&2
      exit 2
      ;;
  esac
}

resolve_cli_binary() {
  if [ -n "$INPUT_CLI_BINARY" ]; then
    if [ ! -x "$INPUT_CLI_BINARY" ]; then
      echo "ERROR: cli-binary '$INPUT_CLI_BINARY' is not executable" >&2
      exit 2
    fi
    echo "$INPUT_CLI_BINARY"
    return 0
  fi

  if [ "$INPUT_CLI_VERSION" = "source" ]; then
    local action_root="${ACTION_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
    local built="$action_root/cli/target/release/eoltrace"
    if [ ! -x "$built" ]; then
      (cd "$action_root/cli" && cargo build --release --locked --bin eoltrace >&2)
    fi
    echo "$built"
    return 0
  fi

  local target archive dl_dir base_url
  target="$(resolve_target_triple)"
  archive="eoltrace-${target}.tar.gz"
  dl_dir="$(mktemp -d "${TMP_BASE}/eoltrace-cli.XXXXXX")"
  base_url="https://github.com/${INPUT_RELEASE_REPO}/releases/download/${INPUT_CLI_VERSION}"

  curl -fsSL "${base_url}/SHA256SUMS" -o "${dl_dir}/SHA256SUMS"
  curl -fsSL "${base_url}/${archive}" -o "${dl_dir}/${archive}"

  # Fail closed on checksum verification before unpacking or running anything
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$dl_dir" && grep "  ${archive}$" SHA256SUMS | sha256sum -c - >&2)
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$dl_dir" && grep "  ${archive}$" SHA256SUMS | shasum -a 256 -c - >&2)
  else
    echo "ERROR: neither sha256sum nor shasum available to verify release checksum" >&2
    exit 2
  fi

  tar -C "$dl_dir" -xzf "${dl_dir}/${archive}"
  local bin_path="${dl_dir}/eoltrace-${target}/eoltrace"
  if [ ! -x "$bin_path" ]; then
    echo "ERROR: extracted archive did not contain executable ${bin_path}" >&2
    exit 2
  fi
  echo "$bin_path"
}

CLI_BIN="$(resolve_cli_binary)"
mkdir -p "$(dirname "$INPUT_MANIFEST_PATH")" "$(dirname "$INPUT_JSON_PATH")"

if [ "$INPUT_MODE" = "local" ]; then
  CMD=(
    "$CLI_BIN" --format json --no-progress scan "$INPUT_PATH"
    --manifest "$INPUT_MANIFEST_PATH"
    --out "$INPUT_JSON_PATH"
    --threads "$INPUT_THREADS"
  )
  if [ "$INPUT_FAIL_ON_PARTIAL" = "true" ]; then
    CMD+=(--fail-on-partial)
  fi
  "${CMD[@]}" > "${TMP_BASE}/eoltrace-stdout.json"
else
  CMD=(
    "$CLI_BIN" --format json --no-progress ci "$INPUT_PATH"
    --mode "$INPUT_CI_MODE"
    --manifest "$INPUT_MANIFEST_PATH"
    --json "$INPUT_JSON_PATH"
    --threads "$INPUT_THREADS"
  )
  if [ -n "$INPUT_REPOSITORY" ]; then
    CMD+=(--repository "$INPUT_REPOSITORY")
  fi
  if [ -n "$INPUT_SARIF_PATH" ]; then
    mkdir -p "$(dirname "$INPUT_SARIF_PATH")"
    CMD+=(--sarif "$INPUT_SARIF_PATH")
  fi
  if [ "$INPUT_FAIL_ON_PARTIAL" = "true" ]; then
    CMD+=(--fail-on-partial)
  fi
  "${CMD[@]}" > "${TMP_BASE}/eoltrace-stdout.json"
fi

COVERAGE_STATE="$(jq -r '.scope.coverage_state // "unknown"' "$INPUT_MANIFEST_PATH")"
OBS_COUNT="$(jq -r '(.observations // []) | length' "$INPUT_MANIFEST_PATH")"
DEP_COUNT="$(jq -r '(.inventory.dependencies // []) | length' "$INPUT_MANIFEST_PATH")"
GAP_COUNT="$(jq -r '(.coverage // []) | length' "$INPUT_MANIFEST_PATH")"
SCAN_ID=""
if [ "$INPUT_MODE" = "ci" ] && [ -s "$INPUT_JSON_PATH" ]; then
  SCAN_ID="$(jq -r '.scan_id // ""' "$INPUT_JSON_PATH")"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "manifest-path=$INPUT_MANIFEST_PATH"
    echo "json-path=$INPUT_JSON_PATH"
    echo "sarif-path=$INPUT_SARIF_PATH"
    echo "coverage-state=$COVERAGE_STATE"
    echo "observation-count=$OBS_COUNT"
    echo "dependency-count=$DEP_COUNT"
    echo "scan-id=$SCAN_ID"
  } >> "$GITHUB_OUTPUT"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## EOLTrace scan summary"
    echo ""
    echo "| Field | Value |"
    echo "| --- | --- |"
    echo "| Mode | \`${INPUT_MODE}\` |"
    echo "| Coverage state | \`${COVERAGE_STATE}\` |"
    echo "| Observations | ${OBS_COUNT} |"
    echo "| Inventory dependencies | ${DEP_COUNT} |"
    echo "| Coverage gaps | ${GAP_COUNT} |"
    if [ -n "$SCAN_ID" ]; then
      echo "| Hosted scan ID | \`${SCAN_ID}\` |"
    fi
    echo ""
    echo "_Customer source code stayed inside the GitHub Actions runner; only metadata was emitted to the inspectable manifest._"
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "${INPUT_COMMENT_ON_PR:-false}" = "true" ]; then
  PR_BODY_FILE="${INPUT_PR_COMMENT_OUT:-${TMP_BASE}/eoltrace-pr-comment.md}"
  {
    echo "<!-- eoltrace-pr-comment -->"
    echo "### EOLTrace Scan Summary"
    echo ""
    echo "| Field | Value |"
    echo "| --- | --- |"
    echo "| Mode | \`${INPUT_MODE}\` |"
    echo "| Coverage state | \`${COVERAGE_STATE}\` |"
    echo "| Observations | ${OBS_COUNT} |"
    echo "| Inventory dependencies | ${DEP_COUNT} |"
    echo "| Coverage gaps | ${GAP_COUNT} |"
    if [ -n "$SCAN_ID" ]; then
      echo "| Hosted scan ID | \`${SCAN_ID}\` |"
    fi
    echo ""
    echo "_Source code stayed inside the GitHub Actions runner; only metadata was emitted._"
  } > "$PR_BODY_FILE"

  if [ -z "${INPUT_PR_COMMENT_OUT:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "${GITHUB_EVENT_PATH:-}" ]; then
    PR_NUMBER="$(jq -r '.pull_request.number // ""' "$GITHUB_EVENT_PATH")"
    if [ -n "$PR_NUMBER" ] && command -v gh >/dev/null 2>&1; then
      EXISTING_ID="$(gh api "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" \
        --jq '[.[] | select(.body | contains("<!-- eoltrace-pr-comment -->"))][0].id // ""' 2>/dev/null || true)"
      if [ -n "$EXISTING_ID" ]; then
        gh api --method PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${EXISTING_ID}" \
          -F "body=@${PR_BODY_FILE}" >/dev/null 2>&1 \
          || echo "WARN: could not update PR comment (check pull-requests: write permission)" >&2
      else
        gh api --method POST "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" \
          -F "body=@${PR_BODY_FILE}" >/dev/null 2>&1 \
          || echo "WARN: could not create PR comment (check pull-requests: write permission)" >&2
      fi
    fi
  fi
fi
