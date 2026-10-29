"""win-arm64 megabuild helper, run by bld.bat with the host %PYTHON%.

The libtorch output compiles the whole tree once against megabuild_python. Each
pytorch output then runs `pip install` on the same build\\ directory. CMake would
keep the previous Python's discovery results (python312.lib, the cp312 module
suffix, ...), so before every pytorch output this drops those cache entries and
lets FindPython / scikit-build-core rediscover the current host Python. When the
Python minor version changed, it also deletes the objects and outputs of the
Python-dependent targets: the include dir text can stay identical between
versions, so ninja would otherwise reuse objects compiled against the old headers.

  save     end of the libtorch output: keep CMakeCache.txt.orig and a baseline
  prepare  pytorch output, before pip
  report   pytorch output, after pip: fail unless only the Python-dependent
           targets were rebuilt (from .ninja_log) and the core DLLs are untouched
"""
import hashlib
import json
import os
import re
import shutil
import sys
import time

BUILD = os.path.join(os.environ["SRC_DIR"], "build")
CACHE = os.path.join(BUILD, "CMakeCache.txt")
ORIG = CACHE + ".orig"
BASELINE = os.path.join(BUILD, "megabuild_baseline.json")
LASTPY = os.path.join(BUILD, "megabuild_lastpy.txt")
NINJA_LOG = os.path.join(BUILD, ".ninja_log")
NINJA_BEFORE = os.path.join(BUILD, "megabuild_ninja_before.json")
SKBUILD_INFO = os.path.join(BUILD, ".skbuild-info.json")

# Python discovery state: FindPython, the legacy PYTHON_* names, pybind11 and
# scikit-build-core's ABI entries.
PYTHON_KEY = re.compile(
    r"^(?:_?Python3?(?:_|$)|PYTHON_|"
    r"PYBIND11_PYTHON_EXECUTABLE_LAST$|pybind11_INCLUDE_DIRS$|"
    r"FIND_PACKAGE_MESSAGE_DETAILS_Python3?$|"
    r"SKBUILD_(?:SOABI|SABI_COMPONENT|SABI_VERSION)$)"
)
# Targets that compile against Python.h or link the Python import library.
PYTHON_TARGETS = ("torch_python", "_C", "nnapi_backend")
CORE_DLLS = ("torch_cpu.dll", "c10.dll", "torch.dll", "torch_cuda.dll", "c10_cuda.dll")
# Small outputs a pytorch output may legitimately rebuild besides PYTHON_TARGETS.
ALLOWED_BINARIES = ("torch_global_deps.",)
BINARY_EXT = (".obj", ".dll", ".lib", ".pyd", ".exe")


def pyver():
    return "%d.%d" % sys.version_info[:2]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def log(msg):
    print("MEGABUILD: " + msg, flush=True)


def ninja_entries():
    """output -> recorded mtime, from .ninja_log (newest entry wins).

    Comparing two snapshots shows what ninja rebuilt in between, even if ninja
    recompacted the log.
    """
    entries = {}
    with open(NINJA_LOG, encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 5 and not line.startswith("#"):
                entries[parts[3].replace("\\", "/")] = parts[2]
    return entries


def dll_state():
    state = {}
    for name in CORE_DLLS:
        p = os.path.join(BUILD, "bin", name)
        if os.path.exists(p):
            state[name] = [sha256(p), os.stat(p).st_mtime_ns]
    return state


def native_objects():
    """relative path -> [size, mtime_ns] for every .obj outside the Python targets."""
    objs = {}
    for root, _, files in os.walk(BUILD):
        for name in files:
            if name.lower().endswith(".obj"):
                p = os.path.join(root, name)
                rel = os.path.relpath(p, BUILD).replace("\\", "/")
                if not is_python_target(rel):
                    st = os.stat(p)
                    objs[rel] = [st.st_size, st.st_mtime_ns]
    return objs


def is_python_target(path):
    norm = path.replace("\\", "/")
    base = os.path.basename(norm)
    return (any("/%s.dir/" % t in norm for t in PYTHON_TARGETS)
            or base.startswith(tuple(t + "." for t in PYTHON_TARGETS) + ALLOWED_BINARIES))


def save():
    for f in (CACHE, os.path.join(BUILD, "build.ninja")):
        if not os.path.exists(f):
            sys.exit("MEGABUILD: missing %s after the libtorch build" % f)
    if os.path.exists(BASELINE):
        sys.exit("MEGABUILD: baseline already exists: %s" % BASELINE)
    shutil.copy2(CACHE, ORIG)
    dlls = dll_state()
    objs = native_objects()
    with open(BASELINE, "w") as f:
        json.dump({"python": pyver(), "time": time.time(), "dlls": dlls, "objs": objs}, f, indent=1)
    with open(LASTPY, "w") as f:
        f.write(pyver())
    log("MEGABUILD_BASELINE python %s, %d core DLLs hashed, %d native objects recorded, cache saved to %s"
        % (pyver(), len(dlls), len(objs), ORIG))


def target_paths():
    """Objects and outputs of PYTHON_TARGETS, from build.ninja."""
    objs, outs = [], []
    with open(os.path.join(BUILD, "build.ninja"), encoding="utf-8", errors="replace") as f:
        for line in f:
            if not line.startswith("build "):
                continue
            outputs = line[6:].split(":", 1)[0].replace("$:", ":").split()
            for o in outputs:
                o = o.replace("$ ", " ")
                norm = o.replace("/", "\\")
                if any("\\%s.dir\\" % t in norm for t in PYTHON_TARGETS) and norm.endswith(".obj"):
                    objs.append(norm)
                base = os.path.basename(norm)
                if base.startswith(("torch_python.", "_C.", "nnapi_backend.")) and not norm.endswith(".obj"):
                    outs.append(norm)
    return objs, outs


def check_skbuild():
    """scikit-build-core deletes CMakeCache.txt and CMakeFiles (a full rebuild) when
    its own location or version differs from .skbuild-info.json; fail before that."""
    import scikit_build_core
    with open(SKBUILD_INFO) as f:
        info = json.load(f)
    here = os.path.dirname(os.path.abspath(scikit_build_core.__file__))
    if (os.path.normcase(info["skbuild_path"]) != os.path.normcase(here)
            or info["skbuild_version"] != scikit_build_core.__version__):
        sys.exit("MEGABUILD: scikit-build-core changed (%s %s -> %s %s); it would reset the build tree"
                 % (info["skbuild_path"], info["skbuild_version"], here, scikit_build_core.__version__))


def prepare():
    if not os.path.exists(ORIG):
        sys.exit("MEGABUILD: no %s; the libtorch output did not save a baseline" % ORIG)
    check_skbuild()
    with open(NINJA_BEFORE, "w") as f:
        json.dump(ninja_entries(), f)
    kept, dropped = [], 0
    with open(ORIG, encoding="utf-8", errors="surrogateescape") as f:
        for line in f:
            if not line.startswith(("#", "//")) and ":" in line and "=" in line:
                if PYTHON_KEY.match(line.split(":", 1)[0]):
                    dropped += 1
                    continue
            kept.append(line)
    tmp = CACHE + ".tmp"
    with open(tmp, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.writelines(kept)
    os.replace(tmp, CACHE)
    log("restored CMakeCache.txt.orig without %d Python discovery entries" % dropped)

    last = open(LASTPY).read().strip() if os.path.exists(LASTPY) else None
    if last == pyver():
        log("python %s already built in this tree; no Python-target invalidation" % pyver())
        return
    objs, outs = target_paths()
    removed = 0
    for rel in objs + outs:
        p = os.path.normpath(os.path.join(BUILD, rel))
        if not p.startswith(BUILD + os.sep):
            continue
        if os.path.exists(p):
            os.remove(p)
            removed += 1
    log("python %s -> %s: removed %d of %d objects/outputs of %s"
        % (last, pyver(), removed, len(objs) + len(outs), ", ".join(PYTHON_TARGETS)))


def report():
    with open(BASELINE) as f:
        base = json.load(f)
    with open(NINJA_BEFORE) as f:
        before = json.load(f)
    rebuilt = [o for o, m in ninja_entries().items() if before.get(o) != m]
    binaries = [o for o in rebuilt if o.lower().endswith(BINARY_EXT)]
    bad = sorted(o for o in binaries if not is_python_target(o))
    py_objs = [o for o in binaries if o.endswith(".obj") and is_python_target(o)]
    log("python %s: ninja rebuilt %d outputs, %d binaries, %d Python-target objects"
        % (pyver(), len(rebuilt), len(binaries), len(py_objs)))
    changed = [n for n, st in base["dlls"].items() if dll_state().get(n) != st]
    now = native_objects()
    missing = sorted(set(base["objs"]) - set(now))
    added = sorted(set(now) - set(base["objs"]))
    altered = sorted(o for o in set(now) & set(base["objs"]) if now[o] != base["objs"][o])
    last = open(LASTPY).read().strip() if os.path.exists(LASTPY) else None
    errors = []
    for what, paths in (("missing", missing), ("added", added), ("changed", altered)):
        if paths:
            errors.append("%d native objects %s since the baseline, e.g. %s" % (len(paths), what, paths[:10]))
    if bad:
        errors.append("%d non-Python binaries rebuilt, e.g. %s" % (len(bad), bad[:10]))
    if changed:
        errors.append("core DLLs changed since the baseline: %s" % changed)
    if last != pyver() and not py_objs:
        errors.append("python changed %s -> %s but no Python-target object was recompiled" % (last, pyver()))
    if errors:
        for e in errors:
            log("ERROR: " + e)
        sys.exit("MEGABUILD: build-tree reuse check failed for python %s" % pyver())
    with open(LASTPY, "w") as f:
        f.write(pyver())
    log("python %s: reuse check passed (core DLLs unchanged)" % pyver())


if __name__ == "__main__":
    {"save": save, "prepare": prepare, "report": report}[sys.argv[1]]()
