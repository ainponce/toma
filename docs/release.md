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

1. `xcodegen generate`, `xcodebuild -resolvePackageDependencies` y `bash scripts/check-licenses.sh`. Los paquetes son siempre las versiones fijadas en los `Package.resolved` (`-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile`, también en el archive): una release nunca toma una versión de Sparkle más nueva que la probada.
2. `xcodebuild archive` en Release, con `CODE_SIGN_STYLE=Manual`, `CODE_SIGN_IDENTITY` = la identidad de firma, `MARKETING_VERSION` = la versión y `CURRENT_PROJECT_VERSION` = `git rev-list --count HEAD` (el número de build que Sparkle compara: cada versión nueva tiene que salir de un commit posterior). Copia la app del archivo a `dist/Toma.app` con `ditto`, sin `-exportArchive`.
3. Vuelve a firmar, de adentro hacia afuera y nunca con `--deep`, como indica Sparkle para firmar fuera del export de Xcode: Xcode solo había firmado `Sparkle.framework`, y sus ayudantes conservaban la firma ad hoc de Sparkle. Primero quita los servicios XPC de Sparkle (`Versions/B/XPCServices` y el enlace `XPCServices`): la app no tiene sandbox y no activa ninguno. Después `codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none` sobre `Autoupdate`, `Updater.app`, `Sparkle.framework` y, por último, la app con `--entitlements App/Toma.entitlements`. Es el último cambio al bundle (después de `scripts/expand-infoplist-strings.sh`, que corre dentro del build).
4. Verifica: `codesign --verify --deep --strict`; que no quedan servicios XPC; runtime endurecido en las cuatro firmas y, con el certificado, `Authority=Toma Project Signing` en cada una y un requisito designado con `certificate leaf = H"`; `com.apple.security.cs.disable-library-validation` presente y `com.apple.security.get-task-allow` ausente (Release no lo inyecta: `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` en `project.yml`); versión, build, feed y clave pública en el Info.plist.
5. Prueba de arranque: `open dist/Toma.app`, 3 s, `pgrep -x Toma`, y la cierra. Falla si ya había una Toma abierta.
6. DMG con `hdiutil create -format UDZO` (la app y un enlace a `/Applications`) y `hdiutil verify`.
7. `generate_appcast --download-url-prefix "$DOWNLOAD_PREFIX" dist/`, que firma el DMG con la clave privada de Sparkle. Falla si generate_appcast avisa algo (por ejemplo, que la clave pública de la app no corresponde a la privada) o si el ítem de esta versión queda sin `sparkle:edSignature`.

Variables de entorno:

| Variable | Por defecto | Para qué |
|---|---|---|
| `SIGN_IDENTITY` | `Toma Project Signing` | Identidad de firma. `-` firma ad hoc, para probar el proceso sin el certificado. |
| `DOWNLOAD_PREFIX` | `http://localhost:8000/` | URL desde donde se baja el DMG, terminada en `/`. El workflow usa la del release. |
| `SPARKLE_ED_PRIVATE_KEY` | — | Clave privada de Sparkle (el contenido de `~/sparkle_ed.key`), que va por la entrada estándar a `generate_appcast --ed-key-file -`. Sin ella se usa la del llavero de login; sin ninguna de las dos, no hay appcast y el script lo dice. |

**Historial del appcast.** El script borra solo lo que vuelve a hacer (`dist/Toma.app` y el DMG de esta versión): los DMG anteriores y el `appcast.xml` que ya están en `dist/` quedan, y `generate_appcast` agrega la versión nueva a ese appcast (guarda las últimas 3; las más viejas pasan a `dist/old_updates/`) con actualizaciones delta (`dist/*.delta`) desde esos DMG. `generate_appcast` apunta todos los DMG de `dist/` a `DOWNLOAD_PREFIX`, así que se publican juntos: el DMG nuevo, los anteriores que el appcast sigue listando, los `.delta` y `appcast.xml`. En una Mac, `dist/` va acumulando las versiones compiladas ahí; si se vació, traer antes las publicadas: `gh release download <tag anterior> --dir dist --pattern appcast.xml --pattern '*.dmg'`. El workflow hace eso mismo con el release anterior antes de compilar. Para que una corrida fallida no estropee ese historial, `generate_appcast` trabaja sobre una copia (`build/appcast-staging`) y `dist/` recibe el resultado solo si pasan todas las verificaciones. `dist/` tiene que tener solo DMG publicados: los de pruebas ad hoc o sin clave hacen que `generate_appcast` avise y la release falle, así que hay que borrarlos antes. Y cada versión es un solo build: si `dist/appcast.xml` ya tiene esa versión con otro número de build, el script falla antes de compilar.

## Publicar una versión

Con la preparación del dueño hecha (abajo):

```sh
git tag -s v0.0.2 -m "Toma 0.0.2"   # o git tag v0.0.2
git push origin v0.0.2
```

El workflow `.github/workflows/release.yml` corre en el entorno `release` (el dueño aprueba cada corrida):

1. Resuelve los paquetes fijados y corre `scripts/check-licenses.sh`.
2. Importa el certificado a un llavero temporal (`security create-keychain`, `security import`, `security set-key-partition-list -S apple-tool:,apple:,codesign:`) e intenta confiar en él para firma de código en ese runner. El `.p12` decodificado se borra al terminar ese paso, falle o no, y otra vez en el paso final. `security import` recibe la contraseña del `.p12` solo como argumento (`-P`): mientras corre, otro proceso del runner podría verla con `ps`; en el log no aparece porque es un secreto.
3. Trae el `appcast.xml` y los DMG del release anterior a `dist/` (historial y deltas).
4. Corre `bash scripts/release.sh 0.0.2` con `DOWNLOAD_PREFIX=https://github.com/<repo>/releases/download/v0.0.2/` y `SPARKLE_ED_PRIVATE_KEY`.
5. Crea el release `v0.0.2` como prerelease con `dist/*.dmg`, `dist/*.delta` y `appcast.xml`: todo lo que el appcast nombra, con la URL de este release.
6. Borra el llavero temporal.

**Feed de la fase 0.** `SPARKLE_FEED_URL` apunta a `http://localhost:8000/appcast.xml`: las versiones de la fase 0 son solo para el dueño y se actualizan desde un servidor local (verificación 1). El appcast que publica el workflow queda listo para cuando exista un feed público. Antes del primer release público hay que elegir una URL estable para el feed (GitHub Pages, por ejemplo; `releases/latest/download/` no sirve mientras las versiones sean prerelease) y escribirla en `Config/Identity.xcconfig`.

### Si `codesign` en CI rechaza el certificado

Un certificado autofirmado solo sirve para firmar si el sistema confía en él. El workflow intenta `sudo security add-trusted-cert -d -r trustRoot -p codeSign` en el runner; si macOS no lo permite sin interacción, `release.sh` falla con `"Toma Project Signing" is in the keychain but not valid for code signing`. En ese caso, anotarlo acá (fecha y mensaje) y firmar las releases de la fase 0 en la Mac del dueño:

```sh
gh release download v0.0.1 --dir dist --pattern appcast.xml --pattern '*.dmg'   # el release anterior, si dist/ no lo tiene
DOWNLOAD_PREFIX=https://github.com/<repo>/releases/download/v0.0.2/ bash scripts/release.sh 0.0.2
gh release create v0.0.2 --prerelease --title "Toma 0.0.2" dist/*.dmg dist/*.delta dist/appcast.xml
```

Resultado en CI: **pendiente** (primera corrida del workflow).

## Preparación del dueño (una sola vez)

Todo esto toca el llavero o los secretos del dueño, así que lo corre el dueño, no un agente.

1. **Claves de Sparkle.** `make project && make build` baja las herramientas de Sparkle. Después:

   ```sh
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys        # crea la clave en el llavero de login e imprime la pública
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/sparkle_ed.key   # exporta la privada, fuera del repositorio
   ```

   La clave privada exportada nunca va dentro del repositorio: el proyecto hace commit con `git add -A`, y una clave de Sparkle filtrada no se puede revocar en las apps ya instaladas. Por eso se exporta a `~/sparkle_ed.key`, `.gitignore` ignora `sparkle_ed.key`, `*.p12` y `*.p12.password`, y `create-signing-cert.sh` se niega a usar una clave o una imagen de respaldo que estén dentro del repositorio.

   Escribir la clave pública en `Config/Identity.xcconfig` como `SPARKLE_PUBLIC_KEY = …`, con cada `//` como `/$()/` (en base64 puede aparecer `/`; `printf '%s' "<clave>" | sed 's|//|/$()/|g; s|//|/$()/|g'` lo hace). `make test` lo comprueba (`IdentityTests`): la clave decodifica a 32 bytes y la línea no tiene `//`. Hacer commit de ese cambio (`git status` no debe mostrar ninguna clave privada). El contenido de `~/sparkle_ed.key` es el secreto `SPARKLE_ED_PRIVATE_KEY`.

2. **Certificado de firma** (pide una contraseña para la imagen de respaldo, y macOS pide la del usuario una vez para confiar en el certificado):

   ```sh
   bash scripts/create-signing-cert.sh ~/sparkle_ed.key && security find-identity -p codesigning -v
   ```

   Esperado: aparece `"Toma Project Signing"`. El script usa `/usr/bin/openssl` (LibreSSL: el OpenSSL 3 de Homebrew escribe `.p12` que `security import` rechaza), importa con `-T /usr/bin/codesign`, confía con `security add-trusted-cert -r trustRoot -p codeSign`, guarda el `.p12`, su contraseña, el certificado y `~/sparkle_ed.key` en `~/Toma-signing-backup.dmg` (AES-256, APFS, 10 MB) e imprime el SHA-1, la contraseña del `.p12` (secreto `SIGNING_CERT_PASSWORD`) y el `.p12` en base64 (secreto `SIGNING_CERT_P12`). La primera firma puede preguntar si `codesign` puede usar la clave: "Permitir siempre". `security import` recibe la contraseña del `.p12` solo como argumento (`-P`) o en un diálogo, así que mientras corre otros procesos del usuario podrían verla con `ps`; solo abre ese `.p12`, que queda en la imagen cifrada y se borra del disco al terminar el script.

3. **Respaldo offline.** Copiar `~/Toma-signing-backup.dmg` a dos lugares offline y borrar `~/sparkle_ed.key` (`rm -P ~/sparkle_ed.key`). Perder el certificado obliga a uno nuevo, y un certificado nuevo hace que macOS vuelva a pedir los permisos a todos los usuarios una vez. Para recuperar en otra Mac: abrir la imagen, `security import toma-signing.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign`, confiar en el certificado para firma de código, y `generate_keys -f <imagen>/sparkle_ed.key`.

4. **GitHub.** Crear el repositorio y, en Settings → Environments, el entorno `release` con el dueño como revisor obligatorio y los secretos `SIGNING_CERT_P12`, `SIGNING_CERT_PASSWORD` y `SPARKLE_ED_PRIVATE_KEY`.

5. **Primera versión firmada:** `bash scripts/release.sh 0.0.1 && codesign -dv --verbose=4 dist/Toma.app 2>&1 | grep Authority && codesign -d -r- dist/Toma.app && /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' -c 'Print :SUPublicEDKey' -c 'Print :CFBundleVersion' dist/Toma.app/Contents/Info.plist`. Esperado: `Authority=Toma Project Signing`, un requisito designado con `certificate leaf = H"`, la URL completa del feed, la clave pública y el número de build.

## Verificaciones del dueño

Las cinco del spec §7.6, en la Mac del dueño, con el certificado y la clave de Sparkle ya creados. Cada resultado va a la tabla de abajo.

1. **Los permisos sobreviven a una actualización.** Compilar 0.0.1 (`bash scripts/release.sh 0.0.1`), copiar `Toma.app` del DMG a `/Applications`, abrirla, otorgar grabación de pantalla y micrófono, y grabar unos segundos. Hacer un commit nuevo (el número de build tiene que subir; por ejemplo, en una rama de prueba, `git commit --allow-empty -s -m "test: update"`), cerrar Toma (la prueba de arranque del script falla si hay una abierta), compilar 0.0.2 (`bash scripts/release.sh 0.0.2`) y servir `dist/` con `cd dist && python3 -m http.server 8000`. En la 0.0.1: "Buscar actualizaciones…" → instalar → la app se vuelve a abrir en 0.0.2. Grabar sin volver a otorgar permisos. Anotar también `codesign -d -r- /Applications/Toma.app` antes y después (debe ser el mismo).
2. **Aviso de Gatekeeper al descargar.** Con `dist/` servido como en la 1, bajar `http://localhost:8000/Toma-0.0.2.dmg` con Safari (queda en cuarentena: `xattr -p com.apple.quarantine ~/Downloads/Toma-0.0.2.dmg`), copiar la app a una carpeta nueva y abrirla. Anotar el texto exacto del aviso, y confirmar que "Abrir igualmente" en Ajustes del Sistema → Privacidad y seguridad la abre. Ese texto reemplaza el **PENDIENTE** de la sección "Instalar" del README.
3. **Sparkle no vuelve a disparar Gatekeeper.** La versión actualizada en la 1 abre sin aviso. Anotar `spctl -a -vv /Applications/Toma.app` y `xattr -l /Applications/Toma.app`.
4. **Compilar desde el repo.** En una cuenta de usuario nueva: clonar, `make project && make install` y abrir `/Applications/Toma.app`: abre sin aviso.
5. **Encoders en CI.** El paso "Encoder probe" (`hevcAndH264EncodersAreAvailable`, de `EncoderProbeTests`) en el primer run de GitHub Actions. Si falla, condicionar las suites que codifican con `.enabled(if: ProcessInfo.processInfo.environment["CI"] != "true" || hevcEncoderAvailable)`. Mientras tanto, la única prueba apagada en CI es `videoDataRateFollowsTheFormula` (`TOMA_CI=1`: el control de tasa H.264 de las máquinas virtuales es otro).

Si falla la 1: avisar en las notas de cada versión que hay que volver a otorgar el permiso, y abrir un issue para evaluar la cuenta de Apple. Los ayudantes de Sparkle que instalan la actualización (`Autoupdate` y `Updater.app`) van firmados con el certificado del proyecto, como el framework y la app (`release.sh`, paso 3), y los servicios XPC de Sparkle no se incluyen. Si la instalación falla en la 1 o en la 3, anotar el error de Sparkle (`log show --last 10m --predicate 'subsystem == "org.sparkle-project.Sparkle"'`) en la tabla. Si falla la 3: documentar el paso manual en el README.

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
- [ ] De esta tarea: "Buscar actualizaciones…" está desactivado mientras se graba; una búsqueda programada que toque durante una toma no se hace (el log dice "No update check while recording; it runs once the take is closed") y se hace al terminarla ("Checking for updates now that the take is closed"); "Licencias de terceros…" abre la ventana con las licencias de Sparkle y swift-argument-parser. Solo mientras `SPARKLE_PUBLIC_KEY` esté vacía, es decir, antes del commit de la clave pública: "Buscar actualizaciones…" muestra el error de Sparkle ("Unable to Check For Updates").
- [ ] La preparación del dueño de arriba, las cinco verificaciones y la primera corrida de CI y del workflow de release (con el repositorio en GitHub).

## Prueba en seco (ad hoc)

Hecha el 2026-11-13 en macOS 26.6.2 (25G83), Apple M5 Pro, Xcode 27.2, sin el certificado ni la clave de Sparkle (que crea el dueño), antes del commit de la ronda de correcciones (build 26 y el aviso de cambios sin commitear). Comandos exactos y su salida sin cambios, en el orden en que corrieron:

```
$ SIGN_IDENTITY=- bash scripts/release.sh 0.0.1
release: warning: the working tree has uncommitted changes; they are in this build

==> Resolving the pinned packages and checking their licenses
⚙️  Generating plists...
⚙️  Generating project...
⚙️  Writing project...
Created project at /Users/ainponce/screen-recorder/Toma.xcodeproj
Command line invocation:
    /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -resolvePackageDependencies -project Toma.xcodeproj -scheme Toma -derivedDataPath build -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -packageAuthorizationProvider netrc

Resolve Package Graph


Resolved source packages:
  swift-argument-parser: https://github.com/apple/swift-argument-parser @ 1.8.2
  Sparkle: https://github.com/sparkle-project/Sparkle @ 2.10.1
  RecorderKit: /Users/ainponce/screen-recorder/Packages/RecorderKit

2026-11-13 22:52:18.075 xcodebuild[26412:66047560] [MT] IDERunDestination: Supported platforms for the buildables in the current scheme is empty.
resolved source packages: swift-argument-parser, Sparkle, RecorderKit
✔ sparkle 2.10.1: MIT BSD zlib
✔ swift-argument-parser 1.8.2: Apache-2.0
check-licenses: 2 dependencies, all allowed

==> Archiving Toma 0.0.1 (build 26), signed by "-"
2026-11-13 22:52:19.329 xcodebuild[26543:66048047] [MT] IDERunDestination: Supported platforms for the buildables in the current scheme is empty.
2026-11-13 22:52:19.335 xcodebuild[26543:66048047] [MT] IDESchemeActionsInvocationRecord: Device <IDEOSXSupportCore.IDEMacPlaceholder: 0x8bb8de580 (Any Mac | undefined_arch)> is missing operatingSystemVersion, operatingSystemVersionWithBuildNumber.

==> Signing Sparkle's helpers and the app with "-"
dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate: replacing existing signature
dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app: replacing existing signature
dist/Toma.app/Contents/Frameworks/Sparkle.framework: replacing existing signature
dist/Toma.app: replacing existing signature

==> Checking the signatures
codesign --verify --deep --strict: valid
Toma.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate: flags=0x10002(adhoc,runtime)
Toma.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app: flags=0x10002(adhoc,runtime)
Toma.app/Contents/Frameworks/Sparkle.framework: flags=0x10002(adhoc,runtime)
Toma.app: flags=0x10002(adhoc,runtime)
Identifier=dev.toma.Toma
Signature=adhoc
TeamIdentifier=not set
# designated => cdhash H"cdc97b06c24e7aab9102dbec1c2d1cb46a8b6843"
entitlements: disable-library-validation present, get-task-allow absent
version 0.0.1, build 26, feed http://localhost:8000/appcast.xml, EdDSA public key (none: updates are off in this build)

==> Launch test
Toma is running (pid 26751); quitting it

==> Creating dist/Toma-0.0.1.dmg
created: /Users/ainponce/screen-recorder/dist/Toma-0.0.1.dmg
hdiutil verify: checksum valid

==> Appcast
No EdDSA private key (neither SPARKLE_ED_PRIVATE_KEY nor Sparkle's key in the login keychain):
skipping dist/appcast.xml. See docs/release.md for creating the key.

==> Done
total 3456
-rw-r--r--@ 1 ainponce  staff  1766982 Nov 13 22:52 Toma-0.0.1.dmg
drwxr-xr-x@ 3 ainponce  staff       96 Nov 13 22:52 Toma.app

$ codesign --verify --deep --strict --verbose=2 dist/Toma.app
--prepared:/Users/ainponce/screen-recorder/dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/Current/.
--prepared:/Users/ainponce/screen-recorder/dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate
--validated:/Users/ainponce/screen-recorder/dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate
--prepared:/Users/ainponce/screen-recorder/dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/Current/Updater.app
--validated:/Users/ainponce/screen-recorder/dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/Current/Updater.app
--validated:/Users/ainponce/screen-recorder/dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/Current/.
dist/Toma.app: valid on disk
dist/Toma.app: satisfies its Designated Requirement

$ codesign -dv --verbose=4 dist/Toma.app
Executable=/Users/ainponce/screen-recorder/dist/Toma.app/Contents/MacOS/Toma
Identifier=dev.toma.Toma
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20500 size=2830 flags=0x10002(adhoc,runtime) hashes=78+7 location=embedded
VersionPlatform=1
VersionMin=983040
VersionSDK=1769984
Hash type=sha256 size=32
CandidateCDHash sha256=cdc97b06c24e7aab9102dbec1c2d1cb46a8b6843
CandidateCDHashFull sha256=cdc97b06c24e7aab9102dbec1c2d1cb46a8b6843bded2a81b459e6fe32368cfa
Hash choices=sha256
CMSDigest=cdc97b06c24e7aab9102dbec1c2d1cb46a8b6843bded2a81b459e6fe32368cfa
CMSDigestType=2
Executable Segment base=0
Executable Segment limit=966656
Executable Segment flags=0x1
Page size=16384
CDHash=cdc97b06c24e7aab9102dbec1c2d1cb46a8b6843
Signature=adhoc
Info.plist entries=26
TeamIdentifier=not set
Runtime Version=27.2.0
Sealed Resources version=2 rules=13 files=7
Internal requirements count=0 size=12

$ codesign -d -r- dist/Toma.app
Executable=/Users/ainponce/screen-recorder/dist/Toma.app/Contents/MacOS/Toma
# designated => cdhash H"cdc97b06c24e7aab9102dbec1c2d1cb46a8b6843"

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
(exit status 1)

$ /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' -c 'Print :SUPublicEDKey' -c 'Print :CFBundleVersion' -c 'Print :CFBundleShortVersionString' dist/Toma.app/Contents/Info.plist
http://localhost:8000/appcast.xml

26
0.0.1

$ ls dist/Toma.app/Contents/Frameworks/Sparkle.framework dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/B
dist/Toma.app/Contents/Frameworks/Sparkle.framework:
Autoupdate
Resources
Sparkle
Updater.app
Versions

dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/B:
Autoupdate
Resources
Sparkle
Updater.app
_CodeSignature

$ codesign -dv dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
Executable=/Users/ainponce/screen-recorder/dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
Identifier=Autoupdate-55554944584fff653a953d35ab20e451a18e04b7
Format=Mach-O universal (x86_64 arm64)
CodeDirectory v=20500 size=852 flags=0x10002(adhoc,runtime) hashes=20+2 location=embedded
Signature=adhoc
Info.plist=not bound
TeamIdentifier=not set
Runtime Version=26.5.0
Sealed Resources=none
Internal requirements count=0 size=12

$ codesign -dv dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app
Executable=/Users/ainponce/screen-recorder/dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater
Identifier=org.sparkle-project.Sparkle.Updater
Format=app bundle with Mach-O universal (x86_64 arm64)
CodeDirectory v=20500 size=516 flags=0x10002(adhoc,runtime) hashes=9+3 location=embedded
Signature=adhoc
Info.plist entries=24
TeamIdentifier=not set
Runtime Version=26.5.0
Sealed Resources version=2 rules=13 files=0
Internal requirements count=0 size=12

$ codesign -dv dist/Toma.app/Contents/Frameworks/Sparkle.framework
Executable=/Users/ainponce/screen-recorder/dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/Current/Sparkle
Identifier=org.sparkle-project.Sparkle
Format=bundle with Mach-O universal (x86_64 arm64)
CodeDirectory v=20500 size=1116 flags=0x10002(adhoc,runtime) hashes=28+3 location=embedded
Signature=adhoc
Info.plist entries=20
TeamIdentifier=not set
Runtime Version=26.5.0
Sealed Resources version=2 rules=13 files=42
Internal requirements count=0 size=12

$ hdiutil imageinfo dist/Toma-0.0.1.dmg | grep '^Format:'
Format: UDZO

$ mkdir -p build/dmg-check && hdiutil attach -nobrowse -readonly -mountpoint build/dmg-check dist/Toma-0.0.1.dmg
esperado   CRC32 $58D8EA5D
/dev/disk25         	GUID_partition_scheme          	
/dev/disk25s1       	Apple_APFS                     	
/dev/disk26         	EF57347C-0000-11AA-AA11-0030654	
/dev/disk26s1       	41504653-0000-11AA-AA11-0030654	/Users/ainponce/screen-recorder/build/dmg-check

$ ls -l build/dmg-check
total 0
lrwxr-xr-x@ 1 ainponce  staff  13 Nov 13 22:52 Applications -> /Applications
drwxr-xr-x@ 3 ainponce  staff  96 Nov 13 22:52 Toma.app

$ codesign --verify --deep --strict --verbose=1 build/dmg-check/Toma.app
build/dmg-check/Toma.app: valid on disk
build/dmg-check/Toma.app: satisfies its Designated Requirement

$ hdiutil detach build/dmg-check && rmdir build/dmg-check
"disk25" ejected.

$ pgrep -lx Toma
(exit status 1)

$ open dist/Toma.app; sleep 5; pgrep -lx Toma
26849 Toma

$ ps -o pid,etime,command -p 26849
  PID ELAPSED COMMAND
26849   00:05 /Users/ainponce/screen-recorder/dist/Toma.app/Contents/MacOS/Toma

$ kill 26849; sleep 2; pgrep -lx Toma
(exit status 1)

$ log show --last 1m --style compact --predicate 'process == "Toma" && subsystem == "dev.toma.Toma"'
Timestamp               Ty Process[PID:TID]
2026-11-13 22:51:56.167 Df Toma[26321:3efca50] [dev.toma.Toma:Updates] This build has no EdDSA public key: the updater is not started
2026-11-13 22:52:28.661 Df Toma[26751:3efd621] [dev.toma.Toma:Updates] This build has no EdDSA public key: the updater is not started
2026-11-13 22:52:40.692 Df Toma[26849:3efda14] [dev.toma.Toma:Updates] This build has no EdDSA public key: the updater is not started

$ bash scripts/check-licenses.sh
✔ sparkle 2.10.1: MIT BSD zlib
✔ swift-argument-parser 1.8.2: Apache-2.0
check-licenses: 2 dependencies, all allowed

$ for f in scripts/*.sh; do bash -n "$f" && echo "bash -n $f: ok"; done
bash -n scripts/check-licenses.sh: ok
bash -n scripts/create-signing-cert.sh: ok
bash -n scripts/expand-infoplist-strings.sh: ok
bash -n scripts/release.sh: ok
bash -n scripts/stress-recovery.sh: ok
bash -n scripts/test-crash-recovery.sh: ok
```

`grep -c` sale con estado 1 cuando cuenta 0. La línea vacía de PlistBuddy es `SUPublicEDKey`, todavía vacía. Ad hoc no tiene línea `Authority` y su requisito designado es un `cdhash`, distinto en cada build; con el certificado, `release.sh` exige `Authority=Toma Project Signing` en las cuatro firmas y `certificate leaf = H"` en el requisito designado.

### Appcast con clave

Con un par de claves Ed25519 descartable, creado con CryptoKit en la carpeta temporal de la sesión (nunca en un llavero) y borrado después.

Clave privada sin clave pública en la app, en este repositorio (`<scratchpad>` es esa carpeta temporal; `[…]` saltea la salida de los pasos anteriores, igual a la de arriba):

```
$ SIGN_IDENTITY=- SPARKLE_ED_PRIVATE_KEY="$(sed -n 1p <scratchpad>/edkey/pair.txt)" bash scripts/release.sh 0.0.1
[…]
==> Appcast
release: there is a private key but the app has no SUPublicEDKey: set SPARKLE_PUBLIC_KEY in Config/Identity.xcconfig
(exit status 1)
```

Historial, en un clon temporal del repositorio con la clave pública descartable en `SPARKLE_PUBLIC_KEY` (solo en ese clon) y `dist/` vacío al empezar. `<scratchpad>` reemplaza la ruta de esa carpeta temporal (lo único cambiado en la salida). Cada corrida de `release.sh` muestra desde el paso Appcast; `../edkey/other.txt` es otra clave privada, que no corresponde a la pública de la app:

```
$ SIGN_IDENTITY=- SPARKLE_ED_PRIVATE_KEY="$(sed -n 1p ../edkey/pair.txt)" bash scripts/release.sh 0.0.1
[…]
==> Appcast
Signing with the key from SPARKLE_ED_PRIVATE_KEY; downloads from http://localhost:8000/
Wrote 1 new update, updated 0 existing updates, and removed 0 old updates in appcast.xml
dist/appcast.xml: 1 versions

==> Done
total 3464
-rw-r--r--@ 1 ainponce  staff  1766955 Nov 13 22:50 Toma-0.0.1.dmg
drwxr-xr-x@ 3 ainponce  staff       96 Nov 13 22:50 Toma.app
-rw-r--r--@ 1 ainponce  staff      827 Nov 13 22:50 appcast.xml
(exit status 0)

$ git commit -q --allow-empty -m "test: next build"
(exit status 0)

$ shasum dist/appcast.xml; ls dist
d7f8eacbc1d0144deec4de0cedf48cce36493225  dist/appcast.xml
Toma-0.0.1.dmg
Toma.app
appcast.xml
(exit status 0)

$ SIGN_IDENTITY=- SPARKLE_ED_PRIVATE_KEY="$(sed -n 1p ../edkey/other.txt)" bash scripts/release.sh 0.0.2
[…]
==> Appcast
Signing with the key from SPARKLE_ED_PRIVATE_KEY; downloads from http://localhost:8000/
Warning: SUPublicEDKey in the app <scratchpad>/history-clone/build/appcast-staging/Toma-0.0.1.dmg does not match key EdDSA in the Keychain. Run generate_keys and update Info.plist to match
Warning: SUPublicEDKey in the app <scratchpad>/history-clone/build/appcast-staging/Toma-0.0.2.dmg does not match key EdDSA in the Keychain. Run generate_keys and update Info.plist to match
Warning: found mismatch code signing identity between build/appcast-staging/Toma-0.0.1.dmg -- file://<scratchpad>/history-clone/ 35 and build/appcast-staging/Toma-0.0.2.dmg -- file://<scratchpad>/history-clone/ 36
Wrote 1 new update, updated 1 existing update, and removed 0 old updates in appcast.xml
release: generate_appcast reported a problem (above); dist/ is unchanged
(exit status 1)

$ shasum dist/appcast.xml; ls dist
d7f8eacbc1d0144deec4de0cedf48cce36493225  dist/appcast.xml
Toma-0.0.1.dmg
Toma-0.0.2.dmg
Toma.app
appcast.xml
(exit status 0)

$ SIGN_IDENTITY=- SPARKLE_ED_PRIVATE_KEY="$(sed -n 1p ../edkey/pair.txt)" bash scripts/release.sh 0.0.2
[…]
==> Appcast
Signing with the key from SPARKLE_ED_PRIVATE_KEY; downloads from http://localhost:8000/
Warning: found mismatch code signing identity between build/appcast-staging/Toma-0.0.1.dmg -- file://<scratchpad>/history-clone/ 35 and build/appcast-staging/Toma-0.0.2.dmg -- file://<scratchpad>/history-clone/ 36
Wrote 1 new update, updated 1 existing update, and removed 0 old updates in appcast.xml
dist/appcast.xml: 2 versions

==> Done
total 6928
-rw-r--r--@ 1 ainponce  staff  1766955 Nov 13 22:50 Toma-0.0.1.dmg
-rw-r--r--@ 1 ainponce  staff  1767062 Nov 13 22:51 Toma-0.0.2.dmg
drwxr-xr-x@ 3 ainponce  staff       96 Nov 13 22:51 Toma.app
-rw-r--r--@ 1 ainponce  staff     1298 Nov 13 22:51 Toma36-35.delta
-rw-r--r--@ 1 ainponce  staff     1879 Nov 13 22:51 appcast.xml
(exit status 0)

$ grep -o 'url="[^"]*"' dist/appcast.xml
url="http://localhost:8000/Toma-0.0.2.dmg"
url="http://localhost:8000/Toma36-35.delta"
url="http://localhost:8000/Toma-0.0.1.dmg"
(exit status 0)

$ git commit -q --allow-empty -m "test: another build"
(exit status 0)

$ SIGN_IDENTITY=- SPARKLE_ED_PRIVATE_KEY="$(sed -n 1p ../edkey/pair.txt)" bash scripts/release.sh 0.0.2
release: dist/appcast.xml already has Toma 0.0.2 from another build: release this one as a new version
(exit status 1)
```

La corrida con la clave equivocada no tocó `dist/appcast.xml` (mismo SHA-1 antes y después). El aviso `found mismatch code signing identity` es esperable con firmas ad hoc y el script lo tolera solo con `SIGN_IDENTITY=-`; con el certificado, las versiones tienen la misma firma y ese aviso hace fallar la release.
