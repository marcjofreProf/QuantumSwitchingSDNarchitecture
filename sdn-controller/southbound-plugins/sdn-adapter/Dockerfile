FROM python:3.11-slim

# Install system dependencies required for compilation and networking tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libxml2-dev \
    libxslt1-dev \
    libffi-dev \
    libssl-dev \
    curl \
    iputils-ping \
    && rm -rf /var/lib/apt/lists/*

# Pre-install Python libraries
RUN pip install --no-cache-dir \
    ncclient \
    paramiko \
    grpcio \
    grpcio-tools \
    requests

WORKDIR /app

# Keep container running continuously
CMD ["sleep", "infinity"]
