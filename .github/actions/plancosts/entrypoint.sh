#!/usr/bin/env bash
set -euo pipefail

PREFIX="${1:-run}"
TFDIR_IN="${2:-}"
API_URL_IN="${3:-}"

echo "=== Starting plancosts action ==="
echo "Prefix: $PREFIX"
echo "TFDIR (input): ${TFDIR_IN:-<none>}"

REPO_ROOT="/github/workspace"

# --- Normalize terraform_dir from host path -> container mount ---
TFDIR="${TFDIR_IN}"
if [[ -n "${TFDIR}" && -n "${GITHUB_WORKSPACE:-}" && "${TFDIR}" == "${GITHUB_WORKSPACE}"* ]]; then
  TFDIR="/github/workspace${TFDIR#${GITHUB_WORKSPACE}}"
fi
echo "TFDIR (normalized): ${TFDIR:-<none>}"

# --- API URL: prefer input, then env, then sensible default ---
API_URL="${API_URL_IN:-${PLANCOSTS_API_URL:-}}"
if [[ -z "${API_URL}" ]]; then
  API_URL="http://host.docker.internal:4000"
fi
case "${API_URL}" in
  http://127.0.0.1:*|http://localhost:*)
    API_URL="http://host.docker.internal:${API_URL##*:}"
    ;;
esac
echo "Initial API_URL: ${API_URL}"

# --- Preflight: if host.docker.internal is not resolvable on this runner, try docker bridge ---
if ! curl -fsS -X POST "${API_URL%/}/graphql" -o /dev/null >/dev/null 2>&1; then
  CANDIDATE="http://172.17.0.1:${API_URL##*:}"
  if curl -fsS -X POST "${CANDIDATE%/}/graphql" -o /dev/null >/dev/null 2>&1; then
    API_URL="${CANDIDATE}"
    echo "Switched API_URL to ${API_URL} (docker bridge)"
  else
    echo "WARNING: Price API not reachable yet at ${API_URL}."
  fi
fi

cd "${REPO_ROOT}"

# --- Install deps from repo root if present; else minimal ---
if [[ -f pyproject.toml ]]; then
  pip install --no-cache-dir -e .
elif [[ -f requirements.txt ]]; then
  pip install --no-cache-dir -r requirements.txt
else
  pip install --no-cache-dir requests boto3
fi

# --- Locate main.py in likely places (your tree has pr/plancosts/main.py) ---
choose_run_dir() {
  for d in "${REPO_ROOT}/pr" "${REPO_ROOT}/base" "${REPO_ROOT}"; do
    [[ -f "${d}/plancosts/main.py" || -f "${d}/main.py" ]] && { echo "$d"; return 0; }
  done
  return 1
}
RUN_DIR="$(choose_run_dir || true)"
if [[ -z "${RUN_DIR}" ]]; then
  echo "[warn] main.py not found; writing dummy output"
  printf "OVERALL TOTAL                 0.00         0.00\n" > "${REPO_ROOT}/${PREFIX}-plancosts.txt"
  echo "monthly_cost=0.00" >> "$GITHUB_OUTPUT"
  exit 0
fi
cd "${RUN_DIR}"
MAIN_PY=$([[ -f main.py ]] && echo main.py || echo plancosts/main.py)
echo "Using run dir: ${RUN_DIR}"
echo "Using main script: ${MAIN_PY}"

# --- Run plancosts (tfdir preferred; else fallback to test JSONs) ---
output=""
if [[ -n "${TFDIR:-}" && -d "${TFDIR}" ]]; then
  echo "Running with --tfdir=${TFDIR}"
  set +e
  output="$(python "${MAIN_PY}" --tfdir "${TFDIR}" --api-url "${API_URL}" -o table 2>&1)"
  rc=$?
  set -e
  if [[ ${rc} -ne 0 ]]; then
    echo "plancosts --tfdir failed (rc=${rc}); falling back to test JSONs"
    output=""
  fi
fi

if [[ -z "${output}" ]]; then
  for f in test_plan_ern.json plancosts/test_plan_ern.json test_plan.json plancosts/test_plan.json; do
    if [[ -f "${f}" ]]; then
      echo "Running with --tfjson ${f}"
      output="$(python "${MAIN_PY}" --tfjson "${f}" --api-url "${API_URL}" -o table 2>&1)"
      break
    fi
  done
fi

if [[ -z "${output}" ]]; then
  output="OVERALL TOTAL                 0.00         0.00"
fi

echo "=== plancosts output ==="
echo "${output}"
echo "========================"

OUT="${REPO_ROOT}/${PREFIX}-plancosts.txt"
echo "${output}" > "${OUT}"
monthly_cost="$(echo "${output}" | awk '/^OVERALL TOTAL/ {print $NF; exit}' 2>/dev/null || echo "0.00")"
echo "monthly_cost=${monthly_cost}" >> "$GITHUB_OUTPUT"
echo "Wrote ${OUT}"
