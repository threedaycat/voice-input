"""用虚构数据渲染面板截图 docs/panel.png（不含任何真实转写）。
用法：python3 docs/demo/make_panel_png.py   需要 Google Chrome。"""
import json, os, random, subprocess, tempfile, datetime

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
random.seed(7)
today = datetime.date(2026, 9, 26)
MODELS = ["qwen3-asr-flash", "gemini-3-flash-preview", "gemini-2.5-flash", "local-qwen3-asr-1.7b"]
days, total_cost = [], 0
for i in range(13, -1, -1):
    d = (today - datetime.timedelta(i)).isoformat()
    bm = {}
    if i < 11:
        n = random.randint(40, 150)
        split = {"qwen3-asr-flash": 0.8, "gemini-3-flash-preview": 0.12, "gemini-2.5-flash": 0.06, "local-qwen3-asr-1.7b": 0.02}
        for m, p in split.items():
            c = round(n * p * random.uniform(0.6, 1.4))
            if c: bm[m] = {"count": c, "chars": c * 60, "secs": c * 17}
    cnt = sum(v["count"] for v in bm.values())
    cost = round(bm.get("qwen3-asr-flash", {"secs": 0})["secs"] * 0.00022 * 1.06, 4)
    total_cost += cost
    days.append({"date": d, "count": cnt, "chars": sum(v["chars"] for v in bm.values()),
                 "secs": sum(v["secs"] for v in bm.values()), "byModel": bm, "cost": cost})
t = days[-1]
models = [{"name": m, "calls": t["byModel"].get(m, {}).get("count", 0), "todayOk": t["byModel"].get(m, {}).get("count", 0),
           "limited": 0, "failed": 0, "cost": t["cost"] if m.startswith("qwen") else 0, "paid": m.startswith("qwen")} for m in MODELS]
data = {"items": [], "settings": {"models": MODELS, "knownModels": [], "devices": ["MacBook Pro 麦克风"], "mic": "", "keep": 10, "vocab": "", "trigger": "右 Command"},
        "stats": {"days": days, "total": {"count": sum(d["count"] for d in days), "chars": sum(d["chars"] for d in days),
                                          "secs": sum(d["secs"] for d in days)},
                  "estimated": False, "models": models,
                  "cost": {"today": t["cost"], "yesterday": days[-2]["cost"], "month": total_cost, "total": total_cost},
                  "today": t, "yesterday": days[-2]}}
html = open(os.path.join(ROOT, "hammerspoon/panel.html"), encoding="utf-8").read()
inject = ("<style>.tip{transition:none}</style><script>try{app.render(%s)}catch(e){document.title='ERR '+e.stack};"
          "setTimeout(()=>{document.querySelector('[data-tab=stats]').click();"
          "const cols=document.querySelectorAll('#chart .col');cols[cols.length-1].onmouseenter();},300)</script></body>"
          % json.dumps(data, ensure_ascii=False))
page = os.path.join(tempfile.mkdtemp(), "panel.html")
open(page, "w", encoding="utf-8").write(html.replace("</body>", inject, 1))
out = os.path.join(ROOT, "docs/panel.png")
if "--dom" in __import__("sys").argv:  # 排查用：打印渲染后的 DOM（出错时 <title> 里是报错）
    subprocess.run(["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "--headless=new", "--disable-gpu",
                    "--virtual-time-budget=2000", "--dump-dom", "file://" + page], stderr=subprocess.DEVNULL)
    raise SystemExit
subprocess.run(["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "--headless=new", "--disable-gpu",
                "--hide-scrollbars", "--force-device-scale-factor=2", "--window-size=900,640",
                "--virtual-time-budget=2000", f"--screenshot={out}", "file://" + page],
               check=True, stderr=subprocess.DEVNULL)
print(out)
