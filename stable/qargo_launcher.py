#!/usr/bin/env python3
"""Qargo Autofill launcher and updater.  Standard library only: it runs on the uv-managed base Python,
before any virtualenv exists, and is the same file on macOS and Windows.

    <python> qargo_launcher.py launch            the icon: start the app at once, then get an update ready for the next start
    <python> qargo_launcher.py install --dist U [--site ID]   first install / repair (called by the installers)
    <python> qargo_launcher.py status | rollback | reset-profile
    <python> qargo_launcher.py stage             launch starts this on its own: the next version, after the program is up

Layout under QARGO_HOME (macOS ~/Library/Application Support/QargoAutofill, Windows %LOCALAPPDATA%\\QargoAutofill):
    bin/uv[.exe]            private uv                    python/      uv-managed CPython (UV_PYTHON_INSTALL_DIR)
    uv-cache/               UV_CACHE_DIR                  browsers/    PLAYWRIGHT_BROWSERS_PATH
    qargo_launcher.py       this file                     assets/      icons (both follow the active version)
    app/state.json          dist URL, site code, current / previous / bad versions, chosen browser
    app/update.json         what an update in the background got ready for the next start (see stage)
    app/site.json           the site profile: the names the public release holds as placeholders (see fill_in_site)
    app/versions/<ver>/     unpacked release zip (.ok when complete)
    envs/<lockhash>/        virtualenv for one uv.lock (.ok when complete, .browser = chromium|chrome|msedge)
    data/                   everything the operator owns (QARGO_DATA_DIR): browser profile, documents, done.json, logs
"""
import gc, hashlib, json, os, re, shutil, subprocess, sys, threading, time, traceback, urllib.request, zipfile
from pathlib import Path

WIN, MAC = sys.platform == "win32", sys.platform == "darwin"
APP_TITLE = "Qargo Autofill"
DIST_BASE = "https://raw.githubusercontent.com/cagataysunal/qargo-autofill-dist/main"     # make_release.sh stamps the public address here; state.json's "dist" wins
CHECK_BUDGET = 30                     # seconds to wait for latest.json: never before a start that has a working version
UPDATE_WAIT = 900                     # seconds an install or repair waits for an update that runs in the background
START_WAIT = 60                      # seconds we watch a started app for its "control page is showing" file
BROWSERS = ("chromium", "msedge", "chrome") if WIN else ("chromium", "chrome", "msedge")       # order of preference
HEADLESS = os.environ.get("QARGO_HEADLESS") == "1"      # tests: no window of ours on the screen, messages go to the log

# The launcher cannot use the app's string tables: it runs before they are downloaded.
TEXT = {
    "en": {"start": "Starting Qargo Autofill…",
           "update": "Installing an update.\nThis can take a few minutes. Please wait…",
           "prepare": "Preparing the program.\nThis can take a few minutes. Please wait…",
           "failed": "The program could not start. Open the installation page you were sent and do the steps again, or call support.",
           "log": "Log file: {path}"},
    "tr": {"start": "Qargo Autofill başlatılıyor…",
           "update": "Güncelleme yükleniyor.\nBu birkaç dakika sürebilir. Lütfen bekleyin…",
           "prepare": "Program hazırlanıyor.\nBu birkaç dakika sürebilir. Lütfen bekleyin…",
           "failed": "Program başlatılamadı. Size gönderilen kurulum sayfasını açıp adımları yeniden yapın veya desteği arayın.",
           "log": "Günlük dosyası: {path}"},
    "nl": {"start": "Qargo Autofill wordt gestart…",
           "update": "Er wordt een update geïnstalleerd.\nDit kan een paar minuten duren. Even geduld…",
           "prepare": "Het programma wordt voorbereid.\nDit kan een paar minuten duren. Even geduld…",
           "failed": "Het programma kon niet starten. Open de installatiepagina die u is gestuurd en doe de stappen opnieuw, of bel de helpdesk.",
           "log": "Logbestand: {path}"},
    "bg": {"start": "Qargo Autofill се стартира…",
           "update": "Инсталира се актуализация.\nТова може да отнеме няколко минути. Моля, изчакайте…",
           "prepare": "Програмата се подготвя.\nТова може да отнеме няколко минути. Моля, изчакайте…",
           "failed": "Програмата не можа да се стартира. Отворете страницата за инсталиране, която Ви е изпратена, и повторете стъпките, или се обадете на поддръжката.",
           "log": "Лог файл: {path}"},
}


def default_home():
    if WIN:
        return Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local") / "QargoAutofill"
    return Path.home() / "Library" / "Application Support" / "QargoAutofill"


HOME = Path(os.environ.get("QARGO_HOME") or default_home())
APP, VERSIONS, ENVS, DATA = HOME / "app", HOME / "app" / "versions", HOME / "envs", HOME / "data"
LOGS = DATA / "logs"
STATE, STARTED_OK, LOCK = APP / "state.json", APP / "started_ok", APP / "launcher.lock"
UPDATE_FILE, UPDATE_LOCK = APP / "update.json", APP / "update.lock"     # see stage()
APP_LOCK = DATA / "app.lock"                  # the app's own single-instance file (pid, port, token)
UV = HOME / "bin" / ("uv.exe" if WIN else "uv")
NO_WINDOW = 0x08000000 if WIN else 0          # CREATE_NO_WINDOW: no console flash when started by pythonw.exe
_logfh = None
_blocked = False                              # Windows application control (Smart App Control) stopped one of our programs


def log(*parts):
    line = time.strftime("%Y-%m-%d %H:%M:%S ") + " ".join(str(p) for p in parts)
    if _logfh:
        _logfh.write(line + "\n")
    if sys.__stdout__ is not None and (os.environ.get("QARGO_VERBOSE") or sys.__stdout__.isatty()):
        print(line, file=sys.__stdout__, flush=True)                # installer / terminal: show progress


def say(text):
    """answer of a command typed by a person: to the real stdout when there is one, else to the log"""
    log(text) if sys.__stdout__ is None else print(text, file=sys.__stdout__, flush=True)


def setup_logging():
    global _logfh
    for d in (LOGS, VERSIONS, ENVS):
        d.mkdir(parents=True, exist_ok=True)
    f = LOGS / "launcher.log"
    try:
        if f.exists() and f.stat().st_size > 1_000_000:
            os.replace(f, LOGS / "launcher.old.log")
    except OSError:                                                 # another launcher has it open (Windows): keep writing
        pass
    _logfh = open(f, "a", encoding="utf-8", buffering=1)
    if sys.stdout is None or not sys.stdout.isatty():               # pythonw.exe / Finder: no console at all
        sys.stdout = sys.stderr = _logfh


def text(key):
    lang = "en"                                                     # English unless the operator chose a language in the app
    try:
        chosen = json.loads((DATA / "settings.json").read_text(encoding="utf-8-sig")).get("lang")
        lang = chosen if chosen in TEXT else "en"
    except Exception:
        pass
    return TEXT[lang][key]


def load_state():
    try:
        return json.loads(STATE.read_text(encoding="utf-8-sig"))
    except Exception:
        return {}


def save_state(state):
    APP.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=1), encoding="utf-8")
    replace(tmp, STATE)                                             # atomic on both systems


def replace(src, dst):
    """os.replace, patient with a virus scanner that still holds a freshly written file (Windows)"""
    for attempt in range(10):
        try:
            return os.replace(src, dst)
        except PermissionError:
            if attempt == 9:
                raise
            time.sleep(0.5)


# ---------------------------------------------------------------- processes

def process_path(pid):
    """None = no such process; "" = alive but its program is unknown; else the path of its program"""
    if WIN:                                                         # os.kill(pid, 0) would terminate it on Windows
        import ctypes
        from ctypes import wintypes
        k = ctypes.WinDLL("kernel32", use_last_error=True)
        k.OpenProcess.restype, k.OpenProcess.argtypes = wintypes.HANDLE, (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        k.GetExitCodeProcess.argtypes = (wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD))
        k.QueryFullProcessImageNameW.argtypes = (wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD))
        k.CloseHandle.argtypes = (wintypes.HANDLE,)
        h = k.OpenProcess(0x1000, False, int(pid))                  # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return None
        try:
            code = wintypes.DWORD()
            if not k.GetExitCodeProcess(h, ctypes.byref(code)) or code.value != 259:      # STILL_ACTIVE
                return None
            buf, n = ctypes.create_unicode_buffer(32768), wintypes.DWORD(32768)
            return buf.value if k.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(n)) else ""
        finally:
            k.CloseHandle(h)
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return None
    except OSError:                                                 # another user's process: not ours
        return None
    try:
        return subprocess.run(["/bin/ps", "-ww", "-p", str(int(pid)), "-o", "comm="], capture_output=True, text=True,
                              encoding="utf-8", errors="replace", timeout=5).stdout.strip()
    except Exception:
        return ""


def ours_alive(pid):
    """is this pid a live process started from inside our folder? (a pid in a stale file may belong to anything by now)"""
    try:
        path = process_path(int(pid))
    except (TypeError, ValueError):
        return False
    if not path:
        return path == ""
    norm = lambda p: os.path.normcase(os.path.realpath(p))
    return norm(path).startswith(norm(HOME) + os.sep) or os.path.normcase(path).startswith(os.path.normcase(str(HOME)) + os.sep)


def app_running(state):
    pids = [state.get("app_pid")]
    try:                                                            # the app writes its pid here; be liberal in what we read
        raw = APP_LOCK.read_text(encoding="utf-8-sig")
        try:
            pids.append(json.loads(raw).get("pid"))
        except Exception:
            pids += re.findall(r"\d+", raw)[:1]
    except OSError:
        pass
    return any(ours_alive(p) for p in pids if p)


def take_lock(path=LOCK):
    """one at a time. LOCK: one start at a time (a second double-click while the first is still starting the program).
    UPDATE_LOCK: one update at a time (in the background, or an install / repair): two must never unpack one version."""
    APP.mkdir(parents=True, exist_ok=True)
    for _ in range(2):
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.write(fd, str(os.getpid()).encode())
            os.close(fd)
            return True
        except FileExistsError:
            try:
                owner, age = path.read_text(encoding="utf-8").strip(), time.time() - path.stat().st_mtime
            except OSError:
                continue
            if (not owner and age < 5) or (owner and ours_alive(owner)):
                return False
            path.unlink(missing_ok=True)                            # left behind by a launcher that died
    return False


def updating_elsewhere():
    """is another launcher getting an update ready right now? (its folders must not be pruned under it)"""
    try:
        owner = UPDATE_LOCK.read_text(encoding="utf-8").strip()
    except OSError:
        return False
    return owner != str(os.getpid()) and (not owner or ours_alive(owner))


def wait_update_lock(step=lambda key: None):
    """the update lock, after an update that runs in the background has finished (it may be getting the very version
    an install or a repair wants). False when it is still busy after UPDATE_WAIT."""
    deadline = time.time() + UPDATE_WAIT
    while not take_lock(UPDATE_LOCK):
        if time.time() > deadline:
            return False
        step("update")
        time.sleep(1)
    return True


def run(cmd, cwd=None, env=None, timeout=1800):
    """run a helper without a console window; every output line goes to the log"""
    global _blocked
    cmd = [str(c) for c in cmd]
    log("$", " ".join("<script>" if "\n" in c else c for c in cmd))
    try:
        p = subprocess.Popen(cmd, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, encoding="utf-8", errors="replace", creationflags=NO_WINDOW)
    except OSError as e:
        _blocked = _blocked or getattr(e, "winerror", None) == 4551
        log("    could not start:", repr(e))
        return 127
    killer = threading.Timer(timeout, p.kill)
    killer.start()
    try:
        for line in p.stdout:
            if line.strip():
                log("   ", line.rstrip())
                _blocked = _blocked or bool(re.search(r"(WinError|os error) 4551|Application Control policy", line))
        return p.wait()
    finally:
        killer.cancel()


# ---------------------------------------------------------------- download and unpack

def http_open(url, timeout):
    req = urllib.request.Request(url, headers={"User-Agent": "qargo-autofill-launcher", "Cache-Control": "no-cache"})
    return urllib.request.urlopen(req, timeout=timeout)


def fetch_latest(dist, budget):
    """latest.json, or an exception when it has not arrived within the budget (a hanging DNS lookup ignores socket timeouts)"""
    box = {}

    def work():
        try:
            with http_open(dist + "/latest.json", budget) as r:
                box["meta"] = json.loads(r.read().decode("utf-8-sig"))
        except Exception as e:
            box["error"] = e
    t = threading.Thread(target=work, daemon=True)
    t.start()
    t.join(budget)
    if "meta" not in box:
        raise box.get("error") or TimeoutError(f"no answer from {dist} within {budget} s")
    meta = box["meta"]
    if not (isinstance(meta, dict) and re.fullmatch(r"[0-9A-Za-z._-]{1,40}", str(meta.get("version")))
            and re.fullmatch(r"[0-9A-Za-z._-]{1,80}\.zip", str(meta.get("zip"))) and re.fullmatch(r"[0-9a-fA-F]{64}", str(meta.get("sha256")))):
        raise RuntimeError(f"latest.json at {dist} is not usable: {str(meta)[:200]}")
    return meta


def download(url, dest, sha256, timeout=60):
    dest.parent.mkdir(parents=True, exist_ok=True)
    part, h = dest.with_name(dest.name + ".part"), hashlib.sha256()
    with http_open(url, timeout) as r, open(part, "wb") as f:
        for chunk in iter(lambda: r.read(1 << 16), b""):
            f.write(chunk)
            h.update(chunk)
    if h.hexdigest() != sha256.lower():
        part.unlink()
        raise RuntimeError(f"checksum mismatch for {url}: got {h.hexdigest()}, expected {sha256}")
    replace(part, dest)


def unpack(zip_path, dest, version, state=None):
    tmp = dest.with_name(dest.name + ".tmp")
    for d in (tmp, dest):
        shutil.rmtree(d, ignore_errors=True)
    with zipfile.ZipFile(zip_path) as z:
        root = tmp.resolve()
        for name in z.namelist():                                   # refuse paths that leave the folder
            if root not in (root / name).resolve().parents and (root / name).resolve() != root:
                raise RuntimeError(f"unsafe path in zip: {name}")
        z.extractall(tmp)
    if (tmp / SITE_MANIFEST).exists():
        try:
            fill_in_site(tmp, site_tokens(state if state is not None else {}, read_manifest(tmp)))
        except Exception:
            shutil.rmtree(tmp, ignore_errors=True)
            raise
    replace(tmp, dest)
    (dest / ".ok").write_text(version, encoding="utf-8")


# ---------------------------------------------------------------- the site profile
# The public release names no company, customer or person: they are placeholders ("Sx", four digits, "x") in the zip, and the
# site profile, a small JSON file in a secret gist, says which name each stands for. The installation page's link
# carries the gist's id (#s=<id>); the installer hands it to "install --site", and it is kept in state.json.
# A version is only unpacked with every name put back, so what runs is byte for byte the code it was made from.

SITE_MANIFEST = "site_manifest.json"
SITE_TOKEN = re.compile(r"Sx\d{4}x")
SITE_ID = re.compile(r"[0-9a-f]{20,40}")
SITE_URL = "https://gist.githubusercontent.com/cagataysunal/{id}/raw/site.json"
SITE_FILE = APP / "site.json"
TEXT_SUFFIXES = {".py", ".json", ".html", ".txt", ".md", ".toml", ".sh", ".ps1", ".js", ".css", ".csv"}


class NoSite(RuntimeError):
    """this version needs the site profile and this computer has no way to get it: not worth downloading again"""


def read_manifest(vdir):
    m = json.loads((vdir / SITE_MANIFEST).read_text(encoding="utf-8"))
    if not (isinstance(m, dict) and m.get("format") == 1 and isinstance(m.get("files"), list) and isinstance(m.get("tokens"), list)):
        raise RuntimeError(f"{SITE_MANIFEST} is not usable")
    return m


def usable_site(profile):
    """{placeholder: name} of a site profile, or an exception (the same rules as packaging/site_scrub.check_profile)"""
    tokens = profile.get("tokens") if isinstance(profile, dict) else None
    if profile.get("format") != 1 or not isinstance(tokens, dict):
        raise RuntimeError("the site profile is not format 1 with a tokens table")
    for k, v in tokens.items():
        if not (SITE_TOKEN.fullmatch(k) and isinstance(v, str) and 0 < len(v) <= 200 and v.isprintable() and not SITE_TOKEN.search(v)):
            raise RuntimeError(f"the site profile has a bad entry: {k!r}")
    return tokens


def fetch_site(site, timeout=30):
    url = os.environ.get("QARGO_SITE_URL") or SITE_URL.format(id=site)     # QARGO_SITE_URL: tests
    with http_open(url, timeout) as r:
        profile = json.loads(r.read().decode("utf-8-sig"))
    tokens = usable_site(profile)
    tmp = SITE_FILE.with_suffix(".tmp")
    APP.mkdir(parents=True, exist_ok=True)
    tmp.write_text(json.dumps(profile, indent=1, ensure_ascii=False), encoding="utf-8")
    replace(tmp, SITE_FILE)
    return tokens


def site_tokens(state, manifest):
    """the names this version needs: from the copy kept here, else (or when it lacks one) from the gist"""
    need = set(manifest["tokens"])
    try:
        tokens = usable_site(json.loads(SITE_FILE.read_text(encoding="utf-8")))
    except Exception:
        tokens = {}
    if need - set(tokens) or state.get("site_refresh"):
        site = state.get("site")
        if not site:
            raise NoSite("this version needs the site profile, and this computer has no site code: "
                         "run the line of the installation page you were sent (its link ends in #s=...)")
        tokens = fetch_site(site)
        state.pop("site_refresh", None)
    missing = need - set(tokens)
    if missing:
        raise RuntimeError(f"the site profile has no name for {', '.join(sorted(missing)[:5])}: try again in a few minutes")
    return tokens


def fill_in_site(vdir, tokens):
    """put the names back into the files the manifest lists (packaging/site_scrub.py made them)"""
    fill = lambda text: SITE_TOKEN.sub(lambda m: tokens[m.group(0)], text)
    for rel in read_manifest(vdir)["files"]:
        src, dst = vdir / rel, vdir / fill(rel)
        if vdir.resolve() not in dst.resolve().parents:
            raise RuntimeError(f"unsafe path from the site profile: {rel}")
        dst.parent.mkdir(parents=True, exist_ok=True)
        if Path(rel).suffix.lower() in TEXT_SUFFIXES:
            with open(src, encoding="utf-8", newline="") as f:
                text = fill(f.read())
            with open(dst, "w", encoding="utf-8", newline="") as f:
                f.write(text)
            if dst != src:
                src.unlink()
        elif dst != src:
            replace(src, dst)


# ---------------------------------------------------------------- virtualenv and browser

def lock_hash(vdir):
    h = hashlib.sha256()
    for name in ("uv.lock", ".python-version", "pyproject.toml"):
        h.update((vdir / name).read_bytes())
    return h.hexdigest()[:12]


def venv_python(envdir, gui=False):
    if WIN:
        return envdir / "Scripts" / ("pythonw.exe" if gui else "python.exe")
    return envdir / "bin" / "python"


def tool_env(envdir=None):
    e = dict(os.environ)
    e.update(UV_PYTHON_INSTALL_DIR=str(HOME / "python"), UV_CACHE_DIR=str(HOME / "uv-cache"), UV_MANAGED_PYTHON="1",
             UV_PYTHON_INSTALL_BIN="0", UV_PYTHON_INSTALL_REGISTRY="0", UV_NO_CONFIG="1", UV_NO_PROGRESS="1",
             UV_SYSTEM_CERTS="1", PLAYWRIGHT_BROWSERS_PATH=str(HOME / "browsers"), PYTHONUTF8="1")
    for k in ("VIRTUAL_ENV", "PYTHONHOME", "PYTHONPATH", "UV_PROJECT_ENVIRONMENT"):
        e.pop(k, None)
    if envdir:
        e["UV_PROJECT_ENVIRONMENT"] = str(envdir)
    return e


def app_env(version, browser):
    """what the app is promised: where it lives, where its data goes, which browser to drive"""
    e = {k: v for k, v in os.environ.items() if not k.startswith("UV_") and k not in ("VIRTUAL_ENV", "PYTHONHOME", "PYTHONPATH")}
    e.update(QARGO_HOME=str(HOME), QARGO_DATA_DIR=str(DATA), QARGO_VERSION=version, QARGO_BROWSER=browser,
             QARGO_STARTED_OK=str(STARTED_OK), PLAYWRIGHT_BROWSERS_PATH=str(HOME / "browsers"), PYTHONUTF8="1",
             PYTHONUNBUFFERED="1")
    return e


def ensure_env(vdir):
    envdir = ENVS / lock_hash(vdir)
    if not (envdir / ".ok").exists():
        shutil.rmtree(envdir, ignore_errors=True)
        # --no-build: only ready-made wheels. Without it uv would fetch a compiler to build a package that has none.
        if run([UV, "sync", "--frozen", "--no-dev", "--no-build", "--project", vdir], env=tool_env(envdir)):
            raise RuntimeError("uv sync failed (see launcher.log)")
        (envdir / ".ok").write_text(time.strftime("%Y-%m-%d %H:%M:%S"), encoding="utf-8")
    return envdir


# Started with the virtualenv's python.  channel="chromium" is the full bundled browser in its own headless mode:
# the very program the operator will see, and the separate "headless shell" does not have to be downloaded.
PROBE = """import sys, tempfile
from playwright.sync_api import sync_playwright
with sync_playwright() as p, tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as d:
    ctx = p.chromium.launch_persistent_context(d, headless=True, channel=sys.argv[1])
    (ctx.pages[0] if ctx.pages else ctx.new_page()).goto("data:text/html,ok")
    ctx.close()
"""


def ensure_browser(envdir, state, fresh=False):
    """the browser the app will drive: Playwright's own Chromium, else an installed Chrome or Edge that really starts here.
    Kept in state["browser"]; the caller saves state (an update in the background never does)."""
    marker = envdir / ".browser"
    if marker.exists() and not fresh:
        name = marker.read_text(encoding="utf-8").strip()
        if name in BROWSERS:
            state["browser"] = name
            return name
    order = list(BROWSERS)
    if not fresh and state.get("browser") in order:                 # stay with the browser the operator is logged in with
        order.insert(0, order.pop(order.index(state["browser"])))
    if os.environ.get("QARGO_BROWSER") in BROWSERS:                 # tests, or a machine where the choice must be forced
        order = [os.environ["QARGO_BROWSER"]]
    for name in order:
        if name == "chromium" and run([venv_python(envdir), "-m", "playwright", "install", "chromium", "--no-shell"], env=tool_env()):
            log("Chromium could not be downloaded")                 # blocked or offline: try an installed browser
            continue
        if run([venv_python(envdir), "-c", PROBE, name], env=tool_env(), timeout=120) == 0:
            marker.write_text(name, encoding="utf-8")
            state["browser"] = name
            return name
        log(f"browser {name} could not be started here")
    raise RuntimeError("no usable browser: Chromium could not be downloaded or started, and neither Chrome nor Edge works")


def selftest(vdir, envdir, version, browser):
    if (vdir / "qargo_launcher.py").exists() and run([sys.executable, vdir / "qargo_launcher.py", "selfcheck"], timeout=60):
        return False                                                # the new launcher would replace this one: it must at least run
    return run([venv_python(envdir), "-m", "qargo_app", "--selftest"], cwd=vdir, env=app_env(version, browser), timeout=180) == 0


# ---------------------------------------------------------------- versions

def prune(state):
    """delete the versions and virtualenvs that are neither current, previous nor ready for the next start. Not while
    an update runs in the background: the folders it is making would look like left-overs."""
    if updating_elsewhere():
        return log("not pruning old versions: an update is being made ready")
    keep = {v for v in (state.get("current"), state.get("previous"), read_update().get("ready")) if v}
    keep_envs = {lock_hash(VERSIONS / v) for v in keep if (VERSIONS / v / "uv.lock").exists()}
    for d in VERSIONS.iterdir():
        if d.is_dir() and d.name not in keep:
            shutil.rmtree(d, ignore_errors=True)
    for d in ENVS.iterdir():
        if d.is_dir() and d.name not in keep_envs:
            shutil.rmtree(d, ignore_errors=True)


def activate(state, version, vdir):
    if state.get("current") != version:
        state["previous"], state["current"] = state.get("current"), version
    state["pending"] = None
    save_state(state)
    try:                                                            # the stable launcher and the icons follow the app version
        if (vdir / "qargo_launcher.py").exists():
            shutil.copyfile(vdir / "qargo_launcher.py", HOME / "qargo_launcher.py.new")
            replace(HOME / "qargo_launcher.py.new", HOME / "qargo_launcher.py")
        if (vdir / "packaging" / "assets").is_dir():
            shutil.copytree(vdir / "packaging" / "assets", HOME / "assets", dirs_exist_ok=True)
    except OSError as e:                                            # an icon in use (Windows): the old one keeps working
        log("could not refresh the launcher or the icons:", repr(e))
    prune(state)


def rollback(state, why):
    prev = state.get("previous")
    if not prev or not (VERSIONS / prev / ".ok").exists():
        return False
    log(f"{state.get('current')} {why}: back to {prev}")
    state.setdefault("bad", []).append(state["current"])
    state["current"], state["previous"], state["pending"] = prev, None, None
    save_state(state)
    return True


def get_version(state, dist, meta, repair=False):
    """download, unpack, virtualenv, browser and self-test of the version latest.json names; returns its folder.
    Writes only that version's own folders. Raises on failure; a version that fails its self-test, or needs a site
    profile this computer cannot get, goes into state["bad"] (not tried again; a reinstall clears it). Saves nothing."""
    version, bad = meta["version"], state.setdefault("bad", [])
    vdir = VERSIONS / version
    if repair or not (vdir / ".ok").exists():
        z = APP / "downloads" / f"{version}.zip"
        download(f"{dist}/{meta['zip']}", z, meta["sha256"])
        try:
            unpack(z, vdir, version, state)
        except NoSite:
            bad.append(version)
            raise
        finally:
            z.unlink(missing_ok=True)
    envdir = ensure_env(vdir)
    browser = ensure_browser(envdir, state, fresh=repair)
    if not selftest(vdir, envdir, version, browser):
        if repair:                                                  # rebuild the environment once
            shutil.rmtree(envdir, ignore_errors=True)
            envdir = ensure_env(vdir)
            browser = ensure_browser(envdir, state, fresh=True)
        if not repair or not selftest(vdir, envdir, version, browser):
            bad.append(version)
            raise RuntimeError(f"version {version} failed its self-test; staying on {state.get('current')}")
    return vdir


def update(state, budget, repair=False, step=lambda key: None):
    """install the version latest.json names, if it is new, and make it the current one; returns True when something
    changed. Raises on failure. Only with UPDATE_LOCK held, and only while the program is not open (install, repair)."""
    dist = state["dist"].rstrip("/")
    meta = fetch_latest(dist, budget)
    version, bad = meta["version"], state.setdefault("bad", [])
    if repair and version in bad:                                   # a person asked for it: give the version another chance
        bad.remove(version)
    if version in bad or (version == state.get("current") and not repair):
        return False
    step("update")
    log(f"installing {version} (current: {state.get('current')})")
    try:
        vdir = get_version(state, dist, meta, repair)
    except Exception:
        save_state(state)                                           # the bad list, the browser chosen
        raise
    activate(state, version, vdir)
    log(f"now on {version}")
    return True


# ---------------------------------------------------------------- updates in the background
# The icon starts the installed version at once. Once the program is up, the launcher asks for latest.json and gets a
# new version ready next to the running one: its own app/versions/<new> and envs/<hash> folders, nothing of the
# running version is touched. It never writes state.json (a start may happen meanwhile): what it got ready goes to
# app/update.json, which the next start reads (take_ready) - that start runs the new version. The app reads the same
# file and says in its window that an update is ready.

def read_update():
    """app/update.json: {"ready": version got ready for the next start, "bad": versions that failed in the background}"""
    try:
        u = json.loads(UPDATE_FILE.read_text(encoding="utf-8-sig"))
        return u if isinstance(u, dict) else {}
    except Exception:
        return {}


def forget_update():
    """app/update.json is used up; on Windows a reader may hold it a moment: then the next start finds it again"""
    try:
        UPDATE_FILE.unlink(missing_ok=True)
    except OSError as e:
        log("update.json not removed:", repr(e))


def write_update(u):
    APP.mkdir(parents=True, exist_ok=True)
    tmp = UPDATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(u, indent=1), encoding="utf-8")
    replace(tmp, UPDATE_FILE)


def take_ready(state):
    """at a start (the program is not open): the version an update in the background got ready runs from now on"""
    u = read_update()
    if not u:
        return
    bad = state.setdefault("bad", [])
    bad += [v for v in u.get("bad", []) if isinstance(v, str) and v not in bad]
    ready = u.get("ready")
    forget_update()
    vdir = VERSIONS / str(ready)
    if (ready and ready != state.get("current") and ready not in bad and (vdir / ".ok").exists()
            and (vdir / "uv.lock").exists() and (ENVS / lock_hash(vdir) / ".ok").exists()):
        log(f"{ready} was made ready in the background: it runs from this start on (was {state.get('current')})")
        activate(state, ready, vdir)
    else:
        save_state(state)


def stage(state):
    """after the start, the program open: get the version latest.json names ready for the next start (see above)"""
    if not take_lock(UPDATE_LOCK):
        return log("background update: another one is running")
    try:
        mine = json.loads(json.dumps(state))                        # a copy that is never saved
        dist = mine["dist"].rstrip("/")
        meta = fetch_latest(dist, CHECK_BUDGET)
        u = read_update()
        version = meta["version"]
        mine["bad"] = sorted(set(mine.get("bad") or []) | set(u.get("bad") or []))
        if version == mine.get("current") or version in mine["bad"] or version == u.get("ready"):
            return log(f"background update: nothing new ({version})")
        log(f"background update: getting {version} ready for the next start (running {mine.get('current')})")
        try:
            get_version(mine, dist, meta)
        except Exception:
            if version in mine["bad"]:
                write_update({**read_update(), "bad": sorted(set(read_update().get("bad") or []) | {version})})
            raise
        write_update({**read_update(), "ready": version})
        log(f"background update: {version} is ready; it runs from the next start")
    except Exception as e:                                          # offline, a bad release ...: the next start tries again
        log("background update skipped:", repr(e))
    finally:
        UPDATE_LOCK.unlink(missing_ok=True)


# ---------------------------------------------------------------- windows of our own

class Progress:
    """Runs the work in a thread and shows a small window only while one step takes longer than a second."""

    def __init__(self):
        self.key, self.since = None, time.time()
        self.stage = False                                          # launch(): get the next version ready afterwards

    def step(self, key):
        if key != self.key:
            self.key, self.since = key, time.time()

    def run(self, work):
        box = {}

        def target():
            try:
                box["value"] = work()
            except BaseException as e:                              # a fault in a worker thread must end in fatal(), not in silence
                box["error"] = e
                log("ERROR", "".join(traceback.format_exception(e)).strip())
        t = threading.Thread(target=target, daemon=True)
        t.start()
        while t.is_alive():
            t.join(0.05)
            if t.is_alive() and self.key and time.time() - self.since > 1.0:
                if HEADLESS:
                    log("progress window skipped (QARGO_HEADLESS):", self.key)
                else:
                    self.window(t)
                    gc.collect()                                    # Tk wants to be freed in the thread that made it
                break
        t.join()
        return box

    def window(self, t):
        root = None
        try:
            import tkinter as tk
            from tkinter import ttk
            root = tk.Tk()
            log("progress window:", self.key)
            root.title(APP_TITLE)
            root.resizable(False, False)
            try:
                root.iconphoto(True, tk.PhotoImage(file=str(HOME / "assets" / "icon.png")))
            except Exception:
                pass
            label = ttk.Label(root, text=text(self.key), padding=(28, 22, 28, 10), font=("TkDefaultFont", 15), justify="center")
            label.pack()
            bar = ttk.Progressbar(root, mode="indeterminate", length=360)
            bar.pack(padx=28, pady=(4, 24))
            bar.start(12)
            root.protocol("WM_DELETE_WINDOW", lambda: None)         # closing it would not stop the work
            root.update_idletasks()
            w, h = root.winfo_reqwidth(), root.winfo_reqheight()
            root.geometry(f"+{(root.winfo_screenwidth() - w) // 2}+{(root.winfo_screenheight() - h) // 3}")
            root.attributes("-topmost", True)

            def poll():
                if not t.is_alive():
                    return root.destroy()
                label.config(text=text(self.key))
                root.after(100, poll)
            root.after(100, poll)
            root.mainloop()
        except Exception as e:                                      # no display, no tkinter: just wait
            log("no progress window:", repr(e))
            try:
                root.destroy()                                      # never leave a dead window on the screen
            except Exception:
                pass


def fatal(detail):
    """never a stack trace on the screen: one plain sentence and where the log is"""
    log("FATAL", detail)
    message = text("failed") + "\n\n" + text("log").format(path=LOGS / "launcher.log")
    if HEADLESS:
        return 1
    try:
        import tkinter as tk
        from tkinter import messagebox
        root = tk.Tk()
        root.withdraw()
        root.attributes("-topmost", True)
        messagebox.showerror(APP_TITLE, message, parent=root)
        root.destroy()
    except Exception:
        try:
            if WIN:
                import ctypes
                ctypes.windll.user32.MessageBoxW(None, message, APP_TITLE, 0x10)
            elif MAC:
                subprocess.run(["/usr/bin/osascript", "-e", "on run argv", "-e",
                                "display alert (item 1 of argv) message (item 2 of argv) as critical", "-e", "end run",
                                APP_TITLE, message], capture_output=True, timeout=600)
        except Exception:
            pass
    return 1


# ---------------------------------------------------------------- starting the app

def spawn_app(version, browser, extra=()):
    """start "<venv python> -m qargo_app" on its own feet: it must outlive this launcher. print() of the app lands in app.log"""
    vdir = VERSIONS / version
    envdir = ENVS / lock_hash(vdir)
    exe, flags = venv_python(envdir, gui=True), 0
    if WIN and not exe.exists():                                    # no pythonw.exe in the venv: python.exe with a hidden console
        exe, flags = venv_python(envdir), NO_WINDOW
    out = open(LOGS / "app.log", "ab")
    own = dict(creationflags=flags | 0x00000200) if WIN else dict(start_new_session=True)       # CREATE_NEW_PROCESS_GROUP
    return subprocess.Popen([str(exe), "-m", "qargo_app", *extra], cwd=vdir, env=app_env(version, browser),
                            stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT, **own)


def start(state, version, ui, extra):
    """start one version and watch it come up: "up", "quit" (left again without complaint), "failed" or "slow" """
    vdir = VERSIONS / version
    if not (ENVS / lock_hash(vdir) / ".ok").exists():
        ui.step("prepare")                                          # the virtualenv was deleted or never finished
    envdir = ensure_env(vdir)
    browser = ensure_browser(envdir, state)
    ui.step("start")
    STARTED_OK.unlink(missing_ok=True)
    try:
        f = LOGS / "app.log"
        if f.exists() and f.stat().st_size > 5_000_000:
            os.replace(f, LOGS / "app.old.log")
    except OSError:
        pass
    state["pending"] = version
    save_state(state)
    log("starting", version, "browser:", browser)
    p = spawn_app(version, browser, extra)
    state["app_pid"] = p.pid
    save_state(state)
    outcome, deadline = "slow", time.time() + START_WAIT
    while time.time() < deadline:
        if STARTED_OK.exists():
            outcome = "up"
            break
        rc = p.poll()
        if rc is not None:
            outcome = "up" if STARTED_OK.exists() else "quit" if rc == 0 else "failed"
            if outcome != "up":
                log(f"the app ended with exit code {rc} before its control page was showing")
            break
        time.sleep(0.1)
    if outcome == "up":
        state["proven"] = version
    if outcome != "slow":                                           # "slow": the next start decides (settle)
        state["pending"] = None
    save_state(state)
    log("start of", version, "->", outcome)
    return outcome


def settle(state):
    """the verdict on a start we stopped watching: a version that never showed its control page goes back"""
    pending = state.get("pending")
    if not pending:
        return
    if STARTED_OK.exists():
        state["proven"] = pending
    elif pending == state.get("current") and state.get("proven") != pending:
        rollback(state, "did not come up last time")
    state["pending"] = None
    save_state(state)


def launch(ui, extra):
    if not take_lock():
        log("another launcher is busy; ignoring this start")
        return 0
    try:
        state = load_state()
        if not state.get("dist") and "://" in DIST_BASE:
            state["dist"] = DIST_BASE + "/stable"
        current = state.get("current")
        if current and (VERSIONS / current / ".ok").exists() and app_running(state):
            # Nothing may be updated or rebuilt underneath a running app. A second copy asks the first to show its window and leaves.
            log("the app is already running: starting it once more so that its window comes to the front")
            spawn_app(current, state.get("browser") or "chromium", extra)
            return 0
        settle(state)
        updates = bool(state.get("dist")) and not os.environ.get("QARGO_NO_UPDATE")
        if updates:
            take_ready(state)                                       # got ready in the background last time
        ui.step("start")
        if updates and (not state.get("current") or not (VERSIONS / state["current"] / ".ok").exists()):
            install_now(state, ui, "no working version installed", repair=True)
        version = state.get("current")
        if not version or not (VERSIONS / version / ".ok").exists():
            raise RuntimeError("no installed version")
        outcome = start(state, version, ui, extra)
        if outcome == "failed" and state.get("proven") != version and rollback(state, "failed at its first start"):
            outcome = start(state, state["current"], ui, extra)
        if outcome == "failed" and updates and install_now(state, ui, f"{state['current']} failed at its start"):
            outcome = start(state, state["current"], ui, extra)     # a newer version was out: it may have the fix
        if outcome == "failed":
            raise RuntimeError("the app ended with an error while starting (see app.log)")
        ui.stage = updates                                          # once the program is up: the next version, in the background
        return 0
    finally:
        LOCK.unlink(missing_ok=True)


def install_now(state, ui, why, repair=False):
    """the program cannot start as it is: install the newest version first, the operator waiting ("Installing an
    update"). Waits for an update that runs in the background, which may be getting that very version. True when a
    new version is current now. state is changed in place."""
    log(f"{why}: installing the newest version before the start")
    ui.step("update")
    if not wait_update_lock(ui.step):
        log("an update in the background is still busy: starting what is installed")
        return False
    try:
        before = state.get("current")
        take_ready(state)                                           # the update that just ended may have got it ready
        if state.get("current") != before and (VERSIONS / state["current"] / ".ok").exists():
            return True
        return update(state, CHECK_BUDGET, repair=repair, step=ui.step)
    except Exception as e:                                          # offline, bad release...: start what we have
        log("update skipped:", repr(e))
        fresh = load_state()
        state.clear()
        state.update(fresh)
        return False
    finally:
        UPDATE_LOCK.unlink(missing_ok=True)


def cmd_launch(extra):
    if MAC:
        log("launch on", os.uname().machine, "rosetta:", subprocess.run(["/usr/sbin/sysctl", "-in", "sysctl.proc_translated"],
                                                                         capture_output=True, text=True).stdout.strip() or "0")
    ui = Progress()
    box = ui.run(lambda: launch(ui, extra))
    if "error" in box:
        return fatal(repr(box["error"]))
    if ui.stage:
        spawn_stage()
    return box.get("value", 0)


def spawn_stage():
    """the background update in a process of its own, so this launcher ends now. On macOS a Tk window stays on the
    screen, frozen, until its process ends: "Starting…" stood over the open program for the whole download (70 s,
    26 Oct 2026)."""
    try:
        own = dict(creationflags=NO_WINDOW | 0x00000200) if WIN else dict(start_new_session=True)   # CREATE_NEW_PROCESS_GROUP
        subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "stage"], env=os.environ.copy(),
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **own)
    except Exception as e:                                          # the next start tries again
        log("background update not started:", repr(e))


def cmd_install(dist, site=None):
    state = load_state()
    if dist:
        state["dist"] = dist
    elif not state.get("dist") and "://" in DIST_BASE:
        state["dist"] = DIST_BASE + "/stable"
    if not state.get("dist"):
        raise SystemExit("install: --dist URL is required the first time")
    if site:
        if not SITE_ID.fullmatch(site):
            raise SystemExit(f"install: {site!r} is not a site code (20-40 digits and letters a-f)")
        state["site"], state["site_refresh"] = site, True          # a reinstall reads the profile again
    save_state(state)
    if app_running(state) or not take_lock():
        say("Qargo Autofill is open or is starting. Close it and run the installer again.")
        return 3
    try:
        if not take_lock(UPDATE_LOCK):
            say("Qargo Autofill is getting an update ready. Waiting for it to finish…")
            if not wait_update_lock():
                say("The update is still busy. Run the installer again in a few minutes.")
                return 3
        try:
            state["pending"] = None
            update(state, budget=CHECK_BUDGET, repair=True)
            forget_update()                                         # what an update got ready before is this one, or older
        finally:
            UPDATE_LOCK.unlink(missing_ok=True)
    except NoSite as e:
        say(f"Qargo Autofill needs its site code: {e}")
        return 4
    finally:
        LOCK.unlink(missing_ok=True)
    log("installed", state["current"], "in", HOME)
    return 0


def cmd_status():
    state = load_state()
    info = {"home": str(HOME), "data": str(DATA), "running": app_running(state), **state,
            "ready_for_next_start": read_update().get("ready"), "updating_now": updating_elsewhere()}
    current = state.get("current")
    if current and (VERSIONS / current / "uv.lock").exists():
        info["python"] = str(venv_python(ENVS / lock_hash(VERSIONS / current)))
    say(json.dumps(info, indent=1))
    return 0


def cmd_rollback():
    state = load_state()
    if app_running(state):
        raise SystemExit("Qargo Autofill is open. Close it first.")
    if not rollback(state, "was rolled back by hand"):
        raise SystemExit("no previous version to go back to")
    forget_update()                                                 # back on purpose: nothing newer slips in at the next start
    say(f"now on {state['current']}")
    return 0


def cmd_reset_profile():
    if app_running(load_state()):                   # the browser holds the folder: Windows refuses, macOS renames it under it
        raise SystemExit("Qargo Autofill is open. Close it first.")
    for p in DATA.glob("profile-*"):
        if p.is_dir() and ".old-" not in p.name:
            try:
                p.rename(p.with_name(f"{p.name}.old-{time.strftime('%Y%m%d-%H%M%S')}"))
            except OSError as e:
                raise SystemExit(f"{p.name} could not be moved aside ({type(e).__name__}: {e}). Close every Qargo Autofill window and try again.")
            say(f"moved aside: {p.name} (Qargo will ask you to log in again)")
    return 0


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "launch"
    if cmd == "selfcheck":                                          # a newer launcher proves it can at least be loaded
        print("launcher ok")
        return 0
    if cmd != "install" and not HOME.is_dir():                      # only an install may create the folder
        say(f"Qargo Autofill is not installed in {HOME}")
        return 1
    setup_logging()
    if cmd == "launch":
        return cmd_launch(argv[2:])
    if cmd == "install":
        arg = lambda flag: argv[argv.index(flag) + 1] if flag in argv[:-1] else None
        return cmd_install(arg("--dist"), arg("--site"))
    if cmd == "stage":                                              # started by cmd_launch, never by hand
        stage(load_state())
        return 0
    if cmd == "status":
        return cmd_status()
    if cmd == "rollback":
        return cmd_rollback()
    if cmd == "reset-profile":
        return cmd_reset_profile()
    raise SystemExit(__doc__)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except SystemExit:
        raise
    except Exception as e:
        log("".join(traceback.format_exception(e)).strip())
        if sys.__stderr__ is not None:
            print(f"ERROR: {e}", file=sys.__stderr__)
        sys.exit(45 if _blocked else 1)                             # 45 tells the Windows installer: application control
