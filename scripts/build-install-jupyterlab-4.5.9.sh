#!/usr/bin/env bash
# Build, package, and install Voilà against JupyterLab 4.5.9, then start Lab.
#
# Steps:
#   1. Create/activate .venv (unless --no-venv)
#   2. Install JupyterLab 4.5.9 + runtime deps + notebooks/requirements.txt
#   3. Prefer jlpm (falls back to npm) for install + run build:prod
#   4. Build/package voila (wheel), then pip-install it + notebook deps
#   5. Start JupyterLab (notebooks/ by default)
#
# Usage (from anywhere):
#   ./scripts/build-install-start-jupyterlab.sh
#   ./scripts/build-install-start-jupyterlab.sh --no-browser
#   ./scripts/build-install-start-jupyterlab.sh --skip-build   # package existing frontend + install + start
#   ./scripts/build-install-start-jupyterlab.sh --no-venv      # use current Python env
#   ./scripts/build-install-start-jupyterlab.sh --npm          # force npm instead of jlpm
#   ./scripts/build-install-start-jupyterlab.sh --editable     # pip install -e . instead of wheel (dev loop)
#   ./scripts/build-install-start-jupyterlab.sh --no-start     # build/install only
#   ./scripts/build-install-start-jupyterlab.sh --port 8889
#   ./scripts/build-install-start-jupyterlab.sh --notebook-dir /path/to/notebooks
#
# Env overrides:
#   PYTHON=/path/to/python3.13 JL_PORT=8888 NOTEBOOK_DIR=./notebooks SSL_CERT_FILE=/path/to/cacert.pem
#
# Python:
#   Requires >= 3.10. If PYTHON is unset, auto-picks python3.14 … python3.10,
#   then conda (~/miniconda3, ~/anaconda3, /opt/homebrew/bin), then python3.
#
# SSL / Extension Manager:
#   Exports SSL_CERT_FILE (Homebrew Python often lacks CAs). Prefers an explicit
#   SSL_CERT_FILE, then ~/gdp/cacert/cacert.pem, then certifi.
#   Starts Lab with --LabApp.extension_manager=readonly to avoid PyPI HTTPS
#   CERTIFICATE_VERIFY_FAILED noise in the Extension Manager.
#
# Package manager:
#   Prefers `jlpm` (ships with JupyterLab) after JL is installed; falls back to `npm`.
#   Pass --npm to force npm. Node/npm should remain available for nested scripts.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PYTHON_FROM_ENV="${PYTHON-}"
PYTHON="${PYTHON:-}"
JL_VERSION="4.5.9"
JL_PORT="${JL_PORT:-8888}"
NOTEBOOK_DIR="${NOTEBOOK_DIR:-${ROOT}/notebooks}"
USE_VENV=1
DO_BUILD=1
NO_BROWSER=0
NO_START=0
FORCE_NPM=0
EDITABLE=0
PM=""

usage() {
  sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --no-venv) USE_VENV=0; shift ;;
    --skip-build) DO_BUILD=0; shift ;;
    --no-browser) NO_BROWSER=1; shift ;;
    --no-start) NO_START=1; shift ;;
    --npm) FORCE_NPM=1; shift ;;
    --editable) EDITABLE=1; shift ;;
    --port)
      JL_PORT="${2:-}"
      if [[ -z "$JL_PORT" ]]; then
        echo "error: --port requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --notebook-dir)
      NOTEBOOK_DIR="${2:-}"
      if [[ -z "$NOTEBOOK_DIR" ]]; then
        echo "error: --notebook-dir requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage
      ;;
  esac
done

log() { printf '\n==> %s\n' "$*"; }

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

python_is_ok() {
  # $1 = interpreter path or name; succeed if it runs and is >= 3.10.
  local py="$1"
  command -v "$py" >/dev/null 2>&1 || return 1
  "$py" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null
}

resolve_python() {
  # Prefer an explicit PYTHON=…; otherwise find a usable >=3.10 interpreter.
  # macOS /usr/bin/python3 is often still 3.9 and cannot install Voilà.
  local candidate
  local -a candidates=()

  if [[ -n "$PYTHON_FROM_ENV" ]]; then
    if python_is_ok "$PYTHON_FROM_ENV"; then
      PYTHON="$(command -v "$PYTHON_FROM_ENV")"
      return
    fi
    echo "error: PYTHON=${PYTHON_FROM_ENV} is not usable (need Python >= 3.10; found $("$PYTHON_FROM_ENV" -V 2>/dev/null || echo missing))" >&2
    echo "       e.g. PYTHON=/Users/bl44001/miniconda3/bin/python3 $0" >&2
    exit 1
  fi

  candidates=(
    python3.14 python3.13 python3.12 python3.11 python3.10
    "${HOME}/miniconda3/bin/python3"
    "${HOME}/miniconda3/bin/python"
    "${HOME}/anaconda3/bin/python3"
    "${HOME}/anaconda3/bin/python"
    /opt/homebrew/bin/python3
    /usr/local/bin/python3
    python3
  )

  for candidate in "${candidates[@]}"; do
    if python_is_ok "$candidate"; then
      PYTHON="$(command -v "$candidate" 2>/dev/null || true)"
      if [[ -z "$PYTHON" && -x "$candidate" ]]; then
        PYTHON="$candidate"
      fi
      log "Auto-selected Python: ${PYTHON} ($("$PYTHON" -V 2>&1))"
      return
    fi
  done

  echo "error: Python >= 3.10 required; none found on PATH" >&2
  echo "       Install Python 3.10+ or set PYTHON=/path/to/python3" >&2
  exit 1
}

resolve_pm() {
  # Prefer jlpm (JupyterLab's Yarn) when available; allow --npm override.
  if [[ "$FORCE_NPM" -eq 1 ]]; then
    require_cmd npm
    PM=npm
    return
  fi
  if command -v jlpm >/dev/null 2>&1; then
    PM=jlpm
    return
  fi
  require_cmd npm
  PM=npm
}

ensure_yarn_node_modules_linker() {
  # Yarn Berry (jlpm 3+) defaults to PnP, which breaks labextension builds.
  # Keep a checked-in .yarnrc.yml; rewrite if someone deleted the nodeLinker line.
  if [[ ! -f .yarnrc.yml ]] || ! grep -q 'nodeLinker: node-modules' .yarnrc.yml; then
    cat > .yarnrc.yml <<'EOF'
# JupyterLab / Voilà frontends expect a real node_modules tree.
# Yarn PnP breaks tools like rimraf / @jupyterlab/builder / lerna.
enableImmutableInstalls: false
nodeLinker: node-modules
EOF
    log "Wrote .yarnrc.yml (nodeLinker: node-modules)"
  fi
}

pm_install() {
  if [[ "$PM" == "jlpm" ]]; then
    ensure_yarn_node_modules_linker
    # Drop stale PnP artifacts from a previous jlpm install.
    rm -f .pnp.cjs .pnp.loader.mjs
    jlpm install
  else
    if [[ -d node_modules ]]; then
      npm install --prefer-offline --no-audit --no-fund
    else
      npm install
    fi
  fi
}

latest_wheel() {
  local wheel
  wheel="$(ls -t dist/voila-*.whl 2>/dev/null | head -n 1 || true)"
  if [[ -z "$wheel" || ! -f "$wheel" ]]; then
    echo "error: no wheel found in dist/ (expected voila-*.whl)" >&2
    exit 1
  fi
  printf '%s\n' "$wheel"
}

configure_ssl() {
  # Homebrew / custom Python builds often lack a usable CA bundle; httpx used by
  # JupyterLab's PyPI extension manager then fails with CERTIFICATE_VERIFY_FAILED.
  log "Configuring SSL CA bundle"
  "$PYTHON" -m pip install --upgrade certifi >/dev/null

  if [[ -z "${SSL_CERT_FILE:-}" ]]; then
    if [[ -f "${HOME}/gdp/cacert/cacert.pem" ]]; then
      SSL_CERT_FILE="${HOME}/gdp/cacert/cacert.pem"
    else
      SSL_CERT_FILE="$("$PYTHON" -c 'import certifi; print(certifi.where())')"
    fi
  fi
  export SSL_CERT_FILE
  export REQUESTS_CA_BUNDLE="${SSL_CERT_FILE}"
  export CURL_CA_BUNDLE="${SSL_CERT_FILE}"
  log "SSL_CERT_FILE=${SSL_CERT_FILE}"
}

resolve_python
require_cmd node
# npm is still needed for nested `npm run` / tooling calls even when PM is jlpm.
require_cmd npm

NODE_MAJOR="$(node -p "process.versions.node.split('.')[0]")"
if [[ "$NODE_MAJOR" -lt 18 ]]; then
  echo "error: Node.js >= 18 required (found $(node -v))" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Create/activate .venv
# ---------------------------------------------------------------------------
if [[ "$USE_VENV" -eq 1 ]]; then
  if [[ ! -d .venv ]]; then
    log "Creating virtualenv at $ROOT/.venv"
    "$PYTHON" -m venv .venv
  fi
  # shellcheck disable=SC1091
  source .venv/bin/activate
  PYTHON=python
  log "Using venv: $(command -v python)"
else
  log "Using current Python: $(command -v "$PYTHON")"
fi

log "Upgrading pip / setuptools / wheel"
"$PYTHON" -m pip install --upgrade pip setuptools wheel

configure_ssl

# ---------------------------------------------------------------------------
# 2. Install JupyterLab 4.5.9 + runtime deps + example-notebook deps
# ---------------------------------------------------------------------------
log "Installing JupyterLab == ${JL_VERSION}"
"$PYTHON" -m pip install \
  "jupyterlab==${JL_VERSION}" \
  "jupyter_server>=2.0"

JL_ACTUAL="$("$PYTHON" -c 'import jupyterlab; print(jupyterlab.__version__)')"
if [[ "$JL_ACTUAL" != "$JL_VERSION" ]]; then
  echo "error: expected jupyterlab ${JL_VERSION}, got ${JL_ACTUAL}" >&2
  exit 1
fi
log "JupyterLab ${JL_ACTUAL} OK"

NOTEBOOK_REQ="${ROOT}/notebooks/requirements.txt"
if [[ -f "$NOTEBOOK_REQ" ]]; then
  log "Installing example-notebook dependencies from ${NOTEBOOK_REQ}"
  # Best-effort for optional / occasionally flaky packages (e.g. ipyvolume wheels).
  if ! "$PYTHON" -m pip install --prefer-binary -r "$NOTEBOOK_REQ"; then
    log "warning: full notebooks/requirements.txt install failed; retrying packages individually"
    while IFS= read -r line || [[ -n "$line" ]]; do
      # Skip blanks and comments.
      [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
      pkg="$line"
      if ! "$PYTHON" -m pip install --prefer-binary "$pkg"; then
        log "warning: could not install notebook dependency: ${pkg}"
      fi
    done < "$NOTEBOOK_REQ"
  fi
else
  log "warning: missing ${NOTEBOOK_REQ}; installing a minimal fallback set"
  "$PYTHON" -m pip install --prefer-binary \
    ipykernel ipywidgets numpy pandas matplotlib ipympl \
    bqplot ipyvolume scipy bokeh bokeh_sampledata PyYAML vega_datasets
fi

# Widget stacks can pull a looser jupyterlab range; keep the pinned JL version.
"$PYTHON" -m pip install "jupyterlab==${JL_VERSION}" >/dev/null
JL_ACTUAL="$("$PYTHON" -c 'import jupyterlab; print(jupyterlab.__version__)')"
if [[ "$JL_ACTUAL" != "$JL_VERSION" ]]; then
  echo "error: jupyterlab pin lost after notebook deps (got ${JL_ACTUAL})" >&2
  exit 1
fi

# jlpm is provided by the jupyterlab package; resolve PM after JL install.
resolve_pm
log "Frontend package manager: ${PM} ($(command -v "$PM"))"

# ---------------------------------------------------------------------------
# 3. Frontend: install deps + build:prod
# ---------------------------------------------------------------------------
if [[ "$DO_BUILD" -eq 1 ]]; then
  log "${PM} install"
  pm_install

  log "Building frontend packages (${PM} run build:prod)"
  "$PM" run build:prod
else
  log "Skipping frontend build (--skip-build)"
fi

if [[ ! -f voila/labextensions/jupyterlab-preview/package.json ]]; then
  echo "error: labextension missing voila/labextensions/jupyterlab-preview/package.json" >&2
  echo "       run without --skip-build, or build the frontend first" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. Package voila, then install
# ---------------------------------------------------------------------------
log "Installing Python packaging tools"
"$PYTHON" -m pip install \
  "build>=1.0" \
  "hatchling>=1.5.0" \
  "hatch-jupyter-builder>=0.5" \
  "editables>=0.3"

# Drop any previous editable / wheel install so labextensions path is clean.
"$PYTHON" -m pip uninstall -y voila >/dev/null 2>&1 || true

if [[ "$EDITABLE" -eq 1 ]]; then
  log "Editable install of voila"
  # Frontend already built; --no-build-isolation uses the env's hatch/JL tooling.
  "$PYTHON" -m pip install -e . --no-build-isolation --prefer-binary
else
  log "Packaging voila (python -m build --wheel)"
  # Frontend already built; hatch skip-if-exists avoids a second npm build.
  rm -rf dist build *.egg-info
  "$PYTHON" -m build --wheel --no-isolation

  WHEEL="$(latest_wheel)"
  log "Installing wheel: ${WHEEL}"
  # --no-deps keeps the pinned JupyterLab ${JL_VERSION} from step 2.
  "$PYTHON" -m pip install --force-reinstall --no-deps "$WHEEL"

  log "Installing Voilà runtime dependencies (skipped by --no-deps above)"
  "$PYTHON" -m pip install --prefer-binary \
    "jupyter_client>=7.4.4,<9" \
    "jupyter_core>=4.11.0" \
    "jupyter_server>=1.18,<3" \
    "jupyterlab_server>=2.3.0,<3" \
    "nbclient>=0.4.0" \
    "nbconvert>=6.4.5,<8" \
    "traitlets>=5.0.3,<6" \
    "websockets>=9.0"
fi

# Keep JL pin even if package install pulled a looser jupyterlab range.
"$PYTHON" -m pip install "jupyterlab==${JL_VERSION}" >/dev/null
JL_ACTUAL="$("$PYTHON" -c 'import jupyterlab; print(jupyterlab.__version__)')"
if [[ "$JL_ACTUAL" != "$JL_VERSION" ]]; then
  echo "error: jupyterlab pin lost after package install (got ${JL_ACTUAL})" >&2
  exit 1
fi

log "Installed package versions"
"$PYTHON" -m pip show jupyterlab voila | awk '/^(Name|Version|Location):/'

log "Verifying extensions"
jupyter labextension list 2>&1 | tee /tmp/voila-labext.txt || true
if ! grep -qiE '@voila-dashboards/jupyterlab-preview.*enabled.*ok' /tmp/voila-labext.txt; then
  echo "error: @voila-dashboards/jupyterlab-preview is not enabled/OK" >&2
  exit 1
fi
jupyter server extension list 2>&1 | tee /tmp/voila-serverext.txt || true
if ! grep -qiE 'voila\.server_extension.*enabled' /tmp/voila-serverext.txt; then
  echo "error: voila.server_extension is not enabled" >&2
  exit 1
fi
voila --version

if [[ "$NO_START" -eq 1 ]]; then
  log "Build and install complete (--no-start). Skipping JupyterLab launch."
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. Start JupyterLab
# ---------------------------------------------------------------------------
if [[ ! -d "$NOTEBOOK_DIR" ]]; then
  echo "error: notebook directory does not exist: ${NOTEBOOK_DIR}" >&2
  exit 1
fi

# Stop an existing server on the same port if we own it (best-effort).
if command -v lsof >/dev/null 2>&1; then
  EXISTING_PIDS="$(lsof -tiTCP:"${JL_PORT}" -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -n "${EXISTING_PIDS}" ]]; then
    log "Stopping process(es) on port ${JL_PORT}: ${EXISTING_PIDS}"
    # shellcheck disable=SC2086
    kill ${EXISTING_PIDS} 2>/dev/null || true
    sleep 1
  fi
fi

JL_ARGS=(
  lab
  --port "${JL_PORT}"
  --notebook-dir "${NOTEBOOK_DIR}"
  --LabApp.extension_manager=readonly
)
if [[ "$NO_BROWSER" -eq 1 ]]; then
  JL_ARGS+=(--no-browser)
fi

log "Starting JupyterLab ${JL_VERSION} on port ${JL_PORT}"
echo "    cwd: $ROOT"
echo "    notebook-dir: ${NOTEBOOK_DIR}"
echo "    cmd: jupyter ${JL_ARGS[*]}"
echo "    note: extension manager = readonly (avoids PyPI SSL fetch noise)"
echo "    tip: open a notebook and use the Voilà preview toolbar button to test"
echo
exec jupyter "${JL_ARGS[@]}"
