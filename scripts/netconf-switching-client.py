#!/usr/bin/env python3
import sys
import argparse
from ncclient import manager
import xml.dom.minidom

# Default NETCONF credentials for the hardware agents
NETCONF_PORT = 830
NETCONF_USER = "admin"
NETCONF_PASS = "admin"

def send_rpc(host, rpc_xml):
    """Establishes a NETCONF session and sends the requested XML RPC."""
    try:
        with manager.connect(
            host=host,
            port=NETCONF_PORT,
            username=NETCONF_USER,
            password=NETCONF_PASS,
            hostkey_verify=False,
            device_params={'name': 'default'}
        ) as m:
            print(f"[*] Connected to NETCONF agent at {host}:{NETCONF_PORT}")
            response = m.dispatch(xml_=rpc_xml)
            
            # Format and print the XML response nicely
            pretty_xml = xml.dom.minidom.parseString(response.xml).toprettyxml()
            print("[*] Response Received:\n")
            print(pretty_xml)
            return True
            
    except Exception as e:
        print(f"[!] NETCONF connection or RPC failed: {e}")
        return False

def main():
    parser = argparse.ArgumentParser(description="Quantum-SDN NETCONF Hardware Client")
    parser.add_argument("ip", help="The IP address of the hardware node")
    parser.add_argument("command", choices=["status", "connect", "disconnect"], 
                        help="The action to perform on the node")
    
    args = parser.parse_args()

    # Define standard NETCONF XML payloads mapped to your YANG models
    # Note: You will eventually replace the URNs with your custom quantum YANG models
    payloads = {
        "status": """
            <get>
              <filter type="subtree">
                <hardware-state xmlns="urn:quantum:sdn:switching:1.0">
                  <connection-status/>
                </hardware-state>
              </filter>
            </get>
        """,
        "connect": """
            <cross-connect xmlns="urn:quantum:sdn:switching:1.0">
                <state>active</state>
            </cross-connect>
        """,
        "disconnect": """
            <cross-connect xmlns="urn:quantum:sdn:switching:1.0">
                <state>inactive</state>
            </cross-connect>
        """
    }

    print(f"[*] Executing '{args.command}' on node {args.ip} via NETCONF...")
    send_rpc(args.ip, payloads[args.command])

if __name__ == "__main__":
    main()
