#!/bin/bash

set -e


cp /opt/odoo/odoo.dist.conf /opt/odoo/odoo.conf;
#==============================================================================
# CONFIGURATION
#==============================================================================

# Define config file location if not set
: ${ODOO_RC:="/opt/odoo/odoo.conf"}
PYTHON="/opt/odoo/venv/bin/python"
ODOO_BIN="/opt/odoo/odoo-bin"

#==============================================================================
# FUNCTIONS
#==============================================================================

# Function to add parameters to command line arguments
function check_config() {
    param="$1"
    value="$2"
    if [ -n "$value" ]; then
        if grep -q -E "^\s*${param}\s*=" "$ODOO_RC"; then
            config_value=$(grep -E "^\s*${param}\s*=" "$ODOO_RC" | cut -d '=' -f2- | xargs)
            if [ -n "$config_value" ]; then
                value="$config_value"
            fi
        fi
        ODOO_ARGS+=("--${param}" "${value}")
    fi
}

# Function to modify odoo.conf file with variables from environment
function update_odoo_conf() {
    echo "Updating odoo.conf with environment variables"
    
    # Create a temporary file for processing
    TEMP_CONF=$(mktemp)
    
    # If the config file doesn't exist or is empty, create a minimal structure
    if [ ! -s "$ODOO_RC" ]; then
        echo "[options]" > "$ODOO_RC"
    fi
    
    # Copy the current config to temp file
    cp "$ODOO_RC" "$TEMP_CONF"
    
    # List of parameters already handled by command-line flags
    declare -A handled_params=(
        [db_host]=1
        [db_port]=1
        [db_user]=1
        [db_password]=1
        [database]=1
        [smtp]=1
        [smtp-port]=1
        [smtp-user]=1
        [smtp-password]=1
        [addons-path]=1
    )
    
    for var in $(compgen -e | grep -E "^CONFIG_"); do
        param_name=$(echo "${var#CONFIG_}" | tr '[:upper:]' '[:lower:]' | tr '_' '-' )
        value="${!var}"

        if [ -n "${handled_params[$param_name]}" ]; then
            echo "Skipping $param_name (handled via CLI)"
            continue
        fi

        if [ -n "$value" ]; then
            # Replace only the first occurrence
            if grep -q -E "^\s*;?\s*${param_name}\s*=" "$TEMP_CONF"; then
                sed -i "0,/^\s*;?\s*${param_name}\s*=.*/s//${param_name} = ${value}/" "$TEMP_CONF"
            else
                sed -i "/\[options\]/a\\${param_name} = ${value}" "$TEMP_CONF"
            fi

            # Remove duplicate entries (keep first)
            awk -F= '!seen[$1]++' "$TEMP_CONF" > "${TEMP_CONF}.dedup" && mv "${TEMP_CONF}.dedup" "$TEMP_CONF"

            echo "Set $param_name = $value in odoo.conf"
        fi
    done

    mv "$TEMP_CONF" "$ODOO_RC"
}

#==============================================================================
# MAIN SCRIPT
#==============================================================================

# Handle password from file if provided
if [ -v PASSWORD_FILE ]; then
    DB_PASSWORD="$(< $PASSWORD_FILE)"
fi

# Set database connection parameters with fallbacks
: ${DB_HOST:=${HOST:='db'}}
: ${DB_PORT:=5432}
: ${DB_USER:=${POSTGRES_USER:='odoo'}}
: ${DB_PASSWORD:=${POSTGRES_PASSWORD:='odoo'}}
: ${DB_NAME:=${POSTGRES_DB:='postgres'}}

: ${SMTP_SERVER:=''}
: ${SMTP_PORT:=''}
: ${SMTP_USER:=''}
: ${SMTP_PASSWORD:=''}
: ${ADDONS_PATH:=''}


# Initialize command line arguments array
ODOO_ARGS=()
# Add database connection parameters
check_config "db_host" "$DB_HOST"
check_config "db_port" "$DB_PORT"
check_config "db_user" "$DB_USER"
check_config "db_password" "$DB_PASSWORD"
check_config "database" "$DB_NAME"

# Add SMTP parameters
check_config "smtp" "$SMTP_SERVER"
check_config "smtp-port" "$SMTP_PORT"
check_config "smtp-user" "$SMTP_USER"
check_config "smtp-password" "$SMTP_PASSWORD"

# Add additional parameters
check_config "addons-path" "$ADDONS_PATH"

# Update odoo.conf with CONFIG_ prefixed variables
if [ -n "$(compgen -e | grep -E "^CONFIG_")" ]; then
    update_odoo_conf
fi

# Create wait-for-psql args from DB_ARGS
WAIT_PSQL_ARGS=()
[[ -n "$DB_HOST" ]] && WAIT_PSQL_ARGS+=("--db_host=$DB_HOST")
[[ -n "$DB_PORT" ]] && WAIT_PSQL_ARGS+=("--db_port=$DB_PORT")
[[ -n "$DB_USER" ]] && WAIT_PSQL_ARGS+=("--db_user=$DB_USER")
[[ -n "$DB_PASSWORD" ]] && WAIT_PSQL_ARGS+=("--db_password=$DB_PASSWORD")
WAIT_PSQL_ARGS+=("--timeout=30")

# Export PGPASSWORD for any PostgreSQL CLI commands that might be used
[[ -n "$DB_PASSWORD" ]] && export PGPASSWORD="$DB_PASSWORD"


# Run Odoo
echo "Executing Odoo with arguments: ${ODOO_ARGS[@]}"
exec $PYTHON $ODOO_BIN "${ODOO_ARGS[@]}"
