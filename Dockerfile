FROM python:3.11-slim AS builder

SHELL ["/bin/bash", "-xo", "pipefail", "-c"]

# Generate locale C.UTF-8 for postgres and general locale data
ENV LANG en_US.UTF-8

WORKDIR /opt/odoo

# Layer 1: Install minimal build dependencies
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    gnupg \
    unzip \
    git \
    python3-dev \
    # Python-related build dependencies
    libxml2-dev \
    libxslt1-dev \
    libldap2-dev \
    libsasl2-dev \
    libpq-dev \
    zlib1g-dev \
    libjpeg-dev \
    liblcms2-dev \
    # Only necessary build dependencies
    libfontconfig1-dev \
    libfreetype6-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Download Odoo source code
# Instead of downloading from GitHub, copy from local source

COPY . /opt/odoo/
RUN rm -rf /opt/odoo/docker

# Setup and activate Python virtual environment
RUN python -m venv /opt/odoo/venv
ENV PATH="/opt/odoo/venv/bin:$PATH"

# Install Odoo dependencies
RUN pip install --no-cache-dir --upgrade pip setuptools wheel && \
    pip install --no-cache-dir -r /opt/odoo/requirements.txt

# Install wkhtmltopdf in builder stage
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
FROM python:3.11-slim

SHELL ["/bin/bash", "-xo", "pipefail", "-c"]
ENV LANG en_US.UTF-8
WORKDIR /opt/odoo

# Install runtime dependencies only
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends \
    # Runtime only dependencies
    ca-certificates \
    curl \
    gnupg \
    # Runtime dependencies for wkhtmltopdf
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
    # Install PostgreSQL client
    lsb-release \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -y postgresql-client-16 \
    # Required shared libraries for Python extensions
    libxml2 \
    libxslt1.1 \
    libldap-2.5-0 \
    libsasl2-2 \
    liblcms2-2 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Copy wkhtmltopdf and install it
COPY --from=builder /opt/odoo/wkhtmltox.deb /tmp/
RUN dpkg --force-depends -i /tmp/wkhtmltox.deb \
    && apt-get update \
    && apt-get -y install -f --no-install-recommends \
    && rm -f /tmp/wkhtmltox.deb \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Copy virtual environment and Odoo from builder
COPY --from=builder /opt/odoo /opt/odoo
RUN rm -f /opt/odoo/wkhtmltox.deb && chmod +x /opt/odoo/odoo-bin

# Copy config and startup scripts
COPY ./docker/wait-for-psql.py /usr/local/bin/wait-for-psql.py
COPY ./docker/entrypoint.sh /
COPY ./docker/odoo.dist.conf /opt/odoo/odoo.conf

# Create necessary directories
RUN chmod +x /entrypoint.sh && \
    chmod +x /usr/local/bin/wait-for-psql.py && \
    mkdir -p /opt/odoo/custom_addons && \
    mkdir -p /var/lib/odoo

# Set environment variables
ENV ODOO_RC /opt/odoo/odoo.conf
ENV CUSTOM_ADDONS_DIR /opt/odoo/custom_addons
ENV MARKETPLACE_ADDONS_DIR /var/lib/odoo/addons/18.0
ENV PATH $PATH:/opt/odoo/venv/bin

# Expose Odoo services
EXPOSE 8069 8071 8072

ENTRYPOINT ["/entrypoint.sh"]