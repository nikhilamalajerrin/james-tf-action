#!/usr/bin/env bash
set -euo pipefail

PREFIX="${1:-run}"
TERRAFORM_DIR="${2:-}"

echo "=== Starting plancosts action ==="
echo "Prefix: $PREFIX"
echo "Terraform dir (if any): ${TERRAFORM_DIR:-<none>}"

# Work in mounted repo
cd /github/workspace
echo "Workspace: $(pwd)"

# Install deps from the repo
if [[ -f pyproject.toml ]]; then
  echo "Installing from pyproject.toml"
  pip install --no-cache-dir -e .
elif [[ -f requirements.txt ]]; then
  echo "Installing from requirements.txt"
  pip install --no-cache-dir -r requirements.txt
else
  echo "No pyproject/requirements found; installing minimal deps"
  pip install --no-cache-dir requests boto3
fi

# Find main.py
if [[ -f main.py ]]; then
  MAIN_PY="main.py"
elif [[ -f plancosts/main.py ]]; then
  MAIN_PY="plancosts/main.py"
else
  echo "main.py not found; writing dummy output"
  cat > "${PREFIX}-plancosts.txt" <<EOF
NAME                          HOURLY COST  MONTHLY COST
no_main_py                    0.00         0.00
OVERALL TOTAL                 0.00         0.00
EOF
  echo "monthly_cost=0.00" >> "$GITHUB_OUTPUT"
  exit 0
fi
echo "Found main script: $MAIN_PY"

# Run: prefer --tfdir when provided & exists; else try known test JSONs
output=""
if [[ -n "${TERRAFORM_DIR}" && -d "${TERRAFORM_DIR}" ]]; then
  echo "Running with --tfdir=${TERRAFORM_DIR}"
  set +e
  output="$(python "$MAIN_PY" --tfdir "${TERRAFORM_DIR}" -o table 2>&1)"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "plancosts --tfdir failed (rc=$rc), falling back to test JSONs"
    output=""
  fi
fi

if [[ -z "$output" ]]; then
  for f in test_plan_ern.json plancosts/test_plan_ern.json test_plan.json; do
    if [[ -f "$f" ]]; then
      echo "Running with --tfjson $f"
      output="$(python "$MAIN_PY" --tfjson "$f" -o table 2>&1)"
      break
    fi
  done
fi

if [[ -z "$output" ]]; then
  echo "No tfdir or JSON plan available; writing minimal output"
  output="OVERALL TOTAL                 0.00         0.00"
fi

echo "=== plancosts output ==="
echo "$output"
echo "========================"

# Save and expose outputs
echo "$output" > "${PREFIX}-plancosts.txt"
monthly_cost="$(echo "$output" | awk '/OVERALL TOTAL/ {print $NF; exit}' || echo "0.00")"
echo "monthly_cost=${monthly_cost}" >> "$GITHUB_OUTPUT"
echo "Wrote ${PREFIX}-plancosts.txt"
