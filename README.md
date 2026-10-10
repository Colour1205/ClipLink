# cross-device-clipboard-p2p
A hybrid p2p cross device clipboard + history tool. Works on Windows, IOS, Android and HarmonyOS. Seamlessly handoff work to all your device and all history is syncedd on your computer

## Windows

One app, `ClipLink.exe`: a tray icon and a window, with the sync engine running inside it.
Build it with the .NET 10 SDK:

```powershell
powershell -ExecutionPolicy Bypass -File windows\publish.ps1   # -> windows\dist\ClipLink.exe
```

See `windows/README.md` for running it, where its data and logs live, and test options.


TODO:
- android passcode and confirmed passcode box should be combined into 1 (remove confirmed passcode)
- android device connection logic: trusted -- waiting for it in the description when the other d3evice is offline, but should say trusted -- offline.
- FOR ALL PLATFORMS send push notif when a pairing request comes to TRUST or IGNORE (not deny because it is still possible for future request of that person) and if the app is in foreground, popout a modal for the prompt (not a separate page , jsust on top of this page, if there is OS level api for this, use it)
- option to blacklist device sononeoftheir pairingrequest willcomethrough to prevent spam (i.e. in the devices tab a "triple dot" menu with drop down to select the option. and once the device is bklacklisted, the device card should have a dark gray background)
- do this last: qol fix. you know in the device card allthe ip options will be displayed there? thats bad design, only the ip that used for the current connection should display rthere, and user is able to click on the device card to open into detailed view where it shows a list of ips that can connect to that device and other details, the device cards should follow the same logic as preview like the animations for each platform, layout, etc (some aniimation is platform specific)
- FOR ALL PLATFORMS the default card transparency should be 35% (it is 0% now). Only the default changes: anyone who already moved the slider keeps their value. Windows, Android and HarmonyOS still need this; iOS is done.