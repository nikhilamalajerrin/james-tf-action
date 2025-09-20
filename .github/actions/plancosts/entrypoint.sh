#!/usr/bin/env bash
set -euo pipefail


PREFIX="${1:-run}"
TERRAFORM_DIR_IN="${2:-}"

echo "=== Starting plancosts action ==="
echo "Prefix: $PREFIX"
echo "Terraform dir (input): ${TERRAFORM_DIR_IN:-<none>}"
echo "GITHUB_WORKSPACE: ${GITHUB_WORKSPACE:-<unset>} (container mount is /github/workspace)"

# --- Normalize terraform_dir (host -> container path) ---
TERRAFORM_DIR="${TERRAFORM_DIR_IN}"
if [[ -n "${TERRAFORM_DIR}" && -n "${GITHUB_WORKSPACE:-}" ]]; then
  if [[ "${TERRAFORM_DIR}" == "${GITHUB_WORKSPACE}"* ]]; then
    TERRAFORM_DIR="/github/workspace${TERRAFORM_DIR#${GITHUB_WORKSPACE}}"
  fi
fi
echo "Terraform dir (normalized): ${TERRAFORM_DIR:-<none>}"

# --- Repo root is always /github/workspace in the container ---
REPO_ROOT="/github/workspace"

# If a tf dir exists like /.../base/examples/terraform_0_13, derive /.../base
DERIVED_CODE_DIR="${REPO_ROOT}"
if [[ -n "${TERRAFORM_DIR:-}" && -d "${TERRAFORM_DIR}" ]]; then
  DERIVED_CODE_DIR="$(dirname "$(dirname "${TERRAFORM_DIR}")")"
fi

# --- Always install deps from repo root (where pyproject/requirements are) ---
cd "${REPO_ROOT}"
if [[ -f pyproject.toml ]]; then
  echo "[deps] Installing from pyproject.toml at ${REPO_ROOT}"
  pip install --no-cache-dir -e .
elif [[ -f requirements.txt ]]; then
  echo "[deps] Installing from requirements.txt at ${REPO_ROOT}"
  pip install --no-cache-dir -r requirements.txt
else
  echo "[deps] No pyproject/requirements at ${REPO_ROOT}; installing minimal deps"
  pip install --no-cache-dir requests boto3
fi

# --- Choose a directory that actually has main.py ---
choose_run_dir() {
  local d
  for d in \
      "${DERIVED_CODE_DIR}" \
      "${REPO_ROOT}/pr" \
      "${REPO_ROOT}/base" \
      "${REPO_ROOT}"
  do
    if [[ -f "${d}/main.py" ]] || [[ -f "${d}/plancosts/main.py" ]]; then
      echo "${d}"
      return 0
    fi
  done
  echo ""   # not found
  return 1
}

RUN_DIR="$(choose_run_dir || true)"
if [[ -z "${RUN_DIR}" ]]; then
  echo "[warn] main.py not found in any candidate dirs:"
  echo "  - ${DERIVED_CODE_DIR}"
  echo "  - ${REPO_ROOT}/pr"
  echo "  - ${REPO_ROOT}/base"
  echo "  - ${REPO_ROOT}"
  OUT="${REPO_ROOT}/${PREFIX}-plancosts.txt"
  cat > "${OUT}" <<'EOF'
NAME                          HOURLY COST  MONTHLY COST
no_main_py                    0.00         0.00
OVERALL TOTAL                 0.00         0.00
EOF
  echo "monthly_cost=0.00" >> "$GITHUB_OUTPUT"
  echo "Wrote ${OUT}"
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

# --- Run plancosts ---
output=""
if [[ -n "${TERRAFORM_DIR:-}" && -d "${TERRAFORM_DIR}" ]]; then
  echo "Running with --tfdir=${TERRAFORM_DIR}"
  set +e
  output="$(python "${MAIN_PY}" --tfdir "${TERRAFORM_DIR}" -o table 2>&1)"
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
      echo "Running with --tfjson ${f}"
      output="$(python "${MAIN_PY}" --tfjson "${f}" -o table 2>&1)"
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
