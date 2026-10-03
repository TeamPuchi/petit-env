#!/usr/bin/env python3
"""最初から載せる道具（preload-tools.txt）が、本当に載る形になっているかを確かめる（2026-10-03）。

claude と同じやり方で MCP 設定（gen-mcp-config.sh が書く <id>.json）の各サーバーを stdio で起動し、
道具の一覧（tools/list）だけを読む。claude は呼ばない（お金は掛からない）。何も書かない。

確かめること:
  - 各サーバーの env の PETIT_PRELOAD_TOOLS に書いた名前が、そのサーバーに実在する道具か
    （道具の名前を変えた・消したのに一覧が古いまま、を見つける）
  - その道具に `_meta` の `anthropic/alwaysLoad: true` が付いているか（サーバーが一覧を読めているか）
  - 一覧に無い道具に付いていないか
を見て、食い違いがあれば終了コード 1。`--sizes` で道具ごとの説明の重さ（文字数）も出す。

Usage（コンテナの中。mcp が入っている家 API の venv の python で動かす）:
    /opt/petit/repos/m5-petit-app/.venv/bin/python /opt/petit/scripts/check-preload-tools.py \
        /opt/petit/run/mcp/mio.json [--sizes] [--json]
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys

ALWAYS_LOAD = "anthropic/alwaysLoad"


async def list_tools(spec: dict, timeout: float) -> list[dict]:
    from mcp import ClientSession
    from mcp.client.stdio import StdioServerParameters, stdio_client

    # claude は MCP サーバーに自分の環境変数をそのまま引き継ぐ（秘密もコンテナの env から届く）。同じにする
    params = StdioServerParameters(command=spec["command"], args=spec.get("args") or [],
                                   env={**os.environ, **(spec.get("env") or {})})
    out: list[dict] = []
    with open(os.devnull, "w") as devnull:
        async with stdio_client(params, errlog=devnull) as (read, write):
            async with ClientSession(read, write) as session:
                await asyncio.wait_for(session.initialize(), timeout)
                cursor = None
                while True:
                    kw = {"params": {"cursor": cursor}} if cursor else {}
                    res = await asyncio.wait_for(session.list_tools(**kw), timeout)
                    for t in res.tools:
                        d = t.model_dump(by_alias=True, exclude_none=True)
                        out.append(d)
                    cursor = getattr(res, "next_cursor", None) or getattr(res, "nextCursor", None)
                    if not cursor:
                        break
    return out


def wanted(spec: dict) -> list[str]:
    raw = (spec.get("env") or {}).get("PETIT_PRELOAD_TOOLS", "")
    return [n.strip() for n in raw.split(",") if n.strip()]


def size_of(tool: dict) -> int:
    """claude に渡る説明の重さの目安（名前・説明・引数の形の JSON の文字数）。"""
    return len(json.dumps({k: tool.get(k) for k in ("name", "description", "inputSchema")}, ensure_ascii=False))


async def check(cfg: dict, timeout: float) -> tuple[list[str], dict]:
    problems: list[str] = []
    report: dict = {}
    for server, spec in (cfg.get("mcpServers") or {}).items():
        try:
            tools = await list_tools(spec, timeout)
        except Exception as e:  # 起動できないサーバーは、それ自体を食い違いとして出す
            problems.append(f"{server}: 起動できない（{type(e).__name__}: {e}）")
            continue
        names = {t["name"] for t in tools}
        marked = {t["name"] for t in tools if (t.get("_meta") or {}).get(ALWAYS_LOAD) is True}
        want = wanted(spec)
        for n in want:
            if n not in names:
                problems.append(f"{server}: 一覧の {n} という道具が無い（名前が変わった・消えた？）")
            elif n not in marked:
                problems.append(f"{server}: {n} に {ALWAYS_LOAD} が付いていない（サーバーが PETIT_PRELOAD_TOOLS を読めていない？）")
        for n in sorted(marked - set(want)):
            problems.append(f"{server}: 一覧に無い {n} に {ALWAYS_LOAD} が付いている")
        report[server] = {
            "server_always_load": bool(spec.get("alwaysLoad")),
            "tools": [{"name": t["name"], "preload": t["name"] in marked, "chars": size_of(t)} for t in tools],
        }
    return problems, report


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("config", help="gen-mcp-config.sh が書いた MCP 設定（例 /opt/petit/run/mcp/mio.json）")
    ap.add_argument("--sizes", action="store_true", help="道具ごとの説明の文字数も出す")
    ap.add_argument("--json", action="store_true", help="結果を JSON で出す")
    ap.add_argument("--timeout", type=float, default=90.0, help="サーバー1つの起動と一覧の待ち時間（秒）")
    args = ap.parse_args()
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    with open(args.config, encoding="utf-8") as f:
        cfg = json.load(f)
    problems, report = asyncio.run(check(cfg, args.timeout))

    if args.json:
        print(json.dumps({"problems": problems, "servers": report}, ensure_ascii=False, indent=1))
    else:
        for server, r in report.items():
            pre = [t for t in r["tools"] if t["preload"] or r["server_always_load"]]
            print(f"{server}: 道具 {len(r['tools'])}・最初から載せる {len(pre)}"
                  f"{'（サーバーごと alwaysLoad）' if r['server_always_load'] else ''}"
                  f"・説明 計 {sum(t['chars'] for t in r['tools'])} 字（載せる分 {sum(t['chars'] for t in pre)} 字）")
            if args.sizes:
                for t in sorted(r["tools"], key=lambda t: -t["chars"]):
                    print(f"  {'*' if t['preload'] else ' '} {t['chars']:6d} {t['name']}")
        for p in problems:
            print(f"NG {p}")
        if not problems:
            print("ok 一覧の道具はすべて実在し、最初から載る印が付いている")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
