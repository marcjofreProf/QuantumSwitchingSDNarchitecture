FROM python:3.9-slim

# gnmic CLI — used for the gNMI → onos-config southbound path.
# The installer script drops the binary into /usr/local/bin.
RUN apt-get update && apt-get install -y --no-install-recommends \
        wget ca-certificates \
    && bash -c "$(wget -qO- https://gnmic.openconfig.net/install.sh)" \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Dependencies first so layer caching survives gateway.py edits
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY gateway.py .

EXPOSE 8181
CMD ["python", "gateway.py"]
