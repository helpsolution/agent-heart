#!/usr/bin/env python3
"""
cc_dashboard.py — локальный дашборд расхода токенов Claude Code.

Пересчитывает данные из ~/.claude/projects/**/*.jsonl и генерирует
самодостаточный dashboard.html с вкладками:
  • Обзор        — KPI, типы токенов, проекты, модели, main/subagent, дни
  • Все сессии   — сортируемая таблица всех сессий
  • Таймлайн     — хронология с человекочитаемыми названиями по дням

Запуск:
    python3 cc_dashboard.py                 # собрать dashboard.html и открыть
    python3 cc_dashboard.py --no-open        # просто собрать файл
    python3 cc_dashboard.py --serve          # локальный сервер, всегда свежие данные
    python3 cc_dashboard.py --serve --port 8899
    python3 cc_dashboard.py --since 2026-07-20

Зависимостей нет, только stdlib.
"""

import argparse
import html as _html
import json
import os
import sys
import webbrowser
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------- pricing ---
# Прайс-лист живёт в shared/prices.json — общий с нативным приложением.
# Не дублировать цифры здесь: при расхождении цен разъедутся два модуля.
PRICES_PATH = Path(__file__).resolve().parent.parent / "shared" / "prices.json"


def load_prices(path=PRICES_PATH):
    """{ключ-подстрока: (input, cache_write_5m, cache_read, output)} за 1M токенов."""
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        sys.exit(f"Не читается прайс-лист {path}: {e}")
    models = raw.get("models") or {}
    if not models:
        sys.exit(f"В прайс-листе {path} нет секции models.")
    out = {}
    for key, p in models.items():
        try:
            out[key] = (float(p["input"]), float(p["cacheWrite5m"]),
                        float(p["cacheRead"]), float(p["output"]))
        except (KeyError, TypeError, ValueError) as e:
            sys.exit(f"Битая запись '{key}' в {path}: {e}")
    return out


PRICES = load_prices()
UNKNOWN_MODELS = set()


def price_for(model):
    if not model:
        return None
    m = model.lower()
    for key in sorted(PRICES, key=len, reverse=True):
        if key in m:
            return PRICES[key]
    UNKNOWN_MODELS.add(model)
    return None


def transcript_roots():
    roots = []
    env = os.environ.get("CLAUDE_CONFIG_DIR")
    if env:
        roots += [Path(p).expanduser() / "projects" for p in env.split(",")]
    home = Path.home()
    roots += [home / ".claude" / "projects", home / ".config" / "claude" / "projects"]
    seen, out = set(), []
    for r in roots:
        if r.is_dir() and str(r) not in seen:
            seen.add(str(r))
            out.append(r)
    return out


def decode_slug(slug):
    return "/" + slug.lstrip("-").replace("-", "/") if slug.startswith("-") else slug


class Bucket:
    __slots__ = ("inp", "cw5", "cw1h", "cr", "out", "calls", "first", "last",
                 "models", "sessions")

    def __init__(self):
        self.inp = self.cw5 = self.cw1h = self.cr = self.out = 0
        self.calls = 0
        self.first = None
        self.last = None
        self.models = defaultdict(int)
        self.sessions = set()

    def add(self, u, model, ts):
        self.inp += u[0]; self.cw5 += u[1]; self.cw1h += u[2]
        self.cr += u[3]; self.out += u[4]
        self.calls += 1
        self.models[model] += sum(u)
        if ts:
            if self.first is None or ts < self.first:
                self.first = ts
            if self.last is None or ts > self.last:
                self.last = ts

    @property
    def total(self):
        return self.inp + self.cw5 + self.cw1h + self.cr + self.out

    def top_model(self):
        if not self.models:
            return "-"
        return (max(self.models.items(), key=lambda kv: kv[1])[0]
                .replace("claude-", "").replace("-20251001", ""))

    def dur_str(self):
        if self.first and self.last:
            mins = (self.last - self.first).total_seconds() / 60
            return f"{mins/60:.1f}ч" if mins >= 60 else f"{mins:.0f}м"
        return "-"


def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc)
    except Exception:
        return None


def _clean_title(txt):
    if not isinstance(txt, str):
        return None
    txt = txt.strip()
    if not txt or txt[0] in "</[":
        return None
    if "Caveat:" in txt or "system-reminder" in txt:
        return None
    txt = " ".join(txt.split())
    return txt or None


def collect(since=None, until=None):
    by_project, by_session, by_model, by_day, by_kind = (
        defaultdict(Bucket), defaultdict(Bucket), defaultdict(Bucket),
        defaultdict(Bucket), defaultdict(Bucket))
    overall = Bucket()
    cost_total = 0.0
    cost_by_project = defaultdict(float)
    cost_by_session = defaultdict(float)
    cost_by_model = defaultdict(float)
    cost_by_day = defaultdict(float)
    cost_by_kind = defaultdict(float)
    session_meta = {}
    custom_title, ai_title, first_prompt = {}, {}, {}
    seen = set()
    files = 0

    for root in transcript_roots():
        for fp in sorted(root.rglob("*.jsonl")):
            files += 1
            try:
                fh = fp.open(encoding="utf-8", errors="replace")
            except OSError:
                continue
            with fh:
                for line in fh:
                    line = line.strip()
                    if not line or line[0] != "{":
                        continue
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue

                    t = rec.get("type")
                    sid_meta = rec.get("sessionId") or fp.stem
                    if t == "custom-title":
                        ct = _clean_title(rec.get("customTitle"))
                        if ct:
                            custom_title[sid_meta] = ct
                        continue
                    if t == "ai-title":
                        at = _clean_title(rec.get("aiTitle"))
                        if at and at.lower() != "unknown session content":
                            ai_title[sid_meta] = at
                        continue

                    msg = rec.get("message")
                    if not isinstance(msg, dict):
                        continue

                    if t == "user" and sid_meta not in first_prompt:
                        c = msg.get("content")
                        if isinstance(c, list):
                            c = " ".join(p.get("text", "") for p in c
                                         if isinstance(p, dict) and p.get("type") == "text")
                        ct = _clean_title(c)
                        if ct:
                            first_prompt[sid_meta] = ct[:90]

                    usage = msg.get("usage")
                    if not isinstance(usage, dict):
                        continue

                    key = (msg.get("id"), rec.get("requestId"))
                    if key != (None, None):
                        if key in seen:
                            continue
                        seen.add(key)

                    ts = parse_ts(rec.get("timestamp"))
                    if since and ts and ts < since:
                        continue
                    if until and ts and ts > until:
                        continue

                    cc = usage.get("cache_creation") or {}
                    cw1h = int(cc.get("ephemeral_1h_input_tokens") or 0)
                    cw_all = int(usage.get("cache_creation_input_tokens") or 0)
                    cw5 = max(cw_all - cw1h, 0)
                    if cw_all == 0:
                        cw5 = int(cc.get("ephemeral_5m_input_tokens") or 0)
                    u = (int(usage.get("input_tokens") or 0), cw5, cw1h,
                         int(usage.get("cache_read_input_tokens") or 0),
                         int(usage.get("output_tokens") or 0))
                    if sum(u) == 0:
                        continue

                    model = msg.get("model") or "unknown"
                    cwd = rec.get("cwd") or decode_slug(fp.parent.name)
                    sid = rec.get("sessionId") or fp.stem
                    # По локальным суткам, а не по UTC: иначе «за сегодня» съезжает
                    # на разницу часовых поясов.
                    day = ts.astimezone().date().isoformat() if ts else "unknown"
                    kind = "subagent" if rec.get("isSidechain") else "main"

                    p = price_for(model)
                    cost = 0.0
                    if p:
                        pin, pcw, pcr, pout = p
                        cost = (u[0]*pin + u[1]*pcw + u[2]*pin*2 + u[3]*pcr + u[4]*pout) / 1e6

                    overall.add(u, model, ts)
                    by_project[cwd].add(u, model, ts); by_project[cwd].sessions.add(sid)
                    by_session[sid].add(u, model, ts)
                    by_model[model].add(u, model, ts)
                    by_day[day].add(u, model, ts)
                    by_kind[kind].add(u, model, ts)
                    cost_total += cost
                    cost_by_project[cwd] += cost
                    cost_by_session[sid] += cost
                    cost_by_model[model] += cost
                    cost_by_day[day] += cost
                    cost_by_kind[kind] += cost
                    session_meta.setdefault(sid, {})["project"] = cwd

    def title_for(sid):
        if sid in custom_title:
            return custom_title[sid], "custom"
        if sid in ai_title:
            return ai_title[sid], "ai"
        if sid in first_prompt:
            return first_prompt[sid], "prompt"
        return "(без названия)", "-"

    return dict(overall=overall, by_project=by_project, by_session=by_session,
                by_model=by_model, by_day=by_day, by_kind=by_kind,
                cost_total=cost_total, cost_by_project=cost_by_project,
                cost_by_session=cost_by_session, cost_by_model=cost_by_model,
                cost_by_day=cost_by_day, cost_by_kind=cost_by_kind,
                session_meta=session_meta, title_for=title_for, files=files)


# ------------------------------------------------------------------ format ---
def h(n):
    for unit, div in (("B", 1e9), ("M", 1e6), ("K", 1e3)):
        if n >= div:
            return f"{n/div:.2f}{unit}"
    return str(int(n))


def esc(s):
    return _html.escape(str(s))


# ------------------------------------------------------------------- HTML ----
CSS = """
:root{color-scheme:dark;
--bg:#0f1115;--panel:#171a21;--line:#1e222b;--line2:#232833;
--text:#e6e8eb;--muted:#8b94a3;--muted2:#7b8494;--accent:#2b6cb0;--accent2:#8fb3e0;
--rowhover:#151922;--dayhdr:#141821}
*{box-sizing:border-box}
body{font:15px/1.5 -apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif;
margin:0;background:var(--bg);color:var(--text)}
.wrap{max-width:1250px;margin:auto;padding:26px 30px 60px}
h1{font-size:23px;margin:0 0 3px}
h2{font-size:15px;margin:34px 0 12px;color:var(--muted);text-transform:uppercase;letter-spacing:.08em}
.sub{color:var(--muted2);font-size:13px}
nav{position:sticky;top:0;z-index:10;background:var(--bg);display:flex;gap:6px;
padding:16px 0 12px;margin-bottom:6px;border-bottom:1px solid var(--line);flex-wrap:wrap}
nav button{font:inherit;font-size:14px;color:var(--muted);background:transparent;
border:1px solid transparent;border-radius:9px;padding:8px 16px;cursor:pointer;transition:.12s}
nav button:hover{color:var(--text);background:var(--panel)}
nav button.active{color:var(--text);background:var(--panel);border-color:var(--line2);font-weight:600}
.panel{display:none} .panel.active{display:block}
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(155px,1fr));gap:12px;margin:20px 0}
.kpi{background:var(--panel);border:1px solid var(--line2);border-radius:11px;padding:14px 16px}
.kpi .v{font-size:22px;font-weight:600} .kpi .l{font-size:12px;color:var(--muted);margin-top:2px}
.tokbar{display:flex;flex-direction:column;gap:7px;margin:8px 0 4px;max-width:760px}
.tokrow{display:grid;grid-template-columns:130px 90px 1fr;align-items:center;gap:12px;font-size:13px}
.tokrow .lab{color:var(--muted)} .tokrow .val{text-align:right;font-variant-numeric:tabular-nums}
.meter{background:var(--line);border-radius:5px;height:10px;overflow:hidden}
.meter span{display:block;height:100%;background:var(--accent);border-radius:5px}
.tblwrap{overflow-x:auto}
table{width:100%;border-collapse:collapse;font-size:13px}
td,th{padding:6px 10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
th{color:var(--muted);font-weight:500;font-size:11px;text-transform:uppercase;white-space:nowrap}
td.n{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.mono{font-family:ui-monospace,Menlo,monospace;color:var(--muted);white-space:nowrap}
.bw{background:var(--line);border-radius:4px;width:120px}
.b{background:var(--accent);height:8px;border-radius:4px;display:block}
tbody tr:hover td{background:var(--rowhover)}
.sortable th{cursor:pointer} .sortable th:hover{color:var(--text)}
tr.day td{background:var(--dayhdr);font-weight:600;color:var(--accent2);
border-top:2px solid var(--line2);font-size:12px;position:sticky;left:0}
.title{max-width:520px} .src{color:var(--muted);display:inline-block;width:13px}
.note{color:var(--muted2);font-size:12px;margin-top:16px;max-width:820px}
.legend{color:var(--muted2);font-size:12px;margin-top:12px}
"""

SORT_JS = """
function makeSortable(tbl){
 const heads=tbl.tHead.rows[0].cells, tb=tbl.tBodies[0];
 [...heads].forEach((th,i)=>{if(th.dataset.nosort!==undefined)return;th.onclick=()=>{
  const rows=[...tb.rows].filter(r=>!r.classList.contains('day'));
  const val=el=>{const t=(el.cells[i].textContent||'').trim();
   const m={'B':1e9,'M':1e6,'K':1e3};const mm=t.match(/([\\d.]+)\\s*([BMK]?)/);
   if(t.startsWith('$')){return parseFloat(t.replace(/[$,]/g,''))||0;}
   if(mm&&(mm[2]||/^[\\d.]+$/.test(t))){return parseFloat(mm[1])*(m[mm[2]]||1);}
   const h=t.match(/([\\d.]+)([чм])/);if(h){return parseFloat(h[1])*(h[2]==='ч'?60:1);}
   return t.toLowerCase();};
  th._d=!th._d;
  rows.sort((a,b)=>{const x=val(a),y=val(b);
   const r=(typeof x==='number'&&typeof y==='number')?x-y:String(x).localeCompare(String(y),'ru');
   return th._d?r:-r;});
  rows.forEach(r=>tb.appendChild(r));};});
}
document.querySelectorAll('nav button').forEach(btn=>btn.onclick=()=>{
 document.querySelectorAll('nav button').forEach(b=>b.classList.remove('active'));
 document.querySelectorAll('.panel').forEach(p=>p.classList.remove('active'));
 btn.classList.add('active');
 document.getElementById(btn.dataset.tab).classList.add('active');
 location.hash=btn.dataset.tab;
});
document.querySelectorAll('table.sortable').forEach(makeSortable);
(function(){const h=location.hash.slice(1);
 const b=document.querySelector(`nav button[data-tab="${h}"]`);if(b)b.click();})();
"""


def _bucket_table(buckets, costs, n, namer, extra_cols=None, bars=True):
    rows = sorted(buckets.items(), key=lambda kv: -kv[1].total)[:n]
    if not rows:
        return ""
    mx = rows[0][1].total or 1
    out = []
    for k, b in rows:
        bar = (f"<td><div class='bw'><span class='b' style='width:{b.total/mx*100:.1f}%'></span></div></td>"
               if bars else "")
        extra = ""
        if extra_cols:
            extra = "".join(f"<td class='n'>{c(b)}</td>" for c in extra_cols)
        out.append(f"<tr><td>{namer(k, b)}</td><td class='n'>{h(b.total)}</td>{bar}"
                   f"<td class='n'>${costs.get(k,0):,.2f}</td>"
                   f"<td class='n'>{b.calls:,}</td>{extra}</tr>")
    return "".join(out)


def build_overview(d):
    o = d["overall"]
    billed_in = o.inp + o.cw5 + o.cw1h + o.cr
    cache_share = o.cr / max(billed_in, 1) * 100

    def kpi(v, l):
        return f'<div class="kpi"><div class="v">{v}</div><div class="l">{l}</div></div>'
    kpis = "".join([
        kpi(h(o.total), "всего токенов"),
        kpi(f"${d['cost_total']:,.0f}", "оценка по API-прайсу"),
        kpi(f"{o.calls:,}", "API-вызовов"),
        kpi(f"{len(d['by_session']):,}", "сессий"),
        kpi(f"{len(d['by_project']):,}", "проектов"),
        kpi(f"{cache_share:.0f}%", "доля кеш-чтений во входе"),
    ])

    tokrows = ""
    for lab, val in (("input (свежий)", o.inp), ("cache write 5m", o.cw5),
                     ("cache write 1h", o.cw1h), ("cache read", o.cr), ("output", o.out)):
        pct = val / o.total * 100 if o.total else 0
        tokrows += (f"<div class='tokrow'><span class='lab'>{lab}</span>"
                    f"<span class='val'>{val:,}</span>"
                    f"<span class='meter'><span style='width:{pct:.2f}%'></span></span></div>")

    proj = _bucket_table(d["by_project"], d["cost_by_project"], 30,
                         lambda k, b: esc(Path(k).name),
                         extra_cols=[lambda b: len(b.sessions)])
    model = _bucket_table(d["by_model"], d["cost_by_model"], 20,
                          lambda k, b: esc(k.replace("claude-", "").replace("-20251001", "")))
    kind = _bucket_table(d["by_kind"], d["cost_by_kind"], 10,
                         lambda k, b: "главный цикл" if k == "main" else "сабагенты")

    days = sorted(d["by_day"].items())
    dmx = max((b.total for _, b in days), default=1) or 1
    dayrows = "".join(
        f"<tr><td class='mono'>{day}</td><td class='n'>{h(b.total)}</td>"
        f"<td><div class='bw'><span class='b' style='width:{b.total/dmx*100:.1f}%'></span></div></td>"
        f"<td class='n'>${d['cost_by_day'].get(day,0):,.2f}</td></tr>"
        for day, b in days)

    unknown = ""
    if UNKNOWN_MODELS:
        unknown = f"<div class='note'>⚠ нет прайса для: {esc(', '.join(sorted(UNKNOWN_MODELS)))} — не учтены в сумме.</div>"

    return f"""
<div class="kpis">{kpis}</div>
<h2>Из чего состоит вход</h2>
<div class="tokbar">{tokrows}</div>
<div class="note">вход/выход ≈ {billed_in/max(o.out,1):.0f} : 1. Доля cache read {cache_share:.1f}% —
чем выше, тем дешевле обходится контекст (кеш не рвётся).</div>
{unknown}

<h2>По проектам</h2>
<div class="tblwrap"><table><thead><tr><th>проект</th><th class='n'>токены</th><th></th>
<th class='n'>$</th><th class='n'>вызовов</th><th class='n'>сессий</th></tr></thead>
<tbody>{proj}</tbody></table></div>

<h2>По моделям</h2>
<div class="tblwrap"><table><thead><tr><th>модель</th><th class='n'>токены</th><th></th>
<th class='n'>$</th><th class='n'>вызовов</th></tr></thead><tbody>{model}</tbody></table></div>

<h2>Главный цикл vs сабагенты</h2>
<div class="tblwrap"><table><thead><tr><th>тип</th><th class='n'>токены</th><th></th>
<th class='n'>$</th><th class='n'>вызовов</th></tr></thead><tbody>{kind}</tbody></table></div>

<h2>По дням</h2>
<div class="tblwrap"><table><thead><tr><th>дата</th><th class='n'>токены</th><th></th>
<th class='n'>$</th></tr></thead><tbody>{dayrows}</tbody></table></div>
"""


def build_sessions(d):
    rows = sorted(d["by_session"].items(), key=lambda kv: -kv[1].total)
    mx = rows[0][1].total if rows else 1
    trs = []
    for i, (sid, b) in enumerate(rows, 1):
        cwd = d["session_meta"].get(sid, {}).get("project", "?")
        name, src = d["title_for"](sid)
        day = b.first.date().isoformat() if b.first else "?"
        trs.append(
            f"<tr><td class='n'>{i}</td><td>{day}</td>"
            f"<td>{esc(Path(cwd).name)}</td><td>{esc(b.top_model())}</td>"
            f"<td class='n'>{h(b.total)}</td>"
            f"<td data-nosort><div class='bw'><span class='b' style='width:{b.total/mx*100:.1f}%'></span></div></td>"
            f"<td class='n'>{h(b.cr)}</td><td class='n'>{h(b.out)}</td>"
            f"<td class='n'>{b.calls}</td><td class='n'>{b.dur_str()}</td>"
            f"<td class='n'>${d['cost_by_session'].get(sid,0):,.2f}</td>"
            f"<td class='title'>{esc(name)}</td></tr>")
    return f"""
<div class="sub" style="margin:16px 0 4px">Все {len(rows)} сессий, по убыванию токенов.
Клик по заголовку столбца — пересортировать.</div>
<div class="tblwrap"><table class="sortable"><thead><tr>
<th>#</th><th>дата</th><th>проект</th><th>модель</th>
<th class='n'>токены</th><th data-nosort></th><th class='n'>cache read</th><th class='n'>output</th>
<th class='n'>вызовов</th><th class='n'>длит.</th><th class='n'>$</th><th>название</th>
</tr></thead><tbody>{''.join(trs)}</tbody></table></div>
"""


def build_timeline(d):
    _FAR = datetime.max.replace(tzinfo=timezone.utc)
    rows = sorted(d["by_session"].items(), key=lambda kv: kv[1].first or _FAR)
    mx = max((b.total for _, b in rows), default=1) or 1
    day_cost = defaultdict(float)
    for sid, b in rows:
        day = b.first.date().isoformat() if b.first else "?"
        day_cost[day] += d["cost_by_session"].get(sid, 0)

    blocks, cur = [], None
    badge = {"custom": "★", "ai": "◆", "prompt": "›", "-": ""}
    for i, (sid, b) in enumerate(rows, 1):
        day = b.first.date().isoformat() if b.first else "?"
        if day != cur:
            blocks.append(f"<tr class='day'><td colspan='8'>{day} · ${day_cost[day]:,.2f}</td></tr>")
            cur = day
        cwd = d["session_meta"].get(sid, {}).get("project", "?")
        name, src = d["title_for"](sid)
        start = b.first.strftime("%H:%M") if b.first else "?"
        blocks.append(
            f"<tr><td class='n'>{i}</td><td class='mono'>{start}</td>"
            f"<td>{esc(Path(cwd).name)}</td><td>{esc(b.top_model())}</td>"
            f"<td class='n'>{h(b.total)}</td>"
            f"<td><div class='bw'><span class='b' style='width:{b.total/mx*100:.1f}%'></span></div></td>"
            f"<td class='n'>${d['cost_by_session'].get(sid,0):,.2f}</td>"
            f"<td class='title'><span class='src' title='{src}'>{badge[src]}</span> {esc(name)}</td></tr>")
    return f"""
<div class="sub" style="margin:16px 0 4px">Все сессии в хронологии — сверху самые ранние.
Сгруппировано по дням, в шапке дня — сумма за день.</div>
<div class="tblwrap"><table><thead><tr>
<th>#</th><th>время</th><th>проект</th><th>модель</th><th class='n'>токены</th><th></th>
<th class='n'>$</th><th>название сессии</th>
</tr></thead><tbody>{''.join(blocks)}</tbody></table></div>
<div class="legend">★ — заданное тобой название · ◆ — авто-название Claude Code · › — по первому сообщению</div>
"""


def build_html(d):
    o = d["overall"]
    span = f"{o.first.date()} – {o.last.date()}" if o.first and o.last else "нет данных"
    gen = datetime.now().strftime("%Y-%m-%d %H:%M")
    if o.calls == 0:
        body = "<p>Транскрипты не найдены в ~/.claude/projects.</p>"
        return f"<!doctype html><html lang=ru><meta charset=utf-8><title>Claude Code</title><body>{body}</body></html>"
    return f"""<!doctype html><html lang="ru"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Claude Code — дашборд токенов</title>
<style>{CSS}</style>
<div class="wrap">
<h1>Расход токенов в Claude Code</h1>
<div class="sub">{span} · {h(o.total)} токенов · ${d['cost_total']:,.0f} по API-прайсу ·
{len(d['by_session'])} сессий · обновлено {gen}</div>
<nav>
<button class="active" data-tab="tab-overview">Обзор</button>
<button data-tab="tab-sessions">Все сессии</button>
<button data-tab="tab-timeline">Таймлайн</button>
</nav>
<div id="tab-overview" class="panel active">{build_overview(d)}</div>
<div id="tab-sessions" class="panel">{build_sessions(d)}</div>
<div id="tab-timeline" class="panel">{build_timeline(d)}</div>
<div class="note">Стоимость — оценка по прайс-листу Claude API (Opus 5 $5/$25, Fable 5 $10/$50,
Sonnet 5 $2/$10 интро, Haiku 4.5 $1/$5 за Mtok; cache read ×0.1, cache write 1h ×2).
На подписке Max/Pro это не счёт, а эквивалент расхода через API.</div>
</div>
<script>{SORT_JS}</script>
</html>"""


# ------------------------------------------------------------------ serve ---
def serve(port, since, until):
    from http.server import BaseHTTPRequestHandler, HTTPServer

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path not in ("/", "/index.html"):
                self.send_error(404); return
            UNKNOWN_MODELS.clear()
            html = build_html(collect(since, until))
            data = html.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *a):
            pass

    httpd = HTTPServer(("127.0.0.1", port), Handler)
    url = f"http://127.0.0.1:{port}/"
    print(f"Дашборд запущен: {url}")
    print("Данные пересчитываются при каждом обновлении страницы. Ctrl+C — остановить.")
    webbrowser.open(url)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nОстановлено.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since")
    ap.add_argument("--until")
    ap.add_argument("--out", default="dashboard.html")
    ap.add_argument("--no-open", action="store_true")
    ap.add_argument("--serve", action="store_true")
    ap.add_argument("--port", type=int, default=8899)
    a = ap.parse_args()

    since = datetime.fromisoformat(a.since).replace(tzinfo=timezone.utc) if a.since else None
    until = datetime.fromisoformat(a.until).replace(tzinfo=timezone.utc) if a.until else None

    if not transcript_roots():
        print("Не нашёл ~/.claude/projects.", file=sys.stderr); sys.exit(1)

    if a.serve:
        serve(a.port, since, until); return

    d = collect(since, until)
    out = Path(a.out).resolve()
    out.write_text(build_html(d), encoding="utf-8")
    o = d["overall"]
    print(f"Готово: {out}")
    print(f"  {o.calls:,} вызовов · {len(d['by_session'])} сессий · "
          f"{h(o.total)} токенов · ${d['cost_total']:,.2f}")
    if not a.no_open:
        webbrowser.open(out.as_uri())


if __name__ == "__main__":
    main()
