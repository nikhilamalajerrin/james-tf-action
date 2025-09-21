#!/usr/bin/env bash
set -euo pipefail

# Enable real Terraform runs by building TF in the Dockerfile and setting USE_TFDIR=1
USE_TFDIR="${USE_TFDIR:-0}"

prefix="${1:-run}"          # "base" or "pr"
tfdir_in="${2:-}"           # host path to the TF dir (e.g. /home/runner/.../base/examples/terraform_0_13)
api_url="${3:-}"            # e.g. http://host.docker.internal:4000

echo "Using prefix=${prefix}"
echo "Using terraform_dir=${tfdir_in}"
echo "Using api_url=${api_url}"

# Price API (initial env)
if [[ -n "${api_url}" ]]; then
  export PLANCOSTS_API_URL="${api_url}"
  echo "Set PLANCOSTS_API_URL=${PLANCOSTS_API_URL}"
fi

# --- Resolve a reachable API base URL from *inside* the container ---
resolve_api_base() {
  local try_urls=()

  # If user provided something, try that first
  if [[ -n "${PLANCOSTS_API_URL:-}" ]]; then
    try_urls+=("${PLANCOSTS_API_URL}")
  fi

  # GH Actions Docker on Linux: common ways to reach the host
  local gw
  gw="$(ip route | awk '/default/ {print $3; exit}')"
  try_urls+=(
    "http://host.docker.internal:4000"
    "http://${gw:-172.17.0.1}:4000"
    "http://172.17.0.1:4000"
    "http://127.0.0.1:4000"
  )

  for u in "${try_urls[@]}"; do
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${u%/}/graphql" || true)"
    if [[ "$code" = "200" ]]; then
      echo "$u"
      return 0
    fi
  done
  echo ""
}

resolved="$(resolve_api_base)"
if [[ -n "$resolved" ]]; then
  export PLANCOSTS_API_URL="$resolved"
  echo "Price API reachable at: ${PLANCOSTS_API_URL}"
else
  echo "WARNING: could not reach any price API endpoint from container; costs may be 0."
fi

# Build CLI flag once (used for both --tfdir and --tfjson calls)
API_ARG=()
if [[ -n "${PLANCOSTS_API_URL:-}" ]]; then
  API_ARG=(--api-url "${PLANCOSTS_API_URL}")
fi

# Normalize terraform_dir host->container path (agnostic to repo name)
tfdir="${tfdir_in}"
if [[ -n "${tfdir}" ]]; then
  case "${tfdir}" in
    */base/*) tfdir="/github/workspace/base/${tfdir##*/base/}" ;;
    */pr/*)   tfdir="/github/workspace/pr/${tfdir##*/pr/}"   ;;
    /github/workspace/*) : ;;
    *) echo "WARNING: unexpected terraform_dir format: ${tfdir}" ;;
  esac
  echo "Normalized terraform_dir=${tfdir}"
fi

cd /github/workspace
echo "Workspace layout:"
ls -la /github/workspace | sed -n '1,120p'

# Choose RUN_DIR that contains the code (prefer PR)
choose_run_dir() {
  for d in /github/workspace/pr /github/workspace/base /github/workspace ; do
    [[ -d "$d" ]] || continue
    if [[ -f "$d/plancosts/main.py" || -f "$d/main.py" ]]; then
      echo "$d"
      return 0
    fi
  done
  return 1
}
RUN_DIR="$(choose_run_dir || true)"
if [[ -z "${RUN_DIR}" ]]; then
  echo "ERROR: No main.py found under pr/, base/, or repo root."
  echo "monthly_cost=0.00" >> "$GITHUB_OUTPUT"
  exit 1
fi
echo "RUN_DIR=${RUN_DIR}"

# Install deps (pyproject preferred)
cd "${RUN_DIR}"
if [[ -f pyproject.toml ]]; then
  echo "[deps] Installing editable from pyproject.toml in ${RUN_DIR}"
  pip install --no-cache-dir -e .
elif [[ -f requirements.txt ]]; then
  echo "[deps] Installing from requirements.txt in ${RUN_DIR}"
  pip install --no-cache-dir -r requirements.txt
else
  echo "[deps] No pyproject/requirements; installing minimal CLI deps"
  pip install --no-cache-dir click requests boto3 || true
fi

# Locate CLI entry script
if [[ -f plancosts/main.py ]]; then
  MAIN_PY="plancosts/main.py"
elif [[ -f main.py ]]; then
  MAIN_PY="main.py"
else
  echo "ERROR: main.py not found in ${RUN_DIR}"
  echo "monthly_cost=0.00" >> "$GITHUB_OUTPUT"
  exit 1
fi
echo "MAIN_PY=${MAIN_PY}"

# Sanity help (non-fatal)
python "${MAIN_PY}" --help >/dev/null 2>&1 || true

# Try --tfdir if enabled and terraform exists
output=""
if [[ "${USE_TFDIR}" = "1" && -n "${tfdir:-}" && -d "${tfdir}" && -x "$(command -v terraform)" ]]; then
  echo "Running with --tfdir ${tfdir}"
  set +e
  output="$(python "${MAIN_PY}" "${API_ARG[@]}" --tfdir "${tfdir}" -o table 2>&1)"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "plancosts --tfdir failed (rc=${rc}); output:"
    echo "${output}"
    output=""
  fi
else
  [[ "${USE_TFDIR}" = "1" ]] && echo "Terraform not available or dir missing; will try --tfjson…"
  [[ "${USE_TFDIR}" != "1" ]] && echo "USE_TFDIR=0; using --tfjson…"
fi

# Prefer a plan.json directly under the provided tfdir (even if USE_TFDIR=0)
if [[ -z "${output}" && -n "${tfdir:-}" && -f "${tfdir}/plan.json" ]]; then
  echo "Running with --tfjson ${tfdir}/plan.json"
  set +e
  tmp_out="$(python "${MAIN_PY}" "${API_ARG[@]}" --tfjson "${tfdir}/plan.json" -o table 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    output="${tmp_out}"
  else
    echo "FAILED for ${tfdir}/plan.json (rc=${rc})"
    echo "${tmp_out}"
  fi
fi

# Fallbacks: run against committed plan JSONs (prefix-aware: base first for base, pr first for pr)
try_jsons_in_dir() {
  local base_dir="$1" out rc
  for f in \
    "examples/terraform_0_13/plan.json" \
    "plancosts/examples/terraform_0_13/plan.json" \
    "plancosts/test_plan_ern.json" \
    "test_plan_ern.json" \
    "plancosts/test_plan.json" \
    "test_plan.json"
  do
    [[ -f "${base_dir}/${f}" ]] || continue
    echo "Running with --tfjson ${base_dir}/${f}"
    set +e
    out="$(python "${MAIN_PY}" "${API_ARG[@]}" --tfjson "${base_dir}/${f}" -o table 2>&1)"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      echo "${out}"
      return 0
    else
      echo "FAILED for ${base_dir}/${f} (rc=${rc})"
      echo "${out}"
    fi
  done
  return 1
}

if [[ -z "${output}" ]]; then
  if [[ "${prefix}" = "base" ]]; then
    search_dirs=(/github/workspace/base /github/workspace/pr "${RUN_DIR}")
  else
    search_dirs=(/github/workspace/pr /github/workspace/base "${RUN_DIR}")
  fi
  for d in "${search_dirs[@]}"; do
    [[ -d "$d" ]] || continue
    if tmp_out="$(try_jsons_in_dir "$d")"; then
      output="${tmp_out}"
      break
    fi
  done
fi

# Final fallback so downstream steps still run
if [[ -z "${output}" ]]; then
  output=$'NAME                          HOURLY COST  MONTHLY COST\nno_data                       0.0000       0.0000\nOVERALL TOTAL                 0.0000       0.0000'
fi

echo "=== FINAL PLANCOSTS OUTPUT ==="
echo "${output}"
echo "=============================="

OUT="/github/workspace/${prefix}-plancosts.txt"
echo "${output}" > "${OUT}"
echo "Wrote ${OUT}"

monthly="$(echo "${output}" | awk '/^OVERALL TOTAL/ {print $NF; exit}')"
monthly="${monthly:-0.00}"
echo "monthly_cost=${monthly}" >> "$GITHUB_OUTPUT"
echo "monthly_cost=${monthly}"
