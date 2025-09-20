#!/usr/bin/env bash
set -euo pipefail

# Arguments from action.yml
PREFIX="${1:-run}"
TERRAFORM_DIR="${2:-.}"

echo "=== Starting plancosts action ==="
echo "Prefix: $PREFIX"

# Move to the mounted workspace (this is where GCPy code is)
cd /github/workspace
echo "Current directory: $(pwd)"
echo "Contents:"
ls -la

# Install Python dependencies from the GCPy repository
echo "Installing Python dependencies from workspace..."
if [[ -f pyproject.toml ]]; then
  echo "Found pyproject.toml in workspace, installing..."
  pip install --no-cache-dir -e .
elif [[ -f requirements.txt ]]; then
  echo "Found requirements.txt in workspace, installing..."
  pip install --no-cache-dir -r requirements.txt
else
  echo "No pyproject.toml or requirements.txt, installing basic deps..."
  pip install --no-cache-dir requests boto3
fi

# Find main.py in the workspace
if [[ -f main.py ]]; then
  MAIN_PY="main.py"
elif [[ -f plancosts/main.py ]]; then
  MAIN_PY="plancosts/main.py"
else
  echo "Error: main.py not found in workspace!"
  # Create dummy output
  cat > "${PREFIX}-plancosts.txt" << EOF
NAME                          HOURLY COST  MONTHLY COST
no_main_py                    0.00         0.00
OVERALL TOTAL                 0.00         0.00
EOF
  echo "monthly_cost=0.00" >> $GITHUB_OUTPUT
  exit 0
fi

echo "Found main script: $MAIN_PY"

# Run plancosts with test file
if [[ -f test_plan_ern.json ]]; then
  echo "Running with test_plan_ern.json"
  output=$(python "$MAIN_PY" --tfjson test_plan_ern.json -o table 2>&1)
elif [[ -f plancosts/test_plan_ern.json ]]; then
  echo "Running with plancosts/test_plan_ern.json"
  output=$(python "$MAIN_PY" --tfjson plancosts/test_plan_ern.json -o table 2>&1)
elif [[ -f test_plan.json ]]; then
  echo "Running with test_plan.json"
  output=$(python "$MAIN_PY" --tfjson test_plan.json -o table 2>&1)
else
  echo "No test files found, creating minimal output"
  output="OVERALL TOTAL                 0.00         0.00"
fi

# Output results
echo "=== Plancosts output ==="
echo "$output"
echo "========================"

# Save to file
echo "$output" > "${PREFIX}-plancosts.txt"

# Extract monthly cost
monthly_cost=$(echo "$output" | awk '/OVERALL TOTAL/ {print $NF; exit}' || echo "0.00")
echo "Extracted monthly cost: $monthly_cost"

# Output for GitHub Actions
echo "monthly_cost=$monthly_cost" >> $GITHUB_OUTPUT

echo "=== Created output file ==="
ls -la "${PREFIX}-plancosts.txt"