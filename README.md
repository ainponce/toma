# Toma

Grabador de pantalla nativo y de código abierto para macOS (Apple silicon, macOS 15+). A native, open-source screen recorder for macOS. Nombre en clave provisorio.

Licencia: GPL-3.0-or-later.

## Instalar

1. Bajar `Toma-<versión>.dmg` de la página de [Releases](../../releases).
2. Abrir el DMG y arrastrar Toma a Aplicaciones.
3. Abrir Toma. La primera vez macOS no la deja abrir, porque Toma no está notarizada por Apple (el proyecto no paga la cuenta de desarrollador de Apple). El aviso dice:

   > **PENDIENTE:** el texto exacto del aviso de macOS, que se anota en la verificación 2 de [docs/release.md](docs/release.md#verificaciones-del-dueño).

4. Ir a Ajustes del Sistema → Privacidad y seguridad. En la sección Seguridad aparece un mensaje sobre Toma: elegir "Abrir igualmente" y confirmar. Hace falta una sola vez.

Toma se firma siempre con el mismo certificado propio del proyecto ("Toma Project Signing"), para que macOS la reconozca como la misma app en cada versión y no vuelva a pedir los permisos de grabación de pantalla y micrófono al actualizar.

## Compilar desde el código

Requiere Xcode 27 (gratis en la App Store) y [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make project
make install
```

`make install` compila en Release y copia `Toma.app` a `/Applications`. Como se compila en la propia Mac, macOS la abre sin aviso.

## Actualizaciones

Toma busca actualizaciones con [Sparkle](https://sparkle-project.org): una vez por día si se acepta cuando lo pregunta, o cuando se elige "Buscar actualizaciones…" en su menú de la barra de menús. Cada actualización viene firmada con la clave EdDSA del proyecto, y Sparkle descarta cualquier archivo que no tenga esa firma. Mientras se graba, "Buscar actualizaciones…" está desactivado, y una actualización ya descargada espera a que termine la grabación para instalarse y volver a abrir la app.

Una copia compilada desde el código se actualiza compilando de nuevo: `git pull && make project && make install`.

En la fase 0 las actualizaciones apuntan a un servidor de prueba local; el feed público llega con el primer release público. Ver [docs/release.md](docs/release.md).

## Desarrollo / Development

Ver [CONTRIBUTING.md](CONTRIBUTING.md). `make test` corre las pruebas.
