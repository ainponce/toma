# Toma

Grabador de pantalla nativo y de código abierto para macOS (Apple silicon, macOS 15+). A native, open-source screen recorder for macOS. Nombre en clave provisorio.

Licencia: GPL-3.0-or-later.

## Instalar / Install

Requiere Xcode 27 y XcodeGen.

```sh
make project
make install
```

`make install` compila en Release y copia `Toma.app` a `/Applications`.

## Primera apertura

Toma todavía no está firmada con un Apple Developer ID, así que macOS la bloquea la primera vez. Para abrirla: Ajustes del Sistema → Privacidad y seguridad → "Abrir igualmente".

## Desarrollo / Development

Ver [CONTRIBUTING.md](CONTRIBUTING.md). `make test` corre las pruebas.
