#!/usr/bin/env python3
# Lists the symbols a Windows engine imports from macOS system libraries that an older SDK doesn't export, i.e. what
# would be missing (strong: dyld refuses to load; weak: NULL, crash on call) on that macOS. Engine 1.0.5 imported
# _pipe2 weakly and crashed on macOS 26. Known false positives: dyld_stub_binder, _OBJC_EHTYPE_$_NSException.
#
#   tools/check-runtime-symbols.py /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk <unpacked runtime>
import os, re, subprocess, sys
sdk, roots = sys.argv[1], sys.argv[2:]
exported = set()
for base in ("usr/lib", "System/Library/Frameworks", "System/Library/PrivateFrameworks"):
    for d, _, fs in os.walk(os.path.join(sdk, base)):
        for f in fs:
            if f.endswith(".tbd"):
                txt = open(os.path.join(d, f), errors="replace").read()
                exported.update(re.findall(r"[\[ ,'\"]((?:_|\.objc_class_name_)[A-Za-z0-9_$.:]+)", txt))
                for block in re.findall(r"objc-classes:\s*\[([^\]]*)\]", txt, re.S):
                    for c in re.findall(r"[A-Za-z0-9_]+", block):
                        exported.update({"_OBJC_CLASS_$_" + c, "_OBJC_METACLASS_$_" + c})
                for block in re.findall(r"objc-ivars:\s*\[([^\]]*)\]", txt, re.S):
                    for c in re.findall(r"[A-Za-z0-9_.]+", block):
                        exported.add("_OBJC_IVAR_$_" + c)
problems, files = {}, 0
for root in roots:
    for d, _, fs in os.walk(root):
        for f in fs:
            p = os.path.join(d, f)
            if os.path.islink(p) or not os.path.isfile(p): continue
            with open(p, "rb") as h:
                if h.read(4) not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xce\xfa\xed\xfe"): continue
            files += 1
            libs = [l.strip().split(" (")[0] for l in subprocess.run(["otool", "-L", p], capture_output=True, text=True).stdout.splitlines()[1:]]
            out = subprocess.run(["nm", "-m", "-u", p], capture_output=True, text=True).stdout
            for line in out.splitlines():
                m = re.search(r"external (\S+) \(from ([^)]+)\)", line)
                if not m: continue
                sym, lib = m.groups()
                src = next((l for l in libs if os.path.basename(l).split(".")[0] == lib or ("/" + lib + ".framework/") in l), "")
                if not (src.startswith("/usr/lib/") or src.startswith("/System/")): continue
                if sym not in exported:
                    problems.setdefault((sym, lib, "weak" if "weak" in line else "strong"), []).append(os.path.relpath(p, root))
print(f"{files} Mach-O files checked, {len(exported)} SDK symbols")
for (sym, lib, kind), ps in sorted(problems.items()):
    print(f"MISSING {sym} ({lib}, {kind}) in {len(ps)}: {', '.join(ps[:4])}")
