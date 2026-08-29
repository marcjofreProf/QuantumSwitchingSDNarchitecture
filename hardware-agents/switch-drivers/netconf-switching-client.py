#!/usr/bin/env python3
import sys
import os
import argparse

# --- VENV AUTO-DISCOVERY ---
try:
    from ncclient import manager
    from lxml import etree
except ModuleNotFoundError:
    current_dir = os.path.dirname(os.path.abspath(__file__))
    venv_python = os.path.abspath(os.path.join(current_dir, '../.venv/bin/python3'))
    if os.path.exists(venv_python):
        os.execl(venv_python, venv_python, *sys.argv)
    else:
        print("[ERROR] 'ncclient' missing and '.venv' not found. Run bootstrap script first.")
        sys.exit(1)

# NETCONF Agent configuration matching BeagleBone
NETCONF_PORT = 8300
NETCONF_USER = "sdn"
NETCONF_PASS = "quantum"

def send_rpc(host, command):
    """Establishes a NETCONF session and prints formatted status/results."""
    try:
        with manager.connect(
            host=host,
            port=NETCONF_PORT,
            username=NETCONF_USER,
            password=NETCONF_PASS,
            hostkey_verify=False,
            device_params={'name': 'default'},
            allow_agent=False,
            look_for_keys=False
        ) as m:
            print(f"[*] Connected to NETCONF agent at {host}:{NETCONF_PORT}")
            
            if command == "status":
                filter_xml = '''
                    <netconf-switch xmlns="urn:quantum:sdn:netconf-switch">
                      <switch-state/>
                      <switch-type/>
                    </netconf-switch>
                '''
                response = m.get(filter=('subtree', filter_xml))
                
                # Parse XML to extract exact values
                root = etree.fromstring(response.xml.encode('utf-8'))
                state = root.xpath('//*[local-name()="switch-state"]/text()')
                s_type = root.xpath('//*[local-name()="switch-type"]/text()')
                
                state_val = state[0] if state else "unknown"
                type_val = s_type[0] if s_type else "unknown"
                
                print(f"[*] Switch State: {state_val}")
                print(f"[*] Switch Type:  {type_val}")

            elif command in ("connect", "disconnect"):
                target_state = "true" if command == "connect" else "false"
                rpc = etree.Element("{urn:quantum:sdn:netconf-switch}set-netconf-switch")
                state = etree.SubElement(rpc, "{urn:quantum:sdn:netconf-switch}state")
                state.text = target_state
                response = m.dispatch(rpc)
                
                # Parse XML result message
                root = etree.fromstring(response.xml.encode('utf-8'))
                msg = root.xpath('//*[local-name()="message"]/text()')
                msg_val = msg[0] if msg else f"State updated to {target_state}"
                
                print(f"[*] Result: {msg_val}")
            
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
    
    print(f"[*] Executing '{args.command}' on node {args.ip} via NETCONF...")
    send_rpc(args.ip, args.command)

if __name__ == "__main__":
    main()
