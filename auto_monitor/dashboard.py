#!/usr/bin/env python3
"""
iBase 开发环境监控 + 自愈一体工具。

模式:
  python3 dashboard.py                    # TUI 只读看板
  python3 dashboard.py --watch            # TUI 看板 + 自愈 (失败重试)
  python3 dashboard.py --daemon           # 静默守护进程 (日志 + 自愈)
  python3 dashboard.py --once             # 单次快照打印

目标环境: 20260428175239, 监控节点: node5 / node8
"""

import json, logging, os, ssl, subprocess, sys, time, functools, traceback
from logging.handlers import RotatingFileHandler
from datetime import datetime
from typing import Optional
from urllib.request import Request, urlopen

# ---- config ----

BASE_URL = "https://127.0.0.1:32206"
ENV_ID = "20260428175239"

# 从环境变量注入 (安全, 不在文件/日志中明文存储)
_ACCOUNT = ""
_PASSWORD = ""

def _cred(which: str) -> str:
    """获取凭据, 不存在则报错退出"""
    val = globals()[f"_{which}"]
    if not val:
        print(f"错误: 请设置环境变量 IBASE_{which} (或传入 --{which.lower()})", file=sys.stderr)
        sys.exit(1)
    return val
WATCH_NODES = ["node5", "node8"]
GPU_TO_CPU = {1: 24, 2: 48, 4: 96, 6: 144, 8: 190}
MAX_GPU = 8

ssl_ctx = ssl.create_default_context()
ssl_ctx.check_hostname = False
ssl_ctx.verify_mode = ssl.CERT_NONE

# ---- retry ----

def with_retry(max_tries: int = 3, base_delay: float = 2, backoff: float = 2):
    """指数退避重试装饰器"""
    def deco(fn):
        @functools.wraps(fn)
        def wrapper(*a, **kw):
            delay = base_delay
            last_err = None
            for attempt in range(1, max_tries + 1):
                try:
                    return fn(*a, **kw)
                except Exception as e:
                    last_err = e
                    if attempt < max_tries:
                        print(f"    ⚠ {fn.__name__} 第{attempt}次失败: {e}, {delay:.0f}s后重试...")
                        time.sleep(delay)
                        delay *= backoff
            raise last_err
        return wrapper
    return deco

# ---- ApiClient ----

class ApiClient:
    def __init__(self):
        self._token: Optional[str] = None
        self._last_login: float = 0

    def _req(self, url: str, method: str = "GET", body: dict = None) -> dict:
        hdrs = {"Content-Type": "application/json"}
        if self._token:
            hdrs["X-Auth-Token"] = self._token
        data = json.dumps(body).encode() if body else None
        with urlopen(Request(url, data=data, headers=hdrs, method=method), context=ssl_ctx, timeout=15) as r:
            return json.loads(r.read().decode())

    def session_valid(self) -> bool:
        """快速校验 token 是否有效"""
        if not self._token:
            return False
        try:
            resp = self._req(f"{BASE_URL}/api/ibase/v1/login")
            return resp.get("flag", False)
        except Exception:
            return False

    @with_retry(max_tries=3, base_delay=3)
    def ensure_login(self):
        if self._token and self.session_valid() and time.time() - self._last_login < 3000:
            return
        # SM2 pubkey
        data = self._req(f"{BASE_URL}/api/ibase/v1/system/secret")
        r = data["resData"]
        pubkey = r.get("secret", "") if isinstance(r, dict) else str(r)
        from gmssl.sm2 import CryptSM2
        sm2 = CryptSM2(public_key=pubkey, private_key="")
        enc = "04" + sm2.encrypt(_cred("PASSWORD").encode()).hex()
        data = self._req(f"{BASE_URL}/api/ibase/v1/login", "POST", {"account": _cred("ACCOUNT"), "password": enc})
        if not data.get("flag"):
            raise RuntimeError(f"登录失败: {data.get('errMessage')}")
        self._token = data["resData"]["token"]
        self._last_login = time.time()

    def get(self, url: str) -> dict:
        self.ensure_login()
        return self._req(url)

    def get_records(self, url: str) -> list:
        resp = self.get(url)
        if not resp.get("flag"):
            return []
        rd = resp.get("resData")
        if not rd:
            return []
        for k in ("data", "records"):
            if k in rd and isinstance(rd[k], list):
                return rd[k]
        return []

# ---- ClusterSnapshot ----

class ClusterSnapshot:
    def __init__(self):
        self.api = ApiClient()
        self.nodes: dict[str, dict] = {}
        self.containers: list[dict] = []
        self.on_node: dict[str, list] = {}
        self.errors: list[str] = []
        self._ts = time.time()

    def refresh(self):
        try:
            self._fetch()
            self._ts = time.time()
            self.errors.clear()
        except Exception as e:
            self.errors.append(str(e))

    def _fetch(self):
        groups = self.api.get_records(
            f"{BASE_URL}/api/iresource/v1/node-group?page=-1&pageSize=-1&groupStatus=1"
            "&groupLabel=usual,develop,train&nodeGroup=1"
        )
        all_nodes = {}
        for g in groups:
            gid = g.get("groupId")
            if not gid:
                continue
            for n in self.api.get_records(
                f"{BASE_URL}/api/iresource/v1/node?page=1&pageSize=999&getUsage=1&groupId={gid}"
            ):
                name = n.get("nodeName", "")
                if name in WATCH_NODES:
                    all_nodes[name] = {
                        "gpuTotal": n.get("acceleratorCard", 0),
                        "gpuUsed": n.get("acceleratorCardUsage", 0),
                        "gpuFree": n.get("acceleratorCard", 0) - n.get("acceleratorCardUsage", 0),
                        "gpuType": n.get("cardType", "?"),
                        "cpuTotal": n.get("cpu", 0),
                        "cpuUsed": n.get("cpuUsage", 0),
                        "cpuFree": n.get("cpu", 0) - n.get("cpuUsage", 0),
                        "status": n.get("nodeStatus", "?"),
                        "groupName": n.get("groupName", "?"),
                    }
        self.nodes = all_nodes

        records = self.api.get_records(f"{BASE_URL}/api/iresource/v1/work-platform?page=1&pageSize=10")
        parsed = []
        node_map = {nd: [] for nd in WATCH_NODES}
        for c in records:
            node_name = (c.get("nodeIpList") or [""])[0]
            gpu = c.get("acceleratorCard", 0)
            if node_name not in WATCH_NODES and gpu == 0:
                continue
            if node_name not in WATCH_NODES:
                node_name = "—"
            item = {
                "id": c.get("wpName", ""), "uuid": c.get("wpId", ""),
                "node": node_name, "status": c.get("wpStatus", ""),
                "gpu": gpu, "gpuType": c.get("acceleratorCardType", ""),
                "cpu": c.get("cpu", 0),
                "image": (c.get("image") or "").split("/")[-1],
                "started": (c.get("startTime") or "")[:16],
                "created": (c.get("createDateTime") or "")[:16],
            }
            parsed.append(item)
            if node_name in node_map:
                node_map[node_name].append(item)
        self.containers = parsed
        self.on_node = node_map

    @property
    def total_gpu_allocated(self): return sum(c["gpu"] for c in self.containers if c["status"] == "Running")
    @property
    def max_gpu_container(self):
        r = [c for c in self.containers if c["status"] == "Running"]
        return max(r, key=lambda c: c["gpu"]) if r else None
    @property
    def has_8gpu_container(self):
        return any(c["gpu"] == 8 and c["status"] == "Running" for c in self.containers)
    def env_info(self, env_id):
        for c in self.containers:
            if c["id"] == env_id:
                return c
        return None


# ---- Healer (自愈逻辑) ----

class Healer:
    def __init__(self):
        self.snap = ClusterSnapshot()
        self.logger = logging.getLogger("healer")
        self._last_action = 0.0

    def best_node(self) -> tuple[str, int, int]:
        self.snap.refresh()
        nodes = self.snap.nodes
        ordered = [x for x in WATCH_NODES if x in nodes]
        for name in ordered + [x for x in sorted(nodes) if x not in ordered]:
            n = nodes[name]
            if n["status"] != "ready":
                continue
            free = n["gpuFree"]
            if free <= 0:
                continue
            gpu = min(free, MAX_GPU)
            cpu = min(GPU_TO_CPU.get(gpu, gpu * 24), n["cpuFree"])
            return (name, gpu, cpu)
        return ("", 0, 0)

    def check_and_heal(self) -> Optional[str]:
        self.snap.refresh()
        info = self.snap.env_info(ENV_ID)

        if info and info["status"] == "Running":
            if self.snap.has_8gpu_container:
                return None  # all good
            # 有容器但没有8卡 → 触发重启
            action = "no_8gpu"
        else:
            status = info["status"] if info else "missing"
            if time.time() - self._last_action < 120:
                return f"waiting ({status})"
            action = f"restart ({status})"

        if time.time() - self._last_action < 120:
            return f"cooldown ({action})"

        node, gpu, cpu = self.best_node()
        if not node or gpu <= 0:
            return "no_gpu_available"

        self._last_action = time.time()
        ok = self._do_restart(node, gpu, cpu)
        return f"restarted:{node} GPU={gpu}" if ok else "restart_failed"

    @with_retry(max_tries=3, base_delay=5, backoff=2)
    def _do_restart(self, node: str, gpu: int, cpu: int) -> bool:
        return _playwright_restart(ENV_ID, gpu, cpu)


# ---- Playwright 启动逻辑 ----

def _playwright_restart(env_id: str, gpu: int, cpu: int) -> bool:
    """Playwright: 停止 → 启动(带资源配置)"""
    try:
        from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout
    except ImportError:
        raise RuntimeError("playwright 未安装")

    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=True, args=["--ignore-certificate-errors", "--allow-insecure-localhost"])
        page = browser.new_page()
        page.set_viewport_size({"width": 1920, "height": 1080})
        try:
            # login
            page.goto(f"{BASE_URL}/index.html#/login", timeout=60000)
            page.wait_for_load_state("networkidle", timeout=30000)
            time.sleep(2)
            page.locator('input[placeholder="用户名"]').fill(_cred("ACCOUNT"))
            page.locator('input[placeholder="密码"]').fill(_cred("PASSWORD"))
            page.locator('button:has-text("登录")').click()
            time.sleep(3)
            try:
                btn = page.locator('button:has-text("确定")')
                if btn.count() and btn.first.is_visible(timeout=2000):
                    btn.first.click()
                    time.sleep(1)
            except PWTimeout:
                pass

            # goto developEnv
            page.goto(f"{BASE_URL}/index.html#/developEnv", timeout=60000)
            page.wait_for_load_state("networkidle", timeout=30000)
            time.sleep(3)

            # stop if running
            _pw_click_dropdown(page, env_id, "停止")
            time.sleep(3)
            try:
                btn = page.locator('.el-message-box button:has-text("确定")')
                if btn.count():
                    btn.first.click()
                    time.sleep(2)
            except Exception:
                pass

            # wait for stop
            for _ in range(12):
                api = ApiClient()
                api.ensure_login()
                records = api.get_records(f"{BASE_URL}/api/iresource/v1/work-platform?page=1&pageSize=10")
                running = any(r.get("wpName") == env_id and r.get("wpStatus") == "Running" for r in records)
                if not running:
                    break
                time.sleep(5)

            time.sleep(3)

            # start with GPU preset
            _pw_click_dropdown(page, env_id, "启动")
            time.sleep(3)
            _pw_close_announce(page)
            preset = {1: "24/1", 2: "48/2", 4: "96/4", 6: "144/6", 8: "190/8"}.get(gpu)
            if preset:
                page.evaluate(f"""() => {{
                    for (const w of document.querySelectorAll('.el-dialog__wrapper'))
                        if (w.style.display !== 'none')
                            for (const r of w.querySelectorAll('input[type="radio"]'))
                                {{ const lb = r.closest('label');
                                  if (lb && lb.textContent.includes('{preset}')) {{ r.click(); return; }} }}
                }}""")
                time.sleep(1)
            page.evaluate("""() => {
                for (const w of document.querySelectorAll('.el-dialog__wrapper'))
                    if (w.style.display !== 'none') {
                        const f = w.querySelector('.el-dialog__footer');
                        if (!f) continue;
                        const b = f.querySelector('button.el-button--primary');
                        if (b && !b.disabled) { b.click(); return; }
                    }
            }""")
            time.sleep(5)

            # verify
            for i in range(30):
                api = ApiClient()
                api.ensure_login()
                records = api.get_records(f"{BASE_URL}/api/iresource/v1/work-platform?page=1&pageSize=10")
                for r in records:
                    if r.get("wpName") == env_id and r.get("wpStatus") == "Running":
                        print(f"    启动成功: node={r.get('nodeIpList',['?'])[0]} GPU={r.get('acceleratorCard')} (wait {i+1}s)")
                        return True
                time.sleep(5)
            return False
        finally:
            browser.close()


def _pw_click_dropdown(page, row_id, item):
    row = page.locator(f'tr:has-text("{row_id}")').first
    row.scroll_into_view_if_needed()
    time.sleep(0.3)
    ops = row.locator('td:has-text("克隆")')
    ops.evaluate("""el => {
        for (const b of el.querySelectorAll('button'))
            if (b.getAttribute('aria-haspopup') === 'list') { b.click(); return true; }
        return false;
    }""")
    time.sleep(0.5)
    page.evaluate(f"""(txt) => {{
        for (const li of document.querySelectorAll('li.el-dropdown-menu__item'))
            if (li.textContent.includes(txt) && !li.classList.contains('is-disabled'))
                {{ li.click(); return true; }}
        return false;
    }}""", item)
    time.sleep(2)


def _pw_close_announce(page):
    page.evaluate("""() => {
        for (const w of document.querySelectorAll('.el-dialog__wrapper'))
            if (w.style.display !== 'none') {
                const t = w.querySelector('.el-dialog__title');
                if (t && t.textContent.includes('公告'))
                    { w.querySelector('.el-dialog__headerbtn')?.click(); return; }
            }
    }""")


# ---- TUI 渲染 ----

from rich.console import Console
from rich.table import Table
from rich.layout import Layout
from rich.panel import Panel
from rich.live import Live
from rich.text import Text
from rich import box

console = Console()

def _bar(used, total, w=10):
    if total == 0:
        return "━" * w
    return "█" * min(round(used / total * w), w) + "░" * (w - min(round(used / total * w), w))

def build_layout(snap: ClusterSnapshot, heal_msg: str = "") -> Layout:
    layout = Layout()
    layout.split_column(Layout(name="header", size=3), Layout(name="body"), Layout(name="footer", size=2))
    ts = datetime.now().strftime("%H:%M:%S")
    header = Table.grid(padding=(0, 2))
    header.add_row(
        Text("iBase 集群监控", style="bold cyan"),
        Text(f"{ts}", style="dim"),
        Text(f"容器:{len(snap.containers)} GPU:{snap.total_gpu_allocated}", style="green"),
    )
    layout["header"].update(Panel(header, style="cyan"))

    body = Layout()
    body.split_row(Layout(name="nodes", ratio=1), Layout(name="containers", ratio=1))
    layout["body"].update(body)

    from rich.columns import Columns
    panels = []
    for name in WATCH_NODES:
        n = snap.nodes.get(name)
        if n is None:
            panels.append(Panel(f"[red]{name}: ?[/]", title=name))
            continue
        content = (f"  GPU: [{ 'green' if n['gpuFree']>=4 else ('yellow' if n['gpuFree']>0 else 'red')}]{n['gpuFree']:2d}[/]/{n['gpuTotal']} {n['gpuType'][:12]}\n"
                   f"       {_bar(n['gpuUsed'], n['gpuTotal'])}\n"
                   f"  CPU: [green]{n['cpuFree']:3d}[/]/{n['cpuTotal']}\n"
                   f"       {_bar(n['cpuUsed'], n['cpuTotal'])}\n"
                   f"  状态: [{'green' if n['status']=='ready' else 'yellow'}]{n['status']}[/]\n"
                   f"  容器: [cyan]{len(snap.on_node.get(name, []))}[/]")
        panels.append(Panel(content, title=f"[bold]{name}[/]", border_style="cyan"))
    body["nodes"].update(Panel(Columns(panels, equal=True), title="[bold]节点状态[/]", border_style="blue"))

    ctable = Table(box=box.ROUNDED, header_style="bold cyan", padding=(0,1))
    for col in [("容器",16), ("节点",6), ("GPU",3), ("CPU",4), ("状态",8), ("启动时间",10)]:
        ctable.add_column(col[0], width=col[1], justify="right" if col[0] in ("GPU","CPU") else "left")
    if not snap.containers:
        ctable.add_row("[dim]—[/]","","","","","")
    for c in snap.containers:
        ctable.add_row(c["id"], c["node"],
            f"[{'bold green' if c['gpu']==8 else 'yellow'}]{c['gpu']}[/]", str(c["cpu"]),
            f"[{'green' if c['status']=='Running' else 'red'}]{c['status']}[/]", c["started"])
    body["containers"].update(Panel(ctable, title="[bold]容器列表[/]", border_style="blue"))

    footer = []
    if heal_msg:
        footer.append(Text(f"🩺 {heal_msg}", style="bold yellow" if "fail" in heal_msg else "green"))
    if snap.has_8gpu_container:
        footer.append(Text("✅ 8 GPU 容器", style="bold green"))
    elif snap.max_gpu_container:
        footer.append(Text(f"⚠ {snap.max_gpu_container['id']} 仅 {snap.max_gpu_container['gpu']} 卡", style="bold yellow"))
    else:
        footer.append(Text("⚠ 无运行容器", style="bold red"))
    tf = sum(n.get("gpuFree",0) for n in snap.nodes.values())
    ta = sum(n.get("gpuTotal",0) for n in snap.nodes.values())
    if ta:
        footer.append(Text(f"  GPU:{ta-tf}/{ta}", style="green" if tf>0 else "red"))
    footer.append(Text("  ".join(f"✗ {e}" for e in snap.errors[-2:]), style="red"))
    layout["footer"].update(Panel(Text("  ").join(footer), style="dim"))
    return layout


# ---- 模式: 只读 TUI ----

def run_tui(interval: int = 3):
    snap = ClusterSnapshot()
    snap.refresh()
    with Live(build_layout(snap), refresh_per_second=4, screen=True) as live:
        while True:
            snap.refresh()
            live.update(build_layout(snap))
            for _ in range(interval):
                time.sleep(1)

# ---- 模式: TUI + 自愈 ----

def run_watch(interval: int = 15):
    snap = ClusterSnapshot()
    healer = Healer()
    heal_msg = ""
    snap.refresh()
    with Live(build_layout(snap, heal_msg), refresh_per_second=4, screen=True) as live:
        tick = 0
        while True:
            snap.refresh()
            if tick % max(1, interval // 3) == 0:
                try:
                    msg = healer.check_and_heal()
                    heal_msg = msg or heal_msg
                except Exception as e:
                    heal_msg = f"error: {e}"
            live.update(build_layout(snap, heal_msg))
            tick += 1
            time.sleep(3)

# ---- 模式: 静默守护 (daemon) ----

def setup_logger(log_dir: str = None):
    logger = logging.getLogger("healer")
    logger.setLevel(logging.DEBUG)
    logger.handlers.clear()
    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s", datefmt="%Y-%m-%d %H:%M:%S")
    sh = logging.StreamHandler(sys.stdout)
    sh.setLevel(logging.INFO)
    sh.setFormatter(fmt)
    logger.addHandler(sh)
    if log_dir:
        os.makedirs(log_dir, exist_ok=True)
        fh = RotatingFileHandler(
            os.path.join(log_dir, "healer.log"),
            maxBytes=10 * 1024 * 1024,  # 10 MB
            backupCount=3,
            encoding="utf-8",
        )
        fh.setLevel(logging.DEBUG)
        fh.setFormatter(fmt)
        logger.addHandler(fh)
    return logger

def run_daemon(interval: int = 60):
    log = setup_logger(os.path.join(os.path.dirname(__file__), "logs"))
    healer = Healer()
    log.info("守护进程启动 env=%s nodes=%s", ENV_ID, WATCH_NODES)
    while True:
        try:
            msg = healer.check_and_heal()
            if msg:
                log.info("[%d] %s", int(time.time()), msg)
        except Exception as e:
            log.error("异常: %s", e)
            traceback.print_exc()
        time.sleep(interval)

# ---- 入口 ----

def main():
    global _ACCOUNT, _PASSWORD
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--once", action="store_true")
    p.add_argument("--watch", action="store_true", help="TUI + 自愈")
    p.add_argument("--daemon", action="store_true", help="静默守护进程")
    p.add_argument("--interval", type=int, default=0)
    p.add_argument("--account", default="", help="账号 (默认读 IBASE_ACCOUNT 环境变量)")
    p.add_argument("--password", default="", help="密码 (默认读 IBASE_PASSWORD 环境变量)")
    args = p.parse_args()

    _ACCOUNT = args.account or os.environ.get("IBASE_ACCOUNT", "")
    _PASSWORD = args.password or os.environ.get("IBASE_PASSWORD", "")
    if not _ACCOUNT or not _PASSWORD:
        print("请设置环境变量 IBASE_ACCOUNT 和 IBASE_PASSWORD", file=sys.stderr)
        print("  或传入 --account / --password", file=sys.stderr)
        sys.exit(1)

    if args.daemon:
        run_daemon(interval=args.interval or 60)
    elif args.watch:
        print("📊 iBase 监控 + 自愈, Ctrl+C 退出")
        time.sleep(1)
        run_watch(interval=args.interval or 15)
    elif args.once:
        snap = ClusterSnapshot()
        snap.refresh()
        console.clear()
        console.print(build_layout(snap))
    else:
        print(f"📊 iBase 集群监控 (只读), Ctrl+C 退出")
        time.sleep(1)
        run_tui(interval=args.interval or 3)


if __name__ == "__main__":
    main()
