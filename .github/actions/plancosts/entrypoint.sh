#!/usr/bin/env bash
set -euo pipefail

prefix="${1:-run}"
tfdir_in="${2:-}"
api_url="${3:-}"

echo "Using prefix=${prefix}"
echo "Using terraform_dir=${tfdir_in}"
echo "Using api_url=${api_url}"

# Price API
if [[ -n "${api_url}" ]]; then
  export PLANCOSTS_API_URL="${api_url}"
  echo "Set PLANCOSTS_API_URL=${PLANCOSTS_API_URL}"
fi

# --- Normalize terraform_dir from host -> container path (generic, no repo name assumed) ---
tfdir="${tfdir_in}"
if [[ -n "${tfdir}" ]]; then
  case "${tfdir}" in
    */base/*) tfdir="/github/workspace/base/${tfdir##*/base/}" ;;
    */pr/*)   tfdir="/github/workspace/pr/${tfdir##*/pr/}"   ;;
    /github/workspace/*) : ;; # already in container space
    *) echo "WARNING: unexpected terraform_dir format: ${tfdir}" ;;
  esac
  echo "Normalized terraform_dir=${tfdir}"
fi

cd /github/workspace
echo "Workspace layout:"
ls -la /github/workspace | sed -n '1,50p'

# --- Pick RUN_DIR that contains the code (prefers PR) ---
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

# --- Install deps from RUN_DIR root (pyproject preferred) ---
cd "${RUN_DIR}"
if [[ -f pyproject.toml ]]; then
  echo "[deps] Installing editable from pyproject.toml in ${RUN_DIR}"
  pip install --no-cache-dir -e .
elif [[ -f requirements.txt ]]; then
  echo "[deps] Installing from requirements.txt in ${RUN_DIR}"
  pip install --no-cache-dir -r requirements.txt
else
  echo "[deps] No pyproject/requirements in ${RUN_DIR}; installing minimal CLI deps"
  pip install --no-cache-dir click python-dotenv || true
fi

# --- Locate main.py in RUN_DIR ---
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

# Sanity: show help (non-fatal)
python "${MAIN_PY}" --help >/dev/null 2>&1 || true

# --- Try --tfdir first ---
output=""
if [[ -n "${tfdir:-}" && -d "${tfdir}" ]]; then
  echo "Running with --tfdir ${tfdir}"
  set +e
  output="$(python "${MAIN_PY}" --tfdir "${tfdir}" -o table 2>&1)"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "plancosts --tfdir failed (rc=${rc}); output:"
    echo "${output}"
    output=""
  fi
else
  echo "No usable terraform dir; will try test JSONs…"
fi

# --- Fallback: look for test plan JSONs in pr/, base/, then RUN_DIR ---
try_jsons() {
  local base_dir="$1" out rc
  for f in plancosts/test_plan_ern.json test_plan_ern.json plancosts/test_plan.json test_plan.json ; do
    [[ -f "${base_dir}/${f}" ]] || continue
    echo "Running with --tfjson ${base_dir}/${f}"
    set +e
    out="$(python "${MAIN_PY}" --tfjson "${base_dir}/${f}" -o table 2>&1)"
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
  for d in /github/workspace/pr /github/workspace/base "${RUN_DIR}"; do
    [[ -d "$d" ]] || continue
    if out="$(try_jsons "$d")"; then
      output="${out}"
      break
    fi
  done
fi

# --- Last resort so downstream steps still run ---
if [[ -z "${output}" ]]; then
  output=$'NAME                          HOURLY COST  MONTHLY COST\nno_data                       0.00         0.00\nOVERALL TOTAL                 0.00         0.00'
fi

echo "=== FINAL PLANCOSTS OUTPUT ==="
echo "${output}"
echo "=============================="

# Write artifact at repo root
OUT="/github/workspace/${prefix}-plancosts.txt"
echo "${output}" > "${OUT}"
echo "Wrote ${OUT}"

monthly="$(echo "${output}" | awk '/^OVERALL TOTAL/ {print $NF; exit}')"
monthly="${monthly:-0.00}"
echo "monthly_cost=${monthly}" >> "$GITHUB_OUTPUT"
echo "monthly_cost=${monthly}"
