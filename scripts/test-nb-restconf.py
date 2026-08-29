import requests
import json

# Targets the exposed Flask RESTCONF Gateway
GATEWAY_URL = "http://localhost:8181/restconf/data/controller-quantum-switching:quantum-services/cross-connect-service"

payload = {
    "cross-connect-service": [{
        "service-id": "xc-100",
        "target-node-ip": "192.168.100.5",
        "ingress-port": 10,
        "egress-port": 20,
        "admin-state": "ENABLED"
    }]
}

headers = {
    "Content-Type": "application/yang-data+json",
    "Accept": "application/yang-data+json"
}

print("Sending RESTCONF POST...")
response = requests.post(GATEWAY_URL, json=payload, headers=headers)
print(f"Status: {response.status_code}")
print(f"Body: {response.text}")

print("\nSending RESTCONF GET...")
get_response = requests.get(f"{GATEWAY_URL}/xc-100", headers={"Accept": "application/yang-data+json"})
print(f"Status: {get_response.status_code}")
print(f"Body: {json.dumps(get_response.json(), indent=2)}")
