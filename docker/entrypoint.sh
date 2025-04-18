#!/bin/bash

set -e

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
    # Only add non-empty values to arguments
    if [ -n "$value" ]; then
        if grep -q -E "^\s*\b${param}\b\s*=" "$ODOO_RC" ; then       
            config_value=$(grep -E "^\s*\b${param}\b\s*=" "$ODOO_RC" |cut -d " " -f3|sed 's/["\n\r]//g')
            # If value is not empty in config, use it instead
            if [ -n "$config_value" ]; then
                value="$config_value"
            fi
        fi;
        ODOO_ARGS+=("--${param}")
        ODOO_ARGS+=("${value}")
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
    declare -A handled_params
    handled_params["db_host"]=1
    handled_params["db_port"]=1
    handled_params["db_user"]=1
    handled_params["db_password"]=1
    handled_params["database"]=1
    handled_params["smtp"]=1
    handled_params["smtp-port"]=1
    handled_params["smtp-user"]=1
    handled_params["smtp-password"]=1
    handled_params["addons-path"]=1
    
    # Process environment variables with CONFIG_ prefix
    for var in $(compgen -e | grep -E "^CONFIG_"); do
        # Extract parameter name by removing prefix and converting to lowercase
        param_name=$(echo ${var#CONFIG_} | tr '[:upper:]' '[:lower:]' | tr '_' ' ' | sed 's/ /_/g')
        value="${!var}"
        
        # Skip if this parameter is already handled by command-line flags
        if [ -n "${handled_params[$param_name]}" ]; then
            echo "Skipping $param_name as it's already handled by command-line flags"
            continue
        fi
        
        # Only process if value is not empty
        if [ -n "$value" ]; then
            # Check if parameter already exists
            if grep -q -E "^\s*;\?\s*\b${param_name}\b\s*=" "$TEMP_CONF"; then
                # Parameter exists, uncomment and update it
                sed -i -E "s|^\s*;\?\s*\b${param_name}\b\s*=.*|${param_name} = ${value}|g" "$TEMP_CONF"
            else
                # Parameter doesn't exist, add it in options section
                if grep -q "\[options\]" "$TEMP_CONF"; then
                    # Add after [options] section
                    sed -i "/\[options\]/a\\${param_name} = ${value}" "$TEMP_CONF"
                else
                    # Add [options] section and parameter
                    echo -e "[options]\n${param_name} = ${value}" >> "$TEMP_CONF"
                fi
            fi
            echo "Set $param_name = $value in odoo.conf"
        fi
    done
    
    # Update the config file
    cat "$TEMP_CONF" > "$ODOO_RC"
    rm "$TEMP_CONF"
}

#==============================================================================
# MAIN SCRIPT
#==============================================================================

# Handle password from file if provided
if [ -v PASSWORD_FILE ]; then
    DB_PASSWORD="$(< $PASSWORD_FILE)"
fi

# Set database connection parameters with fallbacks
: ${DB_HOST:=${HOST:=${DB_PORT_5432_TCP_ADDR:='db'}}}
: ${DB_PORT:=${PORT:=${DB_PORT_5432_TCP_PORT:=5432}}}
: ${DB_USER:=${USER:=${DB_ENV_POSTGRES_USER:=${POSTGRES_USER:='odoo'}}}}
: ${DB_PASSWORD:=${PASSWORD:=${DB_ENV_POSTGRES_PASSWORD:=${POSTGRES_PASSWORD:='odoo'}}}}
: ${DB_NAME:=${POSTGRES_DB:='postgres'}}

# Set other Odoo parameters with defaults
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


install_requirements() {
    local dir="$1"
    if [ -d "$dir" ]; then
        echo "Checking for requirements.txt in $dir..."
        find "$dir" -type f -name "requirements.txt" | while read -r req_file; do
            echo "Found $req_file. Installing dependencies..."
            pip install --no-cache-dir -r "$req_file"
        done
    else
        echo "Directory $dir not found. Skipping requirements installation."
    fi
}
install_requirements "$CUSTOM_ADDONS_DIR"
install_requirements "$MARKETPLACE_ADDONS_DIR"

echo "Executing Odoo with arguments: ${ODOO_ARGS[@]}"
exec $PYTHON $ODOO_BIN "${ODOO_ARGS[@]}" -i base

exit 1