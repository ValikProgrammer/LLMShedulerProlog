# =============================================================================
# Smart Scheduler — Dockerfile
# Base: python:3.11-slim (Debian Bookworm)
# Installs: SWI-Prolog + Python deps + app code
# =============================================================================

FROM python:3.11-slim

# ---------------------------------------------------------------------------
# System dependencies
# swi-prolog      — the Prolog runtime (swipl binary + libraries)
# swi-prolog-dev  — libswipl.so needed by pyswip via ctypes
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        swi-prolog \
        build-essential \
        findutils \
    && rm -rf /var/lib/apt/lists/*

# pyswip loads libswipl.so via ctypes — register its location with ldconfig
RUN SWIPL_LIB=$(find /usr -name "libswipl.so*" -type f 2>/dev/null | head -1) \
    && SWIPL_LIB_DIR=$(dirname "$SWIPL_LIB") \
    && echo "$SWIPL_LIB_DIR" > /etc/ld.so.conf.d/swi-prolog.conf \
    && ldconfig

ENV SWI_HOME_DIR=/usr/lib/swi-prolog

WORKDIR /app

# ---------------------------------------------------------------------------
# Python dependencies (cached layer — only rebuilds when requirements change)
# ---------------------------------------------------------------------------
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ---------------------------------------------------------------------------
# Application code
# ---------------------------------------------------------------------------
COPY . .

# Flask listens on 0.0.0.0 so Docker can forward the port
ENV FLASK_PORT=5000
ENV FLASK_DEBUG=false
ENV PYTHONUNBUFFERED=1

EXPOSE 5000

# Run from /app so relative paths in app.py resolve correctly
CMD ["python", "backend/app.py"]
