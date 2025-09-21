#!/bin/bash
set -euo pipefail

terraform_dir="$1"
percentage_threshold="${2:-0}"

emit_output () { echo "$1=$2" >> "$GITHUB_OUTPUT"; }

# Prefer PR branch code for your Python package
install_repo_pkg() {
  if [ -f "/github/workspace/pull_request/pyproject.toml" ]; then
    pip install -e "/github/workspace/pull_request"
  elif [ -f "/github/workspace/pull_request/requirements.txt" ]; then
    pip install -r "/github/workspace/pull_request/requirements.txt"
  elif [ -f "/github/workspace/master/pyproject.toml" ]; then
    pip install -e "/github/workspace/master"
  elif [ -f "/github/workspace/master/requirements.txt" ]; then
    pip install -r "/github/workspace/master/requirements.txt"
  fi
}
install_repo_pkg

# Pick your main.py
MAIN_PY=""
for base in /github/workspace/pull_request /github/workspace/master; do
  [ -f "$base/plancosts/main.py" ] && MAIN_PY="$base/plancosts/main.py" && break
  [ -f "$base/main.py" ] && MAIN_PY="$base/main.py" && break
done
if [ -z "$MAIN_PY" ]; then
  echo "ERROR: main.py not found in PR or base."
  exit 1
fi

# Run one side (base/pr) either with existing plan.json or by generating one
run_side() {
  local side="$1"   # master | pull_request
  local out="$2"    # output file

  local tf_dir="/github/workspace/${side}/${terraform_dir%/}"
  local plan_json="${tf_dir}/plan.json"
  local gen_json=""

  if [ -f "$plan_json" ]; then
    echo "[$side] Using existing $plan_json"
  else
    echo "[$side] plan.json not found; generating via terraform…"
    export TF_IN_AUTOMATION=1
    export TF_INPUT=0
    (cd "$tf_dir" && terraform init -input=false -lock=false)
    (cd "$tf_dir" && terraform plan -out tfplan)
    gen_json="$(mktemp)"
    (cd "$tf_dir" && terraform show -json tfplan) > "$gen_json"
    plan_json="$gen_json"
  fi

  if python "$MAIN_PY" --tfjson "$plan_json" -o table > "$out" 2>&1; then
    echo "[$side] Wrote $out"
  else
    echo "[$side] plancosts failed; output:"
    cat "$out" || true
    printf 'NAME  HOURLY COST  MONTHLY COST\nOVERALL TOTAL  0.0000  0.0000\n' > "$out"
  fi
}

run_side "master"       master_infracost.txt
run_side "pull_request" pull_request_infracost.txt

# Extract totals safely
extract_total () { awk '/OVERALL[[:space:]]+TOTAL/ { last=$NF } END { if (last=="") last=0; printf "%.4f\n", last }' "$1"; }
master_total="$(extract_total master_infracost.txt)"
pr_total="$(extract_total pull_request_infracost.txt)"

emit_output master_monthly_cost "$master_total"
emit_output pull_request_monthly_cost "$pr_total"

# Build diff body
diff_body="$(git diff --no-color --no-index master_infracost.txt pull_request_infracost.txt | tail -n +3 || true)"
[ -z "$diff_body" ] && diff_body="No differences detected"

# Calculate % change (avoid div-by-zero)
abs_pct="0.0"; change_word="increase"
if awk "BEGIN{exit !($master_total != 0)}"; then
  pct="$(awk -v o="$master_total" -v n="$pr_total" 'BEGIN{printf "%.4f", (n/o)*100 - 100}')"
  abs_pct="$(printf "%s" "$pct" | sed 's/^-\(.*\)$/\1/; s/^+//')"
  if awk "BEGIN{exit !($pct < 0)}"; then change_word="decrease"; fi
fi

# Post commit comment like Infracost if threshold exceeded
if awk -v a="$abs_pct" -v t="$percentage_threshold" 'BEGIN{exit !(a > t)}'; then
  body="$(jq -Mnc \
    --arg word "$change_word" \
    --arg abs "$abs_pct" \
    --arg master "$master_total" \
    --arg pr "$pr_total" \
    --arg diff "$diff_body" \
    '{body: ("Monthly cost estimate will " + $word + " by " + $abs + "% (master branch $" + $master + " vs pull request $" + $pr + ")\n<details><summary>plancosts diff</summary>\n\n```diff\n" + $diff + "\n```\n</details>\n")}')"

  curl -sS -L -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/comments" \
    -d "$body" >/dev/null || echo "WARN: failed to post commit comment"
else
  echo "Not posting comment: ${abs_pct}% <= threshold ${percentage_threshold}%"
fi

# Leave artifacts like Infracost
cp master_infracost.txt /github/workspace/base-plancosts.txt || true
cp pull_request_infracost.txt /github/workspace/pr-plancosts.txt || true
