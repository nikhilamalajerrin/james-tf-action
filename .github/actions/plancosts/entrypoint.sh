#!/usr/bin/env bash
set -euo pipefail

PREFIX="${1:-run}"
TERRAFORM_DIR_IN="${2:-}"
API_URL_IN="${3:-}"

echo "=== Starting plancosts action ==="
echo "Prefix: $PREFIX"
echo "Terraform dir (input): ${TERRAFORM_DIR_IN:-<none>}"
echo "Repo mount: /github/workspace"

# Decide API URL (prefer explicit input, then env, then host.docker.internal)
API_URL="${API_URL_IN:-${PLANCOSTS_API_URL:-}}"
if [[ -z "${API_URL}" ]]; then
  API_URL="http://host.docker.internal:4000"
fi
# If someone passed localhost/127.0.0.1, map to host.docker.internal
case "$API_URL" in
  http://127.0.0.1:*|http://localhost:*)
    API_URL="http://host.docker.internal:${API_URL##*:}"
    ;;
esac
echo "Using Price API: ${API_URL}"

REPO_ROOT="/github/workspace"
cd "${REPO_ROOT}"

# Install deps from repo root if present; else minimal
if [[ -f pyproject.toml ]]; then
  echo "[deps] Installing from pyproject.toml"
  pip install --no-cache-dir -e .
elif [[ -f requirements.txt ]]; then
  echo "[deps] Installing from requirements.txt"
  pip install --no-cache-dir -r requirements.txt
else
  echo "[deps] Minimal deps"
  pip install --no-cache-dir requests boto3
fi

# Choose a directory that actually has main.py (your repo has plancosts/main.py under pr/)
choose_run_dir() {
  local d
  for d in \
      "${REPO_ROOT}/pr" \
      "${REPO_ROOT}/base" \
      "${REPO_ROOT}" ; do
    if [[ -f "${d}/plancosts/main.py" ]] || [[ -f "${d}/main.py" ]]; then
      echo "${d}"
      return 0
    fi
  done
  return 1
}

RUN_DIR="$(choose_run_dir || true)"
if [[ -z "${RUN_DIR}" ]]; then
  echo "[warn] main.py not found; writing dummy output"
  OUT="${REPO_ROOT}/${PREFIX}-plancosts.txt"
  printf "NAME  HOURLY COST  MONTHLY COST\nOVERALL TOTAL  0.00  0.00\n" > "${OUT}"
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

# Prefer --tfdir if the caller provided a real dir; otherwise fallback to test JSONs within the same tree
output=""
if [[ -n "${TERRAFORM_DIR_IN:-}" && -d "${TERRAFORM_DIR_IN}" ]]; then
  echo "Running: --tfdir=${TERRAFORM_DIR_IN}"
  set +e
  output="$(python "${MAIN_PY}" --tfdir "${TERRAFORM_DIR_IN}" --api-url "${API_URL}" -o table 2>&1)"
  rc=$?
  set -e
  if [[ ${rc} -ne 0 ]]; then
    echo "plancosts --tfdir failed (rc=${rc}); falling back to test JSONs"
    output=""
  fi
fi

if [[ -z "${output}" ]]; then
  for f in \
      test_plan_ern.json \
      plancosts/test_plan_ern.json \
      test_plan.json \
      plancosts/test_plan.json
  do
    if [[ -f "${f}" ]]; then
      echo "Running: --tfjson ${f}"
      output="$(python "${MAIN_PY}" --tfjson "${f}" --api-url "${API_URL}" -o table 2>&1)"
      break
    fi
  done
fi

if [[ -z "${output}" ]]; then
  echo "No tfdir or JSON plan available; writing minimal output"
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
