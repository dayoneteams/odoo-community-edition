FROM python:3.11-slim-bookworm AS builder

SHELL ["/bin/bash", "-xo", "pipefail", "-c"]

# Generate locale C.UTF-8 for postgres and general locale data
ENV LANG=en_US.UTF-8

WORKDIR /opt/odoo

# Install build dependencies
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        bash \
        curl \
        gnupg \
        unzip \
        git \
        python3-dev \
        libxml2-dev \
        libxslt1-dev \
        libldap2-dev \
        libsasl2-dev \
        libpq-dev \
        zlib1g-dev \
        libjpeg-dev \
        liblcms2-dev \
        libfontconfig1-dev \
        libfreetype6-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Copy source code and clean up
COPY . /opt/odoo/
RUN rm -rf /opt/odoo/docker

# Setup Python virtual environment and install dependencies
RUN python -m venv /opt/odoo/venv && \
    . /opt/odoo/venv/bin/activate && \
    pip install --no-cache-dir --upgrade pip setuptools wheel && \
    pip install --no-cache-dir -r /opt/odoo/requirements.txt && \
    chown -R 999:999 /opt/odoo/venv

# Download wkhtmltopdf
ARG TARGETARCH
RUN if [ -z "${TARGETARCH}" ]; then \
        TARGETARCH="$(dpkg --print-architecture)"; \
    fi && \
    WKHTMLTOPDF_ARCH=${TARGETARCH} && \
    case ${TARGETARCH} in \
        "amd64") WKHTMLTOPDF_ARCH=amd64 ;; \
        "arm64") WKHTMLTOPDF_ARCH=arm64 ;; \
        "ppc64le" | "ppc64el") WKHTMLTOPDF_ARCH=ppc64el ;; \
    esac && \
    curl -o wkhtmltox.deb -sSL https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_${WKHTMLTOPDF_ARCH}.deb

# Final stage
FROM python:3.11-slim-bookworm

SHELL ["/bin/bash", "-xo", "pipefail", "-c"]
ENV LANG=en_US.UTF-8

WORKDIR /opt/odoo

# Install runtime dependencies and PostgreSQL client
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        libx11-6 \
        libxcb1 \
        libxext6 \
        libxrender1 \
        libfontconfig1 \
        libfreetype6 \
        libjpeg62-turbo \
        xfonts-75dpi \
        xfonts-base \
        fontconfig \
        bash \
        lsb-release \
        libxml2 \
        libxslt1.1 \
        libldap-2.5-0 \
        libsasl2-2 \
        liblcms2-2 \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends postgresql-client-16 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install wkhtmltopdf
COPY --from=builder /opt/odoo/wkhtmltox.deb /tmp/
RUN dpkg --force-depends -i /tmp/wkhtmltox.deb && \
    apt-get update && \
    apt-get -y install -f --no-install-recommends && \
    rm -f /tmp/wkhtmltox.deb && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Create odoo user and group
RUN groupadd -r -g 999 odoo && \
    useradd -r -g odoo -u 999 -m -d /home/odoo odoo

# Copy configuration and scripts first
COPY ./docker/wait-for-psql.py /usr/local/bin/wait-for-psql.py
COPY ./docker/entrypoint.sh /entrypoint.sh
COPY ./docker/odoo.dist.conf /opt/odoo/odoo.dist.conf

# Copy Odoo files from builder
COPY --from=builder /opt/odoo /opt/odoo

# Create directories and set permissions
RUN mkdir -p \
        /var/lib/odoo/sessions \
        /home/odoo/.local \
        /opt/odoo/custom_addons \
        /opt/odoo/marketplace_addons && \
    chmod +x /entrypoint.sh /usr/local/bin/wait-for-psql.py /opt/odoo/odoo-bin && \
    chown -R odoo:odoo /opt/odoo /var/lib/odoo /home/odoo

# Set environment variables
ENV ODOO_RC=/opt/odoo/odoo.conf \
    CUSTOM_ADDONS_DIR=/opt/odoo/custom_addons \
    MARKETPLACE_ADDONS_DIR=/opt/odoo/marketplace_addons \
    PATH=$PATH:/opt/odoo/venv/bin

# Switch to odoo user
USER odoo

# Install additional requirements if they exist
RUN if [ -d /opt/odoo/venv ]; then \
        . /opt/odoo/venv/bin/activate && \
        find /opt/odoo -name 'requirements.txt' -type f | while read req; do \
            echo "Installing dependencies from $req" && \
            pip install --no-cache-dir -r "$req"; \
        done; \
    else \
        echo "Error: Virtual environment not found at /opt/odoo/venv" && \
        exit 1; \
    fi

EXPOSE 8069
ENTRYPOINT ["/entrypoint.sh"]
