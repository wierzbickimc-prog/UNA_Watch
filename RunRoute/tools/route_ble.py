#!/usr/bin/env python3
"""Talk to the watch's Bluetooth file service, to test sending routes without USB.

    python3 RunRoute/tools/route_ble.py scan
    python3 RunRoute/tools/route_ble.py info
    python3 RunRoute/tools/route_ble.py send my_route.gpx
    python3 RunRoute/tools/route_ble.py rm "My Route"

Needs bleak (pip install bleak). The first connection asks macOS to pair with the
watch. A route is sent to a temporary file and checked before it replaces the old
one, so a failed transfer never leaves a broken route in the watch's list. The
protocol is in una-sdk/Docs/BLE-File-Transfer-Service.md.
"""

import argparse
import asyncio
import os
import struct
import sys
import time
import zlib

from bleak import BleakClient, BleakScanner

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gpx2route

SERVICE = "0000febb-0000-1000-8000-00805f9b34fb"
VERSION = "adaf0001-4669-6c65-5472-616e73666572"
TRANSFER = "adaf0002-4669-6c65-5472-616e73666572"
FIRMWARE = "00002a26-0000-1000-8000-00805f9b34fb"

ROUTES = "/Apps/RunRoute/Routes"
TEMP = ROUTES + "/.upload.tmp"

OK, NO_FILE = 0x01, 0x03
WRITE_WINDOW = 2048
MAX_PACKET = 217  # MTU 220 - 3
STALL_SECONDS = 2.0
REPLY_SECONDS = 10.0
MAX_STALLS = 8


class TransferError(Exception):
    pass


class NoFile(TransferError):
    pass


def now_ns():
    return time.time_ns()


class FileService:
    def __init__(self, write, max_packet):
        self.write = write
        self.max_packet = min(max_packet, MAX_PACKET)
        self.replies = asyncio.Queue()

    def on_notify(self, _sender, data):
        self.replies.put_nowait(bytes(data))

    async def reply(self, command, timeout=REPLY_SECONDS):
        """The next reply to this command. Leftovers from an earlier one are dropped."""
        deadline = time.monotonic() + timeout
        while True:
            data = await asyncio.wait_for(self.replies.get(), deadline - time.monotonic())
            if data[0] == command:
                return data

    @staticmethod
    def check(status, what):
        if status == NO_FILE:
            raise NoFile(what)
        if status != OK:
            raise TransferError(f"{what}: status 0x{status:02x}")

    async def listdir(self, path):
        raw = path.encode()
        await self.write(struct.pack("<BBH", 0x50, 0, len(raw)) + raw)
        entries = []
        while True:
            data = await self.reply(0x51)
            status, length, number, total, flags, _mtime, size = struct.unpack_from("<xBHIIIQI", data)
            self.check(status, path)
            if number == total and length == 0:
                return entries
            entries.append((data[28:28 + length].decode(), bool(flags & 1), size))

    async def mkdir(self, path):
        raw = path.encode()
        await self.write(struct.pack("<BBHIQ", 0x40, 0, len(raw), 0, now_ns()) + raw)
        self.check((await self.reply(0x41))[1], path)

    async def delete(self, path):
        raw = path.encode()
        await self.write(struct.pack("<BBH", 0x30, 0, len(raw)) + raw)
        self.check((await self.reply(0x31))[1], path)

    async def move(self, old, new):
        a, b = old.encode(), new.encode()
        await self.write(struct.pack("<BBHH", 0x60, 0, len(a), len(b)) + a + b"\0" + b)
        self.check((await self.reply(0x61))[1], new)

    async def digest(self, path):
        raw = path.encode()
        await self.write(struct.pack("<BBH", 0x70, 0, len(raw)) + raw)
        data = await self.reply(0x71)
        self.check(data[1], path)
        return struct.unpack_from("<II", data, 4)

    async def write_file(self, path, content):
        """Windowed write: resend from the last unbroken byte when acks stall."""
        raw = path.encode()
        total = len(content)
        await self.write(struct.pack("<BBHIQI", 0x20, 0, len(raw), 0, now_ns(), total) + raw)
        pacing = await self.reply(0x21)
        self.check(pacing[1], path)
        free = struct.unpack_from("<I", pacing, 16)[0]

        chunk = self.max_packet - 12
        sent, stalls = 0, 0
        while free != 0:
            acked = total - free
            while sent < total and sent - acked < WRITE_WINDOW:
                part = content[sent:sent + chunk]
                await self.write(struct.pack("<BBHII", 0x22, OK, 0, sent, len(part)) + part)
                sent += len(part)
            try:
                pacing = await self.reply(0x21, STALL_SECONDS)
            except asyncio.TimeoutError:
                stalls += 1
                if stalls > MAX_STALLS:
                    raise TransferError(f"{path}: the watch stopped acknowledging at byte {acked}")
                sent = acked
                continue
            self.check(pacing[1], path)
            newer = struct.unpack_from("<I", pacing, 16)[0]
            if newer < free:
                stalls = 0
            free = min(free, newer)

    async def send_route(self, name, content):
        """Returns how many seconds the transfer itself took."""
        try:
            await self.listdir(ROUTES)
        except NoFile:
            await self.mkdir(ROUTES)

        started = time.monotonic()
        await self.write_file(TEMP, content)
        seconds = time.monotonic() - started

        size, crc = await self.digest(TEMP)
        if size != len(content) or crc != zlib.crc32(content):
            await self.delete(TEMP)
            raise TransferError(f"check failed: watch has {size} bytes, CRC {crc:08x}")

        target = f"{ROUTES}/{name}.bin"
        try:
            await self.delete(target)
        except NoFile:
            pass
        await self.move(TEMP, target)
        return seconds


async def find_watch(args):
    if args.address:
        return args.address
    found = await BleakScanner.discover(timeout=args.timeout, return_adv=True)
    matches = [
        device for device, adv in found.values()
        if SERVICE in [u.lower() for u in adv.service_uuids]
        or args.name.lower() in (device.name or adv.local_name or "").lower()
    ]
    if not matches:
        sys.exit("No watch found. Run the scan command to see what's nearby, and try --address.")
    if len(matches) > 1:
        names = ", ".join(f"{d.name} ({d.address})" for d in matches)
        sys.exit(f"More than one match: {names}. Choose one with --address.")
    return matches[0]


async def scan(args):
    found = await BleakScanner.discover(timeout=args.timeout, return_adv=True)
    rows = sorted(found.values(), key=lambda row: -row[1].rssi)
    for device, adv in rows:
        name = device.name or adv.local_name
        if not name and SERVICE not in [u.lower() for u in adv.service_uuids]:
            continue
        files = "  [file service]" if SERVICE in [u.lower() for u in adv.service_uuids] else ""
        print(f"{adv.rssi:>5} dBm  {device.address}  {name or '(no name)'}{files}")
    print("Done. If the watch isn't listed, it may only be visible while your phone is disconnected from it.")


async def with_service(args, action):
    target = await find_watch(args)
    print(f"Connecting to {getattr(target, 'name', target)}. Accept the pairing request if macOS shows one.")
    async with BleakClient(target, timeout=args.timeout + 20) as client:
        version = struct.unpack("<I", await client.read_gatt_char(VERSION))[0]
        print(f"File service protocol version: {version}")
        if version < 5:
            sys.exit("This watch's firmware doesn't support verified transfers. Update it, then try again.")
        transfer = client.services.get_characteristic(TRANSFER)
        service = FileService(
            lambda packet: client.write_gatt_char(transfer, packet, response=False),
            transfer.max_write_without_response_size,
        )
        await client.start_notify(transfer, service.on_notify)
        await action(client, service)


async def info(client, service):
    firmware = await client.read_gatt_char(FIRMWARE)
    print(f"Firmware: {firmware.decode(errors='replace')}")
    print(f"Largest packet: {service.max_packet} bytes")
    print("/Apps:")
    for name, is_dir, _size in await service.listdir("/Apps"):
        print(f"  {name}{'/' if is_dir else ''}")
    print(f"{ROUTES}:")
    try:
        for name, _is_dir, size in await service.listdir(ROUTES):
            print(f"  {name}  {size} bytes")
    except NoFile:
        print("  (no such folder)")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--address", help="the watch's identifier, from the scan command")
    parser.add_argument("--name", default="una", help="text to look for in the watch's name (default: una)")
    parser.add_argument("--timeout", type=float, default=10.0, help="seconds to scan (default: 10)")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("scan", help="list nearby Bluetooth devices")
    commands.add_parser("info", help="pair, then show the firmware, apps and routes")
    send_parser = commands.add_parser("send", help="send a GPX file to the watch")
    send_parser.add_argument("gpx")
    rm_parser = commands.add_parser("rm", help="delete a route from the watch")
    rm_parser.add_argument("route")
    args = parser.parse_args()

    async def send(_client, service):
        gpx_name, points = gpx2route.read_gpx(args.gpx)
        if len(points) < 2:
            sys.exit(f"{args.gpx} has no route: it needs at least 2 track or route points.")
        data, kept, _tolerance, metres = gpx2route.encode(points)
        name = gpx2route.route_name(gpx_name, args.gpx)
        seconds = await service.send_route(name, data)
        print(f"Sent and verified {name}: {metres / 1609.344:.2f} mi, {kept} points, "
              f"{len(data)} bytes in {seconds:.1f} s ({len(data) / max(seconds, 0.001) / 1024:.1f} KB/s)")

    async def rm(_client, service):
        await service.delete(f"{ROUTES}/{args.route}.bin")
        print(f"Deleted {args.route}")

    try:
        if args.command == "scan":
            asyncio.run(scan(args))
        else:
            action = {"info": info, "send": send, "rm": rm}[args.command]
            asyncio.run(with_service(args, action))
    except NoFile as error:
        sys.exit(f"Not found on the watch: {error}")
    except (TransferError, asyncio.TimeoutError) as error:
        sys.exit(f"Failed: {error or 'the watch did not reply'}")


if __name__ == "__main__":
    main()
