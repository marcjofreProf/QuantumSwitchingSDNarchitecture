FROM python:3.9-slim

# Install wget and the gnmic binary for gNMI translation
RUN apt-get update && apt-get install -y wget && \
    bash -c "$(wget -qO- https://gnmic.openconfig.net/install.sh)" && \
    apt-get clean

WORKDIR /app
COPY gateway.py .

RUN pip install Flask

EXPOSE 8181
CMD ["python", "gateway.py"]
