#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
静默启动器 —— 由启动文件夹的快捷方式调用 (pythonw.exe, 无控制台窗口)

职责:
  1. 用当前解释器启动同目录下的 doh_dns.py
  2. 把它的输出追加写入 relay.log
  3. 日志超过 2MB 时自动轮转, 避免无限增长
  4. 不做任何命令行引号拼接, 从根本上避免转义问题
"""

import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
RELAY = os.path.join(HERE, "doh_dns.py")
LOG = os.path.join(HERE, "relay.log")
MAX_LOG = 2 * 1024 * 1024      # 2MB

# 让子进程能找到同目录的模块
env = os.environ.copy()
env["PYTHONIOENCODING"] = "utf-8"
env["PYTHONPATH"] = HERE + os.pathsep + env.get("PYTHONPATH", "")

# 无窗口运行子进程(即便本进程是 pythonw 也确保没有黑框)
CREATE_NO_WINDOW = 0x08000000 if os.name == "nt" else 0


def rotate_log():
    try:
        if os.path.exists(LOG) and os.path.getsize(LOG) > MAX_LOG:
            bak = LOG + ".1"
            if os.path.exists(bak):
                os.remove(bak)
            os.replace(LOG, bak)
    except OSError:
        pass


def main():
    if not os.path.exists(RELAY):
        return 1

    rotate_log()

    # --host 0.0.0.0: 同时服务本机与(可选的)局域网设备
    cmd = [sys.executable, RELAY, "--host", "0.0.0.0", "--port", "53"]
    # 若安装时勾选了共享, 这里会带上参数
    if "--share" in sys.argv:
        cmd.append("--allow-subnet")
    # 透传自检域名(安装脚本写入快捷方式参数)
    if "--probe" in sys.argv:
        try:
            cmd += ["--probe", sys.argv[sys.argv.index("--probe") + 1]]
        except IndexError:
            pass

    with open(LOG, "a", encoding="utf-8", errors="replace") as logf:
        logf.write("\n===== launcher start %s =====\n" % time.strftime("%Y-%m-%d %H:%M:%S"))
        logf.flush()
        try:
            p = subprocess.Popen(
                cmd,
                cwd=HERE,
                stdout=logf,
                stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL,
                env=env,
                creationflags=CREATE_NO_WINDOW,
            )
        except Exception as e:
            logf.write("launcher: 启动失败 %r\n" % (e,))
            logf.flush()
            return 1

        logf.write("launcher: pid=%d\n" % p.pid)
        logf.flush()
        # 等它退出再结束自己, 这样日志文件句柄一直有效
        rc = p.wait()
        logf.write("launcher: 服务退出, 返回码 %s\n" % rc)
        logf.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
