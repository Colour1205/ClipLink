# cross-device-clipboard-p2p
A hybrid p2p cross device clipboard + history tool. Works on Windows, IOS, Android and HarmonyOS. Seamlessly handoff work to all your device and all history is syncedd on your computer

## Windows

One app, `ClipLink.exe`: a tray icon and a window, with the sync engine running inside it.
Build it with the .NET 10 SDK:

```powershell
powershell -ExecutionPolicy Bypass -File windows\publish.ps1   # -> windows\dist\ClipLink.exe
```

See `windows/README.md` for running it, where its data and logs live, and test options.
