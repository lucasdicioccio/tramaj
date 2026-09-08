#!/bin/bash
# build-code - Compile and/or test tramaj subprojects
#
# Adheres to the agents-exe bash-tools protocol:
#   ./build-code.sh describe
#   ./build-code.sh run --mode <compile|test|all> --project <tramaj|tramaj-cli|tramaj-halogen|tramaj-hs>

set -euo pipefail

PAGINATION_LINES=60

if [ "${1:-}" == "describe" ]; then
  cat <<'DESCRIBE_EOF'
{
  "slug": "build_code",
  "description": "Compile and/or test a tramaj subproject, returning the last lines of output",
  "args": [
    {
      "name": "mode",
      "description": "What to run: compile, test, or all (compile then test)",
      "type": "string",
      "backing_type": "string",
      "arity": "single",
      "mode": "dashdashspace"
    },
    {
      "name": "project",
      "description": "Subproject to build: tramaj, tramaj-cli, tramaj-halogen, or tramaj-hs",
      "type": "string",
      "backing_type": "string",
      "arity": "single",
      "mode": "dashdashspace"
    }
  ],
  "empty-result": { "tag": "AddMessage", "contents": "No output produced by build command" }
}
DESCRIBE_EOF
  exit 0
fi

if [ "${1:-}" != "run" ]; then
  echo "Usage: build-code <describe|run>" >&2
  exit 1
fi
shift

MODE=""
PROJECT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --project)
      PROJECT="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "Error: --mode is required (compile | test | all)" >&2
  exit 1
fi

if [ -z "$PROJECT" ]; then
  echo "Error: --project is required (tramaj | tramaj-cli | tramaj-halogen | tramaj-hs)" >&2
  exit 1
fi

case "$MODE" in
  compile|test|all)
    ;;
  *)
    echo "Error: invalid mode '$MODE' (expected compile, test, or all)" >&2
    exit 1
    ;;
esac

case "$PROJECT" in
  tramaj|tramaj-cli|tramaj-halogen)
    BUILD_CMD=(npx spago build)
    TEST_CMD=(npx spago test)
    ;;
  tramaj-hs)
    BUILD_CMD=(cabal build)
    TEST_CMD=(cabal test)
    ;;
  *)
    echo "Error: invalid project '$PROJECT' (expected tramaj, tramaj-cli, tramaj-halogen, or tramaj-hs)" >&2
    exit 1
    ;;
esac

# Locate the repository root from this script's path (agents/tools/build-code.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_DIR="$REPO_ROOT/$PROJECT"

if [ ! -d "$PROJECT_DIR" ]; then
  echo "Error: project directory not found: $PROJECT_DIR" >&2
  exit 1
fi

run_command() {
  local label="$1"
  shift
  local cmd=("$@")
  local output_file
  output_file=$(mktemp -t build-code.XXXXXX)
  local exit_code=0

  echo ""
  echo "===== [$PROJECT] $label: ${cmd[*]} ====="

  (cd "$PROJECT_DIR" && "${cmd[@]}") > "$output_file" 2>&1 || exit_code=$?

  echo "Exit code: $exit_code"

  if [ -s "$output_file" ]; then
    local total_lines
    total_lines=$(wc -l < "$output_file")
    echo "Output truncated to last $PAGINATION_LINES lines (total lines: $total_lines)"
    echo "---"
    tail -n "$PAGINATION_LINES" "$output_file"
  else
    echo "(no output)"
  fi

  rm -f "$output_file"
  return "$exit_code"
}

if [ "$MODE" == "compile" ] || [ "$MODE" == "all" ]; then
  run_command "compile" "${BUILD_CMD[@]}"
fi

if [ "$MODE" == "test" ] || [ "$MODE" == "all" ]; then
  run_command "test" "${TEST_CMD[@]}"
fi
