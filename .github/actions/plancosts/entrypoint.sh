- name: Start mock pricing API (background with logs)
  shell: bash
  env:
    PYTHONUNBUFFERED: "1"
  run: |
    set -euxo pipefail
    cd pr

    echo "Repo root: $(pwd)"
    echo "Looking for mock_price.py..."
    find . -maxdepth 4 -type f -name "mock_price.py" -print || true

    # Ensure imports like "from plancosts.base..." work when running the script by path.
    # We add both the PR root and the inner package parent to PYTHONPATH.
    export PYTHONPATH="$PWD:$PWD/plancosts:${PYTHONPATH:-}"

    # Prefer running the script by *file path* instead of module import
    # so it works even if 'plancosts.tests' isn't part of the installed package.
    nohup python plancosts/plancosts/tests/mock_price.py > ../mock_server.log 2>&1 &
    echo $! > ../mock_pid.txt
    sleep 1

    if ! kill -0 "$(cat ../mock_pid.txt)" 2>/dev/null; then
      echo "Mock server exited immediately. First 200 lines of log:"
      sed -n '1,200p' ../mock_server.log || true
      exit 1
    fi

- name: Wait for mock API readiness (POST /graphql)
  shell: bash
  env:
    PLANCOSTS_API_URL: http://127.0.0.1:4000
  run: |
    set -euxo pipefail
    for i in {1..60}; do
      code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "${PLANCOSTS_API_URL}/graphql" || true)"
      if [ "$code" = "200" ]; then
        echo "Mock API ready"
        exit 0
      fi
      sleep 0.5
    done
    echo "==== mock_server.log ===="
    cat mock_server.log || true
    exit 1
