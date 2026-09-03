#!/usr/bin/env python3
"""分发安全门禁：确保打包产物中不含任何 API Key / 机密。

检查两层：
1. 本机已知真实密钥（钥匙串 agent_meter 全部账户 + 本机 agent 配置里的 key）不得出现在产物中
2. 通用密钥特征（sk- 前缀、bigmodel id.secret 形态）不得出现在产物中

用法: check_no_secrets.py <目录或文件>...
命中即退出码 1（打包流水线据此中止）。
"""
import subprocess
import sys
import os
import re
import json
import pathlib

from pathlib import Path

def gather_known_secrets() -> set:
    secrets = set()

    # 1) 钥匙串 agent_meter 服务下的已知账户
    accounts = ["glm_api_key"]
    for t in ("glm", "codex", "claude", "deepseek", "moonshot"):
        accounts.append(f"agent.{t}")
    # custom.* 账户名不可枚举，扫描钥匙串 dump 兜底
    try:
        dump = subprocess.run(["security", "dump-keychain"], capture_output=True, text=True, timeout=30).stdout
        for m in re.finditer(r'"acct"<blob>="(custom\.[0-9A-Fa-f-]{36})"', dump):
            accounts.append(m.group(1))
    except Exception:
        pass
    for acct in accounts:
        try:
            r = subprocess.run(
                ["security", "find-generic-password", "-s", "agent_meter", "-a", acct, "-w"],
                capture_output=True, text=True, timeout=10,
            )
            if r.returncode == 0 and r.stdout.strip():
                secrets.add(r.stdout.strip())
        except Exception:
            pass

    # 2) 本机 agent 配置（zcode config）里的所有 apiKey
    zcfg = pathlib.Path.home() / ".zcode/v2/config.json"
    try:
        cfg = json.loads(zcfg.read_text())
        def walk(obj):
            if isinstance(obj, dict):
                for k, v in obj.items():
                    if k.lower() == "apikey" and isinstance(v, str) and len(v) >= 12:
                        secrets.add(v)
                    else:
                        walk(v)
            elif isinstance(obj, list):
                for item in obj:
                    walk(item)
        walk(cfg)
    except Exception:
        pass

    return {s for s in secrets if len(s) >= 12}

# 通用密钥特征
GENERIC_PATTERNS = [
    re.compile(rb"sk-kimi-[A-Za-z0-9_-]{10,}"),
    re.compile(rb"sk-[A-Za-z0-9]{28,}"),          # openai/deepseek/moonshot 形态
]
ID_SECRET_PATTERN = re.compile(rb"[A-Za-z0-9]{16,}\.[A-Za-z0-9]{16,}")  # bigmodel id.secret 形态
GENERIC_PATTERNS.append(ID_SECRET_PATTERN)

def scan(target: Path, known: set) -> list:
    hits = []
    files = [target] if target.is_file() else [p for p in target.rglob("*") if p.is_file()]
    for f in files:
        try:
            data = f.read_bytes()
        except Exception:
            continue
        for secret in known:
            if secret.encode() in data:
                hits.append((str(f), f"已知密钥（{secret[:6]}…{secret[-4:]}）"))
        for pat in GENERIC_PATTERNS:
            for m in pat.finditer(data):
                if pat is ID_SECRET_PATTERN:
                    # 排除代码标识符误报：真实 id.secret 两侧必含数字
                    parts = m.group().split(b".")
                    if len(parts) == 2 and all(p.isalpha() for p in parts):
                        continue
                hits.append((str(f), f"密钥特征 {pat.pattern.decode()} → {m.group()[:12]!r}…"))
    return hits

def main():
    if len(sys.argv) < 2:
        print("用法: check_no_secrets.py <目录或文件>...")
        sys.exit(2)
    known = gather_known_secrets()
    print(f"  · 已加载本机已知密钥 {len(known)} 个用于比对")

    hits = []
    checked = 0
    for arg in sys.argv[1:]:
        p = Path(arg)
        if not p.exists():
            continue
        files = [p] if p.is_file() else [x for x in p.rglob("*") if x.is_file()]
        checked += len(files)
        hits.extend(scan(p, known))

    print(f"  · 已扫描 {checked} 个文件")
    if hits:
        print("✗✗✗ 安全门禁拦截：产物中发现疑似密钥！")
        for f, why in hits[:10]:
            print(f"   {f}: {why}")
        sys.exit(1)
    print("  ✓ 未发现任何密钥，产物安全")

if __name__ == "__main__":
    main()
