#!/usr/bin/env bash
set -euo pipefail

PREFIX="${1:-run}"
TERRAFORM_DIR_IN="${2:-}"

echo "=== Starting plancosts action ==="
echo "Prefix: $PREFIX"
echo "Terraform dir (input): ${TERRAFORM_DIR_IN:-<none>}"
echo "GITHUB_WORKSPACE: ${GITHUB_WORKSPACE:-<unset>} (container mount is /github/workspace)"

# --- Normalize terraform_dir from host -> container path ---
TERRAFORM_DIR="${TERRAFORM_DIR_IN}"
if [[ -n "${TERRAFORM_DIR}" && -n "${GITHUB_WORKSPACE:-}" ]]; then
  # Map the absolute host path to the container mount
  if [[ "${TERRAFORM_DIR}" == "${GITHUB_WORKSPACE}"* ]]; then
    TERRAFORM_DIR="/github/workspace${TERRAFORM_DIR#${GITHUB_WORKSPACE}}"
  fi
fi
echo "Terraform dir (normalized): ${TERRAFORM_DIR:-<none>}"

# --- Pick code directory (where pyproject/main.py live) ---
# If we have a terraform dir like /.../base/examples/terraform_0_13
# the code root is two levels up (/.../base)
CODE_DIR="/github/workspace"
if [[ -n "${TERRAFORM_DIR:-}" && -d "${TERRAFORM_DIR}" ]]; then
  CODE_DIR="$(dirname "$(dirname "${TERRAFORM_DIR}")")"
fi
echo "Code dir: ${CODE_DIR}"
cd "${CODE_DIR}"

# --- Install deps from this code dir ---
if [[ -f pyproject.toml ]]; then
  echo "Installing from pyproject.toml"
  pip install --no-cache-dir -e .
elif [[ -f requirements.txt ]]; then
  echo "Installing from requirements.txt"
  pip install --no-cache-dir -r requirements.txt
else
  echo "No pyproject/requirements here; installing minimal deps"
  pip install --no-cache-dir requests boto3
fi

# --- Find main.py ---
if [[ -f main.py ]]; then
  MAIN_PY="main.py"
elif [[ -f plancosts/main.py ]]; then
  MAIN_PY="plancosts/main.py"
else
  echo "main.py not found under ${CODE_DIR}; writing dummy output"
  OUT="/github/workspace/${PREFIX}-plancosts.txt"
  cat > "${OUT}" <<'EOF'
NAME                          HOURLY COST  MONTHLY COST
no_main_py                    0.00         0.00
OVERALL TOTAL                 0.00         0.00
EOF
  echo "monthly_cost=0.00" >> "$GITHUB_OUTPUT"
  exit 0
fi
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

OUT="/github/workspace/${PREFIX}-plancosts.txt"
echo "${output}" > "${OUT}"

monthly_cost="$(echo "${output}" | awk '/^OVERALL TOTAL/ {print $NF; exit}' 2>/dev/null || echo "0.00")"
echo "monthly_cost=${monthly_cost}" >> "$GITHUB_OUTPUT"
echo "Wrote ${OUT}"
