#!/usr/bin/env python3
"""校验 Vault 三层布局的不变式 (只读)。

把 docs/vault/kv_tier_model.md 里那张分层表变成可执行断言:

  ① 公共服务   kv/data/CICD, openclaw, action-runner   三环境共读, 只读不可改
  ② 基础凭据   kv/data/CICD/<env> + /iac_state          仅本环境可读, 只读
  ③ 环境业务   kv/data/<env>/*                         仅本环境可读写 (prod 无 delete)

只调用 `vault policy read`, 不做任何写操作, 也不读取任何密钥值。

用法:
    export VAULT_ADDR=https://vault.svc.plus
    export VAULT_TOKEN=<有 sys/policy 读权限的 token>
    ./scripts/vault/vault_layout_verify.py

退出码: 0 = 全部通过; 1 = 有断言失败 (可用于 CI 门禁)。
"""
import os
import re
import subprocess
import sys

ENVS = ["sit", "uat", "prod"]
POLICY_FMT = "github-actions-platform-ops-toolkit-{env}"

SHARED_READ_PATHS = ["kv/data/CICD", "kv/data/openclaw", "kv/data/action-runner"]
WRITE_CAPS = {"create", "update", "delete", "patch", "sudo"}

GREEN, RED, YELLOW, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[0m"
if not sys.stdout.isatty():
    GREEN = RED = YELLOW = RESET = ""

failures = []
warnings = []


def read_policy(name):
    r = subprocess.run(
        ["vault", "policy", "read", name],
        capture_output=True, text=True,
        env={**os.environ, "VAULT_ADDR": os.environ.get("VAULT_ADDR", "https://vault.svc.plus")},
    )
    if r.returncode != 0:
        return None
    return r.stdout


def parse_policy(text):
    """-> {path: set(capabilities)}"""
    out = {}
    for m in re.finditer(
        r'path\s+"([^"]+)"\s*\{[^}]*?capabilities\s*=\s*\[([^\]]*)\]', text, re.S
    ):
        path = m.group(1)
        caps = {c.strip().strip('"') for c in m.group(2).split(",") if c.strip()}
        out[path] = caps
    return out


def check(ok, label, detail=""):
    if ok:
        print(f"  {GREEN}PASS{RESET}  {label}")
    else:
        print(f"  {RED}FAIL{RESET}  {label}" + (f"\n          {detail}" if detail else ""))
        failures.append(label)


def warn(label, detail=""):
    print(f"  {YELLOW}WARN{RESET}  {label}" + (f"\n          {detail}" if detail else ""))
    warnings.append(label)


def main():
    policies = {}
    for env in ENVS:
        name = POLICY_FMT.format(env=env)
        text = read_policy(name)
        if text is None:
            print(f"{RED}无法读取 policy {name}{RESET}", file=sys.stderr)
            sys.exit(2)
        policies[env] = parse_policy(text)

    for env in ENVS:
        p = policies[env]
        print(f"\n=== {POLICY_FMT.format(env=env)} ===")

        # --- 第 ① 层: 公共服务, 共读且只读 ---
        for sp in SHARED_READ_PATHS:
            caps = p.get(sp, set())
            check("read" in caps, f"① 可读公共服务路径 {sp}")
            bad = caps & WRITE_CAPS
            check(not bad, f"① {sp} 只读不可改",
                  f"发现写权限: {sorted(bad)}" if bad else "")

        # --- 第 ② 层: 基础凭据, 仅本环境, 只读 ---
        own = f"kv/data/CICD/{env}"
        caps = p.get(own, set())
        check("read" in caps, f"② 可读本环境基础凭据 {own}")
        bad = caps & WRITE_CAPS
        check(not bad, f"② {own} 只读不可改",
              f"发现写权限: {sorted(bad)}" if bad else "")

        # 关键隔离断言: 读不到其他环境的基础凭据
        for other in ENVS:
            if other == env:
                continue
            other_path = f"kv/data/CICD/{other}"
            leaked = other_path in p
            check(not leaked, f"② 读不到 {other} 的基础凭据",
                  f"策略中出现了 {other_path}: {sorted(p.get(other_path, set()))}" if leaked else "")

        # Terraform state credentials have their own contract and must remain
        # isolated by environment just like provider credentials.
        own_state = f"kv/data/CICD/{env}/iac_state"
        state_caps = p.get(own_state, set())
        check("read" in state_caps, f"② 可读本环境 Terraform state 凭据 {own_state}")
        check(not (state_caps & WRITE_CAPS), f"② {own_state} 只读不可改",
              f"发现写权限: {sorted(state_caps & WRITE_CAPS)}" if state_caps & WRITE_CAPS else "")
        for other in ENVS:
            if other == env:
                continue
            other_state = f"kv/data/CICD/{other}/iac_state"
            leaked = other_state in p
            check(not leaked, f"② 读不到 {other} 的 Terraform state 凭据",
                  f"策略中出现了 {other_state}: {sorted(p.get(other_state, set()))}" if leaked else "")

        # 通配符不能把子路径一并放行 (kv/data/CICD/* 会击穿②的隔离)
        wildcard = "kv/data/CICD/*"
        check(wildcard not in p, "② 未使用 kv/data/CICD/* 通配符",
              "该通配符会让本环境读到所有环境的基础凭据" if wildcard in p else "")

        # --- 第 ③ 层: 环境业务密钥, 仅本环境, 可读写 ---
        own_env = f"kv/data/{env}/*"
        caps = p.get(own_env, set())
        check("read" in caps and "create" in caps and "update" in caps,
              f"③ 可读写本环境业务密钥 {own_env}")

        if env == "prod":
            check("delete" not in caps, "③ prod 无 delete (kv/data)",
                  f"当前: {sorted(caps)}" if "delete" in caps else "")
            meta = p.get("kv/metadata/prod/*", set())
            check("delete" not in meta, "③ prod metadata 无 delete (永久销毁所有版本)",
                  f"当前: {sorted(meta)}" if "delete" in meta else "")

        for other in ENVS:
            if other == env:
                continue
            other_path = f"kv/data/{other}/*"
            leaked = other_path in p
            check(not leaked, f"③ 读不到 {other} 的业务密钥",
                  f"策略中出现了 {other_path}" if leaked else "")

        # --- 提示项 ---
        if "kv/data/WEB_SAAS" in p and env in ("uat", "prod"):
            warn(f"{env} 仍可读共享的 kv/data/WEB_SAAS",
                 "uat 与 prod 共用同一套数据库口令; 计划迁往 kv/data/<env>/web-saas")

    print("\n" + "=" * 60)
    if failures:
        print(f"{RED}{len(failures)} 条断言失败{RESET}")
        for f in failures:
            print(f"  - {f}")
    else:
        print(f"{GREEN}全部断言通过{RESET}")
    if warnings:
        print(f"{YELLOW}{len(warnings)} 条提示{RESET}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
