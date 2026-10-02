# MacChanger

Petite app macOS qui change l'adresse MAC Wi-Fi (`en0`) en une adresse aléatoire, en un clic.

## Compiler

```sh
./build.sh
open MacChanger.app
```

Nécessite macOS 13+ et les outils en ligne de commande Xcode (`swiftc`).

## Utilisation

Clique sur « Changer l'adresse MAC » et entre ton mot de passe administrateur. Le Wi-Fi se coupe brièvement puis se reconnecte.

Si macOS garde son adresse privée, désactive « Adresse Wi-Fi privée » dans les réglages du réseau Wi-Fi.
