#!/bin/bash
# run-test - Run a specific command and capture output

if [ "${1:-}" == "describe" ]; then
  cat <<'DESCRIBE_EOF'
{
  "slug": "run_test",
  "description": "Run npx spago test -p tramaj-cli and return full output",
  "args": [],
  "empty-result": { "tag": "AddMessage", "contents": "No output produced" }
}
DESCRIBE_EOF
  exit 0
fi

if [ "${1:-}" != "run" ]; then
  echo "Usage: run-test <describe|run>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_DIR="$REPO_ROOT/tramaj-cli"

output_file=$(mktemp -t run-test.XXXXXX)
exit_code=0

echo "===== Running in $PROJECT_DIR: npx spago test -p tramaj-cli ====="

(cd "$PROJECT_DIR" && npx spago test -p tramaj-cli) > "$output_file" 2>&1 || exit_code=$?

echo "Exit code: $exit_code"
echo "---"
cat "$output_file"
rm -f "$output_file"
exit 0
