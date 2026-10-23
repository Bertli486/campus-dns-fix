#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
本地加密 DNS 转发 (DoH -> 本地 UDP DNS 服务)
=================================================
背景: 校园网对明文 DNS(UDP/53) 的校内域名查询做了拦截, 导致 hdu.edu.cn 等
      校内域名无法解析, 网页打不开; 但网络链路本身正常(用 IP 直连校内网站返回 200)。

方案: 本程序通过 HTTPS 加密 DNS(DoH) 解析域名, 再在本机 127.0.0.1 上以普通
      DNS 形式提供给系统, 从而绕开拦截。

要点: 校园网会按 SNI/域名 阻断 DoH 服务域名, 因此这里一律使用 **IP 直连**
      (如 https://223.5.5.5/), 不解析 DoH 服务器域名。

无需管理员权限即可运行(监听回环地址)。仅依赖 Python 标准库。
"""

import argparse
import ipaddress
import json
import socket
import socketserver
import ssl
import struct
import sys
import threading
import time
import urllib.request

# ---------------------------------------------------------------- 配置
LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 5399          # 默认高位端口; 供系统使用时需用 53(需管理员)
ALLOW_SUBNET = False        # 是否允许局域网其它设备使用(如寝室路由器下的手机/平板)

# 自检用的域名 —— 请改成你自己学校的域名(命令行 --probe 也可覆盖)
# 默认用杭州电子科技大学做示例
PROBE_DOMAINS = ["cas.hdu.edu.cn", "sso.hdu.edu.cn", "hdu.edu.cn", "www.baidu.com"]

# DoH 上游: (IP, 用途说明) —— 全部使用 IP 直连, 避免 SNI 阻断
DOH_UPSTREAMS = [
    ("223.5.5.5", "阿里DNS"),
    ("1.12.12.12", "腾讯DNS"),
    ("223.6.6.6", "阿里DNS-2"),
    ("120.53.53.53", "腾讯DNS-2"),
]

# 明文兜底: 当所有 DoH 都不可用时, 保证校内/本地域名至少有机会解析
PLAINTEXT_FALLBACK = ("210.32.32.1", 53)

TIMEOUT = 6
CACHE_TTL = 60

_cache = {}
_cache_lock = threading.Lock()
_stats = {"doh_ok": 0, "doh_fail": 0, "fallback": 0, "error": 0}


def log(msg):
    print(time.strftime("[%H:%M:%S] ") + msg, flush=True)


def setup_stdio():
    """pythonw 无控制台, 标准输出会退回 ANSI(GBK) 导致日志中文乱码。
       统一强制为 UTF-8, 保证 relay.log 可读。"""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass


# ------------------------------------------------- DNS 报文工具
def parse_qname(data, offset):
    labels = []
    while True:
        if offset >= len(data):
            raise ValueError("报文越界")
        ln = data[offset]
        if ln == 0:
            offset += 1
            break
        if ln & 0xC0:
            raise ValueError("查询名不支持压缩指针")
        offset += 1
        labels.append(data[offset:offset + ln].decode("ascii", "replace"))
        offset += ln
    return ".".join(labels), offset


def build_dns_query(qname, qtype, qclass=1, txid=0):
    header = struct.pack(">HHHHHH", txid, 0x0100, 1, 0, 0, 0)
    q = b""
    for label in qname.rstrip(".").split("."):
        if not label:
            continue
        b = label.encode("idna") if any(ord(c) > 127 for c in label) else label.encode("ascii")
        q += bytes([len(b)]) + b
    q += b"\x00" + struct.pack(">HH", qtype, qclass)
    return header + q


QTYPES = {1: "A", 28: "AAAA", 5: "CNAME", 15: "MX", 16: "TXT", 6: "SOA",
          12: "PTR", 33: "SRV", 65: "HTTPS", 2: "NS", 43: "DS", 48: "DNSKEY"}


def qtype_name(t):
    return QTYPES.get(t, str(t))


# ------------------------------------------------- DoH 客户端
def _ssl_contexts():
    """优先严格校验; IP 证书可能不匹配, 准备一个降级上下文"""
    strict = ssl.create_default_context()
    relaxed = ssl.create_default_context()
    relaxed.check_hostname = False
    relaxed.verify_mode = ssl.CERT_NONE
    return strict, relaxed


_STRICT_CTX, _RELAXED_CTX = _ssl_contexts()


def _post_json(url, ctx):
    req = urllib.request.Request(url, headers={"Accept": "application/dns-json"})
    with urllib.request.urlopen(req, timeout=TIMEOUT, context=ctx) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _post_wire(url, wire_query, ctx):
    req = urllib.request.Request(
        url,
        data=wire_query,
        headers={"Content-Type": "application/dns-message",
                 "Accept": "application/dns-message"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT, context=ctx) as resp:
        return resp.read()


def doh_query(ip, qname, qtype, wire_query):
    """先试 wire 格式(POST /dns-query), 失败再试 JSON 接口。
       返回 (原始DNS响应报文 或 JSON字典, 使用的格式)"""
    base_wire = "https://%s/dns-query" % ip
    base_json = "https://%s/resolve?name=%s&type=%s" % (ip, qname, qtype_name(qtype))

    for ctx in (_STRICT_CTX, _RELAXED_CTX):
        try:
            return _post_wire(base_wire, wire_query, ctx), "wire"
        except Exception:
            pass
    for ctx in (_STRICT_CTX, _RELAXED_CTX):
        try:
            return _post_json(base_json, ctx), "json"
        except Exception:
            pass
    raise RuntimeError("DoH 请求失败")


def json_to_wire(txid, qname, qtype, qclass, doc):
    """把 DoH JSON 应答转成标准 DNS 响应报文"""
    rcode = doc.get("Status", 2)
    answers = doc.get("Answer", []) or []
    authorities = doc.get("Authority", []) or []

    TYPE_MAP = {"A": 1, "AAAA": 28, "CNAME": 5, "MX": 15, "TXT": 16,
                "NS": 2, "SOA": 6, "PTR": 12, "SRV": 33, "HTTPS": 65}

    def rdata(rtype, data):
        if rtype == 1:
            return socket.inet_aton(data)
        if rtype == 28:
            return socket.inet_pton(socket.AF_INET6, data)
        if rtype in (5, 2, 12):
            out = b""
            for lab in str(data).rstrip(".").split("."):
                b = lab.encode("ascii", "replace")[:63]
                out += bytes([len(b)]) + b
            return out + b"\x00"
        if rtype == 16:
            s = str(data).strip('"').encode("utf-8")[:255]
            return bytes([len(s)]) + s
        if rtype == 15:
            parts = str(data).split()
            pref = int(parts[0]) if parts and parts[0].isdigit() else 10
            host = parts[-1] if parts else ""
            out = struct.pack(">H", pref)
            for lab in host.rstrip(".").split("."):
                b = lab.encode("ascii", "replace")[:63]
                out += bytes([len(b)]) + b
            return out + b"\x00"
        return b""

    def enc_name(name):
        out = b""
        for lab in str(name).rstrip(".").split("."):
            if not lab:
                continue
            b = lab.encode("ascii", "replace")[:63]
            out += bytes([len(b)]) + b
        return out + b"\x00"

    # 问题段(回显)
    question = build_dns_query(qname, qtype, qclass, txid)[12:]

    ancount = 0
    ans_bytes = b""
    for a in answers:
        t = TYPE_MAP.get(a.get("type", ""), 0)
        if t == 0:
            continue
        rd = rdata(t, a.get("data", ""))
        if not rd:
            continue
        ans_bytes += enc_name(a.get("name", qname)) + struct.pack(">HHIH", t, 1, min(int(a.get("TTL", 60)), 3600), len(rd)) + rd
        ancount += 1

    flags = 0x8180 | (rcode & 0x0F)          # QR=1 RD=1 RA=1
    header = struct.pack(">HHHHHH", txid, flags, 1, ancount, 0, 0)
    return header + question + ans_bytes


def udp_query(server, wire_query):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(TIMEOUT)
    try:
        s.sendto(wire_query, server)
        return s.recvfrom(4096)[0]
    finally:
        s.close()


def resolve(wire_query, qname, qtype, qclass):
    """返回标准 DNS 响应报文, 或 None"""
    for ip, label in DOH_UPSTREAMS:
        try:
            out, fmt = doh_query(ip, qname, qtype, wire_query)
            if fmt == "wire":
                _stats["doh_ok"] += 1
                log("DoH   %-32s %-5s  <- %s %s" % (qname[:32], qtype_name(qtype), label, ip))
                return out
            doc = out
            resp = json_to_wire(wire_query[0:2], qname, qtype, qclass, doc)
            _stats["doh_ok"] += 1
            log("DoH   %-32s %-5s  <- %s %s (json, %d ans)" %
                (qname[:32], qtype_name(qtype), label, ip, len(doc.get("Answer", []) or [])))
            return resp
        except Exception:
            _stats["doh_fail"] += 1
            continue

    try:
        resp = udp_query(PLAINTEXT_FALLBACK, wire_query)
        _stats["fallback"] += 1
        log("兜底  %-32s %-5s  <- %s" % (qname[:32], qtype_name(qtype), PLAINTEXT_FALLBACK[0]))
        return resp
    except Exception:
        _stats["error"] += 1
        log("失败  %-32s %-5s  所有上游不可用" % (qname[:32], qtype_name(qtype)))
        return None


# ------------------------------------------------- DNS 服务
def is_private_client(addr):
    """仅允许本机与私有网段客户端(避免被当作开放解析器滥用)"""
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return False
    return ip.is_loopback or ip.is_private or ip.is_link_local


class DnsHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        if len(data) < 12:
            return
        if not ALLOW_SUBNET and not is_private_client(self.client_address[0]):
            log("拒绝非内网来源: %s" % self.client_address[0])
            return
        try:
            txid = data[0:2]
            qname, off = parse_qname(data, 12)
            qtype, qclass = struct.unpack(">HH", data[off:off + 4])
        except Exception as e:
            log("解析查询失败: %s" % e)
            return

        key = (qname.lower(), qtype)
        now = time.time()
        with _cache_lock:
            hit = _cache.get(key)
            if hit and now - hit[0] < CACHE_TTL:
                sock.sendto(txid + hit[1][2:], self.client_address)
                return

        resp = resolve(data, qname, qtype, qclass)
        if resp is None:
            servfail = txid + struct.pack(">HHHHH", 0x8182, 1, 0, 0, 0) + data[12:]
            sock.sendto(servfail, self.client_address)
            return

        with _cache_lock:
            _cache[key] = (now, resp)
        sock.sendto(txid + resp[2:], self.client_address)


class DnsServer(socketserver.ThreadingUDPServer):
    allow_reuse_address = True
    daemon_threads = True


# ------------------------------------------------- 命令行
def selftest():
    log("=== 自检: DoH(IP直连) 解析 %d 个域名 ===" % len(PROBE_DOMAINS))
    cases = [(d, 1) for d in PROBE_DOMAINS]
    ok = 0
    for name, qt in cases:
        wq = build_dns_query(name, qt, txid=0x1234)
        r = resolve(wq, name, qt, 1)
        if r:
            ok += 1
            log("      -> %d 字节应答" % len(r))
    log("自检完成: %d/%d 成功" % (ok, len(cases)))
    return 0 if ok == len(cases) else 1


def main():
    global LISTEN_HOST, LISTEN_PORT, ALLOW_SUBNET, PROBE_DOMAINS

    setup_stdio()

    ap = argparse.ArgumentParser(
        description="本地加密DNS转发 (DoH -> UDP DNS), 用于绕开校园网明文DNS拦截")
    ap.add_argument("--selftest", action="store_true", help="只做上游连通性自检后退出")
    ap.add_argument("--host", default=LISTEN_HOST, help="监听地址 (默认 127.0.0.1)")
    ap.add_argument("--port", type=int, default=LISTEN_PORT,
                    help="监听端口 (默认 5399; 供系统DNS使用需 53, 要管理员权限)")
    ap.add_argument("--allow-subnet", action="store_true",
                    help="允许局域网内其它设备(手机/平板)使用本解析器")
    ap.add_argument("--probe", default="",
                    help="自检域名, 逗号分隔 (默认使用脚本内的 PROBE_DOMAINS)")
    args = ap.parse_args()

    LISTEN_HOST = args.host
    LISTEN_PORT = args.port
    ALLOW_SUBNET = args.allow_subnet

    if args.probe.strip():
        PROBE_DOMAINS = [d.strip() for d in args.probe.split(",") if d.strip()]

    if args.selftest:
        return selftest()

    log("=" * 64)
    log("本地加密DNS转发已启动  ->  %s:%d" % (LISTEN_HOST, LISTEN_PORT))
    log("上游: " + ", ".join("%s(%s)" % (ip, lb) for ip, lb in DOH_UPSTREAMS))
    log("明文兜底: %s:%d" % PLAINTEXT_FALLBACK)
    if ALLOW_SUBNET:
        log("已允许局域网其它设备使用(仅私有网段)")
    log("系统 DNS 指向 %s 即可生效;  Ctrl+C 停止" % LISTEN_HOST)
    log("=" * 64)

    try:
        server = DnsServer((LISTEN_HOST, LISTEN_PORT), DnsHandler)
    except PermissionError:
        log("错误: 绑定 %s:%d 被拒绝。端口 53 需要管理员权限!" % (LISTEN_HOST, LISTEN_PORT))
        log("      请以管理员身份运行, 或改用 --port 5399")
        return 2
    except OSError as e:
        log("错误: 无法绑定 %s:%d -> %s" % (LISTEN_HOST, LISTEN_PORT, e))
        log("      端口 53 可能已被系统保留。可尝试:")
        log("      netsh int ipv4 add excludedportrange protocol=udp startport=53 numberofports=1")
        return 2

    threading.Thread(target=selftest, daemon=True).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("已停止. 统计: %s" % _stats)
    return 0


if __name__ == "__main__":
    sys.exit(main())
