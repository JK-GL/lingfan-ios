#!/usr/bin/env python3
"""复刻 App 里 LanScanner 的三路发现逻辑，用 Python 实测。

  ① 网段探测：本机 /24 × [5555, 5557]，700ms 超时
  ② Bonjour：_adb-tls-connect / _adb-tls-pairing / _lingfans-link
  ③ UDP 18687 菱粉广播监听

目的：确认"App 里看不到设备列表"是代码问题还是网络里确实没设备。
"""
import socket
import sys
import time
import concurrent.futures
from zeroconf import Zeroconf, ServiceBrowser, ServiceListener

PROBE_PORTS = [5555, 5557]
TIMEOUT = 0.7
BROADCAST_PORT = 18687
SERVICE_TYPES = [
    "_adb-tls-connect._tcp.local.",
    "_adb-tls-pairing._tcp.local.",
    "_lingfans-link._tcp.local.",
]


def local_prefix():
    """取本机对外 IPv4 的前 24 位"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = ""
    finally:
        s.close()
    if not ip or ip == "0.0.0.0":
        return None, None
    return ip, ip.rsplit(".", 1)[0] + "."


def probe_one(ip, port):
    s = socket.socket()
    s.settimeout(TIMEOUT)
    try:
        if s.connect_ex((ip, port)) == 0:
            return (ip, port)
    except Exception:
        pass
    finally:
        s.close()
    return None


def scan_subnet(prefix):
    print(f"\n① 网段探测 {prefix}0/24 × {PROBE_PORTS} (超时 {TIMEOUT}s)")
    t0 = time.time()
    found = []
    targets = [f"{prefix}{h}" for h in range(1, 255)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=128) as ex:
        futs = [ex.submit(probe_one, ip, p) for ip in targets for p in PROBE_PORTS]
        for f in concurrent.futures.as_completed(futs):
            r = f.result()
            if r:
                found.append(r)
                print(f"   ✅ 命中 {r[0]}:{r[1]}")
    print(f"   耗时 {time.time()-t0:.1f}s，命中 {len(found)} 个")
    return found


class Listener(ServiceListener):
    def __init__(self):
        self.hits = []

    def add_service(self, zc, type_, name):
        info = zc.get_service_info(type_, name)
        if info:
            addrs = []
            for a in info.addresses:
                try:
                    addrs.append(socket.inet_ntoa(a))
                except Exception:
                    pass
            entry = (type_, name, addrs, info.port)
            self.hits.append(entry)
            print(f"   ✅ {type_}  name={name}  addr={addrs}  port={info.port}")
        else:
            self.hits.append((type_, name, [], None))
            print(f"   ✅ {type_}  name={name}  (无地址信息)")

    def update_service(self, zc, type_, name):
        pass

    def remove_service(self, zc, type_, name):
        pass

    def add_service_failed(self, zc, type_, name, error):
        pass


def scan_bonjour(seconds=5.0):
    print(f"\n② Bonjour 三类型，窗口 {seconds}s")
    zc = Zeroconf()
    listener = Listener()
    browsers = []
    try:
        for t in SERVICE_TYPES:
            browsers.append(ServiceBrowser(zc, t, listener))
        time.sleep(seconds)
    finally:
        for b in browsers:
            b.cancel()
        zc.close()
    print(f"   命中 {len(listener.hits)} 个")
    return listener.hits


def scan_broadcast(seconds=2.5):
    print(f"\n③ UDP {BROADCAST_PORT} 菱粉广播，窗口 {seconds}s")
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("0.0.0.0", BROADCAST_PORT))
    except Exception as e:
        print(f"   ⚠️ 绑定失败: {e}")
        return []
    s.settimeout(0.5)
    hits = []
    end = time.time() + seconds
    while time.time() < end:
        try:
            data, addr = s.recvfrom(2048)
            hits.append((addr, data))
            print(f"   ✅ 来自 {addr}: {data[:160]!r}")
        except socket.timeout:
            pass
    s.close()
    print(f"   命中 {len(hits)} 个")
    return hits


def main():
    ip, prefix = local_prefix()
    print("=" * 60)
    print(f"本机 IP   : {ip}")
    print(f"扫描网段  : {prefix}0/24")
    print("=" * 60)

    if not prefix:
        print("无法取得本机 IPv4，网段探测跳过")
        subnet = []
    else:
        subnet = scan_subnet(prefix)

    bonjour = scan_bonjour()
    broadcast = scan_broadcast()

    print("\n" + "=" * 60)
    total = len(subnet) + len(bonjour) + len(broadcast)
    print(f"总命中 {total} 个")
    if total == 0:
        print("结论：当前网络里没有任何可发现的 ADB / 菱粉设备。")
    print("=" * 60)
    return 0


if __name__ == "__main__":
    sys.exit(main())
