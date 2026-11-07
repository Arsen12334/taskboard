#!/bin/sh
# =============================================================================
# deploy.sh - automatic local deployment of the TaskBoard FastAPI application
#
# Steps:
#   1. Install missing system packages (git, python3, pip, venv, PostgreSQL)
#   2. Get the application source code (clone the repository if needed)
#   3. Create the Python virtual environment (.venv)
#   4. Install Python dependencies from requirements.txt
#   5. Prepare PostgreSQL (start service, create user and database)
#   6. Start the application with Uvicorn
#   7. Check that the application is available (healthcheck)
#
# The script can be run many times: every step checks the current state first.
# =============================================================================
#arsen
set -eu

# --------------------------- Configuration -----------------------------------
APP_NAME="${APP_NAME:-TaskBoard}"
REPOSITORY_URL="${REPOSITORY_URL:-https://github.com/Arsen12334/taskboard}"
APP_PORT="${APP_PORT:-8000}"

DB_NAME="${DB_NAME:-taskboard}"
DB_USER="${DB_USER:-taskboard}"
DB_PASSWORD="${DB_PASSWORD:-taskboard}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"

# If deploy.sh lies inside the project (normal case: git clone + ./deploy.sh),
# the project directory is the directory of the script.
# Otherwise the repository is cloned into ./taskboard.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/requirements.txt" ] && [ -d "$SCRIPT_DIR/app" ]; then
    APP_DIR="${APP_DIR:-$SCRIPT_DIR}"
else
    APP_DIR="${APP_DIR:-$SCRIPT_DIR/taskboard}"
fi

VENV_DIR="$APP_DIR/.venv"
PID_FILE="$APP_DIR/.uvicorn.pid"
LOG_FILE="$APP_DIR/uvicorn.log"
APP_URL="http://localhost:${APP_PORT}"
HEALTH_URL="${APP_URL}/api/health"

# Connection string used by the application (see app/config.py)
DATABASE_URL="postgresql+psycopg://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
export DATABASE_URL APP_NAME

# --------------------------- Helper functions --------------------------------
log()  { printf '\n[%s] %s\n' "$APP_NAME" "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# Print a clear message if the script stops because of an error
on_exit() {
    code=$?
    if [ "$code" -ne 0 ]; then
        printf '\nDeployment failed (exit code %s).\n' "$code" >&2
    fi
}
trap on_exit EXIT

have() { command -v "$1" >/dev/null 2>&1; }

# Use sudo only when we are not root
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    AS_POSTGRES="runuser -u postgres --"
else
    have sudo || die "sudo is required to install packages. Install sudo or run the script as root."
    SUDO="sudo"
    AS_POSTGRES="sudo -u postgres"
fi

# --------------------------- 1. System packages ------------------------------
detect_package_manager() {
    if have apt-get; then PKG="apt"
    elif have dnf;   then PKG="dnf"
    elif have yum;   then PKG="yum"
    else die "Unsupported Linux distribution: apt-get, dnf or yum not found."
    fi
}

APT_UPDATED=0
pkg_install() {
    case "$PKG" in
        apt)
            if [ "$APT_UPDATED" -eq 0 ]; then
                $SUDO apt-get update -y || die "apt-get update failed."
                APT_UPDATED=1
            fi
            $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" \
                || die "Failed to install packages: $*"
            ;;
        dnf) $SUDO dnf install -y "$@" || die "Failed to install packages: $*" ;;
        yum) $SUDO yum install -y "$@" || die "Failed to install packages: $*" ;;
    esac
}

install_system_packages() {
    log "Step 1/7: Checking system packages"
    detect_package_manager

    if have git; then info "git: OK"; else
        info "git: not found, installing"
        pkg_install git
    fi

    if have curl; then info "curl: OK"; else
        info "curl: not found, installing"
        pkg_install curl
    fi

    if have python3; then info "python3: OK"; else
        info "python3: not found, installing"
        pkg_install python3
    fi

    # pip
    if python3 -m pip --version >/dev/null 2>&1; then info "pip: OK"; else
        info "pip: not found, installing"
        pkg_install python3-pip
    fi

    # venv module (a separate package on Debian/Ubuntu)
    if python3 -c "import ensurepip, venv" >/dev/null 2>&1; then info "python3-venv: OK"; else
        info "python3-venv: not found, installing"
        if [ "$PKG" = "apt" ]; then pkg_install python3-venv; fi
    fi

    # PostgreSQL server and client
    if have psql && { have pg_ctlcluster || have postgresql-setup || [ -d /var/lib/pgsql ] || [ -d /usr/lib/postgresql ]; }; then
        info "PostgreSQL: OK"
    else
        info "PostgreSQL: not found, installing"
        if [ "$PKG" = "apt" ]; then
            pkg_install postgresql postgresql-contrib
        else
            pkg_install postgresql-server postgresql-contrib
        fi
    fi
}

# --------------------------- 2. Source code ----------------------------------
get_source_code() {
    log "Step 2/7: Getting the application source code"
    if [ -d "$APP_DIR/.git" ] || { [ -f "$APP_DIR/requirements.txt" ] && [ -d "$APP_DIR/app" ]; }; then
        info "Project already exists in $APP_DIR, skipping clone"
    else
        info "Cloning $REPOSITORY_URL into $APP_DIR"
        git clone "$REPOSITORY_URL" "$APP_DIR" || die "Cannot clone repository $REPOSITORY_URL"
    fi
    [ -f "$APP_DIR/requirements.txt" ] || die "requirements.txt not found in $APP_DIR"
}

# --------------------------- 3. Virtual environment --------------------------
create_venv() {
    log "Step 3/7: Python virtual environment"
    if [ -x "$VENV_DIR/bin/python" ]; then
        info "Virtual environment already exists: $VENV_DIR"
    else
        info "Creating virtual environment: $VENV_DIR"
        python3 -m venv "$VENV_DIR" || die "Cannot create virtual environment."
    fi
}

# --------------------------- 4. Python dependencies --------------------------
install_python_dependencies() {
    log "Step 4/7: Installing Python dependencies"
    "$VENV_DIR/bin/python" -m pip install --quiet --upgrade pip \
        || die "Cannot upgrade pip."
    "$VENV_DIR/bin/python" -m pip install --quiet -r "$APP_DIR/requirements.txt" \
        || die "Cannot install dependencies from requirements.txt"
    info "Dependencies installed"
}

# --------------------------- 5. PostgreSQL -----------------------------------
start_postgresql() {
    info "Starting PostgreSQL"

    # Red Hat family: the database cluster must be initialised once
    if [ "$PKG" != "apt" ] && [ ! -f /var/lib/pgsql/data/PG_VERSION ] && have postgresql-setup; then
        $SUDO postgresql-setup --initdb || die "Cannot initialise PostgreSQL."
    fi

    if have systemctl && [ -d /run/systemd/system ]; then
        $SUDO systemctl enable --now postgresql || die "Cannot start PostgreSQL via systemctl."
    elif have service; then
        $SUDO service postgresql start || die "Cannot start PostgreSQL via service."
    elif have pg_ctlcluster && have pg_lsclusters; then
        pg_lsclusters -h | while read -r ver name _; do
            $SUDO pg_ctlcluster "$ver" "$name" start 2>/dev/null || true
        done
    else
        die "Do not know how to start PostgreSQL on this system."
    fi

    # Wait until PostgreSQL accepts connections
    i=0
    until $AS_POSTGRES psql -tAc "SELECT 1" >/dev/null 2>&1; do
        i=$((i + 1))
        [ "$i" -le 30 ] || die "PostgreSQL did not start in 30 seconds."
        sleep 1
    done
    info "PostgreSQL is running"
}

# Run an SQL query as the postgres superuser and print the result
psql_query() {
    $AS_POSTGRES psql -v ON_ERROR_STOP=1 -tA -c "$1"
}

prepare_database() {
    log "Step 5/7: Preparing PostgreSQL"
    start_postgresql

    # User: create if missing, otherwise just update the password
    if [ "$(psql_query "SELECT 1 FROM pg_roles WHERE rolname = '$DB_USER'")" = "1" ]; then
        info "User '$DB_USER' already exists, updating password"
        psql_query "ALTER USER \"$DB_USER\" WITH PASSWORD '$DB_PASSWORD'" >/dev/null \
            || die "Cannot update password of user '$DB_USER'."
    else
        info "Creating user '$DB_USER'"
        psql_query "CREATE USER \"$DB_USER\" WITH PASSWORD '$DB_PASSWORD'" >/dev/null \
            || die "Cannot create user '$DB_USER'."
    fi

    # Database: create if missing
    if [ "$(psql_query "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'")" = "1" ]; then
        info "Database '$DB_NAME' already exists"
    else
        info "Creating database '$DB_NAME'"
        psql_query "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\"" >/dev/null \
            || die "Cannot create database '$DB_NAME'."
    fi

    psql_query "GRANT ALL PRIVILEGES ON DATABASE \"$DB_NAME\" TO \"$DB_USER\"" >/dev/null \
        || die "Cannot grant privileges."

    # Make sure the application user can really log in with the password
    PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT 1" >/dev/null 2>&1 \
        || die "Cannot connect to database '$DB_NAME' as '$DB_USER' (check pg_hba.conf)."
    info "Database connection check: OK"
}

# --------------------------- 6. Start application ----------------------------
stop_old_instance() {
    if [ -f "$PID_FILE" ]; then
        old_pid="$(cat "$PID_FILE")"
        if kill -0 "$old_pid" 2>/dev/null; then
            info "Stopping previous instance (PID $old_pid)"
            kill "$old_pid" 2>/dev/null || true
            i=0
            while kill -0 "$old_pid" 2>/dev/null && [ "$i" -lt 10 ]; do
                sleep 1
                i=$((i + 1))
            done
        fi
        rm -f "$PID_FILE"
    fi
}

start_application() {
    log "Step 6/7: Starting the application"
    stop_old_instance

    cd "$APP_DIR"
    nohup "$VENV_DIR/bin/uvicorn" app.main:app --host 0.0.0.0 --port "$APP_PORT" \
        >"$LOG_FILE" 2>&1 &
    echo $! >"$PID_FILE"
    info "Uvicorn started (PID $(cat "$PID_FILE")), log: $LOG_FILE"
}

# --------------------------- 7. Healthcheck ----------------------------------
check_deployment() {
    log "Step 7/7: Checking the application"
    i=0
    until curl -fsS "$HEALTH_URL" >/dev/null 2>&1; do
        i=$((i + 1))
        if [ "$i" -gt 30 ]; then
            printf '\nLast lines of %s:\n' "$LOG_FILE" >&2
            tail -n 20 "$LOG_FILE" >&2 || true
            die "Application did not become healthy: $HEALTH_URL"
        fi
        sleep 1
    done
    info "Healthcheck response: $(curl -fsS "$HEALTH_URL")"
}

# --------------------------- Main --------------------------------------------
install_system_packages
get_source_code
create_venv
install_python_dependencies
prepare_database
start_application
check_deployment

printf '\nApplication deployed successfully.\n'
printf 'Application is available at: %s\n' "$APP_URL"
printf 'Swagger API: %s/docs\n' "$APP_URL"
printf 'Healthcheck: %s\n' "$HEALTH_URL"
