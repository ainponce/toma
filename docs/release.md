# Releases de Toma

Toma se distribuye gratis, sin la cuenta paga de desarrollador de Apple (spec §7.6):

- **Firma con un certificado propio estable**, "Toma Project Signing": autofirmado, de firma de código, válido 10 años. Todas las versiones se firman con él, así que el requisito designado de la app (`identifier "dev.toma.Toma" and certificate leaf = H"…"`) no cambia entre versiones y macOS debería conservar los permisos al actualizar. Sin notarización: la primera apertura de un DMG descargado pide "Abrir igualmente".
- **DMG en GitHub Releases**, marcado como prerelease durante la fase 0.
- **Actualizaciones con Sparkle 2**, firmadas con una clave EdDSA propia. El feed es `SPARKLE_FEED_URL` y la clave pública `SPARKLE_PUBLIC_KEY`, los dos en `Config/Identity.xcconfig` (cada `//` escrito como `/$()/`).
- **Compilar desde el código** con `make install`.

Nada secreto entra al repositorio ni se imprime: el certificado con su clave privada y la clave privada de Sparkle viven en el llavero del dueño, en una imagen cifrada guardada offline y en los secretos del entorno `release` de GitHub.

La app y el DMG llevan la licencia (GPLv3 §4 y §6): `Contents/Resources/LICENSE`, `LICENSE` junto a la app en el DMG, `NSHumanReadableCopyright` en el Info.plist, y la ventana "Licencias de terceros…" empieza con el aviso de Toma (copyright, GPL-3.0-or-later, sin ninguna garantía) y la dirección del código fuente de esa versión (`SOURCE_CODE_URL`, en el tag `v<versión>`).

## `scripts/release.sh`

```sh
bash scripts/release.sh 0.0.2
```

Produce `dist/Toma.app`, `dist/Toma-0.0.2.dmg` y `dist/appcast.xml`. Con `SIGN_IDENTITY=-` (ad hoc) escribe todo en `build/adhoc-dist/` y nunca toca `dist/`, el historial de releases, ni el llavero. En orden:

0. Saca `SPARKLE_ED_PRIVATE_KEY` del entorno antes de correr nada (queda en una variable del script): ni xcodegen, ni la resolución de paquetes, ni `xcodebuild` ni sus fases de build la heredan. Solo `generate_appcast` la recibe, por la entrada estándar.
1. `xcodegen generate`, `xcodebuild -resolvePackageDependencies` y `bash scripts/check-licenses.sh`. Los paquetes son siempre las versiones fijadas en los `Package.resolved` (`-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile`, también en el archive): una release nunca toma una versión de Sparkle más nueva que la probada.
2. `xcodebuild archive` en Release, con `CODE_SIGN_STYLE=Manual`, `CODE_SIGN_IDENTITY` = la identidad de firma, `MARKETING_VERSION` = la versión y `CURRENT_PROJECT_VERSION` = `git rev-list --count HEAD` (el número de build que Sparkle compara: cada versión nueva tiene que salir de un commit posterior). Con `SOURCE_CODE_URL` definida, también `SOURCE_CODE_URL` (pisa la de `Config/Identity.xcconfig`). Copia la app del archivo a `dist/Toma.app` con `ditto`, sin `-exportArchive`, y falla si no tiene `Contents/Resources/LICENSE`.
3. Vuelve a firmar, de adentro hacia afuera y nunca con `--deep`, como indica Sparkle para firmar fuera del export de Xcode: Xcode solo había firmado `Sparkle.framework`, y sus ayudantes conservaban la firma ad hoc de Sparkle. Primero quita los servicios XPC de Sparkle (`Versions/B/XPCServices` y el enlace `XPCServices`): la app no tiene sandbox y no activa ninguno. Después `codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none` sobre `Autoupdate`, `Updater.app`, `Sparkle.framework` y, por último, la app con `--entitlements App/Toma.entitlements`. Es el último cambio al bundle (después de `scripts/expand-infoplist-strings.sh`, que corre dentro del build).
4. Verifica: `codesign --verify --deep --strict`; que no quedan servicios XPC; runtime endurecido en las cuatro firmas y, con el certificado, `Authority=Toma Project Signing` en cada una y un requisito designado con `certificate leaf = H"`; `com.apple.security.cs.disable-library-validation` presente y `com.apple.security.get-task-allow` ausente (Release no lo inyecta: `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` en `project.yml`); versión, build, feed, clave pública y `NSHumanReadableCopyright` en el Info.plist; sin `SourceCodeURL` avisa (una build que se entrega tiene que decir dónde está su código).
5. Prueba de arranque: `open dist/Toma.app`, 3 s, `pgrep -x Toma`, y la cierra. Falla si ya había una Toma abierta.
6. DMG con `hdiutil create -format UDZO` (la app, `LICENSE` y un enlace a `/Applications`) y `hdiutil verify`; lo monta y falla si no tiene `LICENSE` junto a la app y dentro de ella.
7. `generate_appcast --download-url-prefix "$DOWNLOAD_PREFIX" dist/`, que firma el DMG con la clave privada de Sparkle: la de `SPARKLE_ED_PRIVATE_KEY` o, en una build firmada sin ella, la del llavero de login. Una build ad hoc hace appcast solo con `SPARKLE_ED_PRIVATE_KEY` (pensada como clave descartable) y nunca busca la del llavero: su appcast metería una build ad hoc en un feed firmado de verdad. Falla si generate_appcast avisa algo (por ejemplo, que la clave pública de la app no corresponde a la privada) o si el ítem de esta versión queda sin `sparkle:edSignature`.

Variables de entorno:

| Variable | Por defecto | Para qué |
|---|---|---|
| `SIGN_IDENTITY` | `Toma Project Signing` | Identidad de firma. `-` firma ad hoc, para probar el proceso sin el certificado: todo va a `build/adhoc-dist/`, nunca a `dist/`, y no se consulta el llavero. |
| `DOWNLOAD_PREFIX` | `http://localhost:8000/` | URL desde donde se baja el DMG, terminada en `/`. El workflow usa la del release. |
| `SPARKLE_ED_PRIVATE_KEY` | — | Clave privada de Sparkle (el contenido de `sparkle_ed.key` en la imagen cifrada), que va por la entrada estándar a `generate_appcast --ed-key-file -` y que el script saca del entorno antes de correr nada. Sin ella, una build firmada usa la del llavero de login; sin ninguna de las dos, no hay appcast y el script lo dice. Una build ad hoc hace appcast solo con esta variable, y con una clave descartable. |
| `SOURCE_CODE_URL` | la de `Config/Identity.xcconfig` (vacía) | Repositorio donde se publica el código fuente (GPLv3 §6). La app la muestra, en el tag `v<versión>`, en "Licencias de terceros…". El workflow la pone desde el repositorio donde corre. |

**Historial del appcast.** El script borra solo lo que vuelve a hacer (`dist/Toma.app` y el DMG de esta versión): los DMG anteriores y el `appcast.xml` que ya están en `dist/` quedan, y `generate_appcast` agrega la versión nueva a ese appcast (guarda las últimas 3; las más viejas pasan a `dist/old_updates/`) con actualizaciones delta (`dist/*.delta`) desde esos DMG. `generate_appcast` apunta todos los DMG de `dist/` a `DOWNLOAD_PREFIX`, así que se publican juntos: el DMG nuevo, los anteriores que el appcast sigue listando, los `.delta` y `appcast.xml`. En una Mac, `dist/` va acumulando las versiones compiladas ahí; si se vació, traer antes las publicadas: `gh release download <tag anterior> --dir dist --pattern appcast.xml --pattern '*.dmg'`. El workflow hace eso mismo con el release anterior antes de compilar. Para que una corrida fallida no estropee ese historial, `generate_appcast` trabaja sobre una copia (`build/appcast-staging`) y `dist/` recibe el resultado solo si pasan todas las verificaciones. `dist/` tiene que tener solo DMG publicados: una prueba ad hoc ya no puede mezclarse (escribe en `build/adhoc-dist/`), pero un DMG firmado de otra forma o sin clave hace que `generate_appcast` avise y la release falle, así que hay que borrarlo antes. Y cada versión es un solo build: si `dist/appcast.xml` ya tiene esa versión con otro número de build, el script falla antes de compilar.

## Publicar una versión

Con la preparación del dueño hecha (abajo), y antes de cada `git tag`, la verificación por versión del spec §13, en este orden (sin las cinco, no hay tag):

- [ ] CI verde en el commit de `main` que se publica: los jobs `build` y `thread-sanitizer`.
- [ ] `make crash-test` en la Mac del dueño.
- [ ] `make tsan` en la Mac del dueño.
- [ ] `bash scripts/stress-recovery.sh` (1 h, `kill -9` a los 30 min) en la Mac del dueño, con sus números en `docs/performance.md`.
- [ ] El commit está en `main` (el workflow falla si no).

```sh
git tag -s v0.0.2 -m "Toma 0.0.2"   # o git tag v0.0.2
git push origin v0.0.2
```

El workflow `.github/workflows/release.yml` corre en el entorno `release` (el dueño aprueba cada corrida), una release a la vez y sin cancelarse a medias (`concurrency: release`). Cada `uses:` está fijado a un commit (`scripts/check-workflows.sh` lo comprueba en CI) y el checkout no deja el token en `.git/config` (`persist-credentials: false`):

0. Falla si el commit del tag no está en `main`. Instala XcodeGen fijado (`scripts/install-xcodegen.sh`: el código de la versión 2.45.4, comprobado con `shasum -a 256 -c` contra el SHA-256 que registra la fórmula de Homebrew, y compilado con SwiftPM), nunca el `brew install` del día.
1. Resuelve los paquetes fijados y corre `scripts/check-licenses.sh`.
2. Importa el certificado a un llavero temporal (`security create-keychain`, `security import`, `security set-key-partition-list -S apple-tool:,apple:,codesign:`) e intenta confiar en él para firma de código en ese runner. El `.p12` decodificado se borra al terminar ese paso, falle o no, y otra vez en el paso final. `security import` recibe la contraseña del `.p12` solo como argumento (`-P`): mientras corre, otro proceso del runner podría verla con `ps`; en el log no aparece porque es un secreto.
3. Trae el `appcast.xml` y los DMG del release anterior a `dist/` (historial y deltas).
4. Corre `bash scripts/release.sh 0.0.2` con `DOWNLOAD_PREFIX=https://github.com/<repo>/releases/download/v0.0.2/`, `SOURCE_CODE_URL` (el repositorio) y `SPARKLE_ED_PRIVATE_KEY`, que `release.sh` saca del entorno antes de correr nada. Después bloquea el llavero temporal (`security lock-keychain`): ningún paso siguiente firma.
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

Todo esto toca el llavero o los secretos del dueño, así que lo corre el dueño, no un agente. En este orden: los secretos se cargan desde la imagen cifrada mientras está montada, así que el repositorio y su entorno van primero.

1. **GitHub.** Crear el repositorio y, en Settings → Environments, el entorno `release` con el dueño como revisor obligatorio. Los secretos `SIGNING_CERT_P12`, `SIGNING_CERT_PASSWORD` y `SPARKLE_ED_PRIVATE_KEY` se cargan en el paso 3.

2. **Herramientas de Sparkle.** `make build` (genera el proyecto y baja Sparkle, con su `generate_keys`).

3. **Certificado de firma y clave de Sparkle** (pide una contraseña para la imagen de respaldo, y macOS pide la del usuario una vez para confiar en el certificado):

   ```sh
   bash scripts/create-signing-cert.sh && security find-identity -p codesigning -v
   ```

   Esperado: aparece `"Toma Project Signing"`. El script crea primero `~/Toma-signing-backup.dmg` (AES-256, APFS, 10 MB), la monta, y crea adentro, y en ningún otro lugar fuera de los llaveros, cada secreto: el certificado y su `.p12` (con `/usr/bin/openssl`: LibreSSL; el OpenSSL 3 de Homebrew escribe `.p12` que `security import` rechaza), la contraseña del `.p12`, el `.p12` en base64 y la clave privada de Sparkle, que `generate_keys -x` exporta directamente a la imagen (si el llavero de login todavía no tiene una, `generate_keys` la crea antes). La clave de Sparkle nunca pasa por la carpeta de inicio, donde Time Machine o una instantánea la guardarían, y una clave de Sparkle filtrada no se puede revocar en las apps ya instaladas. No imprime nada secreto: el SHA-1 del certificado, la clave pública de Sparkle y tres comandos para correr desde otra Terminal mientras la imagen sigue montada, que leen cada secreto de su archivo:

   ```sh
   gh secret set SIGNING_CERT_P12 --env release < "<imagen>/toma-signing.p12.b64"
   gh secret set SIGNING_CERT_PASSWORD --env release < "<imagen>/toma-signing.p12.password"
   gh secret set SPARKLE_ED_PRIVATE_KEY --env release < "<imagen>/sparkle_ed.key"
   ```

   Return la desmonta. Importa el certificado con `-T /usr/bin/codesign -x` (codesign puede usar la clave, que no se puede exportar del llavero; la imagen guarda el `.p12`) y lo confía con `security add-trusted-cert -r trustRoot -p codeSign`. La primera firma puede preguntar si `codesign` puede usar la clave: "Permitir siempre". `security import` recibe la contraseña del `.p12` solo como argumento (`-P`) o en un diálogo, así que mientras corre otros procesos del usuario podrían verla con `ps`; solo abre ese `.p12`, que está en la imagen cifrada. `.gitignore` ignora `sparkle_ed.key`, `*.p12` y `*.p12.password`, y el script se niega a escribir la imagen dentro del repositorio.

   Escribir la clave pública que imprimió en `Config/Identity.xcconfig` como `SPARKLE_PUBLIC_KEY = …`, con cada `//` como `/$()/` (en base64 puede aparecer `/`; `printf '%s' "<clave>" | sed 's|//|/$()/|g; s|//|/$()/|g'` lo hace). `make test` lo comprueba (`IdentityTests`): la clave decodifica a 32 bytes y la línea no tiene `//`. Hacer commit de ese cambio (`git status` no debe mostrar ninguna clave privada).

4. **Respaldo offline.** Copiar `~/Toma-signing-backup.dmg` a dos lugares offline. Perder el certificado obliga a uno nuevo, y un certificado nuevo hace que macOS vuelva a pedir los permisos a todos los usuarios una vez. Para recuperar en otra Mac: abrir la imagen, `security import <imagen>/toma-signing.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign -x` (sin `-P` pide la contraseña en un diálogo; está en `toma-signing.p12.password`), confiar en el certificado para firma de código, y `generate_keys -f <imagen>/sparkle_ed.key`. Para volver a cargar un secreto, abrir la imagen y correr el mismo `gh secret set` con su punto de montaje.

5. **Primera versión firmada:** `bash scripts/release.sh 0.0.1 && codesign -dv --verbose=4 dist/Toma.app 2>&1 | grep Authority && codesign -d -r- dist/Toma.app && /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' -c 'Print :SUPublicEDKey' -c 'Print :CFBundleVersion' -c 'Print :NSHumanReadableCopyright' dist/Toma.app/Contents/Info.plist`. Esperado: `Authority=Toma Project Signing`, un requisito designado con `certificate leaf = H"`, la URL completa del feed, la clave pública, el número de build y la línea de copyright.

## Verificaciones del dueño

Las cinco del spec §7.6, en la Mac del dueño, con el certificado y la clave de Sparkle ya creados. Cada resultado va a la tabla de abajo.

1. **Los permisos sobreviven a una actualización.** Compilar 0.0.1 (`bash scripts/release.sh 0.0.1`), copiar `Toma.app` del DMG a `/Applications`, abrirla, otorgar grabación de pantalla y micrófono, y grabar unos segundos. Hacer un commit nuevo (el número de build tiene que subir; por ejemplo, en una rama de prueba, `git commit --allow-empty -s -m "test: update"`), cerrar Toma (la prueba de arranque del script falla si hay una abierta), compilar 0.0.2 (`bash scripts/release.sh 0.0.2`) y servir `dist/` con `cd dist && python3 -m http.server 8000`. En la 0.0.1: "Buscar actualizaciones…" → instalar → la app se vuelve a abrir en 0.0.2. Grabar sin volver a otorgar permisos. Anotar también `codesign -d -r- /Applications/Toma.app` antes y después (debe ser el mismo).
2. **Aviso de Gatekeeper al descargar.** Con `dist/` servido como en la 1, bajar `http://localhost:8000/Toma-0.0.2.dmg` con Safari (queda en cuarentena: `xattr -p com.apple.quarantine ~/Downloads/Toma-0.0.2.dmg`), copiar la app a una carpeta nueva y abrirla. Anotar el texto exacto del aviso, y confirmar que "Abrir igualmente" en Ajustes del Sistema → Privacidad y seguridad la abre. Ese texto reemplaza el **PENDIENTE** de la sección "Instalar" del README. El spec §7.6 pregunta qué aviso tiene cada tipo de firma: hacer lo mismo con un DMG ad hoc (`SIGN_IDENTITY=- bash scripts/release.sh 0.0.3` y `cd build/adhoc-dist && python3 -m http.server 8001`, bajando `http://localhost:8001/Toma-0.0.3.dmg`) y anotar los dos textos, uno al lado del otro (fila 2b).
3. **Sparkle no vuelve a disparar Gatekeeper.** La versión actualizada en la 1 abre sin aviso. Anotar `spctl -a -vv /Applications/Toma.app` y `xattr -l /Applications/Toma.app`.
4. **Compilar desde el repo.** En una cuenta de usuario nueva **con permisos de administrador** (`make install` borra `/Applications/Toma.app` con `rm -rf` y copia la nueva): clonar, `make install` (genera el proyecto solo) y abrir `/Applications/Toma.app`: abre sin aviso. Después, volver a instalar la versión firmada desde su DMG, para que las verificaciones 1 y 3 sigan teniendo la instalación firmada.
5. **Encoders en CI.** El paso "Encoder probe" (`hevcAndH264EncodersAreAvailable`, de `EncoderProbeTests`) en el primer run de GitHub Actions; con `TOMA_CI=1` también exige un dispositivo Metal. Si falla, condicionar las suites que codifican con `.enabled(if: ProcessInfo.processInfo.environment["CI"] != "true" || hevcEncoderAvailable)`. En CI (`TOMA_CI=1`) las pruebas que dibujan con Metal (render y export, entre ellas las de paridad vista previa/export) corren siempre y fallan, en lugar de saltearse, si el runner no tiene Metal. Las apagadas en CI son `videoDataRateFollowsTheFormula` (el control de tasa H.264 de las máquinas virtuales es otro) y las de `RECORDER_INTEGRATION=1`, que necesitan permisos de grabación y hardware real y las corre el dueño.

Si falla la 1: avisar en las notas de cada versión que hay que volver a otorgar el permiso, y abrir un issue para evaluar la cuenta de Apple. Los ayudantes de Sparkle que instalan la actualización (`Autoupdate` y `Updater.app`) van firmados con el certificado del proyecto, como el framework y la app (`release.sh`, paso 3), y los servicios XPC de Sparkle no se incluyen. Si la instalación falla en la 1 o en la 3, anotar el error de Sparkle (`log show --last 10m --predicate 'subsystem == "org.sparkle-project.Sparkle"'`) en la tabla. Si falla la 3: documentar el paso manual en el README.

**Riesgos aceptados.** Sin Team ID, dyld rechaza `Sparkle.framework` si la validación de librerías está activa, así que la app lleva `com.apple.security.cs.disable-library-validation` (`App/Toma.entitlements`). El costo: una librería ad hoc que alguien ponga dentro del bundle (con permisos de escritura sobre `/Applications/Toma.app`) se carga y hereda los permisos de Grabación de pantalla y Micrófono que macOS le dio a Toma. Se acepta en la fase 0, porque quien puede escribir en el bundle ya tiene la cuenta del usuario. La mitigación a revisar antes del primer release público, o si algún día hay un Team ID: validar el código anidado (`SecStaticCodeCheckValidity` sobre `Sparkle.framework`) antes de cargarlo dinámicamente, o firmar con un Team ID y volver a activar la validación (pendiente en `docs/backlog.md`).

### Resultados de verificación

| Verificación | Fecha | macOS | Resultado |
|---|---|---|---|
| 1. Los permisos sobreviven a una actualización | pendiente | pendiente | pendiente |
| 2. Aviso de Gatekeeper al descargar (texto exacto) | pendiente | pendiente | pendiente |
| 2b. Aviso de Gatekeeper del DMG ad hoc (texto exacto, junto al de 2) | pendiente | pendiente | pendiente |
| 3. Sparkle no vuelve a disparar Gatekeeper | pendiente | pendiente | pendiente |
| 4. `make install` en una cuenta limpia (de administrador) abre sin aviso | pendiente | pendiente | pendiente |
| 5. `EncoderProbeTests` en GitHub Actions | pendiente | pendiente | pendiente |

## Prueba opcional de reinicio

Viene de `docs/performance.md`. Comprueba que un corte sin vaciar la caché del sistema de archivos conserva la toma.

1. `caffeinate -ims -t 1000 &` y, en la misma Terminal, `recorder-dev record <carpeta> --duration 900 > out &`; la primera línea de `out` es la ruta del paquete.
2. A los 300 s: `sudo reboot -q -n` (reinicia sin vaciar la caché de disco).
3. Después del arranque: `recorder-dev recover <carpeta>` y `recorder-dev verify <paquete> --min-duration 290`.
4. Anotar abajo la duración recuperada de cada pista y su `endReason`.

| Medición | Valor |
|---|---|
| Fecha, Mac, macOS | pendiente |
| Duración recuperada por pista y `endReason` | pendiente |
| `verify --min-duration 290` | pendiente |

## Pendientes del dueño de la fase 0

Lo que necesita permisos de grabación, hardware real o una persona, de las tareas 6 a 13:

- [ ] `RECORDER_INTEGRATION=1 make test`, con Grabación de pantalla y Micrófono otorgados a la Terminal.
- [ ] `bash scripts/stress-recovery.sh` (1 h, `kill -9` a los 30 min) en el disco interno y en uno USB, y los números en `docs/performance.md`. El script ahora exige y reporta RSS a los 30 min ≤ RSS a los 5 min + 50 MB (falla si no), y falla también con `trackPaused` o `displayPaused`.
- [ ] `make tsan` (criterio de salida del plan: la corrida con `--sanitize=thread` de los coordinadores y del lector de cuadros pasa). Si en los runners de 3 vCPU de GitHub resulta inestable, queda como paso obligatorio del dueño antes de cada tag y se anota acá.
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
  - Límite al salir: Cmd-Q grabando sale cuando la toma se cierra. Cerrar sesión durante una toma: la toma se cierra (`.stopped`) o, pasados 30 s, el log dice "Quitting before the take closed; anything it recorded stays recoverable" y la toma se recupera al abrir.
  - Proyectos dañados: uno dañado en `~/Movies/Toma` (por ejemplo, un manifiesto con `formatVersion: 99`) aparece una vez al abrir, no en la apertura siguiente, y siempre en "Recuperar grabaciones…".
  - Finder en español: el "Tipo" de un `.toma` dice "Proyecto de Toma", y el primer pedido del micrófono muestra el texto en español.
- [ ] También de la Task 12: el orden de la alerta de recuperación y la ventana de permisos en la primera apertura; doble clic en un `.toma` en Finder abre el editor; en una Mac sin micrófono se graba igual, con el aviso "No se encontró un micrófono…".
- [ ] De esta tarea: "Buscar actualizaciones…" está desactivado mientras se graba; una búsqueda programada que toque durante una toma no se hace (el log dice "No update check while recording; it runs once the take is closed") y se hace al terminarla ("Checking for updates now that the take is closed"); "Licencias de terceros…" abre la ventana con las licencias de Sparkle y swift-argument-parser. Solo mientras `SPARKLE_PUBLIC_KEY` esté vacía, es decir, antes del commit de la clave pública: "Buscar actualizaciones…" muestra el error de Sparkle ("Unable to Check For Updates").
- [ ] La preparación del dueño de arriba, las cinco verificaciones y la primera corrida de CI y del workflow de release (con el repositorio en GitHub).
- [ ] Comprobaciones de la revisión final (abajo), con su resultado en la tabla.

### Comprobaciones de la revisión final

Lo que las correcciones de la revisión final dejan para comprobar con hardware real o con una persona:

1. **La pantalla no se apaga sola durante una toma.** "Apagar la pantalla" en 1 min (Ajustes del Sistema → Pantalla de bloqueo), grabar 3 min sin tocar el teclado ni el mouse, hablando: la pantalla sigue encendida, el audio del micrófono es continuo y `pmset -g assertions` lista `PreventUserIdleDisplaySleep` de Toma. Un bloqueo explícito muestra "En pausa (pantalla bloqueada o Mac en reposo)" en el menú, y desaparece al desbloquear.
2. **Tapa cerrada o reposo a mitad de una toma.** Al despertar, los segmentos de antes del reposo terminan `paused`, no `writerError`, y la toma sigue en segmentos nuevos. Anotar el resultado: decide el pendiente del acuse de reposo (`docs/backlog.md`).
3. **Micrófono desconectado y reconectado en vivo**, en hardware real (USB, y Bluetooth tardando más de 15 s en volver): pasa al micrófono por omisión o vuelve (el menú dice "El micrófono dejó de grabar. Se sigue intentando recuperarlo." y después "Se reanudó la captura del micrófono."), y el editor muestra el hueco.
4. **Aviso de Gatekeeper del DMG ad hoc**, bajado con Safari, al lado del autofirmado (verificación 2, fila 2b).
5. **Una corrida de 3 h** (spec §7.3.9) con `DURATION=10800 KILL_AT=10500 MIN_DURATION=10490 RSS_AT="300 5400 10200" bash scripts/stress-recovery.sh`, o una postergación explícita aprobada por el dueño escrita en `docs/performance.md`.
6. **La prueba opcional de reinicio** (arriba), con su fila.
7. **`stress-recovery.sh`** informa y exige RSS a los 30 min ≤ RSS a los 5 min + 50 MB, en el disco interno y en uno USB.
8. **`make tsan`** pasa.
9. **La verificación por versión** antes de cada `git tag` (spec §13, "Publicar una versión"): CI verde, `make crash-test`, `make tsan` y el script de resistencia en la Mac del dueño.
10. **`create-signing-cert.sh`**: nada secreto en la salida, los secretos cargados con `gh secret set` desde la imagen montada, y nunca se creó `~/sparkle_ed.key`.
11. **La verificación 4 necesita una cuenta de administrador**; después, volver a instalar el DMG firmado, para que las verificaciones 1 y 3 sigan con la instalación firmada.
12. **Más proyectos que núcleos, abiertos juntos desde Finder mientras se graba**: cada editor carga, y "Detener grabación" cierra la toma.
13. **Salir o "Instalar y reiniciar" durante una exportación**: pregunta primero ("Hay una exportación en curso. ¿Salir y cancelarla?"), y no queda ningún `*.partial.mp4` junto al destino.
14. **Disco casi lleno con mucho espacio purgable** (disponible < 1 GB): "Grabar" se rechaza con el mensaje de espacio, en lugar de empezar y parar enseguida.
15. **Salir grabando y dormir la Mac enseguida**; despertarla al minuto: la toma cierra `.complete` con `.stopped` y el log no dice "Quitting before the take closed".
16. **Dos tomas cortadas y "Recuperar"**: la alerta lista las dos y abre las dos. Un paquete cortado movido al Escritorio y abierto con doble clic se recupera desde su editor (botón "Recuperar").
17. **Antes del primer release público**: elegir una URL https para el feed, poner `SURequireSignedFeed` y `SUVerifyUpdateBeforeExtraction`, y hacer que `release.yml` rechace un feed `localhost` (pendiente en `docs/backlog.md`). Y comprobar los SHA de los `uses:` contra sus tags (`gh api repos/actions/checkout/git/ref/tags/v4.3.1`), porque se fijaron sin poder consultarlos.

| Comprobación | Fecha | macOS | Resultado |
|---|---|---|---|
| 1. La pantalla no se apaga sola; `PreventUserIdleDisplaySleep` | pendiente | pendiente | pendiente |
| 2. Tapa cerrada a mitad de una toma | pendiente | pendiente | pendiente |
| 3. Micrófono desconectado en vivo (USB, Bluetooth > 15 s) | pendiente | pendiente | pendiente |
| 4. Aviso de Gatekeeper del DMG ad hoc | pendiente | pendiente | pendiente |
| 5. Corrida de 3 h (o postergación aprobada) | pendiente | pendiente | pendiente |
| 6. Prueba de reinicio | pendiente | pendiente | pendiente |
| 7. RSS a los 30 min ≤ RSS a los 5 min + 50 MB (interno, USB) | pendiente | pendiente | pendiente |
| 8. `make tsan` | pendiente | pendiente | pendiente |
| 9. Verificación por versión antes del primer tag | pendiente | pendiente | pendiente |
| 10. `create-signing-cert.sh` sin secretos en la salida | pendiente | pendiente | pendiente |
| 11. Verificación 4 con cuenta de administrador y DMG firmado reinstalado | pendiente | pendiente | pendiente |
| 12. Más proyectos que núcleos abiertos mientras se graba | pendiente | pendiente | pendiente |
| 13. Salir durante una exportación | pendiente | pendiente | pendiente |
| 14. Disco casi lleno con espacio purgable | pendiente | pendiente | pendiente |
| 15. Salir grabando y dormir la Mac | pendiente | pendiente | pendiente |
| 16. Recuperar dos tomas; recuperar desde el editor | pendiente | pendiente | pendiente |
| 17. Feed público https y SHA de las acciones | pendiente | pendiente | pendiente |

## Pendientes del dueño del hito 1a

Lo que necesita permisos de grabación, hardware real o una persona, de las tareas del hito 1a. Cada resultado va a la tabla de abajo.

- [ ] Task 5a (el ciclo de vida de la toma pasó a `AppSupport`): repetir las comprobaciones 2, 5, 6 y 8 de las verificaciones manuales de la Task 12 de la fase 0 ("Pendientes del dueño de la fase 0", arriba), con `make build` y `build/Build/Products/Debug/Toma.app`. En la 2, el tiempo del menú ("Grabando 0:00:xx") ahora lo dibuja un `TimelineView`: anotar si se ve y si avanza con el menú abierto.
- [ ] Task 5a: Cmd-Q durante "Iniciando la grabación…". Para que el arranque espere, borrar antes el permiso del micrófono (`tccutil reset Microphone dev.toma.Toma`) y salir mientras el sistema lo pide: la app sale cuando termina el arranque (al responder el pedido, o a los 30 s del límite para salir, y entonces el log dice "Quitting before the take closed; anything it recorded stays recoverable") y `~/Movies/Toma` no tiene un paquete vacío nuevo.
- [ ] Task 5a: bloquear la pantalla 20 s durante una toma: el tiempo del menú no avanza mientras está bloqueada y, al desbloquear, sigue desde donde quedó.
- [ ] Task 14a: grabar la pantalla principal ("Grabar pantalla principal") sin ventanas de Toma abiertas; durante la toma abrir una ventana de Toma (por ejemplo "Licencias de terceros…" desde el menú): no sale en el video, y el arranque no tarda notablemente más que antes.
- [ ] Task 15a, la isla: reposo, asomada, panel abierto y elección de pantalla (la lista completa del corte de UI llega con la Task 16e, "Probar el corte de UI"). Con `make build` y `build/Build/Products/Debug/Toma.app`; anotar la versión exacta de macOS y lo que se quiera cambiar frente al prototipo. Desde esta tarea el menú dice "Nueva grabación" en lugar de "Grabar pantalla principal": donde las comprobaciones de arriba dicen "Grabar pantalla principal", abrir la isla con "Nueva grabación" y tocar Grabar.
  - [ ] **En el notch:** en reposo la isla no se distingue del notch (el negro se funde, el ancho y el alto calzan); con otra app adelante, el puntero sobre el notch la asoma con el ícono, "Nueva grabación" y ⇧⌘2 debajo del notch, sin cortarse (si los 14 pt de la asomada quedan apretados, anotar cuánto alto hace falta); al sacar el puntero vuelve al reposo después de 300 ms; un clic en el notch o en la asomada la abre, y "Nueva grabación" del menú la abre en la pantalla del puntero.
  - [ ] **Cerrar y teclado:** se cierra con Esc, con ✕ y con un clic en otra app o en el escritorio, y nunca cambia la app de adelante ni tapa clics fuera de lo que se ve; después de cerrarla, escribir en la app de adelante sin hacer clic: las letras le llegan a esa app (si no, partir la isla en dos paneles, uno clave y otro nunca clave, como permite el diseño §8); con el editor abierto, abrir la isla quita el ícono del Dock y cerrarla lo devuelve sin traer el editor adelante; con la isla abierta y otra app adelante, ⌘W cierra la isla, ⌘Q no hace nada (Toma no sale ni sale la otra app) y las teclas sin uso no suenan.
  - [ ] **Panel abierto:** las pantallas con su nombre, la resolución en píxeles y la marca en la elegida; pasar el mouse por una fila marca esa pantalla con el borde azul; el menú del micrófono (Predeterminado del sistema, los conectados y Apagado) se abre sin activar la app; Ajustes se abre como una tarjeta dentro de la isla (no como un popover del sistema, que tendría que volverse clave y activaría la app) con 30/60 fps de la pantalla elegida y Nativa/Puntos; con la tarjeta abierta, Esc cierra solo la tarjeta, y ✕ y Grabar responden al primer clic; conectar o desconectar un micrófono con la app abierta cambia la lista del menú (también con el panel abierto), y abrir la isla no espera a la lista; Ventana, Área, "Grabar varias pantallas", el audio del sistema, No Molestar y Ocultar íconos se ven deshabilitados (el interruptor de la cámara también, hasta la Task 16e: desde ahí funciona, "Probar el corte de UI") y, con otra app adelante, dicen "Llega en esta versión." al pasar el mouse, e iPhone dice "Llega en la fase 2."; en Ventana o Área, Grabar está deshabilitado y su ayuda dice el motivo; Grabar cierra la isla y graba la pantalla elegida a los fps y la resolución elegidos, con el micrófono elegido (el manifiesto lo nombra), y al volver a abrir la isla está lo elegido.
  - [ ] **Elegir en la pantalla:** "Elegir en la pantalla" deja la isla en "Hacer clic en una pantalla para grabarla." · "Esc para volver" · Listo; la pantalla bajo el cursor se resalta (y la otra, al pasar a ella); un clic la elige, no le llega a la app de abajo y vuelve al panel con esa pantalla marcada; Esc, Return y Listo vuelven al panel sin cambiar la elección; Cmd-Tab a otra app cierra la isla.
  - [ ] **Monitor externo:** sin notch no se dibuja nada en reposo; el puntero arriba al centro (60 × 8 pt) muestra la píldora 38 pt debajo del borde y se llega a ella antes de que se vaya; conectar o desconectar el monitor, cerrar la tapa o cambiar la resolución ("Más espacio") con la app abierta: la zona y la isla quedan donde corresponde; con la isla en el monitor externo, llevar el puntero al notch de la MacBook: se asoma ahí, al sacar el puntero vuelve al reposo después de 300 ms y al volver a entrar se asoma otra vez.
  - [ ] **Movimiento y aspecto:** al crecer se ve la parte de arriba del contenido (no su centro) y las esquinas de abajo con su radio durante todo el movimiento; bajo el notch, la franja negra queda pegada arriba, sin vidrio gris al lado del notch; al achicarse, el contenido no salta cuando termina de irse; abrir y cerrar a mitad de camino no salta, y abrir y cerrar rápido varias veces no da tirones; el contenido aparece con el leve desenfoque poco después de que la isla empieza a crecer y el que se va se desvanece; Liquid Glass en macOS 26: oscuro y legible, deja ver lo que hay detrás y se actualiza al pasar una ventana por debajo (si queda fijo, `NSGlassEffectView` como `contentView` del panel, Task 16e); el vidrio de respaldo en macOS 15, si hay una Mac con 15; "Reducir movimiento" deja fundidos sin rebote ni escala, también dentro del panel (el indicador de los selectores, la marca de la pantalla elegida, la tarjeta de Ajustes, los botones al apretarlos y el nombre de la pantalla resaltada), y "Reducir transparencia", vidrios sólidos, también si se cambian con la isla abierta; sobre una app a pantalla completa en otro escritorio, el reposo, la asomada y el panel funcionan ahí.
  - [ ] **Nada de Toma en el video:** abrir la isla durante una toma y pasar el mouse por las filas de pantallas: ni la isla, ni la zona del notch, ni el borde azul salen en el video.
- [ ] Task 8 (pausa del usuario, marcadores, reiniciar toma y papelera), desde la isla de la Task 16a (pausar/reanudar, marcador y reiniciar llegan con ella; antes no hay cómo pedirlos desde la app):
  - [ ] **Pausa:** pausar 10 s con la pantalla cambiando (por ejemplo, un video o un reloj con segundos en pantalla); mientras dura, el menú dice "En pausa" y el tiempo no avanza; al reanudar sigue desde donde quedó. En el editor la toma muestra el hueco y el video no tiene nada de esos 10 s (ni cuadros, ni el cursor, ni clics).
  - [ ] **Reiniciar toma:** grabar unos segundos y reiniciar: la toma nueva arranca sin abrir el editor; el proyecto viejo aparece en `~/Movies/Toma/Trash` y se abre con doble clic en Finder. "Mostrar la papelera en Finder" del menú (en reposo) abre esa carpeta.
- [ ] Task 16a (cuenta regresiva, alas, isla abierta grabando, atajos globales y nivel del micrófono), con `make build` y `build/Build/Products/Debug/Toma.app`; anotar la versión exacta de macOS:
  - [ ] **Cuenta regresiva:** con la cuenta en 3 s, Grabar lleva la isla a la cuenta (número grande, anillo que se vacía en cada segundo, "Esc para cancelar"); cada número entra desde chico y desenfocado y sale agrandándose; Esc y ⇧⌘2 la cancelan y `~/Movies/Toma` no tiene un proyecto nuevo; al terminar pasa a las alas y deja de ser clave: escribir en la app de adelante sin hacer clic, y las letras le llegan a esa app (si no, partir la isla en dos paneles, como en la Task 15a). Con la cuenta en 10 s, hacer clic en otra app a los 2 s y escribir hasta que termine la cuenta: todas las letras le llegan a esa app (la cuenta no vuelve a tomar el teclado en cada segundo; Esc ya no la cancela, ⇧⌘2 sí). Con la cuenta en 0, Grabar pasa directo a las alas. La cuenta 0 · 3 · 5 · 10 se cambia en la tarjeta de Ajustes del panel y en la ventana de Ajustes, y las dos muestran lo mismo. "Reiniciar" vuelve a contar. Con el permiso del micrófono sin pedir (`tccutil reset Microphone dev.toma.Toma`), el aviso del sistema queda por encima de la cuenta (la isla baja de nivel mientras tanto) y la cuenta sigue al responderlo. Con "Reducir movimiento", los números se funden y el anillo queda quieto.
  - [ ] **Alas:** en una MacBook con notch real, cada ala mide 84 pt al lado del notch (la isla, el ancho del notch + 168 pt): a la izquierda el punto y el tiempo, a la derecha el medidor, enteros y sin nada detrás del notch, en "0:12", "12:34" y pasada la hora ("1:02:03", un punto más chico); anotar el modelo y la resolución ("Predeterminada", "Más espacio"). El punto rojo late cada 1,8 s, el tiempo avanza y el medidor sube rápido y baja lento con la voz; en pausa (del usuario o con la pantalla bloqueada) el punto es ámbar y quieto; con el micrófono apagado se ve el micrófono tachado; tapar el micrófono (o elegir uno mudo) los primeros 5 s: en el ala derecha solo el triángulo ámbar, y "Sin señal" en la isla abierta; se van al hablar. En un monitor externo, las alas en la píldora de 300 × 36, con "Sin señal" escrito.
  - [ ] **Isla abierta grabando:** el mouse sobre las alas la abre (640 × 226) con el tiempo grande, "Grabando" o "En pausa" y el medidor; pausar y reanudar, marcador (deshabilitado en pausa), reiniciar (pregunta "¿Reiniciar la toma? La actual va a la papelera." con Reiniciar · Cancelar) y detener, todos al primer clic con otra app adelante; al sacar el mouse se cierra a los 650 ms, salvo con la confirmación abierta; Esc no hace nada y la app de adelante sigue recibiendo el teclado.
  - [ ] **Atajos:** con otra app adelante, ⇧⌘2 abre y cierra la isla en reposo (en la pantalla del puntero), cancela la cuenta y detiene la toma; ⌥⌘P pausa y reanuda y ⌥⌘M pone un marcador solo durante una toma (en reposo le llegan a la app de adelante); "Nueva grabación" del menú y la isla asomada muestran ⇧⌘2. La ventana "Ajustes…" del menú (con ella abierta la app está en el Dock): clic en un atajo y escribir otro; ⌥P se rechaza con "Los atajos necesitan ⌘ o ⌃."; uno de macOS (⌃↑ de Mission Control, ⇧⌘3) o uno que otra app registró en exclusiva se rechaza con "macOS u otra app ya usan este atajo."; el atajo nuevo funciona sin volver a abrir la app, y el menú y la isla asomada lo muestran; Esc deja el atajo como estaba y ⌫ lo quita.
  - [ ] **Medidor antes de grabar:** con el permiso del micrófono otorgado, la columna Audio del panel abierto muestra el nivel en vivo del micrófono elegido, y el indicador del micrófono de macOS aparece solo mientras el panel está abierto; al cambiar de micrófono el medidor sigue al nuevo; sin el permiso no hay medidor ni pedido.
  - [ ] **Barra de menús:** mientras se graba, el ícono rojo muestra el tiempo al lado (anotar si avanza: lo dibuja un `TimelineView`); durante la cuenta el menú dice "Iniciando la grabación…" y "Detener grabación" la cancela.
  - [ ] **Otra pantalla:** grabando, llevar el puntero al monitor externo: la isla se muda allá con un fundido corto (las alas o la píldora), y vuelve al volver.
  - [ ] **Nada de Toma en el video:** la cuenta, las alas y la isla abierta grabando no salen en el video.
- [ ] Task 16b (avisos en la isla, guardando y guardada, "Al detener"), con `make build` y `build/Build/Products/Debug/Toma.app`, con otra app adelante en todo momento; anotar la versión exacta de macOS:
  - [ ] **Cápsula de confirmación:** durante una toma, ⌥⌘M dice "Marcador puesto." y ⌥⌘P "En pausa." (reanudar no dice nada) en una cápsula de vidrio que cuelga 10 pt debajo de la isla, 2 s, y sigue a la isla si se abre o se cierra mientras se ve; dos seguidas: la segunda reemplaza a la primera. Reiniciar la toma dice "La toma quedó en la papelera."; Esc o ⇧⌘2 en la cuenta, "Cuenta cancelada.". La cápsula no toma el foco (escribir en la app de adelante sin hacer clic), deja pasar los clics a lo que hay debajo y no sale en el video. Con "Reducir movimiento" aparece y se va con un fundido.
  - [ ] **Aviso compacto:** con el micrófono tapado los primeros 5 s, la isla se abre sola 4 s debajo del notch (360 pt de ancho, 40 pt debajo de la barra) con el triángulo ámbar y "El micrófono no está recibiendo sonido." y vuelve a las alas sin tomar el foco; el ala derecha muestra el triángulo ámbar mientras dure, y la isla abierta (mouse encima) lo lista debajo de los botones; al hablar, el aviso y el triángulo se van. Desenchufar un micrófono USB durante la toma: "Se interrumpió la captura del micrófono. Se vuelve a intentar…" en el aviso compacto; al volver a enchufarlo, "Se reanudó la captura del micrófono." en la cápsula, y el triángulo se va. Con la cámara prendida (o sin permiso del micrófono), el aviso del arranque se ve 4 s al empezar a grabar, después de la cuenta. Dos avisos seguidos se ven uno después del otro, 4 s cada uno, en el orden en que llegaron: por ejemplo, reiniciar con la cámara prendida una toma que no se pudo mover a la papelera (para que falle: `chmod a-w ~/Movies/Toma/Trash`, y después `chmod u+w` para dejarla como estaba) muestra primero "No se pudo mover la toma a la papelera. Queda en la carpeta de proyectos." y después el aviso de la cámara.
  - [ ] **Corte por disco lleno:** con un disco casi lleno (una imagen de disco chica, como en la fase 0), el ala derecha se pone roja, la isla pasa a "Guardando la toma" y después a "Toma guardada" con "La grabación se detuvo: el disco está casi lleno." en rojo; el editor se abre o no según "Al detener", y "Toma guardada" con el motivo en rojo se queda 8 s en los dos casos (también con "Abrir el editor", mientras se abre el editor). Lo mismo si la toma se cerró con un error.
  - [ ] **Guardando y guardada, "Abrir el editor":** detener una toma de unos segundos con un marcador: "Guardando la toma" con el indicador y "Cerrando los archivos de cada pista" (el indicador es el de macOS: sigue girando con "Reducir movimiento"), después "Toma guardada" con la duración, "1 marcador" y "Pantalla y Micrófono" mientras se abre el editor (1,5 s), y la isla vuelve al reposo.
  - [ ] **"Quedarme donde estoy":** elegirlo en la tarjeta de Ajustes del panel y ver que la ventana "Ajustes…" muestra lo mismo (y al revés). Detener una toma, también con la ventana de Ajustes o un editor abiertos: la app no se activa, la app de adelante sigue adelante, y la isla queda con Abrir en el editor · Grabar otra · Cerrar 8 s y vuelve al reposo; cada botón responde al primer clic: Abrir en el editor abre esa toma, Grabar otra abre el panel y Cerrar vuelve al reposo; ⇧⌘2 y "Nueva grabación" del menú también abren el panel.
  - [ ] **Fallo al arrancar:** elegir una pantalla, desconectarla y tocar Grabar antes de que el panel se actualice (o grabar en una carpeta de proyectos sin permiso de escritura): no aparece ninguna alerta; la isla abierta dice "No se pudo empezar a grabar" y el motivo encima de Grabar, y el aviso se va al volver a grabar o al cerrar la isla.
- [ ] Task 16c (teleprompter), con `make build` y `build/Build/Products/Debug/Toma.app`, con otra app adelante en todo momento; anotar la versión exacta de macOS:
  - [ ] **Prender y apagar:** el interruptor "Teleprompter" de la columna Audio y guion del panel abierto lo muestra 10 pt debajo de la isla (vidrio de 640 × 160 con las esquinas redondeadas) y lo esconde; grabando, el botón del teleprompter de la isla abierta (`text.alignleft`, iluminado mientras se ve) hace lo mismo, y los dos muestran lo mismo. Se ve con la isla abierta, en la cuenta, con las alas, con la isla abierta grabando y con un aviso compacto; no se ve en reposo, asomada, eligiendo en la pantalla, guardando ni guardada. Aparece y se va con un fundido. Al salir y volver a abrir Toma, el interruptor, el guion, el tamaño, la velocidad y la opacidad están como se dejaron.
  - [ ] **Sigue a la isla:** grabando, pasar el mouse por las alas: la isla crece a 640 × 226 y el teleprompter baja con ella en el mismo cuadro, sin quedarse atrás ni separarse de los 10 pt; al sacar el mouse sube con ella. Lo mismo al pasar del panel abierto a la cuenta y de la cuenta a las alas, y al abrir y cerrar a mitad de camino (no salta). Grabando, llevar el puntero a otra pantalla: el teleprompter se muda con la isla, con el mismo fundido.
  - [ ] **Lectura:** el guion centrado, en semibold, que se desvanece arriba y abajo; sin guion dice "Escribir el guion…", y un clic ahí lo edita. En la cuenta está quieto, desde el principio; al empezar a grabar sube a 24 pt por segundo a 1× (a 3× tres veces más rápido, a 0,3× bastante más lento); en pausa (⌥⌘P o con la pantalla bloqueada) se queda quieto y al reanudar sigue desde ahí; al llegar al final la última línea queda en la franja clara y no sube más. Cambiar el tamaño de letra a mitad de la toma: el guion sigue en la misma parte del texto, sin saltar a otra; acortarlo mucho editándolo no deja el teleprompter en blanco. Reiniciar la toma: la cuenta nueva lo muestra desde el principio; detener y "Grabar otra", también. Apagarlo y prenderlo durante la toma: sigue donde estaba.
  - [ ] **Editar:** Editar (`pencil`) pasa el texto a un campo con el cursor listo, sin activar Toma (la app de adelante sigue adelante, con su menú en la barra); escribir, ⌘A, ⌘C, ⌘V, ⌘X, ⌘Z y ⇧⌘Z funcionan (si alguno no, anotar cuál); cada cambio queda guardado. Listo (`checkmark`) o Esc vuelve a la lectura y devuelve el teclado (Esc no abre la lista de palabras del campo): con la isla abierta, Esc la cierra; grabando, escribir sin hacer clic y las letras le llegan a la app de adelante. Con la isla abierta y el guion en edición, un clic en otra app cierra la isla y el teleprompter; grabando, el guion no sube mientras se edita y sigue al tocar Listo, y también al hacer clic en otra app sin tocar Listo (el campo vuelve a la lectura); tocar Grabar con el guion en edición lo deja en lectura al empezar la cuenta. ⌘Q con el guion en edición no sale de Toma ni de la otra app.
  - [ ] **Controles:** el tamaño (`textformat.size`, − y +) va de a 2 entre 14 y 40 pt y cada botón se deshabilita en su punta; la velocidad (`gauge.with.dots.needle.33percent`) va de 0,3× a 3×; la opacidad (`circle.lefthalf.filled`) de 20 a 100 % cambia el tinte oscuro sobre el vidrio y el texto (el texto nunca baja de 35 %): a 20 % queda casi solo el vidrio, a 100 % el fondo es oscuro; la etiqueta "No sale en el video" (`eye.slash`). Cada control responde al primer clic y su ayuda dice qué es; con VoiceOver, el tamaño y los dos deslizadores dicen su valor, y el tamaño se ajusta con las flechas de VoiceOver.
  - [ ] **Con la cápsula:** con el teleprompter a la vista, ⌥⌘M: "Marcador puesto." cuelga 10 pt debajo del teleprompter (ninguno tapa al otro); sin el teleprompter, 10 pt debajo de la isla. Si el teleprompter se esconde con la cápsula a la vista, la cápsula sube debajo de la isla.
  - [ ] **Accesibilidad y vidrio:** con "Reducir movimiento", aparece y se va con un fundido de 200 ms y sigue a la isla sin resorte (el guion sigue subiendo: es su función); con "Reducir transparencia", el fondo es sólido (también si se cambia con el teleprompter a la vista). Liquid Glass en macOS 26 y el vidrio de respaldo en macOS 15: el vidrio no cambia con la opacidad, solo el tinte oscuro de encima; al mover la opacidad el vidrio no desaparece, ni parpadea ni se ve gris (si pasa, anotar); en macOS 15, anotar si con la opacidad alta el borde claro de 1 pt se ve demasiado tapado por el tinte.
  - [ ] **Nada de Toma en el video:** el teleprompter, también editando, no sale en el video.
- [ ] Task 16d (escritorios por nombre y salto con ⌃← ⌃→), con `make build` y `build/Build/Products/Debug/Toma.app`, con otra app adelante en todo momento; anotar la versión exacta de macOS. Sin el certificado del proyecto la build es ad hoc: después de cada `make build`, `tccutil reset Accessibility dev.toma.Toma` antes de probar el permiso, sin confiar en un interruptor de Accesibilidad que ya estaba prendido.
  - [ ] **La lista contra Mission Control:** con dos o más escritorios y una app a pantalla completa, la sección Escritorio del panel abierto (modo Pantalla, debajo de las pantallas) y la fila de la isla abierta grabando muestran los mismos nombres, en el mismo orden y con el mismo actual resaltado que Mission Control ("Escritorio 1…N", "Escritorio" si hay uno solo, la app a pantalla completa por su nombre); con dos ventanas de la misma app a pantalla completa, cada una con el título de su ventana ("Safari — …"); con un escritorio en Split View, sus dos apps ("Safari y Notas"). Con la isla abierta, cambiar de escritorio con ⌃→ desde el teclado: el resaltado pasa al nuevo con el resorte (con "Reducir movimiento", con un fundido). Debajo de la lista del panel, "La grabación sigue al escritorio que está adelante.". Con muchos escritorios la lista se desplaza de costado; con dos pantallas conectadas, anotar si la primera columna del panel abierto entra entera. Con dos pantallas y "Las pantallas tienen Spaces separados" prendido, cada isla lista los de su pantalla; con eso apagado, la lista es la misma en las dos.
  - [ ] **Sin Accesibilidad:** tocar otro escritorio no salta ni le llega nada a la app de adelante, y la isla explica en ámbar que hace falta el permiso y que ⌃← ⌃→ funcionan igual con el teclado, con "Dar permiso…"; tocar el actual no explica nada. "Dar permiso…" la primera vez muestra el aviso del sistema y la isla se cierra (o vuelve a las alas, grabando): el aviso se ve entero; las siguientes abre Ajustes del Sistema › Privacidad y seguridad › Accesibilidad, nunca los dos. La ventana de permisos (menú) lista Accesibilidad con "Opcional: solo para cambiar de escritorio desde el notch.", su estado y el mismo botón; grabar funciona sin el permiso y la ventana de permisos no se abre sola por él.
  - [ ] **Con Accesibilidad:** saltar del 1 al 3 llega al 3, y del 3 al 1 vuelve al 1, sin activar Toma. Desde el panel abierto (sin grabar), la isla sigue abierta después del salto, con el resaltado en el escritorio nuevo, también cuando ese escritorio tiene otra app adelante o una app a pantalla completa; Esc la sigue cerrando y un clic en otra app después del salto también (si un clic hecho enseguida, en el primer segundo, no la cierra o pierde el teclado, anotarlo: es el margen de `SpaceSwitchGrace`). Lo mismo al cambiar de escritorio con ⌃→ desde el teclado con la isla abierta. Si alguna pulsación se pierde o no hace nada, anotar qué intervalo (hoy 150 ms entre pulsaciones) o qué flags hacen falta (hoy `.maskControl`, `.maskSecondaryFn` y `.maskNumericPad`, decisión 32), y probar a publicar también ⌃ abajo y arriba (keyCode 59) alrededor de cada flecha, como un teclado real. Con dos pantallas, saltar desde la isla de la secundaria cambia el escritorio de esa pantalla.
  - [ ] **Atajos apagados:** con "Mover un espacio a la izquierda" apagado en Ajustes del Sistema › Teclado › Atajos de teclado › Mission Control, y después cambiado a otra combinación (por ejemplo ⌃⌥←), y lo mismo con "Mover un espacio a la derecha": en cada caso, tocar otro escritorio (y ← → si aparecen) no le llega a la app de adelante: el cursor de un campo de texto de otra app no se mueve, y la ventana de adelante no se mueve ni se acomoda en una mitad de la pantalla (macOS 15 y posteriores usan ⌃fn← y ⌃fn→ para acomodar ventanas); la isla explica cómo activarlos, y los nombres de ese texto coinciden con los que muestra macOS en español. Al volver a dejarlos como estaban (sin abrir Toma de nuevo), el salto vuelve a funcionar: el estado se lee antes de cada salto.
  - [ ] **Mission Control:** grabando, la isla abierta tiene el botón Mission Control (`rectangle.3.group`): lo abre y la isla vuelve a las alas al instante, sin tapar la barra de escritorios. Si alguna vez la lista no aparece (anotar la versión de macOS), en su lugar están ← → (con las mismas reglas del permiso y los atajos) y, en el panel abierto, Mission Control.
  - [ ] **La toma sigue:** grabar Pantalla y cambiar de escritorio desde la isla, también a una app a pantalla completa: la toma no se corta y el video muestra lo que la pantalla mostró en cada momento.
  - [ ] **Nada de Toma en el video:** la fila de escritorios y la explicación en ámbar no salen en el video.
- [ ] Task 16e, **Probar el corte de UI** (la burbuja de la cámara cierra el primer corte que se puede probar, diseño del notch §7): todo lo de la isla junto, con `make build` y `build/Build/Products/Debug/Toma.app`.
  - [ ] **Antes de probar, una sola vez (paso del dueño en su llavero; los agentes nunca lo corren):** crear el certificado de firma del proyecto con `bash scripts/create-signing-cert.sh` (después de un `make build`, porque usa las herramientas de Sparkle; es el mismo certificado de las releases, "Preparación del dueño (una sola vez)", arriba: pide la contraseña de la imagen cifrada de respaldo y la del usuario para confiar en el certificado, y espera Return para desmontar la imagen). Desde ahí `make build` firma la Debug con él: `codesign -dv build/Build/Products/Debug/Toma.app` muestra `Authority=Toma Project Signing` y `runtime` en `flags`, y los permisos sobreviven a cada build (`make build DEBUG_SIGN_IDENTITY=` fuerza la firma ad hoc). La primera vez después de crearlo, `tccutil reset All dev.toma.Toma` y otorgar de nuevo (los permisos de la build ad hoc no valen para la firmada). Sin el certificado la build es ad hoc: después de cada `make build`, `tccutil reset Accessibility dev.toma.Toma` y `tccutil reset Camera dev.toma.Toma` (y `ScreenCapture` o `Microphone` si vuelven a pedirse) y otorgar de nuevo, sin confiar en un interruptor de Accesibilidad que ya estaba prendido; y el grupo **Cámara** no prueba el entitlement (la Debug ad hoc no tiene runtime endurecido).
  - [ ] Abrir `build/Build/Products/Debug/Toma.app` con Grabación de pantalla y Micrófono otorgados, anotar la versión exacta de macOS y lo que se quiera cambiar frente al prototipo.
  - [ ] **La isla en la MacBook:** en reposo no se distingue del notch (el negro se funde, el ancho y el alto calzan); con otra app adelante y el puntero quieto un momento sobre el notch, se asoma; se abre con un clic, con ⇧⌘2 desde cualquier app y con "Nueva grabación" del menú; se cierra con Esc, ✕, ⇧⌘2 y un clic fuera; nunca cambia la app de adelante ni tapa clics fuera de lo que se ve; después de la cuenta, escribir en la app de adelante sin hacer clic: las letras llegan a esa app, y lo mismo después de tocar Pausar o Marcador en la isla abierta grabando (si no, partir la isla en dos paneles, 15a); funciona sobre una app a pantalla completa en otro escritorio, también con el editor abierto (ícono en el Dock): la isla en reposo, la asomada y ⇧⌘2 funcionan ahí; con el editor abierto, abrir la isla quita el ícono del Dock.
  - [ ] **Monitor externo:** sin notch no hay píldora en reposo; llevar el puntero arriba al centro (o ⇧⌘2 con el puntero ahí) la muestra 38 pt debajo del borde; grabando, la isla está en la pantalla del puntero y se muda con un fundido al cambiar de pantalla; conectar o desconectar el monitor con la app abierta: la zona y la isla quedan donde corresponde.
  - [ ] **Movimiento y aspecto:** los resortes se sienten rápidos y se pueden interrumpir (abrir y cerrar a mitad de camino no salta; abrir y cerrar rápido varias veces, sin tirones, y el teleprompter no se separa de la isla); el contenido aparece con el leve desenfoque; Liquid Glass en macOS 26: el vidrio deja ver lo que hay detrás y se actualiza al pasar una ventana por debajo (si queda fijo, usar `NSGlassEffectView` como `contentView` del panel, con el `NSHostingView` como su `contentView` y `cornerRadius`), y el vidrio de respaldo en 15, si hay una Mac con 15; "Reducir movimiento" deja fundidos sin rebote y "Reducir transparencia", vidrios sólidos, también si se cambian con la isla abierta; los íconos son SF Symbols.
  - [ ] **Panel y toma:** la lista de pantallas y "Elegir en la pantalla" (resalta la pantalla bajo el cursor, un clic la elige y no le llega a la app de abajo); Ventana, Área, Audio del sistema, "Grabar varias pantallas", "De otros escritorios", No Molestar y Ocultar íconos se ven deshabilitados y, con otra app adelante, dicen "Llega en esta versión." al pasar el mouse, e iPhone dice "Llega en la fase 2."; el primer pedido del micrófono (con el permiso sin pedir: `tccutil reset Microphone dev.toma.Toma`) se ve entero, sin la isla encima, y la cuenta sigue cuando se contesta; con 30 fps y Puntos el video sale a 30 fps y con la mitad de píxeles, y el manifiesto nombra el micrófono elegido; el medidor del micrófono se mueve antes de grabar; Grabar cuenta 3·2·1 en la isla con el anillo, y Esc la cancela sin crear proyecto (cápsula "Cuenta cancelada."); grabando, las alas muestran el punto rojo que late, el tiempo y el medidor; al pasar el mouse se abre y se cierra 650 ms después de salir, salvo con la confirmación de reiniciar abierta; pausa (punto ámbar quieto, cápsula), marcador (deshabilitado en pausa, cápsula), reiniciar (confirmación, cápsula de la papelera, vuelve a contar) y stop: "Guardando la toma", "Toma guardada" y el editor; con "Al detener: Quedarme donde estoy", la app no se activa y la isla queda con Abrir en el editor · Grabar otra · Cerrar hasta 8 s; ⌥⌘P y ⌥⌘M funcionan solo mientras se graba y ⇧⌘2 detiene; grabar ⇧⌘5 en Ajustes muestra el aviso de reservado; el tiempo aparece junto al ícono de la barra de menú; con el micrófono silenciado por hardware, a los 5 s el ala dice "Sin señal" y la isla se abre sola 4 s con el aviso; con un permiso que falta al arrancar, el motivo aparece dentro de la isla (ningún cuadro de diálogo).
  - [ ] **Teleprompter:** editar el guion (⌘V pega), cambiar tamaño, velocidad y opacidad; cuelga de la isla y la sigue al crecer; sube solo mientras se graba y no en pausa; vuelve al principio al reiniciar la toma.
  - [ ] **Escritorios:** la lista coincide con Mission Control en nombres, orden y actual (con dos o más escritorios y una app a pantalla completa; también con dos ventanas de la misma app a pantalla completa y con un escritorio en Split View); sin Accesibilidad, tocar uno no salta y explica cómo darlo, y "Dar permiso…" muestra el aviso del sistema la primera vez (la isla se corre y el aviso se ve entero) y abre Ajustes las siguientes; con el permiso, saltar de 1 a 3 llega a 3 (si no, anotar el intervalo o los flags que hagan falta, decisión 32, y probar a publicar también ⌃ abajo y arriba, keyCode 59, alrededor de cada flecha, como un teclado real); con "Mover un espacio a la izquierda" apagado en Ajustes › Teclado › Atajos de teclado › Mission Control, tocar un escritorio no mueve nada en la app de adelante y la isla explica cómo activarlo (y los nombres del texto coinciden con los de macOS en español); con dos pantallas, saltar desde la isla de la secundaria; Mission Control se abre desde la isla grabando y la isla se recoge, sin tapar la barra de escritorios; grabar Pantalla y cambiar de escritorio no corta la toma.
  - [ ] **Cámara** (con la Debug firmada con el certificado: ahí el entitlement cuenta): con la cámara prendida, la burbuja aparece en vivo, espejada, sobre la pantalla elegida (por defecto, un círculo mediano abajo a la derecha, con el borde claro y la sombra del prototipo), y se ve con la isla abierta, eligiendo, en la cuenta, con las alas, con la isla abierta grabando y con un aviso, pero no en reposo, asomada, guardando ni guardada (la luz verde de la cámara se apaga cuando se va); cambiar de cámara desde el menú (Predeterminado del sistema y las conectadas, también un iPhone cercano por Cámara de Continuidad): sigue espejada; desconectar la cámara elegida con la burbuja a la vista: pasa a la del sistema, espejada, y vuelve a la elegida al reconectarla; sin ninguna cámara, la burbuja oscura con la cámara tachada; las cuatro formas (Círculo, Cuadrado redondeado, Vertical, Horizontal: la ayuda de cada ícono dice su nombre) y los tres tamaños (Chica · Mediana · Grande) se animan con el resorte, y se ven atenuados con la cámara apagada; arrastrarla la lleva pegada al puntero desde donde se la agarró, con la sombra más honda y los 8 puntos de los lugares a la vista, y soltarla con impulso la lleva al lugar más cercano a donde iba (no al más cercano a donde se soltó), con un toque háptico en el trackpad al soltar; un clic sin moverla no hace nada ni vibra; agarrarla mientras vuela la frena ahí; arrastrarla no le quita el teclado a la app de adelante ni activa Toma, y tampoco grabando; la elección (forma, tamaño y lugar) se recuerda al volver a abrir, también después de salir de Toma; el primer pedido del permiso de cámara (con el permiso sin pedir: `tccutil reset Camera dev.toma.Toma`, y prender el interruptor) sale con el texto en español y se ve entero, sin la isla encima, y la isla sigue abierta al contestarlo (Esc la sigue cerrando); con el permiso negado, el interruptor queda apagado y la columna dice "El acceso a la cámara está desactivado." con "Abrir Ajustes", que abre Privacidad y seguridad › Cámara; la ventana de permisos (menú) lista la Cámara con su estado; al grabar con la cámara prendida, la isla se abre sola 4 s al empezar a grabar con el aviso de que esa toma va sin cámara; con "Reducir movimiento", la burbuja aparece y se va con un fundido y los cambios de forma, tamaño y lugar son inmediatos, sin resorte; con el acceso a la cámara negado o sin pedir, Grabar graba igual (sin cámara) y la ventana de permisos no se abre sola por la cámara; con el pedido del permiso de cámara a la vista, hacer clic en otra app en lugar de contestarlo: la isla sigue abierta, y al contestar más tarde vuelve a tomar el teclado (Esc la cierra), aunque ya se esté escribiendo en esa otra app: anotar qué pasa y si molesta. En Ventana y Área la burbuja no se ve todavía (no hay ventana ni área elegidas hasta la Task 15). Limitación conocida: las esquinas transparentes de la burbuja (fuera del círculo o del rectángulo redondeado que se ve) toman los clics: un clic justo afuera de lo visible arrastra la burbuja en lugar de llegarle a la app de abajo (anotar si molesta).
  - [ ] **Nada de Toma en el video:** la isla, las cápsulas, el teleprompter, la burbuja (con su sombra y los puntos de los lugares) y la superposición no salen en el video grabado.
- [ ] Task 9 (la cámara grabada, con `recorder-dev`; en la app llega con la Task 14), desde Terminal.app con los permisos de Grabación de pantalla, Micrófono y Cámara otorgados a Terminal; anotar la versión exacta de macOS. Antes, `swift build --package-path Packages/RecorderKit --product recorder-dev` (el binario queda en `$(swift build --package-path Packages/RecorderKit --show-bin-path)/recorder-dev`) y `recorder-dev list-sources`: lista las pantallas, las cámaras (la preferida del sistema con "system preferred" y un iPhone cercano con "Continuity Camera") y los micrófonos, cada uno con su ID. Después de cada toma, `recorder-dev verify <paquete> --min-duration 25` da OK en todas las pistas, y el manifiesto y `takes/<toma>/events.jsonl` muestran lo que se dice abajo.
  - [ ] **Prueba de integración:** `RECORDER_INTEGRATION=1 swift test --package-path Packages/RecorderKit --filter capturesDefaultCameraForTwoSeconds` pasa (la primera vez macOS pide el permiso de Cámara para Terminal: contestarlo y correrla otra vez).
  - [ ] **Cámara integrada:** `recorder-dev record <carpeta> --duration 30 --camera default`: la pista `camera` dura unos 30 s en un solo segmento, en 1920×1080 si la cámara tiene ese formato a 30 fps (si no, el más grande que los dé), y el manifiesto la nombra con su `deviceUniqueID`; la luz verde de la cámara se apaga al terminar.
  - [ ] **Calidad de la cámara:** `recorder-dev record <carpeta> --duration 15 --camera default --camera-preset p720` y otra toma igual sin `--camera-preset`; abrir `takes/<toma>/camera/seg-0001.mov` de cada una en QuickTime Player (Ventana › Mostrar el inspector de películas, ⌘I): con p720, 1280×720 (o el formato más chico de la cámara que lo cubra) a unos 30 fps; sin la opción, 1920×1080 si la cámara lo tiene, también a unos 30 fps. Si el tamaño o el ritmo son otros, la sesión cambió el formato: anotarlo, con lo que diga `log show --last 5m --predicate 'subsystem == "dev.toma.Toma" AND category == "CameraSessionHost"'`.
  - [ ] **iPhone por Continuity Camera:** lo mismo con `--camera <uniqueID del iPhone>` (de `list-sources`), con el iPhone cerca, bloqueado y apoyado en horizontal: la pista es la del iPhone.
  - [ ] **Cámara USB desenchufada:** con `--camera <uniqueID de la USB>`, desenchufarla a los 10 s y volver a enchufarla a los 20 s: la toma sigue; la pista `camera` tiene dos segmentos, el segundo con la cámara del sistema y un `deviceChanged` en `events.jsonl` (si volvió otra cámara), con líneas `warning:` de la cámara interrumpida y reanudada y sin un tramo largo sin cuadros entre los dos. La USB que vuelve a los 20 s no se retoma a mitad de la toma (la captura nunca cambia sola): anotar si se preferiría que sí.
  - [ ] **Otra app con la misma cámara:** con `--camera default`, abrir FaceTime con esa cámara a los 10 s y cerrarlo a los 20 s: la pista no se queda sin cuadros (sigue igual, o se corta y sigue en un segmento nuevo); anotar cuál de las dos pasó.
  - [ ] **Tapa cerrada:** con un monitor externo como pantalla principal (Ajustes del Sistema › Pantallas; la toma graba la principal) y, si se puede, otra cámara conectada, `--camera default` y cerrar la tapa a los 10 s: la cámara pasa a la otra (`deviceChanged`) o, sin otra, sigue intentando (línea `warning:` de la cámara en pausa) y vuelve a la integrada al abrir la tapa; la pista de la pantalla no se corta.
- [ ] Task 10 (el audio del sistema por app, con `recorder-dev`; en la app se graba desde la Task 14), todo desde Terminal.app salvo el pedido desde la app; anotar la versión exacta de macOS. Antes, `swift build --package-path Packages/RecorderKit --product recorder-dev` (como en la Task 9). macOS nunca dice si el permiso de audio del sistema se otorgó: si se negó, la pista graba silencio sin error. Después de cada toma, `recorder-dev verify <paquete> --min-duration 25` da OK en todas las pistas, y el manifiesto nombra la pista `system-audio` con `excludedBundleIDs` (todo: el bundle propio, si lo hay, y los de las notificaciones y alertas) o `includedBundleIDs` (por app). Si `verify` dice que `system-audio` no tiene medios, o la prueba de integración no recibe muestras, el agregado sin sub-dispositivo no entrega audio (último punto).
  - [ ] **Prueba de integración:** `RECORDER_INTEGRATION=1 swift test --package-path Packages/RecorderKit --filter capturesSystemAudioForTwoSeconds` pasa (reproduce un tono de 440 Hz con `afplay` y graba todo; la primera vez macOS pide el permiso para Terminal: contestarlo y correrla otra vez). Confirmar que Terminal aparece en Ajustes del Sistema › Privacidad y seguridad › Grabación de pantalla y audio del sistema, en "Solo grabación de audio del sistema". Si falla midiendo unos −160 dBFS, anotar "silencio = permiso" (el permiso está negado o todavía no se aplicó).
  - [ ] **El pedido sin nada sonando:** con `make build` y `build/Build/Products/Debug/Toma.app`, con el permiso nunca pedido (si ya se pidió: `tccutil reset AudioCapture dev.toma.Toma` y `defaults delete dev.toma.Toma permissionRequested.systemAudio`; anotar si `tccutil` no reconoce el servicio) y nada sonando, Permisos… › Audio del sistema › Permitir…: el aviso de macOS sale igual, sin esperar a que algo suene; al contestarlo la fila dice "Pedido" con la nota de dónde cambiarlo, también si se negó.
  - [ ] **Los sonidos de alerta:** `osascript -e 'display notification "x" sound name "Glass"'` y, mientras suena, `recorder-dev list-sources | grep '^audio process'`: anotar el bundle ID y la ruta de cada proceso que aparece o dice "playing". Los de las notificaciones y alertas tienen que decir "excluded"; si el que reprodujo el sonido no es `systemsoundserverd` (bundle `systemsoundserverd` o `com.apple.systemsoundserverd`, ruta `/usr/sbin/systemsoundserverd`) ni otro excluido, corregir `SystemAudioExclusions` con lo anotado.
  - [ ] **Todo, sin la notificación:** `recorder-dev record <carpeta> --duration 30 --system-audio all` con música sonando (Música, Spotify o un video) y `osascript -e 'display notification "x" sound name "Glass"'` a los 10 s: en `takes/<toma>/system-audio/seg-0001.mov` (QuickTime Player) la música está y el sonido de la notificación no.
  - [ ] **Por app:** `--system-audio com.google.Chrome` con Chrome abierto y callado: la toma arranca enseguida (no espera a que algo suene) y la pista queda en silencio. Otra toma con un video sonando en Chrome y música en otra app: la pista tiene solo Chrome (sus ayudantes, `com.google.Chrome.helper`, incluidos).
  - [ ] **Safari por app:** `--system-audio com.apple.Safari` con un video sonando en Safari: anotar si la pista tiene el audio o queda en silencio. WebKit reproduce desde `com.apple.WebKit.GPU`, que no lleva el prefijo de Safari y no entra por app (lo más probable es silencio); para Safari el diseño recomienda "Todo". Con `list-sources` mientras suena, anotar qué procesos dicen "playing".
  - [ ] **Alertas que arrancan a mitad de toma en macOS 15:** en una Mac con macOS 15, comprobar con `list-sources` que `systemsoundserverd` no aparece, y grabar `--system-audio all` con música y una notificación con sonido a los 10 s (`osascript -e 'display notification "x" sound name "Glass"'`). En macOS 15 la exclusión entra recién cuando el tap se actualiza al aparecer el proceso: anotar si el sonido de esa primera alerta, o su comienzo, quedó en la pista, y si una segunda alerta a los 20 s ya no queda. En macOS 26 (`bundleIDs`) ninguna de las dos debería quedar.
  - [ ] **La app elegida se abre después:** `--system-audio com.google.Chrome` con Chrome cerrado; abrirlo a los 10 s y poner un video: el audio de Chrome entra en la pista desde ahí, en el mismo segmento (antes, silencio).
  - [ ] **Auriculares e interfaz:** `--system-audio all` con AirPods como salida y después con una interfaz USB como salida, con música: la calidad de los auriculares no baja (no pasan a manos libres) y la pista tiene el audio en los dos casos.
  - [ ] **Cambiar la salida a mitad:** en una toma de 30 s con música, cambiar la salida (de los parlantes a los auriculares) a los 10 s: la pista sigue; si la toma abrió un segundo segmento de `system-audio`, anotarlo con las líneas `warning:`.
  - [ ] **Lista vacía:** en una rama de prueba, cambiar el marcador de `SystemAudioSelection.targets` por `.only([])` y grabar `--system-audio com.google.Chrome` con Chrome cerrado: anotar si la toma arranca y graba silencio igual (entonces el marcador se quita desde `docs/backlog.md`).
  - [ ] Si el agregado sin sub-dispositivo no entrega audio con el permiso dado, anotarlo y abrir en `docs/backlog.md` el ítem "Tap con la salida como sub-dispositivo" (el respaldo de `ProcessTapSource`: la salida por defecto como sub-dispositivo principal, tomando del IOProc solo el búfer del stream del tap, y un cambio de la salida por defecto termina la corrida). Si las taps no sirven en esta Mac, abrir el ítem "Audio del sistema con ScreenCaptureKit como respaldo" con lo observado.
- [ ] Task 11 (pantallas, ventana y área en la captura, con `recorder-dev`; en la app llegan con la Task 14), desde Terminal.app con los permisos de Grabación de pantalla y Micrófono otorgados a Terminal; anotar la versión exacta de macOS. Antes, `swift build --package-path Packages/RecorderKit --product recorder-dev` (como en la Task 9) y `recorder-dev list-sources`: además de las pantallas, lista una línea por ventana en pantalla (`window <CGWindowID>: <bundle ID o app>, "<título>", <ancho>×<alto> pt at (<x>, <y>)`); de ahí salen los ID de `--display` y `--window`. Después de cada toma, `recorder-dev verify <paquete> --min-duration <la duración menos 5 s>` da OK en las pistas que siguieron hasta el final, el resumen que imprime `record` dice cuántos segmentos tuvo cada pista y por qué terminó el último, y el manifiesto y `takes/<toma>/events.jsonl` muestran lo que se dice abajo. Si algo falla, `log show --last 5m --predicate 'subsystem == "dev.toma.Toma" AND (category == "ScreenStreamCapture" OR category == "DisplayCaptureSource")'` dice cuándo el stream siguió un tamaño nuevo y qué app o ventana no se pudo excluir o incluir (que `recorder-dev` mismo no se pueda excluir es normal: no tiene ventanas).
  - [ ] **Prueba de integración:** `RECORDER_INTEGRATION=1 swift test --package-path Packages/RecorderKit --filter capturesAFinderWindowForTwoSeconds` pasa (abre una ventana de Finder sobre una carpeta nueva y la graba 2 s: al menos un cuadro del tamaño de la ventana × la escala).
  - [ ] **Dos pantallas a la vez:** `recorder-dev record <carpeta> --duration 60 --display <A> --display <B>` moviendo el cursor de una a otra todo el tiempo y desenchufando la secundaria a los 20 s: sale `warning: trackLost` de la pista de esa pantalla (antes, líneas de reintento) y la otra sigue hasta el final con un solo segmento; `events.jsonl` tiene posiciones del cursor sobre las dos pantallas hasta los 20 s.
  - [ ] **Área y cambio de resolución:** `--display <ID> --area 100,100,800,450 --duration 30` y, a los 10 s, otra resolución para esa pantalla (Ajustes del Sistema › Pantallas): la pista tiene `captureArea` en el manifiesto y graba la pantalla entera (el primer segmento con el tamaño en píxeles de la pantalla); `events.jsonl` tiene un `displayGeometry` nuevo de esa pantalla, con el marco nuevo, después del inicial; si la resolución nueva cambia el tamaño en píxeles, la pista sigue en un segundo segmento (el primero terminó con `formatChanged`) del tamaño nuevo, sin el contenido achicado ni bordes negros.
  - [ ] **Área con una pantalla externa de 16:10 a 16:9:** lo mismo con una pantalla externa (`--display <externa>`), pasándola a los 10 s de un modo 16:10 a uno 16:9: segmento nuevo `formatChanged` del tamaño nuevo. Con la Task 12 hecha (el render recorta el área), `recorder-dev export <paquete> <salida.mp4>`: el recorte y el cursor siguen alineados antes y después del cambio.
  - [ ] **Ventana de Safari en otro Space:** con una ventana de Safari en un Space, `--window <ID> --duration 90`, y durante la toma: (1) pasar a otro Space y volver: la ventana se sigue grabando mientras está en el otro Space (lo que cambie en ella sale en el video) y salen líneas `visibility: otherSpace` y `visibility: visible`; dejarla quieta 10 s en el otro Space y anotar si sale `visibility: hidden` (no hay cuadros cuando no cambia); (2) abrir un menú de Safari y un popover (el de descargas o el de una extensión): confirmar que los menús no salen en el video y anotar si los popovers sí; (3) redimensionarla: segmento nuevo (`formatChanged`) del tamaño nuevo, sin contenido achicado (como mucho un segmento cada 250 ms mientras se arrastra); (4) arrastrarla hasta dejarla medio fuera de la pantalla: sin segmentos nuevos, y con la Task 12 el cursor del export sigue alineado; (5) minimizarla 5 s: un `windowGeometry` con `onScreen: false`, `visibility: hidden` y ningún cuadro nuevo mientras está en el Dock; (6) cerrarla: la toma sigue hasta el final (la pista de la ventana sigue intentando, con una línea `warning: displayPaused`, y la del micrófono sigue grabando).
  - [ ] **Notificaciones fuera del video:** una toma de pantalla (`--display <principal> --duration 15`) que empieza sin notificaciones ni widgets del escritorio a la vista, y a los 2 s `osascript -e 'display notification "x"'`: la notificación no aparece en `takes/<toma>/display-<ID>/seg-0001.mov` (QuickTime Player). Si sale, anotar lo que diga `log show` (arriba) sobre `com.apple.notificationcenterui`. Repetirlo con widgets en el escritorio: no salen.
  - [ ] **Puntos:** la misma toma de 10 s con y sin `--points`: con `--points` el segmento tiene la mitad de píxeles de ancho y de alto en una pantalla Retina (QuickTime Player › Ventana › Mostrar el inspector de películas) y el `pixelScale` del manifiesto es 1; lo mismo con `--window`.

| Comprobación | Fecha | macOS | Resultado |
|---|---|---|---|
| 5a. Comprobaciones 2, 5, 6 y 8 de la Task 12 de la fase 0 | pendiente | pendiente | pendiente |
| 5a. Cmd-Q durante "Iniciando la grabación…" sin paquete vacío nuevo | pendiente | pendiente | pendiente |
| 5a. El tiempo del menú no avanza con la pantalla bloqueada | pendiente | pendiente | pendiente |
| 14a. Una ventana de Toma abierta durante la toma no sale en el video; el arranque no tarda más | pendiente | pendiente | pendiente |
| 15a. La isla: notch, teclado, panel, elegir en la pantalla, monitor externo, movimiento y vidrio, fuera del video | pendiente | pendiente | pendiente |
| 8. Pausa de 10 s: el video no tiene nada de ese tramo y el editor muestra el hueco | pendiente | pendiente | pendiente |
| 8. Reiniciar toma: el proyecto viejo en `~/Movies/Toma/Trash`, se abre con doble clic | pendiente | pendiente | pendiente |
| 16a. Cuenta, alas, isla abierta grabando, atajos y Ajustes, medidor, barra de menús, otra pantalla, fuera del video | pendiente | pendiente | pendiente |
| 16b. Cápsula, aviso compacto, disco lleno, guardando y guardada con las dos opciones de "Al detener", fallo al arrancar sin alerta | pendiente | pendiente | pendiente |
| 16c. Teleprompter: prender y apagar, sigue a la isla, lectura, editar, controles, con la cápsula, accesibilidad y vidrio, fuera del video | pendiente | pendiente | pendiente |
| 16d. Escritorios: lista contra Mission Control, sin y con Accesibilidad (intervalo y flags), atajos apagados, Mission Control, la toma sigue, fuera del video | pendiente | pendiente | pendiente |
| 16e. Probar el corte de UI: certificado de firma, la isla en la MacBook, monitor externo, movimiento y aspecto, panel y toma, teleprompter, escritorios, cámara, fuera del video | pendiente | pendiente | pendiente |
| 9. Cámara con `recorder-dev`: integración, integrada, calidad p720 (tamaño y fps), iPhone, USB desenchufada, otra app, tapa cerrada | pendiente | pendiente | pendiente |
| 10. Audio del sistema con `recorder-dev`: integración, pedido sin sonido, sonidos de alerta, todo sin notificación, por app, Safari por app, alertas a mitad de toma en macOS 15, app abierta después, auriculares e interfaz, cambio de salida, lista vacía | pendiente | pendiente | pendiente |
| 11. Pantallas, ventana y área con `recorder-dev`: integración, dos pantallas, área con cambio de resolución, área 16:10 a 16:9, ventana de Safari (otro Space, menús y popovers, redimensionar, medio fuera, minimizar, cerrar), notificaciones fuera del video, `--points` | pendiente | pendiente | pendiente |

## Prueba en seco (ad hoc)

**Antes de la revisión final.** En esa versión una corrida ad hoc escribía en `dist/` y buscaba la clave de Sparkle en el llavero; desde la revisión final escribe en `build/adhoc-dist/` y no consulta el llavero (ver "Prueba en seco después de la revisión final", al final). Lo de abajo queda como registro de lo que se probó entonces.

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
