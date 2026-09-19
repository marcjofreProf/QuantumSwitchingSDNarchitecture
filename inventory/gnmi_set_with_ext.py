#!/usr/bin/env python3
"""
gnmi_set_with_ext.py

Send a gNMI Set request to onos-config, using extensions 101 (version)
and 102 (device type) to register a previously-unknown target.

This bypasses onos-topo entirely. onos-config will store the config
internally and apply it when the device becomes reachable.
"""

import argparse
import sys

try:
    import grpc
    from gnmi import gnmi_pb2 as gnmi
    from gnmi import gnmi_pb2_grpc as gnmi_grpc
    from gnmi import gnmi_ext_pb2 as gnmi_ext
except ImportError:
    # Fallback: protos generated into proto/ directory
    sys.path.insert(0, "proto")
    import gnmi_pb2 as gnmi
    import gnmi_pb2_grpc as gnmi_grpc
    import gnmi_ext_pb2 as gnmi_ext


def build_extensions(version: str, device_type: str):
    """Build gNMI extensions 101 (version) and 102 (type)."""
    ext_ver = gnmi_ext.Extension(
        registered_ext=gnmi_ext.RegisteredExtension(
            id=101,
            msg=version.encode("utf-8"),
        )
    )
    ext_type = gnmi_ext.Extension(
        registered_ext=gnmi_ext.RegisteredExtension(
            id=102,
            msg=device_type.encode("utf-8"),
        )
    )
    return [ext_ver, ext_type]


def build_path(target: str, path_str: str):
    """Build a gnmi.Path from a slash-separated path string.

    The target goes into the Path.target field of the prefix, NOT the
    element list.
    """
    elems = [gnmi.PathElem(name=e) for e in path_str.strip("/").split("/") if e]
    return gnmi.Path(target=target, elem=elems)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--address", required=True,
                   help="onos-config gRPC endpoint, e.g. localhost:5150")
    p.add_argument("--target", required=True,
                   help="Device/target ID, e.g. devicesim-1")
    p.add_argument("--type", required=True,
                   help="Device type matching a loaded model plugin")
    p.add_argument("--version", required=True,
                   help="Model version matching the model plugin")
    p.add_argument("--path", required=True,
                   help="Path relative to target, e.g. /system/config/motd-banner")
    p.add_argument("--value", required=True,
                   help="String value to set")
    p.add_argument("--cert", required=True, help="Client cert (PEM)")
    p.add_argument("--key", required=True, help="Client private key (PEM)")
    p.add_argument("--skip-verify", action="store_true", default=True,
                   help="Skip server cert verification (default: on)")
    args = p.parse_args()

    with open(args.cert, "rb") as f:
        cert_bytes = f.read()
    with open(args.key, "rb") as f:
        key_bytes = f.read()

    creds = grpc.ssl_channel_credentials(
        root_certificates=None,
        private_key=key_bytes,
        certificate_chain=cert_bytes,
    )
    channel_opts = []
    if args.skip_verify:
        # gRPC Python does not expose "skip verify" directly for ssl
        # creds; the workaround is to set the target name to a bogus
        # value so verification always fails as intended. If your
        # server cert matches --address, drop --skip-verify.
        channel_opts.append(("grpc.ssl_target_name_override", args.target))

    channel = grpc.secure_channel(args.address, creds, options=channel_opts)
    stub = gnmi_grpc.gNMIStub(channel)

    request = gnmi.SetRequest(
        prefix=gnmi.Path(target=args.target),
        update=[
            gnmi.Update(
                path=build_path(args.target, args.path),
                val=gnmi.TypedValue(string_val=args.value),
            )
        ],
        extension=build_extensions(args.version, args.type),
    )

    try:
        response = stub.Set(request, timeout=15)
        print("[OK] Set succeeded.")
        print(response)
        return 0
    except grpc.RpcError as e:
        print(f"[ERROR] Set failed: {e.code()} - {e.details()}",
              file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
