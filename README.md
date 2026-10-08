# MacChanger

A tiny macOS app that changes your Wi-Fi (`en0`) MAC address to a random one, in one click.

## Build

```sh
./build.sh
open MacChanger.app
```

Requires macOS 13+ and the Xcode command line tools (`swiftc`).

## Usage

Click "Changer l'adresse MAC" (Change MAC address) and enter your administrator password. Wi-Fi turns off briefly, then reconnects.

If macOS keeps its own private address, turn off "Private Wi-Fi Address" in the Wi-Fi network's settings.

## License

MIT — see [LICENSE](LICENSE).

## Wi-Fi credit monitor

In the app, tick "Surveiller les crédits (NormandieTrainConnecte)". Every 10 seconds the app reads the remaining credits on the captive portal (`wifi.normandie.fr`). When they run out, it changes the MAC address (asking for your password) and opens the portal so you can accept the cookies and the terms of use again. A copy of the portal page is saved to `~/Library/Logs/MacChanger/portal.html`.

The remaining credits are also shown in the macOS menu bar (`–` when unknown). Its menu lets you reopen the window, change the MAC address, check the credits right away, or quit. Closing the window keeps the app running in the menu bar.

### Command-line version

`wifi-monitor.sh` watches the remaining internet credits on the `NormandieTrainConnecte` captive portal (`wifi.normandie.fr`). Every time they run out, it switches to a new random MAC address and rejoins the network.

```sh
sudo ./wifi-monitor.sh
```

After each change, the portal opens in your browser so you can accept the cookies and the terms of use. A copy of the portal page is saved in `portal-dump/`. Settings such as `SSID`, `PORTAL`, `INTERVAL` and `MIN_CREDITS` can be overridden with environment variables, for example `sudo INTERVAL=10 ./wifi-monitor.sh`.
