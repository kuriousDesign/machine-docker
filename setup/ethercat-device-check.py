#!/usr/bin/env python3

import argparse
import os
import select
import socket
import sys
import time
from dataclasses import dataclass


ETHERCAT_ETHERTYPE = 0x88A4


@dataclass
class PacketCounters:
    rx_packets: int
    tx_packets: int


def read_text(path: str) -> str:
    with open(path, "r", encoding="ascii") as handle:
        return handle.read().strip()


def read_counters(interface_name: str) -> PacketCounters:
    base_path = f"/sys/class/net/{interface_name}/statistics"
    return PacketCounters(
        rx_packets=int(read_text(os.path.join(base_path, "rx_packets"))),
        tx_packets=int(read_text(os.path.join(base_path, "tx_packets"))),
    )


def read_mac(interface_name: str) -> bytes:
    mac_text = read_text(f"/sys/class/net/{interface_name}/address")
    return bytes.fromhex(mac_text.replace(":", ""))


def require_root() -> None:
    if os.geteuid() != 0:
        raise SystemExit("Run this script with sudo or as root.")


def require_interface(interface_name: str) -> None:
    if not os.path.isdir(f"/sys/class/net/{interface_name}"):
        raise SystemExit(f"Network interface not found: {interface_name}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Passively watch a NIC for EtherCAT frames and report whether the "
            "host sees outbound-only traffic or live slave responses."
        )
    )
    parser.add_argument(
        "--nic",
        default="enp3s0",
        help="Network interface to inspect (default: %(default)s)",
    )
    parser.add_argument(
        "--duration",
        type=float,
        default=10.0,
        help="Capture duration in seconds (default: %(default)s)",
    )
    return parser.parse_args()


def summarize(interface_name: str, duration_seconds: float) -> int:
    host_mac = read_mac(interface_name)
    before = read_counters(interface_name)
    operstate = read_text(f"/sys/class/net/{interface_name}/operstate")

    frame_total = 0
    outbound_frames = 0
    inbound_frames = 0
    unique_peer_macs: set[str] = set()

    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETHERCAT_ETHERTYPE))
    try:
        sock.bind((interface_name, 0))
        sock.setblocking(False)

        deadline = time.monotonic() + duration_seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break

            ready, _, _ = select.select([sock], [], [], remaining)
            if not ready:
                continue

            frame = sock.recv(65535)
            if len(frame) < 14:
                continue

            destination = frame[0:6]
            source = frame[6:12]
            ethertype = int.from_bytes(frame[12:14], byteorder="big")
            if ethertype != ETHERCAT_ETHERTYPE:
                continue

            frame_total += 1

            if source == host_mac:
                outbound_frames += 1
                if destination != b"\xff\xff\xff\xff\xff\xff":
                    unique_peer_macs.add(":".join(f"{byte:02x}" for byte in destination))
            else:
                inbound_frames += 1
                unique_peer_macs.add(":".join(f"{byte:02x}" for byte in source))
    finally:
        sock.close()

    after = read_counters(interface_name)

    print(f"Interface: {interface_name}")
    print(f"Link state: {operstate}")
    print(f"Capture duration: {duration_seconds:.1f}s")
    print(f"EtherCAT frames seen: {frame_total}")
    print(f"Outbound EtherCAT frames: {outbound_frames}")
    print(f"Inbound EtherCAT frames: {inbound_frames}")
    print(f"NIC RX packet delta: {after.rx_packets - before.rx_packets}")
    print(f"NIC TX packet delta: {after.tx_packets - before.tx_packets}")

    if unique_peer_macs:
        print("Peer MACs observed:")
        for peer_mac in sorted(unique_peer_macs):
            print(f"  {peer_mac}")

    print()
    if operstate != "up":
        print("Result: link is not up on this NIC.")
        return 2

    if inbound_frames > 0:
        print("Result: this NIC is seeing EtherCAT responses from the bus.")
        return 0

    if outbound_frames > 0:
        print("Result: the host is sending EtherCAT traffic, but no slave responses were observed.")
        return 1

    print("Result: no EtherCAT traffic was observed during the capture window.")
    return 1


def main() -> int:
    args = parse_args()
    require_root()
    require_interface(args.nic)

    if args.duration <= 0:
        raise SystemExit("--duration must be greater than 0 seconds.")

    return summarize(args.nic, args.duration)


if __name__ == "__main__":
    sys.exit(main())