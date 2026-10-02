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
