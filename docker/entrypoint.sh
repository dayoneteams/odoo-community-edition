#!/bin/bash

set -e


cp /opt/odoo/config/odoo.dist.conf /opt/odoo/config/odoo.conf;
#==============================================================================
# CONFIGURATION
#==============================================================================

# Define config file location if not set
: ${ODOO_RC:="/opt/odoo/config/odoo.conf"}
PYTHON="/opt/odoo/venv/bin/python"
ODOO_BIN="/opt/odoo/odoo-bin"

#==============================================================================
# FUNCTIONS
#==============================================================================


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
    
    
    for var in $(compgen -e | grep -E "^CONFIG_"); do
        param_name=$(echo "${var#CONFIG_}" | tr '[:upper:]' '[:lower:]')
        value="${!var}"

        
        # Only process if value is not empty
        if [ -n "$value" ]; then
            # Check if parameter already exists (commented or not)
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

    mv "$TEMP_CONF" "$ODOO_RC"
}

#==============================================================================
# MAIN SCRIPT
#==============================================================================

# Set database connection parameters with fallbacks
: ${DB_HOST:=${CONFIG_DB_HOST:='db'}}
: ${DB_PORT:=${CONFIG_DB_PORT:='5432'}}
: ${DB_USER:=${CONFIG_DB_USER:='odoo'}}
: ${DB_PASSWORD:=${CONFIG_DB_PASSWORD:='odoo'}}
: ${DB_NAME:=${CONFIG_DB_NAME:='postgres'}}

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
if psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -p "$DB_PORT" -tAc "SELECT 1 FROM pg_tables WHERE tablename='ir_module_module';" | grep -q 1; then
    echo "Database already initialized, skipping -i base"
    exec $PYTHON $ODOO_BIN --config="$ODOO_RC"
else
    echo "Database is empty, initializing with -i base"
    exec $PYTHON $ODOO_BIN --config="$ODOO_RC" -i base
fi
