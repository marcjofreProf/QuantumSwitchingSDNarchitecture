#!/usr/bin/env python3
import sys
import os
import argparse
import xml.dom.minidom

# --- VENV AUTO-DISCOVERY ---
try:
    from ncclient import manager
    import paramiko
    from paramiko.rsakey import RSAKey
except ModuleNotFoundError:
    current_dir = os.path.dirname(os.path.abspath(__file__))
    venv_python = os.path.abspath(os.path.join(current_dir, '../.venv/bin/python3'))
    if os.path.exists(venv_python):
        os.execl(venv_python, venv_python, *sys.argv)
    else:
        print("[ERROR] 'ncclient' missing and '.venv' not found. Run bootstrap script first.")
        sys.exit(1)

# --- THE ULTIMATE PARAMIKO FIX ---
# 1. Re-allow 'ssh-rsa' in key exchange to prevent "Incompatible ssh peer"
if hasattr(paramiko.Transport, '_preferred_pubkeys'):
    keys = list(paramiko.Transport._preferred_pubkeys)
    if 'ssh-rsa' not in keys:
        keys.append('ssh-rsa')
    paramiko.Transport._preferred_pubkeys = tuple(keys)
    
if hasattr(paramiko.Transport, '_key_info') and 'ssh-rsa' not in paramiko.Transport._key_info:
    paramiko.Transport._key_info['ssh-rsa'] = RSAKey

# 2. Force signature verification to succeed, bypassing the cryptography failure.
# Safe here because hostkey_verify=False is used in this trusted SDN testbed.
RSAKey.verify_ssh_sig = lambda self, data, msg: True

# NETCONF Agent configuration matching BeagleBone
NETCONF_PORT = 8300
NETCONF_USER = "sdn"
NETCONF_PASS = "quantum"

def send_rpc(host, rpc_xml):
    """Establishes a NETCONF session and sends the requested XML RPC."""
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
            response = m.dispatch(xml_=rpc_xml)
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

    payloads = {
        "status": """
            <get>
              <filter type="subtree">
                <netconf-switch xmlns="urn:quantum:sdn:netconf-switch">
                  <switch-state/>
                  <switch-type/>
                </netconf-switch>
              </filter>
            </get>
        """,
        "connect": """
            <set-netconf-switch xmlns="urn:quantum:sdn:netconf-switch">
                <state>true</state>
            </set-netconf-switch>
        """,
        "disconnect": """
            <set-netconf-switch xmlns="urn:quantum:sdn:netconf-switch">
                <state>false</state>
            </set-netconf-switch>
        """
    }

    print(f"[*] Executing '{args.command}' on node {args.ip} via NETCONF...")
    send_rpc(args.ip, payloads[args.command])

if __name__ == "__main__":
    main()
