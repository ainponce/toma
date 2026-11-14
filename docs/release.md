# Releases de Toma

Toma se distribuye gratis, sin la cuenta paga de desarrollador de Apple (spec §7.6):

- **Firma con un certificado propio estable**, "Toma Project Signing": autofirmado, de firma de código, válido 10 años. Todas las versiones se firman con él, así que el requisito designado de la app (`identifier "dev.toma.Toma" and certificate leaf = H"…"`) no cambia entre versiones y macOS debería conservar los permisos al actualizar. Sin notarización: la primera apertura de un DMG descargado pide "Abrir igualmente".
- **DMG en GitHub Releases**, marcado como prerelease durante la fase 0.
- **Actualizaciones con Sparkle 2**, firmadas con una clave EdDSA propia. El feed es `SPARKLE_FEED_URL` y la clave pública `SPARKLE_PUBLIC_KEY`, los dos en `Config/Identity.xcconfig` (cada `//` escrito como `/$()/`).
- **Compilar desde el código** con `make install`.

Nada secreto entra al repositorio: el certificado con su clave privada y la clave privada de Sparkle viven en el llavero del dueño, en una imagen cifrada guardada offline y en los secretos del entorno `release` de GitHub.

## `scripts/release.sh`

```sh
bash scripts/release.sh 0.0.2
```

Produce `dist/Toma.app`, `dist/Toma-0.0.2.dmg` y `dist/appcast.xml`. En orden:

1. `xcodegen generate` y `xcodebuild archive` en Release, con `CODE_SIGN_STYLE=Manual`, `CODE_SIGN_IDENTITY` = la identidad de firma, `MARKETING_VERSION` = la versión y `CURRENT_PROJECT_VERSION` = `git rev-list --count HEAD` (el número de build que Sparkle compara: cada versión nueva tiene que salir de un commit posterior).
2. Copia la app del archivo a `dist/Toma.app` con `ditto`, sin `-exportArchive`. Xcode firma al final del build, después de todos los cambios al bundle (incluido `scripts/expand-infoplist-strings.sh`).
3. Verifica la firma: `codesign --verify --deep --strict`, runtime endurecido, autoridad (si no es ad hoc), requisito designado, `com.apple.security.cs.disable-library-validation` presente y `com.apple.security.get-task-allow` ausente (Release no lo inyecta: `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` en `project.yml`), versión, build, feed y clave pública en el Info.plist.
4. Prueba de arranque: `open dist/Toma.app`, 3 s, `pgrep -x Toma`, y la cierra. Falla si ya había una Toma abierta.
5. DMG con `hdiutil create -format UDZO` (la app y un enlace a `/Applications`) y `hdiutil verify`.
6. `generate_appcast --download-url-prefix "$DOWNLOAD_PREFIX" dist/`, que firma el DMG con la clave privada de Sparkle. Falla si generate_appcast avisa algo (por ejemplo, que la clave pública de la app no corresponde a la privada) o si el appcast queda sin `sparkle:edSignature`.

Variables de entorno:

| Variable | Por defecto | Para qué |
|---|---|---|
| `SIGN_IDENTITY` | `Toma Project Signing` | Identidad de firma. `-` firma ad hoc, para probar el proceso sin el certificado. |
| `DOWNLOAD_PREFIX` | `http://localhost:8000/` | URL desde donde se baja el DMG, terminada en `/`. El workflow usa la del release. |
| `SPARKLE_ED_PRIVATE_KEY` | — | Clave privada de Sparkle (el contenido de `sparkle_ed.key`), que va por la entrada estándar a `generate_appcast --ed-key-file -`. Sin ella se usa la del llavero de login; sin ninguna de las dos, no hay appcast y el script lo dice. |

El appcast de cada release lista solo esa versión, porque `dist/` empieza vacío. Para conservar versiones anteriores o generar actualizaciones delta, poner antes en `dist/` los DMG anteriores y el `appcast.xml` publicado (`generate_appcast` los reutiliza).

## Publicar una versión

Con la preparación del dueño hecha (abajo):

```sh
git tag -s v0.0.2 -m "Toma 0.0.2"   # o git tag v0.0.2
git push origin v0.0.2
```

El workflow `.github/workflows/release.yml` corre en el entorno `release` (el dueño aprueba cada corrida): importa el certificado a un llavero temporal (`security create-keychain`, `security import`, `security set-key-partition-list -S apple-tool:,apple:,codesign:`), intenta confiar en él para firma de código en ese runner, corre `bash scripts/release.sh 0.0.2` con `DOWNLOAD_PREFIX=https://github.com/<repo>/releases/download/v0.0.2/` y `SPARKLE_ED_PRIVATE_KEY`, y crea el release `v0.0.2` como prerelease con el DMG y `appcast.xml`. Al final borra el llavero temporal.

**Feed de la fase 0.** `SPARKLE_FEED_URL` apunta a `http://localhost:8000/appcast.xml`: las versiones de la fase 0 son solo para el dueño y se actualizan desde un servidor local (verificación 1). El appcast que publica el workflow queda listo para cuando exista un feed público. Antes del primer release público hay que elegir una URL estable para el feed (GitHub Pages, por ejemplo; `releases/latest/download/` no sirve mientras las versiones sean prerelease) y escribirla en `Config/Identity.xcconfig`.

### Si `codesign` en CI rechaza el certificado

Un certificado autofirmado solo sirve para firmar si el sistema confía en él. El workflow intenta `sudo security add-trusted-cert -d -r trustRoot -p codeSign` en el runner; si macOS no lo permite sin interacción, `release.sh` falla con `"Toma Project Signing" is in the keychain but not valid for code signing`. En ese caso, anotarlo acá (fecha y mensaje) y firmar las releases de la fase 0 en la Mac del dueño:

```sh
DOWNLOAD_PREFIX=https://github.com/<repo>/releases/download/v0.0.2/ bash scripts/release.sh 0.0.2
gh release create v0.0.2 --prerelease --title "Toma 0.0.2" dist/Toma-0.0.2.dmg dist/appcast.xml
```

Resultado en CI: **pendiente** (primera corrida del workflow).

## Preparación del dueño (una sola vez)

Todo esto toca el llavero o los secretos del dueño, así que lo corre el dueño, no un agente.

1. **Claves de Sparkle.** `make project && make build` baja las herramientas de Sparkle. Después:

   ```sh
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys        # crea la clave en el llavero de login e imprime la pública
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_ed.key   # exporta la privada
   ```

   Escribir la clave pública en `Config/Identity.xcconfig` como `SPARKLE_PUBLIC_KEY = …`, con cada `//` como `/$()/` (en base64 puede aparecer `/`; `printf '%s' "<clave>" | sed 's|//|/$()/|g; s|//|/$()/|g'` lo hace). `make test` lo comprueba (`IdentityTests`): la clave decodifica a 32 bytes y la línea no tiene `//`. Hacer commit de ese cambio. El contenido de `sparkle_ed.key` es el secreto `SPARKLE_ED_PRIVATE_KEY`.

2. **Certificado de firma** (pide una contraseña para la imagen de respaldo, y macOS pide la del usuario una vez para confiar en el certificado):

   ```sh
   bash scripts/create-signing-cert.sh sparkle_ed.key && security find-identity -p codesigning -v
   ```

   Esperado: aparece `"Toma Project Signing"`. El script usa `/usr/bin/openssl` (LibreSSL: el OpenSSL 3 de Homebrew escribe `.p12` que `security import` rechaza), importa con `-T /usr/bin/codesign`, confía con `security add-trusted-cert -r trustRoot -p codeSign`, guarda el `.p12`, su contraseña, el certificado y `sparkle_ed.key` en `~/Toma-signing-backup.dmg` (AES-256, APFS, 10 MB) e imprime el SHA-1, la contraseña del `.p12` (secreto `SIGNING_CERT_PASSWORD`) y el `.p12` en base64 (secreto `SIGNING_CERT_P12`). La primera firma puede preguntar si `codesign` puede usar la clave: "Permitir siempre".

3. **Respaldo offline.** Copiar `~/Toma-signing-backup.dmg` a dos lugares offline y borrar `sparkle_ed.key` (`rm -P sparkle_ed.key`). Perder el certificado obliga a uno nuevo, y un certificado nuevo hace que macOS vuelva a pedir los permisos a todos los usuarios una vez. Para recuperar en otra Mac: abrir la imagen, `security import toma-signing.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign`, confiar en el certificado para firma de código, y `generate_keys -f sparkle_ed.key`.

4. **GitHub.** Crear el repositorio y, en Settings → Environments, el entorno `release` con el dueño como revisor obligatorio y los secretos `SIGNING_CERT_P12`, `SIGNING_CERT_PASSWORD` y `SPARKLE_ED_PRIVATE_KEY`.

5. **Primera versión firmada:** `bash scripts/release.sh 0.0.1 && codesign -dv --verbose=4 dist/Toma.app 2>&1 | grep Authority && codesign -d -r- dist/Toma.app && /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' -c 'Print :SUPublicEDKey' -c 'Print :CFBundleVersion' dist/Toma.app/Contents/Info.plist`. Esperado: `Authority=Toma Project Signing`, un requisito designado con `certificate leaf = H"`, la URL completa del feed, la clave pública y el número de build.

## Verificaciones del dueño

Las cinco del spec §7.6, en la Mac del dueño, con el certificado y la clave de Sparkle ya creados. Cada resultado va a la tabla de abajo.

1. **Los permisos sobreviven a una actualización.** Compilar 0.0.1 (`bash scripts/release.sh 0.0.1`), copiar `Toma.app` del DMG a `/Applications`, abrirla, otorgar grabación de pantalla y micrófono, y grabar unos segundos. Hacer un commit nuevo (el número de build tiene que subir; por ejemplo, en una rama de prueba, `git commit --allow-empty -s -m "test: update"`), cerrar Toma (la prueba de arranque del script falla si hay una abierta), compilar 0.0.2 (`bash scripts/release.sh 0.0.2`) y servir `dist/` con `cd dist && python3 -m http.server 8000`. En la 0.0.1: "Buscar actualizaciones…" → instalar → la app se vuelve a abrir en 0.0.2. Grabar sin volver a otorgar permisos. Anotar también `codesign -d -r- /Applications/Toma.app` antes y después (debe ser el mismo).
2. **Aviso de Gatekeeper al descargar.** Con `dist/` servido como en la 1, bajar `http://localhost:8000/Toma-0.0.2.dmg` con Safari (queda en cuarentena: `xattr -p com.apple.quarantine ~/Downloads/Toma-0.0.2.dmg`), copiar la app a una carpeta nueva y abrirla. Anotar el texto exacto del aviso, y confirmar que "Abrir igualmente" en Ajustes del Sistema → Privacidad y seguridad la abre. Ese texto reemplaza el **PENDIENTE** de la sección "Instalar" del README.
3. **Sparkle no vuelve a disparar Gatekeeper.** La versión actualizada en la 1 abre sin aviso. Anotar `spctl -a -vv /Applications/Toma.app` y `xattr -l /Applications/Toma.app`.
4. **Compilar desde el repo.** En una cuenta de usuario nueva: clonar, `make project && make install` y abrir `/Applications/Toma.app`: abre sin aviso.
5. **Encoders en CI.** El paso "Encoder probe" (`hevcAndH264EncodersAreAvailable`, de `EncoderProbeTests`) en el primer run de GitHub Actions. Si falla, condicionar las suites que codifican con `.enabled(if: ProcessInfo.processInfo.environment["CI"] != "true" || hevcEncoderAvailable)`. Mientras tanto, la única prueba apagada en CI es `videoDataRateFollowsTheFormula` (`TOMA_CI=1`: el control de tasa H.264 de las máquinas virtuales es otro).

Si falla la 1: avisar en las notas de cada versión que hay que volver a otorgar el permiso, y abrir un issue para evaluar la cuenta de Apple. Si la instalación de Sparkle falla por Gatekeeper (verificación 1 o 3), probar primero firmar también los ayudantes de Sparkle con la identidad del proyecto: hoy `Autoupdate`, `Updater.app` y los servicios XPC de `Sparkle.framework` conservan la firma ad hoc de Sparkle, y Xcode solo vuelve a firmar el framework. Si falla la 3: documentar el paso manual en el README.

### Resultados de verificación

| Verificación | Fecha | macOS | Resultado |
|---|---|---|---|
| 1. Los permisos sobreviven a una actualización | pendiente | pendiente | pendiente |
| 2. Aviso de Gatekeeper al descargar (texto exacto) | pendiente | pendiente | pendiente |
| 3. Sparkle no vuelve a disparar Gatekeeper | pendiente | pendiente | pendiente |
| 4. `make install` en una cuenta limpia abre sin aviso | pendiente | pendiente | pendiente |
| 5. `EncoderProbeTests` en GitHub Actions | pendiente | pendiente | pendiente |

## Pendientes del dueño de la fase 0

Lo que necesita permisos de grabación, hardware real o una persona, de las tareas 6 a 13:

- [ ] `RECORDER_INTEGRATION=1 make test`, con Grabación de pantalla y Micrófono otorgados a la Terminal.
- [ ] `bash scripts/stress-recovery.sh` (1 h, `kill -9` a los 30 min) en el disco interno y en uno USB, y los números en `docs/performance.md`.
- [ ] Medir el salto en la vista previa del editor (scrub) con el comando `log stream` de `docs/performance.md` y anotarlo ahí.
- [ ] Grabar con una interfaz de audio real de 4 canales y revisar cada canal en el archivo del micrófono.
- [ ] Una toma con micrófono cortada con `kill -9` en sus primeros 3 s: ¿se recupera algo de audio? (Si no, evaluar un primer fragmento más corto o LPCM en el primer segmento.)
- [ ] Verificaciones manuales de la app (Task 12, Step 6), con `make project && make build` y `build/Build/Products/Debug/Toma.app`, y después `make install` y `/Applications/Toma.app` (Release con runtime endurecido: debe abrir):
  1. La ventana de permisos pide grabación de pantalla y micrófono ("Permitir…" → aviso del sistema; "Abrir Ajustes del Sistema" si se negó). Anotar si hizo falta "Salir y volver a abrir".
  2. "Grabar pantalla principal" graba 30 s moviendo el mouse y cambiando de escritorio: el ícono se pone rojo, el menú muestra "Grabando 0:00:xx" y no hay ícono en el Dock.
  3. "Detener grabación" abre el editor con el degradado, la pantalla con esquinas redondeadas y el cursor que sigue al grabado; reproducir/pausar, espacio, arrastrar la barra de tiempo, tiempo actual y duración.
  4. "Exportar MP4…" produce un archivo que QuickTime reproduce con audio (barra de progreso, "Exportación terminada." y "Mostrar en Finder").
  5. `kill -9` durante una grabación y volver a abrir: aparece la alerta de recuperación, "Recuperar" abre el proyecto recuperado y se reproduce.
  6. Cmd-Q a los 60 s de grabación: la toma termina `.complete` con `.stopped` y no hay alerta al volver a abrir.
  7. Bloquear la pantalla 10 s durante una toma: al desbloquear sigue grabando y el editor muestra el hueco.
  8. El ícono del Dock aparece solo con el editor (o la ventana de permisos) abierto y desaparece al grabar.
- [ ] Agregadas en la ronda de correcciones de la Task 12:
  - Micrófono que no arranca (por ejemplo, una interfaz en uso exclusivo): la pantalla se graba igual, el menú muestra "No se pudo iniciar el micrófono. Se graba la pantalla sin audio.", `~/Movies/Toma` tiene el proyecto fallido y uno nuevo (" 2"), y el editor abre el nuevo.
  - Límite al salir: Cmd-Q grabando sale cuando la toma se cierra. Cerrar sesión durante una toma: la toma se cierra (`.stopped`) o, pasados 30 s, el log dice "Quitting before the take closed; it stays recoverable" y la toma se recupera al abrir.
  - Proyectos dañados: uno dañado en `~/Movies/Toma` (por ejemplo, un manifiesto con `formatVersion: 99`) aparece una vez al abrir, no en la apertura siguiente, y siempre en "Recuperar grabaciones…".
  - Finder en español: el "Tipo" de un `.toma` dice "Proyecto de Toma", y el primer pedido del micrófono muestra el texto en español.
- [ ] También de la Task 12: el orden de la alerta de recuperación y la ventana de permisos en la primera apertura; doble clic en un `.toma` en Finder abre el editor; en una Mac sin micrófono se graba igual, con el aviso "No se encontró un micrófono…".
- [ ] De esta tarea: "Buscar actualizaciones…" está desactivado mientras se graba y, en una versión sin clave pública, muestra el error de Sparkle; "Licencias de terceros…" abre la ventana con las licencias de Sparkle y swift-argument-parser.
- [ ] La preparación del dueño de arriba, las cinco verificaciones y la primera corrida de CI y del workflow de release (con el repositorio en GitHub).

## Prueba en seco (ad hoc)

Hecha el 2026-11-13 en macOS 26.6.2 (25G83), Apple M5 Pro, Xcode 27.2, sin el certificado ni la clave de Sparkle (que crea el dueño). Build 25: la prueba se corrió antes del commit de esta tarea, con sus cambios sin commitear (de ahí el aviso del script).

```
$ SIGN_IDENTITY=- bash scripts/release.sh 0.0.1
release: warning: the working tree has uncommitted changes; they are in this build

==> Archiving Toma 0.0.1 (build 25), signed by "-"
⚙️  Generating plists...
⚙️  Generating project...
⚙️  Writing project...
Created project at /Users/ainponce/screen-recorder/Toma.xcodeproj
(dos líneas de diagnóstico de xcodebuild sobre el destino "Any Mac"; ningún warning ni error)

==> Checking the signature
codesign --verify --deep --strict: valid
Identifier=dev.toma.Toma
CodeDirectory v=20500 size=2830 flags=0x10002(adhoc,runtime) hashes=78+7 location=embedded
Executable Segment flags=0x1
Signature=adhoc
TeamIdentifier=not set
# designated => cdhash H"75f31e4b2acb9aec9a5021cdd8a071daf163a4e4"
entitlements: disable-library-validation present, get-task-allow absent
version 0.0.1, build 25, feed http://localhost:8000/appcast.xml, EdDSA public key (none: updates are off in this build)

==> Launch test
Toma is running (pid 13612); quitting it

==> Creating dist/Toma-0.0.1.dmg
created: /Users/ainponce/screen-recorder/dist/Toma-0.0.1.dmg
hdiutil verify: checksum valid

==> Appcast
No EdDSA private key (neither SPARKLE_ED_PRIVATE_KEY nor Sparkle's key in the login keychain):
skipping dist/appcast.xml. See docs/release.md for creating the key.

==> Done
total 3632
-rw-r--r--@ 1 ainponce  staff  1856023 Nov 13 22:14 Toma-0.0.1.dmg
drwxr-xr-x@ 3 ainponce  staff       96 Nov 13 22:14 Toma.app
```

Después, a mano sobre `dist/`:

```
$ codesign --verify --deep --strict --verbose=2 dist/Toma.app
dist/Toma.app: valid on disk
dist/Toma.app: satisfies its Designated Requirement

$ codesign -dv --verbose=4 dist/Toma.app 2>&1 | grep -E "Authority|^Identifier|flags|^Signature|TeamIdentifier|Runtime"
Identifier=dev.toma.Toma
CodeDirectory v=20500 size=2830 flags=0x10002(adhoc,runtime) hashes=78+7 location=embedded
Executable Segment flags=0x1
Signature=adhoc
TeamIdentifier=not set
Runtime Version=27.2.0
(sin línea Authority: firma ad hoc. Con el certificado: Authority=Toma Project Signing)

$ codesign -d -r- dist/Toma.app
Executable=/Users/ainponce/screen-recorder/dist/Toma.app/Contents/MacOS/Toma
# designated => cdhash H"75f31e4b2acb9aec9a5021cdd8a071daf163a4e4"
(ad hoc: cambia en cada build. Con el certificado: identifier "dev.toma.Toma" and certificate leaf = H"…")

$ codesign -d --entitlements - dist/Toma.app
Executable=/Users/ainponce/screen-recorder/dist/Toma.app/Contents/MacOS/Toma
[Dict]
	[Key] com.apple.security.cs.disable-library-validation
	[Value]
		[Bool] true
	[Key] com.apple.security.device.audio-input
	[Value]
		[Bool] true

$ codesign -d --entitlements - dist/Toma.app 2>/dev/null | grep -c get-task-allow
0

$ /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' -c 'Print :SUPublicEDKey' -c 'Print :CFBundleVersion' -c 'Print :CFBundleShortVersionString' dist/Toma.app/Contents/Info.plist
http://localhost:8000/appcast.xml
(vacío: todavía no hay clave pública)
25
0.0.1

$ codesign -dv dist/Toma.app/Contents/Frameworks/Sparkle.framework (y sus ayudantes)
Contents/Frameworks/Sparkle.framework: flags=0x10002(adhoc,runtime)
Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate: flags=0x10002(adhoc,runtime)
Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app: flags=0x10002(adhoc,runtime)

$ hdiutil imageinfo dist/Toma-0.0.1.dmg | grep '^Format:'
Format: UDZO
$ hdiutil attach -nobrowse -readonly -mountpoint <mnt> dist/Toma-0.0.1.dmg && ls -l <mnt>
lrwxr-xr-x@ 1 ainponce  staff  13 Nov 13 22:14 Applications -> /Applications
drwxr-xr-x@ 3 ainponce  staff  96 Nov 13 22:14 Toma.app
<mnt>/Toma.app: codesign --verify --deep --strict valid

$ open dist/Toma.app; sleep 5; pgrep -lx Toma
13822 Toma
  PID ELAPSED COMMAND
13822   00:05 /Users/ainponce/screen-recorder/dist/Toma.app/Contents/MacOS/Toma
$ kill 13822
Toma quit
(log: [dev.toma.Toma:Updates] This build has no EdDSA public key: the updater is not started.
 Sin alerta de Sparkle, sin reportes de crash.)

$ bash scripts/check-licenses.sh
✔ sparkle 2.10.1: MIT BSD zlib
✔ swift-argument-parser 1.8.2: Apache-2.0
check-licenses: 2 dependencies, all allowed
```

El appcast se probó aparte con un par de claves Ed25519 descartable, creado con CryptoKit en una carpeta temporal (nunca en el llavero) y borrado después, y con `SPARKLE_PUBLIC_KEY` puesta solo para esas corridas:

- Clave privada sin clave pública en la app: `release: there is a private key but the app has no SUPublicEDKey: set SPARKLE_PUBLIC_KEY in Config/Identity.xcconfig` (falla).
- Claves que corresponden, con `DOWNLOAD_PREFIX=https://example.invalid/releases/v0.0.1`: `Wrote 1 new update, updated 0 existing updates, and removed 0 old updates in appcast.xml`; el `enclosure` apunta a `https://example.invalid/releases/v0.0.1/Toma-0.0.1.dmg` (el script agrega la `/` final), con `sparkle:version` 25, `sparkle:shortVersionString` 0.0.1, `minimumSystemVersion` 15.0, `hardwareRequirements` arm64 y un `sparkle:edSignature` que CryptoKit verificó contra el DMG con la clave pública ("EdDSA signature valid"). Al abrirse, esa app arrancó Sparkle sin error (solo el aviso de Sparkle sobre un feed HTTP).
- Clave privada que no corresponde a la pública de la app: generate_appcast avisa `Warning: SUPublicEDKey in the app … does not match key EdDSA in the Keychain` y escribe un ítem sin firma; el script falla con `release: generate_appcast reported a problem (above)`.
