#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本地 DoH DNS 服务测试客户端

用法:
    python check_dns.py cas.hdu.edu.cn sso.hdu.edu.cn
    python check_dns.py --port 5399 www.baidu.com
"""
import argparse
import os
import socket
import struct
import sys

# 以本文件所在目录为准加载服务模块, 避免硬编码路径
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from doh_dns import build_dns_query

HOST = "127.0.0.1"
PORT = 53


def read_name(data, offset, depth=0):
    """解析域名, 支持压缩指针(0xC0)"""
    if depth > 10:
        raise ValueError("指针嵌套过深")
    labels = []
    jumped = False
    resume = offset
    while True:
        if offset >= len(data):
            raise ValueError("报文越界")
        ln = data[offset]
        if ln == 0:
            offset += 1
            if not jumped:
                resume = offset
            break
        if ln & 0xC0 == 0xC0:
            ptr = ((ln & 0x3F) << 8) | data[offset + 1]
            if not jumped:
                resume = offset + 2
                jumped = True
            sub, _ = read_name(data, ptr, depth + 1)
            labels.append(sub)
            break
        offset += 1
        labels.append(data[offset:offset + ln].decode("ascii", "replace"))
        offset += ln
    return ".".join(l for l in labels if l), resume


def parse_response(data):
    """粗解析 DNS 响应, 提取 A / AAAA / CNAME"""
    if len(data) < 12:
        return "响应过短"
    txid, flags, qd, an, ns, ar = struct.unpack(">HHHHHH", data[:12])
    rcode = flags & 0x0F
    rcode_txt = {0: "NOERROR", 1: "FORMERR", 2: "SERVFAIL", 3: "NXDOMAIN"}.get(rcode, str(rcode))
    out = ["rcode=%s ancount=%d" % (rcode_txt, an)]
    off = 12
    for _ in range(qd):
        _, off = read_name(data, off)
        off += 4
    for _ in range(an):
        name, off = read_name(data, off)
        rtype, rclass, ttl, rdlen = struct.unpack(">HHIH", data[off:off + 10])
        off += 10
        rd = data[off:off + rdlen]
        off += rdlen
        if rtype == 1 and rdlen == 4:
            val = socket.inet_ntoa(rd)
        elif rtype == 28 and rdlen == 16:
            val = socket.inet_ntop(socket.AF_INET6, rd)
        elif rtype == 5:
            nm = []
            i = 0
            while i < len(rd) and rd[i]:
                ln = rd[i]
                nm.append(rd[i + 1:i + 1 + ln].decode("ascii", "replace"))
                i += 1 + ln
            val = ".".join(nm)
        else:
            val = rd.hex()[:32]
        out.append("   %-28s TTL=%-5d %s" % (name, ttl, val))
    return "\n".join(out)


def query(name, qtype=1, timeout=8):
    q = build_dns_query(name, qtype, txid=0x4321)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(q, (HOST, PORT))
        data, _ = s.recvfrom(4096)
        print("[OK] %s" % name)
        print(parse_response(data))
    except socket.timeout:
        print("[超时] %s  (无响应)" % name)
    except Exception as e:
        print("[错误] %s : %s" % (name, e))
    finally:
        s.close()
    print()


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="测试本地加密DNS转发服务的解析结果")
    ap.add_argument("names", nargs="*", help="要查询的域名")
    ap.add_argument("--host", default=HOST, help="服务地址 (默认 127.0.0.1)")
    ap.add_argument("--port", type=int, default=PORT, help="服务端口 (默认 53)")
    args = ap.parse_args()

    HOST, PORT = args.host, args.port
    names = args.names or ["www.baidu.com"]
    for n in names:
        query(n)
