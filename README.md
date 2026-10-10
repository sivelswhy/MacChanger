# MacChanger

A tiny macOS app that changes your Wi-Fi (`en0`) MAC address to a random one, in one click.

## Build

```sh
./build.sh
open MacChanger.app
```

Requires macOS 13+ and the Xcode command line tools (`swiftc`).

The app icon is drawn by `icon/make-icon.swift`; run `swift icon/make-icon.swift` to regenerate `icon/AppIcon.icns`.

Or download `MacChanger.zip` from the [Releases](https://github.com/sivelswhy/MacChanger/releases) page. The app is not notarized, so on first launch right-click it and choose "Open", or run `xattr -cr MacChanger.app`.

### Releases

Pushing a `v*` tag builds a universal (Apple Silicon + Intel) app on GitHub Actions and publishes it as a release:

```sh
git tag v1.0.0 && git push origin v1.0.0
```

## Usage

Click "Changer l'adresse MAC" (Change MAC address) and enter your administrator password. Wi-Fi turns off briefly, then reconnects.

If macOS keeps its own private address, turn off "Private Wi-Fi Address" in the Wi-Fi network's settings.

## License

MIT — see [LICENSE](LICENSE).

## Wi-Fi credit monitor

In the app, tick "Surveiller les crédits (NormandieTrainConnecte)". Every 10 seconds the app reads the remaining credits (percentage and megabytes left) from the captive portal API (`wifi.normandie.fr`). If the current address has no data plan yet, it simply accepts the terms of use to get one. When they run out, it changes the MAC address, rejoins the network and accepts the cookies and the terms of use again by itself. The portal only opens in your browser if that automatic step fails.

The first MAC change asks for your administrator password once: it installs a small root tool (`/Library/PrivilegedHelperTools/local.macchanger.rotate`) and a sudo rule (`/etc/sudoers.d/macchanger`) so later changes need no password. To remove them: `sudo rm /Library/PrivilegedHelperTools/local.macchanger.rotate /etc/sudoers.d/macchanger`.
 A copy of the portal page is saved to `~/Library/Logs/MacChanger/portal.html`.

The remaining credits are also shown in the macOS menu bar (`–` when unknown). Its menu lets you reopen the window, change the MAC address, check the credits right away, or quit. Closing the window keeps the app running in the menu bar.

### Command-line version

`wifi-monitor.sh` watches the remaining internet credits on the `NormandieTrainConnecte` captive portal (`wifi.normandie.fr`). Every time they run out, it switches to a new random MAC address and rejoins the network.

```sh
sudo ./wifi-monitor.sh
```

After each change, the portal opens in your browser so you can accept the cookies and the terms of use. A copy of the portal page is saved in `portal-dump/`. Settings such as `SSID`, `PORTAL`, `INTERVAL` and `MIN_CREDITS` can be overridden with environment variables, for example `sudo INTERVAL=10 ./wifi-monitor.sh`.
