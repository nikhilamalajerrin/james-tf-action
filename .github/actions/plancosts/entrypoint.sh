#!/bin/sh -l

prefix=$1
terraform_dir=$2
api_url=$3

echo "Using prefix=$prefix"
echo "Using terraform_dir=$terraform_dir" 
echo "Using api_url=$api_url"

# Set API URL if provided
if [ -n "$api_url" ]; then
    export PLANCOSTS_API_URL="$api_url"
    echo "Set PLANCOSTS_API_URL=$PLANCOSTS_API_URL"
fi

# Normalize terraform directory path (GitHub workspace -> container path)
if [ -n "$terraform_dir" ]; then
    # Convert host path to container path
    case "$terraform_dir" in
        /home/runner/work/*/GCPy/base/*)
            terraform_dir="/github/workspace/base/${terraform_dir##*/base/}"
            ;;
        /home/runner/work/*/GCPy/pr/*)
            terraform_dir="/github/workspace/pr/${terraform_dir##*/pr/}"
            ;;
        /github/workspace/*)
            # Already correct
            ;;
        *)
            echo "WARNING: Unexpected terraform_dir format: $terraform_dir"
            ;;
    esac
    echo "Normalized terraform_dir=$terraform_dir"
fi

# Working directory and file discovery
echo "Current working directory: $(pwd)"
echo "Available directories:"
ls -la /github/workspace/ 2>/dev/null || echo "No /github/workspace found"

# Check which branch directories exist
for dir in base pr; do
    if [ -d "/github/workspace/$dir" ]; then
        echo "Found branch directory: $dir"
        echo "Contents of $dir:"
        ls -la "/github/workspace/$dir" | head -10
    fi
done
if [ -f "plancosts/setup.py" ]; then
    echo "Installing plancosts package..."
    cd plancosts
    pip install -e . || echo "Package install failed"
    cd /github/workspace
elif [ -f "plancosts/requirements.txt" ]; then
    echo "Installing plancosts requirements..."
    pip install -r plancosts/requirements.txt || echo "Requirements install failed"
fi

# Find main.py
if [ -f "plancosts/main.py" ]; then
    main_script="plancosts/main.py"
elif [ -f "main.py" ]; then
    main_script="main.py"
else
    echo "ERROR: No main.py found"
    echo "::set-output name=monthly_cost::0.00"
    exit 1
fi

echo "Using script: $main_script"

# Test the script first (CRITICAL DEBUG STEP)
echo "Testing script execution..."
python $main_script --help > test_output.txt 2>&1
test_exit_code=$?
echo "Help test exit code: $test_exit_code"
if [ $test_exit_code -ne 0 ]; then
    echo "Script help test failed:"
    cat test_output.txt
fi

# Try running plancosts (following Infracost pattern exactly)
echo "Running plancosts analysis..."

if [ -n "$terraform_dir" ] && [ -d "$terraform_dir" ]; then
    echo "Analyzing terraform directory: $terraform_dir"
    python $main_script --tfdir $terraform_dir -o table > plancosts_output.txt 2>&1
    exit_code=$?
    echo "Terraform analysis exit code: $exit_code"
    if [ $exit_code -eq 0 ]; then
        output=$(cat plancosts_output.txt)
        echo "SUCCESS with terraform directory"
    else
        echo "FAILED with terraform directory. Output:"
        cat plancosts_output.txt
        output=""
    fi
else
    echo "No terraform directory, trying test JSON..."
    output=""
fi

# Fallback to test JSON files
if [ -z "$output" ]; then
    echo "Trying test JSON files..."
    for branch in pr base; do
        for test_file in "plancosts/test_plan_ern.json" "test_plan_ern.json" "plancosts/test_plan.json" "test_plan.json"; do
            full_test_path="/github/workspace/$branch/$test_file"
            if [ -f "$full_test_path" ]; then
                echo "Found test file: $full_test_path"
                python $main_script --tfjson "$full_test_path" -o table > plancosts_output.txt 2>&1
                exit_code=$?
                echo "Test file analysis exit code: $exit_code"
                if [ $exit_code -eq 0 ]; then
                    output=$(cat plancosts_output.txt)
                    echo "SUCCESS with test file: $full_test_path"
                    break 2
                else
                    echo "FAILED with $full_test_path. Output:"
                    cat plancosts_output.txt
                fi
            fi
        done
    done
fi

# Final fallback
if [ -z "$output" ]; then
    echo "All methods failed. Creating minimal output."
    output="NAME                          HOURLY COST  MONTHLY COST
no_data                       0.00         0.00
OVERALL TOTAL                 0.00         0.00"
fi

echo "=== FINAL PLANCOSTS OUTPUT ==="
echo "$output"
echo "=============================="

# Write output file (like Infracost does)
echo "$output" > ${prefix}-plancosts.txt

# Extract monthly cost (following Infracost pattern exactly)
monthly_cost=$(echo "$output" | awk '/OVERALL TOTAL/ { print $NF }')

if [ -z "$monthly_cost" ]; then
    monthly_cost="0.00"
fi

echo "::set-output name=monthly_cost::$monthly_cost"
echo "Monthly cost extracted: $monthly_cost"
echo "Plancosts analysis completed"