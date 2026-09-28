#!/usr/bin/env python3
"""Builds a macOS-runnable copy of the REAL Windows engine for interop tests.

Copies windows/daemon/**/*.cs (the ClipLinkEngine library the Windows app
runs in-process) verbatim into <out>/src and applies only platform shims -
nothing that touches networking, crypto, JSON, history, trust or
file-transfer logic:
  * DPAPI (Windows-only) -> plain bytes on disk
  * AppData root and beacon destinations from env vars (so it can run beside
    another node on one Mac without touching ~/Library)
  * optional fixed identity key / preset passcode (tests pick tie-breaker order)
  * no STA apartment, optional fake Tailscale IP
  * the WinForms clipboard is replaced by FakeClipboardSync.cs (stdin/stdout)
HarnessHost.cs is the program: it starts the engine (discovery UDP port from
CLIPLINK_UDP_PORT) and serves the old tray pipe commands the tests send.
Usage: prepare.py <repo-root> <out-dir>
"""
import os, re, shutil, sys

repo, out = sys.argv[1], sys.argv[2]
daemon = os.path.join(repo, "windows", "daemon")
src = os.path.join(out, "src")
shutil.rmtree(out, ignore_errors=True)
for root, dirs, files in os.walk(daemon):
    dirs[:] = [d for d in dirs if d not in ("bin", "obj", ".vscode")]
    for f in files:
        if f.endswith(".cs"):
            rel = os.path.relpath(os.path.join(root, f), daemon)
            os.makedirs(os.path.join(src, os.path.dirname(rel)), exist_ok=True)
            shutil.copy(os.path.join(root, f), os.path.join(src, rel))
here = os.path.dirname(os.path.abspath(__file__))
os.makedirs(os.path.join(out, "shim"), exist_ok=True)
shutil.copy(os.path.join(here, "FakeClipboardSync.cs"), os.path.join(out, "shim"))
shutil.copy(os.path.join(here, "HarnessHost.cs"), os.path.join(out, "shim"))
shutil.copy(os.path.join(here, "ClipboardDaemonHarness.csproj"), out)

def patch(path, old, new):
    p = os.path.join(src, path)
    s = open(p, encoding="utf-8").read()
    if old not in s:
        sys.exit(f"prepare.py: {path} changed upstream - shim anchor not found:\n{old[:120]}")
    open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))

for root, _, files in os.walk(src):
    for f in files:
        p = os.path.join(root, f)
        s = open(p, encoding="utf-8").read()
        s = s.replace("Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData)",
                      '(Environment.GetEnvironmentVariable("CLIPLINK_APPDATA") ?? Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData))')
        s = re.sub(r"System\.Security\.Cryptography\.ProtectedData\.(Unprotect|Protect)\((\w+), null, System\.Security\.Cryptography\.DataProtectionScope\.CurrentUser\)", r"\2", s)
        open(p, "w", encoding="utf-8").write(s)

patch("Identity/DeviceIdentity.cs", "        bool loaded = false;\n",
      '        bool loaded = false;\n        string? fixedKey = Environment.GetEnvironmentVariable("CLIPLINK_IDENTITY_PKCS8_B64");\n'
      '        if (!string.IsNullOrEmpty(fixedKey)) { key = ECDsa.Create(ECCurve.NamedCurves.nistP256); key.ImportPkcs8PrivateKey(Convert.FromBase64String(fixedKey), out _); return; }\n')
patch("Identity/PassphraseKeyStore.cs",
      '                Console.WriteLine($"Could not load passphrase key ({ex.Message}) — treating as not set.");\n            }\n        }\n',
      '                Console.WriteLine($"Could not load passphrase key ({ex.Message}) — treating as not set.");\n            }\n        }\n'
      '        string? preset = Environment.GetEnvironmentVariable("CLIPLINK_PASSCODE");\n        if (!string.IsNullOrEmpty(preset)) SetPassphrase(preset);\n')
patch("Networking/Discovery.cs", "        await client.SendAsync(data, data.Length, new IPEndPoint(IPAddress.Broadcast, PORT));",
      '        string? targets = Environment.GetEnvironmentVariable("CLIPLINK_BEACON_TARGETS");\n'
      "        if (string.IsNullOrEmpty(targets)) { await client.SendAsync(data, data.Length, new IPEndPoint(IPAddress.Broadcast, PORT)); return; }\n"
      "        foreach (var t in targets.Split(',', StringSplitOptions.RemoveEmptyEntries))\n"
      "        {\n            var parts = t.Split(':');\n"
      "            await client.SendAsync(data, data.Length, new IPEndPoint(IPAddress.Parse(parts[0]), int.Parse(parts[1])));\n        }")
patch("Networking/TailscaleHelper.cs", "    public static string? GetOwnTailscaleIp()\n    {",
      '    public static string? GetOwnTailscaleIp()\n    {\n        var fake = Environment.GetEnvironmentVariable("CLIPLINK_TAILSCALE_IP"); if (fake != null) return fake.Length == 0 ? null : fake;')
patch("Engine/ClipLinkEngine.cs", "        thisThread.SetApartmentState(ApartmentState.STA);\n", "")
print(f"prepared {out}")
