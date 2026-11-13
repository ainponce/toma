# Contribuir a Toma

Gracias por querer ayudar. / Thanks for helping out.

## Developer Certificate of Origin (DCO)

Todos los commits deben llevar la línea `Signed-off-by` (DCO 1.1, https://developercertificate.org). Se agrega con:

```sh
git commit -s -m "feat: mensaje"
```

Toma se distribuye bajo GPL-3.0-or-later; cada archivo fuente empieza con `// SPDX-License-Identifier: GPL-3.0-or-later`.

## Pruebas

```sh
make test
```

Corre las pruebas del paquete `RecorderKit` (Swift Testing). Antes de abrir un pull request, `make test` debe pasar. Las pruebas que necesitan permisos de grabación se activan con `RECORDER_INTEGRATION=1`.

## Entorno

macOS 15 o superior, Apple silicon, Xcode 27 y [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). Genera el proyecto con `make project`.
