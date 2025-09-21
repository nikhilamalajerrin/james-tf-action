#!/usr/bin/env bash
set -euo pipefail

PREFIX="${1:-run}"
TFDIR_IN="${2:-}"
API_URL_IN="${3:-}"

echo "=== Starting plancosts action ==="
echo "Prefix: ${PREFIX}"
echo "TFDIR (input): ${TFDIR_IN}"
echo "Initial API_URL: ${API_URL_IN:-<empty>}"

# --- If API URL not given, try common gateways (works on GH-hosted runners)
if [[ -z "${API_URL_IN}" ]]; then
  for host in host.docker.internal 172.17.0.1 127.0.0.1; do
    if curl -fsS -m 1 -X POST "http://${host}:4000/graphql" >/dev/null 2>&1; then
      API_URL_IN="http://${host}:4000"
      break
    fi
  done
fi
if [[ -n "${API_URL_IN}" ]]; then
  echo "Resolved API_URL: ${API_URL_IN}"
  export PLANCOSTS_API_URL="${API_URL_IN}"
else
  echo "WARNING: Price API not reachable; continuing (tests may use static JSON)."
fi

# --- We run inside the checked-out repo mount
REPO_ROOT="/github/workspace"

# Install deps from repo root (pyproject/requirements optional)
cd "${REPO_ROOT}"
if [[ -f pyproject.toml ]]; then
  echo "[deps] Installing from pyproject.toml"
  pip install --no-cache-dir -e .
elif [[ -f requirements.txt ]]; then
  echo "[deps] Installing from requirements.txt"
  pip install --no-cache-dir -r requirements.txt
else
  echo "[deps] Installing minimal deps"
  pip install --no-cache-dir requests boto3
fi

# --- Pick a run dir that has your main.py
choose_run_dir() {
  local candidates=(
    "${REPO_ROOT}/pr"
    "${REPO_ROOT}/base"
    "${REPO_ROOT}"
  )
  for d in "${candidates[@]}"; do
    [[ -f "${d}/main.py" ]] && { echo "${d}"; return; }
    [[ -f "${d}/plancosts/main.py" ]] && { echo "${d}"; return; }
  done
  echo ""
}

RUN_DIR="$(choose_run_dir)"
if [[ -z "${RUN_DIR}" ]]; then
  echo "[warn] main.py not found; writing dummy output"
  OUT="${REPO_ROOT}/${PREFIX}-plancosts.txt"
  cat > "${OUT}" <<'EOF'
NAME                          HOURLY COST  MONTHLY COST
no_main_py                    0.00         0.00
OVERALL TOTAL                 0.00         0.00
EOF
  echo "monthly_cost=0.00" >> "$GITHUB_OUTPUT"
  exit 0
fi

cd "${RUN_DIR}"
if [[ -f main.py ]]; then
  MAIN_PY="main.py"
else
  MAIN_PY="plancosts/main.py"
fi
echo "Using run dir: ${RUN_DIR}"
echo "Using main script: ${MAIN_PY}"

# Normalize TFDIR (runner absolute path works in container since /github/workspace is mounted)
TFDIR="${TFDIR_IN}"

# Prefer real TF dir, else fallback to known test plans
output=""
if [[ -n "${TFDIR}" && -d "${TFDIR}" ]]; then
  echo "Running with --tfdir=${TFDIR}"
  set +e
  output="$(python "${MAIN_PY}" --tfdir "${TFDIR}" -o table 2>&1)"
  rc=$?
  set -e
  [[ $rc -eq 0 ]] || output=""
fi

if [[ -z "${output}" ]]; then
  for f in \
    plancosts/test_plan_ern.json \
    test_plan_ern.json \
    plancosts/test_plan.json \
    test_plan.json
  do
    if [[ -f "${f}" ]]; then
      echo "Running with --tfjson ${f}"
      output="$(python "${MAIN_PY}" --tfjson "${f}" -o table 2>&1)"
      break
    fi
  done
fi

[[ -n "${output}" ]] || output="OVERALL TOTAL                 0.00         0.00"

echo "=== plancosts output ==="
echo "${output}"
echo "========================"

OUT="${REPO_ROOT}/${PREFIX}-plancosts.txt"
echo "${output}" > "${OUT}"

monthly_cost="$(echo "${output}" | awk '/^OVERALL TOTAL/ {print $NF; exit}' 2>/dev/null || echo "0.00")"
echo "monthly_cost=${monthly_cost}" >> "$GITHUB_OUTPUT"
echo "Wrote ${OUT}"
