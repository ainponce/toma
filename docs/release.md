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

Una sola pasada de fin de hito, contra la app de esta rama, en orden: la preparación, el recorrido completo, el detalle por área y lo que corre en Terminal. Cada comprobación dice qué se tiene que ver. Si se ve otra cosa, o algo molesta, anotar lo que se ve (con la versión exacta de macOS) en la tabla del final: los agentes trabajan con esas notas. Ninguna comprobación pide cambiar código. Entre paréntesis, la tarea de origen.

### 0. Preparación (una sola vez, en este orden)

1. **Certificado de firma (opcional; es un paso del dueño en su llavero, los agentes nunca lo corren).** Después de un `make build` (usa las herramientas de Sparkle): `bash scripts/create-signing-cert.sh`. Es el mismo certificado de las releases ("Preparación del dueño (una sola vez)", paso 3): pide la contraseña de la imagen cifrada de respaldo y la del usuario para confiar en el certificado, y espera Return para desmontar la imagen. Con él, la copia de prueba sale firmada con "Toma Project Signing" y macOS conserva los permisos de una copia a la siguiente. Sin él, la copia es ad hoc: macOS vuelve a pedir los permisos con cada copia nueva, y un interruptor que ya estaba prendido en Ajustes del Sistema puede no valer (`tccutil reset All dev.toma.Toma` y otorgarlos de nuevo).
2. **Abrir la copia de prueba.** La arma el controlador después de unir la rama: `open build/prueba/Toma.app`. `codesign -dv build/prueba/Toma.app 2>&1 | grep Authority` dice `Authority=Toma Project Signing` cuando salió firmada con el certificado. La primera vez con el certificado recién creado: `tccutil reset All dev.toma.Toma` antes de abrirla (los permisos de una copia ad hoc no valen para la firmada).
3. **Permisos.** Toma pide cada uno cuando hace falta, y la ventana Permisos… (menú de la barra) los lista con su estado y un botón:
   - **Grabación de pantalla:** al primer Grabar. Se otorga en Ajustes del Sistema › Privacidad y seguridad › Grabación de pantalla y audio del sistema; si macOS lo pide, salir y volver a abrir Toma.
   - **Micrófono y Cámara:** el aviso del sistema sale al primer Grabar con cada uno prendido (o al prender la cámara en la isla); se contesta "Permitir".
   - **Audio del sistema:** al tocar Todo o "Elegir apps…" en la isla. macOS nunca dice si se otorgó: si se negó, la pista queda en silencio.
   - **Accesibilidad (opcional, solo para saltar de escritorio desde la isla):** "Dar permiso…" en la isla o en Permisos….
4. **Atajo de No Molestar.** Crearlo como dice el README ("No Molestar durante las grabaciones"), correrlo una vez a mano desde Atajos y elegirlo en Ajustes.
5. **Para Terminal.** Usar Terminal.app (el permiso se atribuye a la terminal; otras pueden grabar silencio sin preguntar) con Grabación de pantalla, Micrófono, Cámara y Audio del sistema otorgados. Compilar `recorder-dev`: `swift build --package-path Packages/RecorderKit --product recorder-dev`; queda en `$(swift build --package-path Packages/RecorderKit --show-bin-path)/recorder-dev`. `recorder-dev list-sources` da los ID de pantallas, ventanas, cámaras y micrófonos.
6. **Tener a mano:** una MacBook con notch y un monitor externo, un iPhone (Cámara de Continuidad), una cámara y un micrófono USB si hay, dos o más escritorios con fondos distintos (uno con una app a pantalla completa) y archivos en el escritorio.

### 1. Recorrido completo (la salida del hito)

1. Con una app a pantalla completa adelante, ⇧⌘2: la isla se abre en el notch y la app de adelante sigue adelante.
2. Área › Dibujar en la pantalla: un área 16:9 en la pantalla secundaria.
3. Cámara prendida, la del iPhone; en la isla, forma Horizontal y tamaño Chica; arrastrar la burbuja arriba a la izquierda.
4. Micrófono prendido; Audio del sistema › "Elegir apps…" con una sola app sonando (por ejemplo Música) y otra app sonando también; Teleprompter prendido con un guion.
5. Grabar: la isla cuenta 3·2·1.
6. Grabando: pausa 5 s (⌥⌘P) y reanudar; marcador (⌥⌘M); mover la burbuja abajo a la derecha; saltar a otro escritorio desde la isla abierta y volver.
7. Stop (⇧⌘2): "Guardando la toma", "Toma guardada" y se abre el editor.
8. En el editor se ven la pantalla recortada al área, la burbuja que empieza arriba a la izquierda y pasa con un movimiento suave abajo a la derecha, y el cursor.
9. Exportar el MP4: se oyen la voz y la app elegida (no la otra); no salen la isla, las cápsulas, el teleprompter, la burbuja ni notificaciones; los bordes del área no muestran una línea de lo que quedó afuera.

### 2. Detalle por área

**Isla y notch** (15a, 16a, 16e)
- En reposo la isla no se distingue del notch: el negro se funde, el ancho y el alto calzan.
- Con otra app adelante y el puntero quieto sobre el notch, se asoma con el ícono, "Nueva grabación" y ⇧⌘2; al sacar el puntero vuelve al reposo a los 300 ms.
- Se abre con un clic, con ⇧⌘2 desde cualquier app y con "Nueva grabación" del menú, en la pantalla del puntero; se cierra con Esc, ✕, ⇧⌘2 y un clic afuera.
- Nunca cambia la app de adelante ni tapa clics fuera de lo que se ve. Después de cerrarla, después de la cuenta y después de tocar Pausar o Marcador grabando, escribir sin hacer clic: las letras llegan a la app de adelante.
- Con la isla abierta y otra app adelante: ⌘W la cierra, ⌘Q no hace nada, las teclas sin uso no suenan.
- Sobre una app a pantalla completa en otro escritorio funcionan el reposo, la asomada y ⇧⌘2, también con el editor abierto; abrir la isla quita el ícono del Dock y cerrarla lo devuelve sin traer el editor adelante.
- Monitor externo: sin notch no se ve nada en reposo; el puntero arriba al centro muestra la píldora 38 pt debajo del borde. Conectar o desconectar el monitor, cerrar la tapa o cambiar la resolución con la app abierta: la zona y la isla quedan en su lugar.
- Movimiento: los resortes son rápidos e interrumpibles (abrir y cerrar a mitad de camino no salta; abrir y cerrar rápido varias veces no da tirones); el contenido aparece con un leve desenfoque; al crecer se ve la parte de arriba del contenido y las esquinas de abajo redondeadas; bajo el notch la franja negra queda pegada arriba.
- Vidrio: en macOS 26, Liquid Glass deja ver lo de atrás y cambia al pasar una ventana por debajo; en macOS 15, el vidrio de respaldo con un borde claro. Con "Reducir transparencia", vidrios sólidos; con "Reducir movimiento", fundidos sin rebote ni escala, también en los selectores, la marca de la fila y la tarjeta de Ajustes; los dos, también si se cambian con la isla abierta.
- Ajustes de la isla es una tarjeta dentro de la isla: Esc cierra solo la tarjeta; ✕ y Grabar responden al primer clic.
- Ningún control dice "Llega en esta versión."; iPhone dice "Llega en la fase 2.".

**Cuenta, alas e isla grabando** (16a)
- Con la cuenta en 3 s: el número entra chico y desenfocado y sale agrandándose, el anillo se vacía cada segundo, "Esc para cancelar".
- Esc o ⇧⌘2 en la cuenta: se cancela al instante, con la cápsula "Cuenta cancelada." (también con un atajo de No Molestar elegido), y `~/Movies/Toma` no tiene un proyecto nuevo.
- Con la cuenta en 10 s, un clic en otra app a los 2 s y escribir: todas las letras llegan a esa app. Con la cuenta en 0, Grabar pasa directo a las alas. La cuenta (0 · 3 · 5 · 10) se cambia en la tarjeta de Ajustes y en la ventana Ajustes, y las dos muestran lo mismo.
- Alas en la MacBook (anotar el modelo y la resolución): 84 pt a cada lado del notch; a la izquierda el punto rojo, que late cada 1,8 s, y el tiempo ("0:12", "12:34", "1:02:03" un punto más chico); a la derecha el medidor, que sube rápido y baja lento con la voz. En pausa, el punto es ámbar y quieto; con el micrófono apagado, el micrófono tachado. En un monitor externo, las alas van en la píldora de 300 × 36.
- Grabando, llevar el puntero a otra pantalla: la isla se muda con un fundido corto, y vuelve.
- El mouse sobre las alas abre la isla grabando (640 × 226) con el tiempo, "Grabando" o "En pausa" y el medidor. Pausar, marcador (deshabilitado en pausa), reiniciar (pregunta "¿Reiniciar la toma? La actual va a la papelera.") y detener responden al primer clic. Se cierra 650 ms después de sacar el mouse, salvo con la pregunta abierta. Esc no hace nada.
- Barra de menús: grabando, el tiempo junto al ícono rojo avanza; durante la cuenta el menú dice "Iniciando la grabación…" y "Detener grabación" la cancela.
- Atajos: ⇧⌘2 abre y cierra la isla en reposo, cancela la cuenta y detiene; ⌥⌘P y ⌥⌘M solo durante una toma (en reposo le llegan a la app de adelante).
- Ventana Ajustes…: clic en un atajo y escribir otro; ⌥P se rechaza con "Los atajos necesitan ⌘ o ⌃."; ⇧⌘3 o ⌃↑ se rechazan con "macOS u otra app ya usan este atajo."; el nuevo funciona enseguida y el menú y la asomada lo muestran; Esc deja el atajo como estaba y ⌫ lo quita. Un atajo con la barra espaciadora se ve como "⌥⌘Espacio".
- Antes de grabar, con el permiso del micrófono: la columna Audio muestra el nivel en vivo del micrófono elegido y lo sigue al cambiarlo; el indicador del micrófono de macOS está solo mientras el panel está abierto. Sin el permiso, ni medidor ni pedido.

**Avisos, guardando y guardada** (16b)
- Cápsula, 2 s, 10 pt debajo de la isla, sin tomar el foco y dejando pasar los clics: ⌥⌘M dice "Marcador puesto.", ⌥⌘P "En pausa." y reiniciar "La toma quedó en la papelera."; una segunda reemplaza a la primera.
- Micrófono tapado los primeros 5 s: la isla se abre sola 4 s con "El micrófono no está recibiendo sonido." y el ala derecha muestra el triángulo ámbar; al hablar se van.
- Desenchufar un micrófono USB grabando: "Se interrumpió la captura del micrófono. Se vuelve a intentar…"; al enchufarlo, "Se reanudó la captura del micrófono.". Dos avisos seguidos se ven uno después del otro, 4 s cada uno.
- Stop: "Guardando la toma" con su indicador (el de macOS: sigue girando con "Reducir movimiento"), después "Toma guardada" con la duración, "1 marcador" y lo que se grabó, y el editor.
- "Al detener: Quedarme donde estoy" (la tarjeta de Ajustes y la ventana Ajustes muestran lo mismo): al detener la app no se activa y la isla queda 8 s con Abrir en el editor · Grabar otra · Cerrar, cada uno al primer clic.
- Disco casi lleno (una imagen de disco chica como carpeta de proyectos): el ala se pone roja y la toma termina con "La grabación se detuvo: el disco está casi lleno." en rojo, 8 s.
- Fallo al arrancar (elegir una pantalla y desconectarla antes de tocar Grabar): ninguna alerta; la isla dice "No se pudo empezar a grabar" y el motivo. Durante una toma nunca aparece una alerta.

**Pantallas** (14a, 15)
- El panel lista las pantallas con su nombre, la resolución en píxeles y la marca en la elegida; pasar el mouse por una fila la marca con un borde azul.
- "Elegir en la pantalla": la pantalla bajo el cursor se resalta, un clic la elige y no le llega a la app de abajo; Esc, Return y Listo vuelven sin cambiar nada; ⌘Tab a otra app cierra la isla.
- Con 30 fps y Puntos en Ajustes, el video sale a 30 fps y con la mitad de píxeles; el manifiesto nombra el micrófono elegido.
- Dos pantallas marcadas, 20 s: la toma tiene dos pistas `display-<id>` (`jq '.takes[-1].tracks[].id' <paquete>/manifest.json`), y Ajustes muestra los fps de cada una.
- Carga del encoder: con la combinación más pesada que haya (por ejemplo dos pantallas 5K a 60 fps), el punto del pie de la isla pasa a ámbar con "Esta combinación puede ser demasiado para el codificador."; un clic abre Ajustes, y su sugerencia lo vuelve a verde.
- Abrir una ventana de Toma durante la toma (por ejemplo "Licencias de terceros…"): no sale en el video.

**Ventana** (15)
- Ventana › Elegir en la pantalla: "Hacer clic en una ventana para grabarla."; la ventana bajo el puntero se resalta en azul con su app y su tamaño, y el resaltado pasa de una a otra con el resorte; sobre el escritorio no resalta nada; un clic la elige y no le llega a la app; Esc, Enter y Listo vuelven sin elegir.
- Grabar 20 s: el video es esa ventana, sin sus menús. "Con muchos menús, mejor Área o Pantalla." muestra su ayuda al pasar el mouse.
- Minimizarla 5 s grabando: "La ventana que se graba está minimizada u oculta. La grabación sigue cuando vuelva.", que se va al restaurarla; pasarla a otro escritorio no avisa nada.
- Elegir una ventana, salir de Toma, cerrar sesión (o reiniciar la Mac) y abrir la isla de nuevo: en Ventana está elegida una ventana de esa misma app, o ninguna (Grabar queda deshabilitado hasta elegir una); nunca la de otra app, la barra de menús ni una de Toma.
- Con la cámara prendida, la burbuja queda en su lugar dentro de la ventana y la sigue con un movimiento suave al moverla y cambiarle el tamaño.

**Área** (15)
- Área › Dibujar en la pantalla: "Arrastrar para dibujar el área." y después "Mover el área o cambiar su tamaño."; afuera queda oscuro; las medidas siguen al puntero ("1280 × 720 · 16:9"); la grilla de tercios se ve (Grilla la apaga); la barra va a la pantalla del área.
- Moverla, cambiarle el tamaño desde la esquina (no sale de la pantalla ni baja de 64 pt de lado) y pasar a 9:16 (el alto cambia con el resorte).
- "Guardar el área" muestra la cápsula "Área guardada." sin tapar la barra; al cerrar y abrir la isla sigue en "Áreas guardadas", y tocarla la elige.
- La columna dice que se guarda la pantalla entera (el área es el recorte). Confirmar si eso está bien (decisión 1 del plan) o anotar que se prefiere grabar solo el área.
- Con la cámara prendida, la burbuja queda dentro del área y la sigue al dibujarla o moverla.
- Grabar 20 s y exportar: el video es el área, sin una línea de lo que quedó afuera en los bordes.

**De otros escritorios** (15)
- Con una app a pantalla completa en otro escritorio y una ventana en otro escritorio común: Ventana › "De otros escritorios" las lista por app, en orden alfabético, con el ícono de la app.
- Elegir la de pantalla completa sin ir hasta ahí y grabar 20 s: se graba (si macOS deja de mandar cuadros, llega el aviso de ventana oculta y la toma sigue).
- Sin el permiso de Grabación de pantalla la lista no aparece y no sale ningún aviso del sistema.
- Con la cámara prendida y una ventana de otro escritorio elegida, la burbuja flota sobre el escritorio actual (limitación conocida): anotar si molesta.

**Cámara y burbuja** (16e, 14, 15)
- Con la cámara prendida, la burbuja en vivo y espejada (por defecto un círculo mediano abajo a la derecha, con borde claro y sombra). Se ve con la isla abierta, eligiendo, en la cuenta, grabando y con avisos; no en reposo, asomada, guardando ni guardada, y la luz verde se apaga cuando se va.
- Cambiar de cámara desde el menú (también al iPhone): sigue espejada. Desconectar la elegida: pasa a la del sistema y vuelve al reconectarla. Sin ninguna cámara: la burbuja oscura con la cámara tachada.
- Las cuatro formas (Círculo, Cuadrado redondeado, Vertical, Horizontal; la ayuda de cada ícono dice su nombre) y los tres tamaños (Chica · Mediana · Grande) cambian con el resorte; con la cámara apagada se ven atenuados.
- Arrastrarla: va pegada al puntero, con la sombra más honda y los 8 lugares a la vista; soltarla con impulso la lleva al lugar hacia donde iba, con un toque háptico; un clic sin moverla no hace nada; agarrarla mientras vuela la frena; arrastrarla no activa Toma ni le quita el teclado a la app de adelante, tampoco grabando. Forma, tamaño y lugar se recuerdan al volver a abrir Toma.
- Clic secundario (o Control-clic) sobre la burbuja: el menú con las formas y los tamaños, con los actuales marcados; elegir otro cambia la burbuja y la columna Cámara.
- Grabar 30 s: a los 10 s cambiar la forma desde ese menú, a los 20 s el tamaño, y a los 25 s soltarla en otra esquina; exportar desde el editor: el video sigue los tres cambios en esos momentos, con un movimiento suave. El menú no sale en el video.
- Grabando, la burbuja no se congela ni parpadea al empezar ni al detener, y la pista `camera` es la cámara que mostraba, con el tamaño y los fps de la calidad elegida en Ajustes. Desenchufar una cámara USB grabando: la burbuja y la pista pasan juntas a la integrada; al volver a enchufarla, la toma no cambia de cámara sola.
- Permiso nunca pedido (`tccutil reset Camera dev.toma.Toma`): el pedido sale en español, entero y sin la isla encima, y la isla sigue abierta al contestarlo. Negado: el interruptor queda apagado, la columna dice "El acceso a la cámara está desactivado." con "Abrir Ajustes", y una toma con la cámara elegida graba sin ella y avisa "El acceso a la cámara está desactivado. Se graba sin la cámara.".
- Con "Reducir movimiento", la burbuja aparece y se va con un fundido, y los cambios de forma, tamaño y lugar son inmediatos.
- Las esquinas transparentes de la burbuja toman los clics (limitación conocida): anotar si molesta.

**Audio del sistema** (10, 14, 15)
- Primera vez (`tccutil reset AudioCapture dev.toma.Toma` y `defaults delete dev.toma.Toma permissionRequested.systemAudio`): tocar Todo en la isla muestra el aviso del sistema entero, con la isla debajo, que no se cierra; al contestarlo y pasar el mouse por la isla, la isla vuelve a su nivel y toma el teclado. Anotar cuánto tarda el aviso en salir.
- Con el audio del sistema elegido y el permiso nunca pedido, Grabar: la toma arranca sin esa pista y avisa "Para grabar el audio del sistema, primero hay que activarlo en el control de grabación y dar el permiso. Se graba sin él."; ningún pedido sale en el video.
- "Elegir apps…" lista las apps abiertas con su ícono (primero las que suenan); los íconos de las elegidas quedan al lado. Grabar con Música elegida y otra app sonando: solo se oye Música.
- Todo, con música y `osascript -e 'display notification "x" sound name "Glass"'` a los 10 s: la música está y el sonido de la notificación no.
- Con AirPods y después con una interfaz USB como salida: los auriculares no bajan de calidad y la pista tiene el audio. Cambiar la salida a mitad de toma: la pista sigue.

**Teleprompter** (16c)
- El interruptor de la columna Audio y guion y el botón de la isla grabando (`text.alignleft`) lo muestran 10 pt debajo de la isla, y los dos muestran lo mismo. Se ve con la isla abierta, en la cuenta, en las alas, grabando y con un aviso; no en reposo, asomada, eligiendo, guardando ni guardada. Aparece y se va con un fundido.
- Sigue a la isla al crecer y al achicarse, sin quedarse atrás ni separarse, y se muda con ella a otra pantalla.
- Quieto en la cuenta, desde el principio; al grabar sube a 24 pt por segundo a 1× (0,3× más lento, 3× más rápido); quieto en pausa; al final la última línea queda en la franja clara. Reiniciar la toma o "Grabar otra" lo vuelve al principio. Cambiar el tamaño de letra grabando no lo hace saltar a otra parte del texto.
- Editar (`pencil`) no activa Toma; ⌘A, ⌘C, ⌘V, ⌘X, ⌘Z y ⇧⌘Z funcionan. Listo o Esc vuelven a la lectura y devuelven el teclado. ⌘Q editando no sale de Toma ni de la otra app.
- Tamaño de 14 a 40 pt de a 2; velocidad de 0,3× a 3×; opacidad de 20 a 100 % (cambia el tinte, no el vidrio); la etiqueta "No sale en el video". Con VoiceOver, los tres dicen su valor.
- Con el teleprompter a la vista, la cápsula cuelga 10 pt debajo de él.
- Al salir y volver a abrir Toma, el interruptor, el guion, el tamaño, la velocidad y la opacidad están como se dejaron.

**Escritorios** (16d)
- La lista (panel en modo Pantalla y fila de la isla grabando) coincide con Mission Control: los nombres, el orden y el actual resaltado; dos ventanas de una app a pantalla completa con su título ("Safari — …") y un escritorio en Split View con sus dos apps ("Safari y Notas"). ⌃→ con la isla abierta mueve el resaltado.
- Sin Accesibilidad (`tccutil reset Accessibility dev.toma.Toma`): tocar otro escritorio no salta y la isla lo explica en ámbar con "Dar permiso…", que la primera vez muestra el aviso del sistema entero y después abre Ajustes del Sistema. Grabar funciona sin el permiso.
- Con Accesibilidad: saltar del 1 al 3 y volver, sin activar Toma; la isla sigue abierta con el escritorio nuevo resaltado y Esc la cierra. Con dos pantallas, el salto desde la isla de la secundaria cambia el escritorio de esa pantalla. Si una pulsación se pierde, anotar cuándo.
- Con "Mover un espacio a la izquierda" apagado o cambiado (Ajustes del Sistema › Teclado › Atajos de teclado › Mission Control): tocar un escritorio no mueve nada en la app de adelante y la isla explica cómo activarlo; al dejarlo como estaba, el salto vuelve a funcionar sin abrir Toma de nuevo.
- Grabando, el botón Mission Control (`rectangle.3.group`) lo abre y la isla vuelve a las alas sin tapar la barra de escritorios.
- Grabar Pantalla y cambiar de escritorio desde la isla, también a una app a pantalla completa: la toma no se corta y el video muestra cada escritorio.

**No Molestar** (17a)
- Grabar 10 s con No Molestar apagado: se activa antes de que la cuenta empiece a bajar y se apaga al detener.
- Con No Molestar activado a mano antes de grabar: sigue activado al terminar.
- Cancelar la cuenta con Esc: "Cuenta cancelada." al instante, y No Molestar se apaga enseguida.
- Grabando, `kill -9 $(pgrep -x Toma)` y volver a abrir Toma: No Molestar se apaga al abrir.
- Una notificación con sonido a los 5 s de una toma (`osascript -e 'display notification "x" sound name "Glass"'`): ni se ve ni se oye. Sin atajo elegido, se ve y se oye en la Mac, pero no sale en el video ni en la pista de audio del sistema.
- Atajo lento: uno que espere 10 s y después active No Molestar. La toma arranca igual y la isla dice "No se pudo correr el atajo de No Molestar. Puede que suenen notificaciones durante la grabación."; reiniciar la toma: el aviso sigue. Al detener, anotar si No Molestar quedó activado (se espera que no: Toma corre el atajo con `off` al terminar).
- Reiniciar con el atajo normal: No Molestar sigue activado en la toma nueva y se apaga una sola vez, al detener.
- El interruptor No Molestar de los Ajustes de la isla muestra la lista de atajos (la misma de Ajustes); en Permisos, la fila opcional "No Molestar" abre Ajustes.

**Ocultar íconos y foto del fondo** (17b)
- "Ocultar íconos" se prende en los Ajustes de la isla o en Ajustes ("Ocultar los íconos del escritorio al grabar"), y los dos muestran lo mismo.
- Con un fondo estático y una ventana de Finder abierta: al empezar la cuenta los íconos desaparecen y el escritorio se ve igual (sin corrimiento ni cambio de color); en el video no están los íconos, sí el fondo y la ventana de Finder; al detener, y al cancelar la cuenta, vuelven. Con "Ocultar íconos" apagado, los íconos salen en el video.
- Con un fondo dinámico, y en un escritorio con su propio fondo: la tapa y el video muestran ese fondo (anotar cómo se ve: se espera una imagen fija, la del momento de empezar o de cambiar de escritorio).
- Con la tapa puesta, un clic secundario en el escritorio abre el menú de Finder; Toma no aparece en ⌘Tab ni en el Dock.
- Dos escritorios con fondos distintos: al cambiar de escritorio grabando, la tapa muestra el fondo del actual (anotar cuánto tarda), y el video también.
- Dos pantallas: las dos quedan tapadas; cambiar la resolución de una a mitad de toma: su tapa la sigue cubriendo entera. Desenchufar una pantalla grabando y volver a enchufarla (o apagar y prender el monitor): al volver, su tapa vuelve y los íconos no se ven ni salen en el video; ninguna tapa aparece sobre la otra pantalla.
- En una pantalla P3 la tapa puede verse un poco más apagada que el escritorio (limitación conocida): anotar si se nota.
- Cada toma tiene `takes/<toma>/wallpapers/display-<id>.png` por pantalla grabada (`ls <paquete>/takes/*/wallpapers`), igual al fondo que se ve, del tamaño en píxeles de la pantalla, sin íconos, Dock, barra de menús, ventanas ni una notificación que llegue al empezar. También con "Ocultar íconos" apagado; en Ventana, la de la pantalla de la ventana; en Área, la del área; un reinicio tiene la suya.

**Pausa, reinicio, salida y recuperación** (5a, 8)
- Pausa de 10 s con un reloj con segundos en pantalla: el tiempo no avanza; el editor muestra el hueco y el video no tiene nada de esos 10 s (ni cuadros, ni cursor, ni clics).
- Bloquear la pantalla 20 s grabando: el tiempo no avanza y al desbloquear sigue desde donde quedó.
- Reiniciar: la toma nueva arranca sin abrir el editor; el proyecto viejo está en `~/Movies/Toma/Trash` y se abre con doble clic. "Mostrar la papelera en Finder" (menú, en reposo) abre esa carpeta.
- Cmd-Q grabando: la toma queda `.complete` y no hay alerta al volver a abrir. Cmd-Q mientras el sistema pide el micrófono (`tccutil reset Microphone dev.toma.Toma` antes de grabar): Toma sale cuando termina el arranque y `~/Movies/Toma` no tiene un paquete vacío.
- `kill -9 $(pgrep -x Toma)` grabando y volver a abrir: aparece la alerta de recuperación y "Recuperar" abre el proyecto, que se reproduce.
- El ícono del Dock aparece solo con el editor, Permisos o Ajustes abiertos y sin toma.

**Export y nada de Toma en el video** (13, 14)
- Grabar 30 s con la cámara, hablando, y con el audio del sistema en Todo y música sonando; exportar desde el editor: se oyen el micrófono y el audio del sistema, y van con el video (un aplauso frente a la cámara suena en el cuadro en que se juntan las manos, al principio y al final de la toma).
- En ningún video salen la isla, la zona del notch, el borde azul de las filas, las cápsulas, el teleprompter (tampoco editando), la burbuja con su sombra y sus lugares, su menú, la superposición del área o de la ventana, la fila de escritorios ni las notificaciones.

### 3. Desde Terminal

En Terminal.app, con los permisos de la preparación (punto 5).

1. **Las suites:** `make test`, `make tsan` y `make crash-test` (cinco casos: una pantalla en movimiento; una pantalla que se queda quieta a los 2 s; el tercero con dos pantallas, cámara, micrófono y audio del sistema; el cuarto con una ventana; y el quinto, el del editor del hito 1b: la primera edición de un v1 y de un v2 con `kill -9` después de cada paso del paso a la versión 3, tras el que el paquete se vuelve a abrir y guarda una edición; un v3 con `kill -9` después de cada paso de la compactación del registro (la instantánea escrita, el registro nuevo escrito y sincronizado, renombrado sobre el viejo); y 100 corridas de ediciones con `kill -9` en momentos al azar, la mitad con compactación del registro) pasan.
2. **Integración:** `RECORDER_INTEGRATION=1 make test` pasa con Grabación de pantalla, Micrófono, Cámara y Audio del sistema otorgados a Terminal (la primera vez macOS pide cada uno: contestarlo y correrla otra vez). Si `capturesSystemAudioForTwoSeconds` falla midiendo unos −160 dBFS, anotar "silencio = permiso".
3. **Resistencia:** `bash scripts/stress-recovery.sh` (1 h, `kill -9` a los 30 min) pasa, y otra vez con `STRESS_FLAGS="--display <principal> --display <secundaria> --camera default --system-audio all"` (los ID de `recorder-dev list-sources`): memoria acotada con todas las pistas. Anotar los números que imprime cada corrida (RSS a los 5 y a los 30 min, duración recuperada).
4. **Calibración del encoder:** los pasos de [`docs/performance.md`](performance.md), "Presupuesto del encoder (hito 1a)": anotar en su tabla la carga medida y los cuadros perdidos por pista (un agente ajusta el presupuesto con eso).
5. **Cámara con `recorder-dev`** (9). Después de cada toma, `recorder-dev verify <paquete> --min-duration <la duración menos 5 s>` da OK.
   - `recorder-dev record <carpeta> --duration 30 --camera default`: la pista `camera` dura unos 30 s en un segmento, en 1920×1080 si la cámara lo tiene a 30 fps, y el manifiesto nombra su `deviceUniqueID`; la luz verde se apaga al terminar.
   - Con `--camera-preset p720`: el segmento de la cámara (QuickTime Player, ⌘I) es 1280×720 (o el formato más chico que lo cubra) a unos 30 fps. Si no, anotar lo que diga `log show --last 5m --predicate 'subsystem == "dev.toma.Toma" AND category == "CameraSessionHost"'`.
   - Con `--camera <uniqueID del iPhone>`, el iPhone cerca, bloqueado y en horizontal: la pista es la del iPhone.
   - Con `--camera <uniqueID de una USB>`, desenchufarla a los 10 s y enchufarla a los 20 s: la toma sigue, la pista `camera` tiene un segundo segmento con la cámara del sistema y un `deviceChanged` en `events.jsonl`, sin un tramo largo sin cuadros; la USB no se retoma sola (anotar si se preferiría que sí).
   - Con `--camera default`, abrir FaceTime con esa cámara a los 10 s y cerrarlo a los 20 s: la pista no se queda sin cuadros (anotar si siguió igual o en un segmento nuevo).
   - Con un monitor externo como pantalla principal, cerrar la tapa a los 10 s: la cámara pasa a otra (`deviceChanged`) o sigue intentando, y vuelve a la integrada al abrir la tapa; la pantalla no se corta.
6. **Audio del sistema con `recorder-dev`** (10). El manifiesto nombra la pista `system-audio` con `excludedBundleIDs` (Toma y los sonidos de notificaciones y alertas) o `includedBundleIDs`.
   - Mientras suena `osascript -e 'display notification "x" sound name "Glass"'`, `recorder-dev list-sources | grep '^audio process'`: anotar el bundle ID y la ruta de cada proceso que dice "playing"; los de notificaciones y alertas tienen que decir "excluded".
   - `--system-audio com.google.Chrome` con Chrome callado: la toma arranca enseguida y la pista queda en silencio; con un video en Chrome y música en otra app, solo Chrome. Con Chrome cerrado y abierto a los 10 s con un video: su audio entra desde ahí, en el mismo segmento.
   - `--system-audio com.apple.Safari` con un video en Safari: anotar si la pista tiene el audio o queda en silencio, y qué procesos dicen "playing".
   - En macOS 15: `systemsoundserverd` no aparece en `list-sources`; grabar `--system-audio all` con música y notificaciones con sonido a los 10 s y a los 20 s: anotar si la primera alerta (o su comienzo) quedó en la pista y si la segunda no.
   - Si `verify` dice que `system-audio` no tiene medios con el permiso dado, anotarlo.
7. **Pantallas, ventana y área con `recorder-dev`** (11). Si algo falla, `log show --last 5m --predicate 'subsystem == "dev.toma.Toma" AND (category == "ScreenStreamCapture" OR category == "DisplayCaptureSource")'`.
   - `--display <A> --display <B> --duration 60`, moviendo el cursor entre las dos y desenchufando la secundaria a los 20 s: `warning: trackLost` de esa pista y la otra sigue en un segmento; `events.jsonl` tiene el cursor sobre las dos hasta los 20 s.
   - `--display <ID> --area 100,100,800,450 --duration 30` y otra resolución a los 10 s: `captureArea` en el manifiesto, la pantalla entera grabada, un `displayGeometry` nuevo y, si cambió el tamaño en píxeles, un segundo segmento (`formatChanged`) sin contenido achicado ni bordes negros. Lo mismo en una pantalla externa pasando de 16:10 a 16:9; `recorder-dev export <paquete> <salida.mp4>`: el recorte y el cursor siguen alineados.
   - `--window <ID de una ventana de Safari> --duration 90`: pasar a otro escritorio y volver (se sigue grabando; `visibility: otherSpace` y `visibility: visible`; anotar si sale `hidden` con la ventana quieta 10 s); un menú no sale (anotar si un popover sí); redimensionarla abre segmentos `formatChanged` sin contenido achicado; medio fuera de la pantalla, sin segmentos nuevos; minimizada 5 s, `onScreen: false` y `visibility: hidden`; cerrada, la toma sigue hasta el final.
   - `--display <principal> --duration 15` y `osascript -e 'display notification "x"'` a los 2 s: la notificación no sale y la pista tiene un solo segmento; lo mismo con widgets en el escritorio.
   - `--display <principal> --duration 20`, `killall NotificationCenter` a los 5 s y una notificación a los 10 s: no sale, y el log dice "makes its filter again to exclude com.apple.notificationcenterui" y después "excludes com.apple.notificationcenterui again".
   - La misma toma de 10 s con y sin `--points` (también con `--window`): con `--points`, la mitad de píxeles de ancho y de alto en una pantalla Retina y `pixelScale` 1; un solo segmento por pista.
   - `--display <ID> --window <ID>` se rechaza ("--window records no display").

| Comprobación | Fecha | macOS | Resultado |
|---|---|---|---|
| 0. Preparación: certificado (o ad hoc), copia de prueba, permisos, atajo, Terminal | pendiente | pendiente | pendiente |
| 1. Recorrido completo: Área 16:9, iPhone, audio de una app, teleprompter, pausa, marcador, burbuja, salto, editor y MP4 | pendiente | pendiente | pendiente |
| 2. Isla y notch | pendiente | pendiente | pendiente |
| 2. Cuenta, alas e isla grabando, atajos, medidor | pendiente | pendiente | pendiente |
| 2. Avisos, guardando y guardada | pendiente | pendiente | pendiente |
| 2. Pantallas | pendiente | pendiente | pendiente |
| 2. Ventana (también la guardada después de reiniciar) | pendiente | pendiente | pendiente |
| 2. Área (decisión 1) | pendiente | pendiente | pendiente |
| 2. De otros escritorios | pendiente | pendiente | pendiente |
| 2. Cámara y burbuja (menú de la burbuja durante la toma) | pendiente | pendiente | pendiente |
| 2. Audio del sistema | pendiente | pendiente | pendiente |
| 2. Teleprompter | pendiente | pendiente | pendiente |
| 2. Escritorios | pendiente | pendiente | pendiente |
| 2. No Molestar (atajo lento) | pendiente | pendiente | pendiente |
| 2. Ocultar íconos y foto del fondo (pantalla que vuelve) | pendiente | pendiente | pendiente |
| 2. Pausa, reinicio, salida y recuperación | pendiente | pendiente | pendiente |
| 2. Export y nada de Toma en el video | pendiente | pendiente | pendiente |
| 3. `make test`, `make tsan`, `make crash-test` | pendiente | pendiente | pendiente |
| 3. `RECORDER_INTEGRATION=1 make test` | pendiente | pendiente | pendiente |
| 3. Resistencia, también con todas las pistas | pendiente | pendiente | pendiente |
| 3. Calibración del encoder | pendiente | pendiente | pendiente |
| 3. Cámara con `recorder-dev` | pendiente | pendiente | pendiente |
| 3. Audio del sistema con `recorder-dev` | pendiente | pendiente | pendiente |
| 3. Pantallas, ventana y área con `recorder-dev` | pendiente | pendiente | pendiente |

## Pendientes del dueño del hito 1b

Una sola pasada de fin de hito, contra la app de esta rama, en orden: la preparación, el recorrido completo y el detalle por área. Cada comprobación dice qué se tiene que ver. Si se ve otra cosa, o algo molesta, anotar lo que se ve (con la versión exacta de macOS) en la tabla del final: los agentes trabajan con esas notas. Ninguna comprobación pide cambiar código. Entre paréntesis, la tarea de origen. Lo que un agente puede correr no está acá: las suites, `make tsan`, `make crash-test` y `make golden` los corre el controlador en la rama del hito antes de entregar esta pasada, y las medidas de la Mac M5 Pro están en `docs/performance.md`, con las que siguen pendientes. Acá queda lo que necesita una Mac con permisos reales, una pantalla, un oído, un macOS 15 o la Mac M1 de piso.

### 0. Preparación

La app de la fase 2 está en `build/fase2/Toma.app` (Release, firma ad hoc; es la única copia registrada). Como es una compilación nueva, macOS pide de nuevo los permisos: «Abrir Ajustes del Sistema» la vuelve a poner en la lista.

1. **Abrir la copia de prueba.** La arma el controlador después de unir la rama: `open build/prueba/Toma.app`. `codesign -dv build/prueba/Toma.app 2>&1 | grep Authority` dice `Authority=Toma Project Signing` cuando salió firmada con el certificado (paso 1 de la preparación del hito 1a); si no, es ad hoc.
2. **La copia ad hoc y el certificado** (pendiente del hito 1a). Si se creó el certificado de firma (paso 1 de la preparación del hito 1a) después de recibir la copia de prueba, pedir una copia nueva: la anterior quedó ad hoc y macOS no conserva sus permisos de una copia a la siguiente (con una copia nueva firmada, `tccutil reset All dev.toma.Toma` y otorgarlos de nuevo la primera vez).
3. **Permisos.** Los mismos del hito 1a (paso 3 de su preparación): Toma pide cada uno cuando hace falta. El hito 1b **no pide ninguno nuevo**: ni Monitoreo de entrada ni Accesibilidad para el editor; si algún aviso nuevo aparece, anotarlo.
4. **Las dos copias de la app.** Algunas comprobaciones de «La ventana del editor» necesitan abrir el mismo proyecto en dos copias de la app (la copia de prueba y otra, por ejemplo una compilada con Xcode: `make build`).
5. **Tener a mano:** la Mac de siempre (M5 Pro, macOS 26) y, si hay, una con macOS 15 (mejor la M1 de piso); un monitor externo de otra forma que la pantalla de la Mac (16:9, o uno vertical); AirPods; un trackpad y un mouse con rueda de líneas; una cámara; un micrófono (y uno USB a 44,1 kHz o Bluetooth, para las dos pruebas de macOS 15 de abajo); y apps con campos de texto, de contraseña, enlaces y una de dibujo.
6. **Para las medidas de la M1.** En la M1, en una copia de esta rama: `swift build --package-path Packages/RecorderKit -c release --product recorder-dev` deja el binario en `Packages/RecorderKit/.build/release/recorder-dev`; es el que usan «El export» y «La vista previa» de abajo.

### 1. Recorrido completo (la salida del hito)

Con la copia de prueba abierta desde Finder, en la Mac del dueño y, donde se dice, en macOS 15. Las diez comprobaciones del diseño del hito (§10.3), en ese orden:

1. **Una toma real con todo.** Grabar con clics en varias apps, un campo de texto donde se escribe un buen rato, un campo de contraseña de Safari donde se escribe, scroll en Safari, el cursor pasando por I-beam, mano y flechas de redimensionar, una pausa de 5 s y un cambio de la burbuja de la cámara. Parar y abrir en el editor: se ven zooms automáticos en los clics; con «Mantener el zoom al escribir», el zoom se queda mientras se escribe; la forma del cursor en cada momento es la que se vio al grabar; y `events.jsonl` de la toma no tiene ninguna línea `keyActivity` mientras se escribía la contraseña (ni la del Enter que cierra el campo) y sí tiene `scroll` y `cursorImage`.
2. **El cursor y sus efectos.** Con el suavizado Medio el cursor aterriza en cada clic y se siente como el de Screen Studio; los efectos de clic (Ondas y Círculo), ocultar en reposo y el desenfoque de movimiento se ven bien a 1080p y a 4K, en la vista previa y en el video exportado.
3. **Editar y sobrevivir a un crash.** Cortar un tramo, recortar un borde, poner 2× un tramo, deshacer y rehacer muchos pasos; mientras se edita, `kill -9` a Toma desde Terminal (`pkill -9 -x Toma`); al reabrir el proyecto, todo está y Deshacer llega hasta la primera edición.
4. **Exportar.** Con ⌘E, en 16:9, 9:16 y 1:1 (el formato se cambia antes en la barra), a 1080p y a 4K, siempre a 60 cuadros: cada MP4 se abre en QuickTime, se reproduce sin saltos y con el sonido en sincronía, no tiene nada de lo cortado y se ve como la vista previa del editor en el mismo instante.
5. **La vista previa fluida.** Reproducir una toma de la pantalla XDR con un zoom con desenfoque de movimiento: se ve fluida a la frecuencia de la pantalla, sin saltos de imagen ni tirones del sonido; si queda más borrosa mientras suena (es lo que hace cuando no da abasto, hasta pausar), anotarlo. Arrastrar el cabezal de punta a punta por la regla, rápido: la interfaz nunca se congela y al soltar aparece el cuadro exacto. El editor no muestra los cuadros por segundo: para leerlos, abrir la app desde Terminal con el HUD de Metal, `MTL_HUD_ENABLED=1 <carpeta>/Toma.app/Contents/MacOS/Toma` (los permisos que recibe así no cambian nada en esta comprobación), y mirar la cifra de cuadros por segundo del HUD mientras reproduce; sin el HUD, la comprobación es solo visual.
6. **Dos pantallas.** Con una toma de dos pantallas, la pista Pantalla sigue al cursor entre las dos, y se puede cambiar a mano en la pista, con el cambio animado (ver «Dos pantallas y cambios de forma»).
7. **Fondos.** El escritorio desenfocado (con el propio fondo del escritorio de la toma), una imagen propia, los fondos de pantalla procedurales y los degradados, en macOS 26 y, si hay una a mano, en macOS 15.
8. **Teclado, VoiceOver y accesibilidad.** Recorrer la línea de tiempo y el panel con VoiceOver; cortar y exportar solo con el teclado; Reducir movimiento y Reducir transparencia.
9. **Un proyecto de 1a.** Abrir uno grabado con la copia del hito 1a: se ve igual que antes, con su franja «Este proyecto se grabó con una versión anterior y conserva su aspecto.»; «Aplicar el estilo por defecto» lo cambia y se deshace con ⌘Z; hasta la primera edición, el paquete no cambia (`manifest.json` sigue con `"formatVersion" : 2`, sin `edit.json` ni `edit.lock`); exportarlo sin editar y abrir el MP4 al lado del que exporta la copia del hito 1a: en el mismo instante se ven iguales (que los cuadros den los mismos bytes lo prueba `make golden`).
10. **Las metas de rendimiento** de diseño §7.9 en la Mac del dueño y en la M1: las medidas del agente están en [`docs/performance.md`](performance.md), con la columna de la M1 y las dos medidas que solo se hacen a mano (la línea de tiempo de una hora y abrir un proyecto de una hora) para anotar ahí.

### 2. Detalle por área

**Imágenes del cursor** (16)
- En macOS 15 y en macOS 26, grabar una toma con el cursor en I-beam (un campo de texto), en la mano (un enlace en Safari), en las flechas de redimensionar (el borde lateral, el de arriba y una esquina de una ventana) y en uno propio de una app (una de dibujo): `takes/<toma>/cursors/` tiene una imagen por forma (una sola aunque la forma vuelva varias veces), el editor muestra cada una y, en estilo Toma, los bordes salen con las flechas de Toma (la esquina, con la imagen grabada).
- En `events.jsonl` de esa toma, los `cursorImage` del I-beam, la mano y los bordes tienen `"kind"` (`iBeam`, `pointingHand`, `resizeLeftRight`, `resizeUpDown`); el de la esquina y el de la app de dibujo, no.
- Toma no aparece en ninguna lista nueva de Ajustes del Sistema ▸ Privacidad y seguridad.
- Grabando con el cursor quieto, el uso de CPU de Toma (Monitor de Actividad) es a lo sumo 2 puntos más que con la copia del hito 1a en la misma toma: anotar los dos números.
- Con Accesibilidad ▸ Pantalla ▸ Puntero en el tamaño más grande, o con otros colores del puntero, y con un pincel grande en una app de dibujo, grabar 10 s moviéndolo: ninguna imagen de `cursors/` pasa de 512 px de lado (un cursor de más de 128 pt se guarda a menos de 4 píxeles por punto), el editor muestra el puntero grabado de su tamaño, no la flecha de Toma, y anotar el tamaño en píxeles de las imágenes y si tienen `"kind"`.

**Los nueve cursores de Toma** (24)

Los dibuja Toma en código (negros con un contorno blanco; ningún arte de Apple). Con la toma de «Imágenes del cursor» abierta en el editor, en la pestaña Cursor con el estilo «Toma»: el puntero, el I-beam, la mano que señala, la mano abierta, la mano cerrada, la cruz, las flechas de redimensionar de izquierda a derecha y de arriba abajo, y el de prohibido.
- A 1080p y a 4K, y con un zoom de 3×: cada uno se ve nítido, sin bordes dentados, y reconocible como lo que es; el contorno blanco se lee sobre un fondo oscuro y sobre uno claro.
- El punto de clic cae donde debe: la punta de la flecha y de la mano que señala, y el centro del I-beam, de la cruz, de las manos y de las flechas de redimensionar.
- Anotar, para cada uno, si hay que redibujarlo (y por qué).

**Los sonidos de clic** (28)

`soft-1` y `mechanical-1` se sintetizan en código (no hay archivos de audio): `soft-1` es un golpe suave de 45 ms y `mechanical-1` una tecla de 55 ms, con un golpe al bajar y otro más suave al subir. Con una toma con clics, en la pestaña Cursor y con «Sonido de clic» en cada uno, con el volumen en 50 y en 100 %, en la vista previa (con la salida de la Mac y con AirPods) y en el video exportado: los dos suenan limpios (sin chasquidos ni zumbido ni cortes), el Mecánico se distingue claramente del Suave, y cada uno cae en el cuadro del clic. Anotar cuál preferís y si alguno suena raro: cada sonido queda congelado con su id, y uno nuevo se agrega con otro (`soft-2`).

**Scroll y actividad del teclado** (17)

Lo de "sin permiso" solo vale con Toma abierta desde Finder: la que se abre desde Terminal o Xcode recibe sus permisos, y la de los agentes también. El registro de la app se lee con `log show --last 10m --predicate 'subsystem == "dev.toma.Toma" AND category == "KeyActivityRecorder"'`.
- Antes, `tccutil reset ListenEvent dev.toma.Toma`, y abrir Toma desde Finder. Anotar si aparece algún aviso, al abrirla o al grabar (no tiene que aparecer ninguno).
- En macOS 15 y en macOS 26, sin Monitoreo de entrada otorgado, con "Anotar cuándo se escribe (nunca qué)" prendido (Ajustes, lo está por defecto), escribir en un campo de texto mientras se graba: `events.jsonl` de la toma tiene líneas `{"t":…,"type":"keyActivity"}`, a lo sumo una cada 250 ms, y el registro de la app dice, al empezar la toma, "Input Monitoring is granted" o "not granted" (lo que dio `CGPreflightListenEventAccess`). Si no hay ninguna línea `keyActivity`, anotarlo, con lo que dice el registro: es el plan B, y "Mantener el zoom al escribir" queda deshabilitado con su nota.
- Mover el mouse sin escribir durante 10 s: ninguna `keyActivity` en ese lapso. Si el registro dice "follows the mouse, not the keyboard", anotarlo: en esa Mac la lectura sigue al mouse y la toma deja de anotar.
- Escribir en un campo de contraseña de Safari y la contraseña de `sudo` en Terminal: ninguna línea `keyActivity` en ese lapso, ni la del Enter que cierra el campo. Con Terminal ▸ "Secure Keyboard Entry" prendido, ninguna línea mientras se escribe en Terminal.
- Con "Anotar cuándo se escribe (nunca qué)" apagado, grabar escribiendo: ninguna línea `keyActivity`, y el registro no dice nada de esa toma.
- Después de grabar, Ajustes del Sistema ▸ Privacidad y seguridad ▸ Monitoreo de entrada: Toma no aparece.
- Hacer scroll en Safari con el trackpad y con un mouse de rueda de líneas: `events.jsonl` tiene líneas `scroll` con `dx` y `dy` en puntos de un orden razonable (un giro corto de la rueda, unas decenas de puntos; la rueda cuenta 10 pt por línea). Anotar, para cada uno, cuánto se movió la página y qué sumaron los `dy`.

**El audio con velocidad en macOS 15** (29)

El estirador (`AVAudioUnitTimePitch`) solo se midió en macOS 26: ahí avanza su entrada de a `round(256 × rate)` cuadros por salto, que es lo que corrige Toma para que el audio no se corra del video, y su latencia es 0. Ningún agente tiene una Mac con macOS 15.
- En una Mac con macOS 15 (mejor la del piso M1), en una copia de esta rama con Xcode 26 (Swift 6.2, lo que pide `swift-tools-version: 6.2`; Xcode 27, el de `CONTRIBUTING.md`, pide macOS 26.6 o posterior, según el `LSMinimumSystemVersion` de Xcode 27.2), correr `swift test --package-path Packages/RecorderKit --filter 'aLongClipAtAnUnevenSpeedDoesNotDrift|stretchedOnsetIsAligned|stretchIsDeterministic'`: las tres pasan (`stretchedOnsetIsAligned` con sus 4 casos, a 0,25×, 0,7×, 2× y 4×). Ningún agente comprobó que el paquete compile con Swift 6.2 (los agentes usan Xcode 27.2, Swift 6.4): si no compila, anotar el primer error y la versión de Xcode, y la comprobación queda pendiente. Anotar la versión exacta de macOS y, si alguna falla, el mensaje entero: en `aLongClipAtAnUnevenSpeedDoesNotDrift` dice cuánto se corrió el sonido (el salto del efecto es otro), en `stretchedOnsetIsAligned` cuánto antes o después empieza (una latencia que el efecto no informa) y en `stretchIsDeterministic` qué rango dio otros bits.

**Micrófonos que no graban a 48 kHz, en macOS 15** (32)

Un micrófono USB a 44,1 kHz o uno Bluetooth a 16 o 24 kHz se graba a su frecuencia y se remuestrea a 48 kHz al leerlo. Para que un salto de la vista previa no lo decodifique desde el comienzo, Toma lo empieza en el medio, en un punto donde coinciden una muestra del archivo y una de 48 kHz: ahí el remuestreador de macOS da, a las pocas muestras, las mismas que leyéndolo desde el comienzo. Eso solo se midió en macOS 26. Al abrir el proyecto Toma lo comprueba en cada segmento, y si no da lo mismo, ese segmento se lee desde el comienzo: el sonido es el mismo, pero un salto tarda más (unos 0,35 s a los 10 min de una toma, en esta Mac).
- En una Mac con macOS 15, en una copia de esta rama con Xcode 26 (como la comprobación de arriba), correr `swift test --package-path Packages/RecorderKit --filter 'aTrackIsReadFromNearTheFrameAskedFor|aResampledSegmentIsStartedOnlyWhereItGivesTheSameFrames'`: las dos pasan (la primera, con sus 7 casos: 48; 44,1 mono y estéreo; 24; 16; 11,025 y 8 kHz). Anotar la versión exacta de macOS y, si alguna falla, el mensaje entero: si dice `placed.seekOrigin != nil` o "started at", en esa versión el remuestreador no da lo mismo desde el medio (y esos segmentos se leen desde el comienzo); si dice `bits`, el sonido leído desde el medio es otro, y eso no tiene que pasar.

**Esquinas de las tomas de ventana** (22)

Una captura de ventana graba en negro las esquinas redondeadas de la ventana, con un radio que depende del macOS que grabó. Un proyecto nuevo de una toma de ventana empieza con esquinas que tapan 26 pt de la ventana (`WindowCornerCover.blackCornerPoints`, provisional hasta esta medida).
- En macOS 26 y, si hay a mano, en macOS 15, grabar una ventana en modo Ventana (una de Safari o de Finder, con sus esquinas a la vista) y abrir la toma en el editor con el estilo por defecto: no se ve ninguna esquina negra en las cuatro esquinas de la pantalla, ni en la vista previa ni en el video exportado. Lo mismo con el marco "Ventana de macOS" prendido: ni bajo la barra ni en las esquinas de abajo.
- Medir el radio de las esquinas negras de esa toma: exportarla sin edición y a 1:1 con `recorder-dev export --raw <paquete> <salida.mp4>`, con `--width` igual al ancho en píxeles de la ventana grabada dividido por 0,84 (el margen del legado ocupa el 16 % del ancho), redondeado a par, y `--height` de al menos el alto en píxeles de la ventana más 0,16 veces ese `--width`, también par (así la ventana sale de su tamaño grabado). En un cuadro del video al 100 %, contar los píxeles desde la esquina de la pantalla hasta donde el borde de arriba deja de tener negro, y dividirlos por el `pixelScale` de la pista (en el manifiesto) para pasarlos a puntos.
- Anotar en la tabla, para cada macOS, el radio en píxeles y en puntos: con eso se ajusta `blackCornerPoints` antes del cierre del hito (más grande si alguno pasa de 26 pt).

**Dos pantallas y cambios de forma** (27)

Un proyecto nuevo cambia de pantalla, y de forma, con un resorte: el rectángulo del video va de la forma vieja a la nueva en unos 0,2 s y, al cambiar de pantalla, el contenido de una se funde en el de la otra en 0,25 s. Mientras se mueve, cada video llena el rectángulo recortado, nunca estirado. Un proyecto de antes del hito 1b sigue saltando, como antes.
- Con dos pantallas de distinta forma (la de la Mac y un monitor externo, por ejemplo 16:10 y 16:9, o uno vertical), grabar una toma con las dos y pasar el cursor de una a otra, quedándose unos segundos en cada una. En el editor, con el estilo por defecto: la pista Pantalla cambia sola a la pantalla donde está el cursor y, en la vista previa y en el video exportado, el video pasa de una a otra con un movimiento suave, sin un salto ni un cuadro negro ni un video estirado. El cursor aparece en la pantalla nueva en el instante del cambio, sin cruzar el video. Cambiar la pantalla a mano en la pista: pasa igual.
- Grabar la pantalla completa y, a mitad de la toma, cambiar su resolución a una de otra forma (Ajustes del Sistema ▸ Pantallas, por ejemplo de 16:10 a 4:3, o girar un monitor externo). En el editor, el cambio se anima: el rectángulo pasa suave de una forma a la otra, el video lo llena recortado, sin estirarse, y después queda con la forma nueva entera.
- En las dos, grabar un Área en lugar de la pantalla completa: durante el movimiento nunca se ve nada de fuera del Área, ni un borde.

**El export** (30)

El export dibuja los cuadros de la vista previa, con la edición, al tamaño, los cuadros por segundo y la calidad que se le piden, varios cuadros a la vez en la GPU. Se exporta desde la hoja de exportar del editor (⌘E; sus comprobaciones están en «La hoja de exportar (43)», más abajo): ya no hace falta `recorder-dev` para exportar. Exportar no escribe nada en el paquete.
- Con una toma real editada en el editor (un corte, un tramo a 2×, un zoom, el fondo de pantalla, el marco y la cámara), exportarla desde la hoja en 16:9 a 1080p y a 4K, en 9:16 y en 1:1 (el formato se cambia antes en la barra del editor), a 60 cuadros por segundo. Cada MP4 se abre en QuickTime, se reproduce sin saltos, con el sonido en sincronía, sin nada de lo cortado, y se ve como la vista previa del editor en el mismo instante. Que cada uno de esos tamaños se codifica ya lo prueba `everyExportSizeEncodes` en la Mac del agente.
- En la Mac M1 de piso, con la copia en Release (preparación, paso 6): `recorder-dev bench-export --synthetic --width 1920 --height 1080` exporta una toma sintética de 10 s a 1080p60 con todo prendido. Anotar la línea `speed:` (la meta es ≥ 1× el tiempo real, diseño §7.9) y la de `peak memory:` en la tabla y en `docs/performance.md`, sección «El export (Task 30)».

**La vista previa** (31)

La vista previa decodifica, dibuja y presenta en una cola propia: el hilo principal solo pide el cuadro. En pausa muestra exactamente el cuadro del export; al arrastrar el cabezal, el cuadro clave de la pantalla en o antes del instante (con el cursor y el zoom del instante exacto) y, al soltar, el exacto; reproduciendo, si la Mac no da abasto durante medio segundo, dibuja a la mitad del lado (nunca menos de 720p) hasta pausar. Se mide con `recorder-dev` compilado en Release (preparación, paso 6).
- En la Mac M1 de piso: `recorder-dev bench-preview --synthetic --width 1920 --height 1080 --view-width 1920 --view-height 1080` (graba una toma sintética de 10 s con la pantalla en 4K60 y una cámara, como diseño §7.9, y la reproduce y arrastra dibujándola a 1080p con todo prendido; la línea `source:` dice el tamaño de la fuente y `playing at` el tamaño al que se dibujó). Anotar las líneas `source:`, `playing at`, `playing (…)` (la meta: 60 cuadros por segundo, p95 del cuadro ≤ 16,7 ms), `scrubbing:` (≥ 20 cuadros nuevos por segundo sobre la fuente 4K), `release:` (el exacto ≤ 150 ms después de soltar), `released moving:` y `main thread:` (ninguna espera > 4 ms), en la tabla y en `docs/performance.md`, sección "La vista previa (Task 31)". Después, `recorder-dev bench-preview --synthetic` (la misma fuente, al tamaño del export 4K): anotar `playing at`, que dice si la vista previa bajó sola a 1920 × 1080 por quedarse atrás y desde cuándo, y la línea `playing at 1920 × 1080:` si aparece. Y `recorder-dev bench-export --synthetic --width 1920 --height 1080` (≥ 1×), si no se anotó ya con el export.
- En la Mac del dueño: la vista previa en pausa se ve igual de nítida que el MP4 exportado abierto en QuickTime al mismo tamaño en pantalla (el texto de una ventana grabada, sin titilar ni dientes), y del mismo color.

**El panel: Cámara y Cursor** (38)

Con una toma real con cámara y cursor, abierta en el editor. Solo se ve con la app; ningún agente tiene permiso de Cámara ni de Pantalla.
- **Cursor suavizado.** En la pestaña Cursor, probar Rápido, Medio y Suave sobre una toma de clics y movimientos largos: el cursor aterriza en cada clic y se siente como el de Screen Studio; anotar cuál preferís y si alguno se pasa del clic o llega tarde.
- **Efecto de clic.** Ondas y Círculo a 1080p y a 4K, en la vista previa y en el video exportado: se ven del mismo tamaño y no se cortan en el borde. Con "Mostrar el cursor" apagado, "Efecto de clic" queda deshabilitado y no se dibuja nada.
- **Sonido de clic.** Suave y Mecánico, con el volumen en 50 y en 100 %: los dos suenan limpios (sin chasquidos) y caen en el cuadro del clic, en la vista previa y en el video exportado.
- **Ocultar en reposo.** Con "Ocultar cuando no se mueve" y "Después de" 1, 2,5 y 5 s, el cursor se oculta tras ese tiempo quieto y vuelve al moverse; apagado, nunca se oculta.
- **Cámara.** Forma, Tamaño (los tres botones y la barra de 10 a 45) y la grilla de 3×3 (con el centro apagado y las flechas del teclado con la grilla enfocada) cambian la burbuja de la vista previa sin espera. Con el cabezal antes de todo cambio dice "Se edita: el estilo inicial"; sobre un cambio, "Se edita: el cambio de 0:42". "Agregar un cambio en el cabezal" agrega uno con el estilo de ahí, y "Borrar el cambio" deja seguir el anterior; elegir una fila lleva el cabezal a ese cambio. Un cambio dentro de un corte no aparece en la lista.
- Una toma sin cámara no tiene la pestaña Cámara; una toma sin imágenes del cursor muestra la nota "Esta toma no guardó la forma del cursor: se usa la flecha de Toma."

**La línea de tiempo: editar con el mouse** (41)

Con una toma real abierta en el editor. Solo se ve con la app; ningún agente tiene permiso de Pantalla.
- **Cortar y recortar.** Dividir (botón de la barra de pistas y menú del tramo) corta el tramo en el cabezal; arrastrar el borde de un tramo (a 6 pt, el cursor pasa a flechas izquierda-derecha) lo recorta con la etiqueta "−1,20 s · 0:18,40", los demás tramos se corren y el cabezal sigue en su cuadro. Un solo ⌘Z deshace cada corte o recorte.
- **Velocidad.** Poner 2× un tramo desde el menú de la barra y desde el menú contextual; "Velocidad personalizada…" acepta de 0,25 a 16; el menú muestra la nota del sonido.
- **Zooms.** Crear uno arrastrando en un lugar vacío de la pista Zoom (menos de 0,3 s no crea nada) y con doble clic (3 s); moverlo, recortar sus bordes; mover uno automático lo vuelve del usuario y su lugar viejo no se vuelve a llenar. Menú contextual: Profundidad, Enfoque, Instantánea, Borrar.
- **Rombos y pantallas.** Arrastrar un rombo de la cámara y el límite entre dos pantallas; "Mostrar «nombre»" y "Seguir el cursor" en el menú de una pantalla.
- **Selección y ajuste.** ⇧-clic suma solo en la misma pista; clic en vacío deselecciona y mueve el cabezal; ⌥ + arrastre en la regla marca un rango; los bordes se pegan a 8 pt (el botón Ajuste lo apaga, ⌘ lo invierte mientras se arrastra). Pasar el mouse resalta tramos, bloques y bordes; al borrar o deshacer, los elementos se acomodan con resorte (con Reducir movimiento, un fundido).
- Borrar el único tramo muestra "Tiene que quedar al menos un tramo.".
- Deshacer y rehacer muchos pasos; `kill -9` a la app en medio de una edición y, al reabrir, todo está y deshacer llega hasta la primera edición.

**El panel: Zoom y Audio** (39)

Con una toma real (clics, tipeo, micrófono y audio del sistema), abierta en el editor. Ningún agente puede grabarla.
- **Zooms automáticos.** Los zooms automáticos caen en los clics de la toma, y con "Mantener el zoom al escribir" prendido el zoom se queda mientras se escribe. Sin ninguna línea `keyActivity` en la toma, ese interruptor queda deshabilitado con "Esta toma no anotó cuándo se escribía.".
- **Un solo paso.** Cambiar Profundidad, Velocidad, "Agrupar clics separados hasta", los márgenes o "Hacer zoom con" regenera los zooms automáticos que no se tocaron, y un solo Deshacer (⌘Z) vuelve a como estaban; cambiar varias veces seguidas se deshace de una. Un zoom movido o recortado a mano no se regenera. "Regenerar los zooms automáticos" reemplaza los automáticos que no se tocaron y deja en paz los propios y los que se borraron a mano.
- **Zoom seleccionado.** Al elegir un zoom en la pista, el panel pasa a Zoom y muestra la tarjeta: "Usar la del proyecto" en un automático sin tocar; tocar Profundidad, Enfoque o Animación lo pasa a zoom propio; "Punto fijo" muestra el recuadro en la vista previa; "Borrar el zoom" lo borra.
- **Desenfoque de movimiento del zoom** (0, 50 y 100): se ve natural al entrar y salir de un zoom, sin estelas raras ni parpadeo, en la vista previa y en el video exportado.
- **Audio.** Una fila por pista: el Micrófono con el nombre del dispositivo, y el Audio del sistema. El volumen (0–200 %) y Silenciar se oyen en la vista previa al instante, y lo mismo en el video exportado; con "Evitar la saturación" un volumen de 200 % no distorsiona de golpe. Una toma sin audio dice "Esta toma no tiene audio.".

**La ventana del editor** (34)

El editor abre cada proyecto en una ventana con la barra arriba (el nombre y la duración, el formato, el botón del panel y Exportar) y la vista previa sobre un gris oscuro fijo, con el transporte debajo.
- **Tamaño.** En una pantalla de 1440×900 pt o más grande, la ventana nueva mide 1440×900 (en una más chica, el 85 % del área visible) y aparece centrada. No se puede achicar a menos de 1024×680. Anotar el tamaño de la pantalla y el de la ventana.
- **La barra.** A la izquierda, el nombre del proyecto sin `.toma` y la duración (`2:14`, o `1:02:14` desde una hora); en el centro, el formato con su ícono (`16:9`, `9:16`, `1:1`), que despliega "16:9 horizontal", "9:16 vertical" y "1:1 cuadrado"; a la derecha, el botón del panel y Exportar, prominente. En macOS 26 la barra es Liquid Glass; en macOS 15, el material estándar de la barra; con Accesibilidad ▸ Pantalla ▸ Reducir transparencia, sólida en los dos. (El panel: ver «El panel del editor: Fondo y Marco (37)».)
- **El gris.** Alrededor del video, el mismo gris oscuro en modo claro y en modo oscuro (Ajustes del Sistema ▸ Apariencia); el resto de la ventana sigue la apariencia. Los botones del transporte y el tiempo se leen sobre el gris.
- **Transporte.** ⏮ va al principio, ▶ reproduce y pasa a ⏸, ⏭ va al final; el tiempo dice `0:42,18 / 2:14,00` (con punto en lugar de coma con la Mac en inglés). Reproduciendo, el tiempo avanza unas diez veces por segundo; en pausa, el cuadro es exactamente el del export. Un clic en la vista previa reproduce o pausa; un doble clic hace lo mismo que un clic; Espacio también.
- **Formato.** Elegir 9:16 en la barra: el video pasa a vertical sin esperar y la duración no cambia.
- **Abriendo.** Un proyecto de una hora muestra "Abriendo…" en lugar de la vista previa y su primer cuadro en menos de un segundo; la ventana responde mientras tanto.
- **Las franjas de arriba de la vista previa**, cada una con su texto:
  - Un proyecto grabado con la copia del hito 1a: "Este proyecto se grabó con una versión anterior y conserva su aspecto.", con "Aplicar el estilo por defecto" (el aspecto cambia al estilo por defecto en un solo paso) y una ✕. Cerrada con la ✕, no vuelve al abrirlo otra vez; después de una edición, tampoco.
  - El mismo proyecto abierto en dos copias de la app (la copia de prueba y otra, por ejemplo una compilada con Xcode): la segunda dice "Este proyecto está abierto en otra app: se abre solo para ver.", reproduce y exporta, y el formato no se puede cambiar.
  - Otra app empezó a editar primero: una copia de un proyecto grabado con la copia del hito 1a, abierta en las dos copias de la app (A y B) a la vez. Cambiar el formato en A, y después en B con A todavía abierta: B dice "Otra app empezó a editar este proyecto: el último cambio no se aplicó y el proyecto queda solo para ver.", vuelve al formato de antes y no deja cambiar nada más.
  - Otra app cambió el proyecto: lo mismo, pero cerrando la ventana de A antes de cambiar el formato en B: B dice "Otra app cambió este proyecto: se volvió a abrir y el último cambio no se aplicó.", muestra el formato que eligió A y se puede seguir editando.
  - Archivos de edición que no se pueden usar con seguridad: en una copia de un proyecto ya editado, con la ventana cerrada, `mv edit.json edit-real.json && ln -s edit-real.json edit.json` dentro del paquete (Mostrar contenido del paquete, o Terminal). Al abrirlo: "Los archivos de edición de este proyecto no se pueden usar con seguridad: se abre solo para ver."
  - Un proyecto que otra app dejó ilegible: una copia de un proyecto de la copia del hito 1a, abierta en el editor. Con la ventana abierta, en Terminal, `printf '{"formatVersion" : 2}' > <copia>.toma/manifest.json`, y cambiar el formato en el editor: en lugar de la vista previa, "No se pudo abrir el proyecto" y "Otra app cambió este proyecto y esta versión de Toma ya no puede abrirlo."
  - "Aplicar el estilo por defecto" con el disco lleno: con un estilo por defecto de imagen propia (Task 37) y el proyecto de 1a en el disco lleno de abajo, tocar "Aplicar el estilo por defecto": una franja ámbar con un indicador, "Esperando espacio en el disco para aplicar el estilo por defecto…", y el aspecto no cambia; al borrar el archivo de relleno se aplica. Cerrar la ventana mientras espera no aplica nada (al abrirlo otra vez, la franja de proyecto viejo sigue).
  - Un proyecto en un disco de solo lectura (`hdiutil create -srcfolder <carpeta con el proyecto> -format UDRO solo-lectura.dmg`, y abrir el `.dmg`): "Este proyecto está en un disco donde no se puede escribir: los cambios no se pueden guardar."
  - Un proyecto en un disco lleno: copiar un proyecto de pocos segundos a una imagen de disco de 50 MB (`hdiutil create -size 50m -fs HFS+ -volname Lleno lleno.dmg`), abrirlo desde ahí y llenar el disco con `dd if=/dev/zero of=/Volumes/Lleno/relleno bs=1m` (termina con "No space left on device"). Al cambiar el formato, una franja ámbar "No se pudo guardar el último cambio: el disco está lleno. Los cambios se guardan apenas haya lugar."; el cambio se ve igual, y al borrar el archivo de relleno la franja se va en unos segundos.
  - Un proyecto cuyo `edit.json` dice `"documentVersion" : 99` (con la ventana cerrada, en una copia): ninguna vista previa, el texto "Este proyecto se editó con una versión más nueva de Toma. Actualizar Toma para abrirlo." y Exportar deshabilitado.
  - Un proyecto cuyo `edit-log.jsonl` tiene una línea del medio cambiada por `{` (en una copia, con la ventana cerrada): "Se recuperó la edición hasta las 14:32. Lo que no se pudo leer quedó guardado aparte." (con la hora de la última edición buena), y `edit-log.jsonl.damaged-…` junto al registro.
  - Un proyecto con un segmento de la pantalla vaciado (en una copia, `: > takes/<toma>/display-1/seg-0001.mov`): con el cabezal en esa parte, "Esta parte de la grabación no se pudo leer: se muestra el cuadro anterior."
- **Sonido de la vista previa** (32), con la salida de la Mac y con AirPods: el sonido va en sincronía con el video (el clic de una toma suena cuando se ve el clic; anotar si se nota un adelanto o un atraso). Cambiar la salida a los AirPods mientras se reproduce: sigue sonando desde donde iba, en sincronía. Con los AirPods, ⏮ mientras suena: el sonido vuelve enseguida (anotar si tarda más de un cuarto de segundo). Cambiar el volumen o cortar mientras suena: un hueco breve (unos 85 ms) sin chasquido.

**Superposiciones de la vista previa** (36)

Con una toma real abierta en el editor. Solo se ve con la app; ningún agente tiene permiso de Pantalla ni un trackpad.
- **El recuadro del zoom.** Elegir un zoom, pasarlo a «Punto fijo» y arrastrar su recuadro en la vista previa, y también sus esquinas: mientras se arrastra, la vista previa muestra el cuadro sin zoom y, al soltar, el de verdad; el recuadro nunca sale de la pantalla.
- **La burbuja de la cámara.** Arrastrarla y soltarla con fuerza: sigue al puntero, se ven los 8 puntos de anclaje, se ancla con un movimiento suave y el trackpad vibra.
- Un clic en la vista previa fuera de las superposiciones sigue reproduciendo o pausando.
- `kill -9` a Toma en medio de un arrastre: al reabrir, el proyecto tiene todo menos ese arrastre.

**El panel del editor: Fondo y Marco** (37)

Con una toma real abierta en el editor.
- **Fondos.** Cada uno se ve bien a 1080p y a 4K en la vista previa, que cambia sin espera al arrastrar las barras: los 12 fondos de pantalla (el grano se ve fino y no cambia al hacer zoom), los 10 degradados y el personalizado, colores, una imagen propia PNG, JPEG y HEIC (el panel de abrir no ofrece TIFF) y el escritorio desenfocado (con el fondo del escritorio de la toma; en una toma de ventana, no hay foto y se ve el degradado de Toma). Con el desenfoque al máximo, el borde del escenario no se oscurece.
- **«Usar este estilo en los proyectos nuevos»** vale para la toma siguiente, y «Volver al estilo de Toma» lo deshace. Con el disco lleno, «Elegir imagen…» espera, y «Cancelar» lo deja.
- **El marco de ventana de macOS** (apariencia clara y oscura, título, botones): el título usa la fuente del sistema; con un título en chino, japonés o coreano, los glifos son los mismos con el sistema en español y en inglés.
- **El panel.** Se ve como el inspector del sistema (Liquid Glass en macOS 26, estándar en 15, sólido con Reducir transparencia), mide 300 pt (entre 260 y 380), ⌥⌘I lo oculta y ⌘1 a ⌘6 cambian de pestaña.

**La línea de tiempo** (40)

La línea de tiempo, debajo de la vista previa y del panel, muestra la toma en el tiempo de salida: la regla, Video (con miniaturas), Pantalla (con dos o más pantallas), Zoom, Cámara (con cámara) y una pista por cada audio, con una capa por elemento visible.
- **Al abrir.** La línea de tiempo mide 236 pt y la secuencia entera entra en el ancho. Las miniaturas aparecen de a una, sin que la ventana deje de responder mientras llegan. El divisor de arriba se arrastra entre 180 pt y la mitad de la ventana; al agrandar o achicar la ventana cambia la vista previa, no la línea de tiempo.
- **Pistas.** Una toma con una pantalla, cámara, micrófono y audio del sistema muestra Video, Zoom, Cámara, Micrófono y Sistema, cada una con su ícono y su nombre a la izquierda; con dos pantallas, también Pantalla, con el nombre de la que se ve en cada tramo. Los zooms dicen su profundidad ("1,5×"); los automáticos llevan además una "A", un borde punteado y un tono más claro. Un tramo a 2× dice "2×". Hay un rombo por cada cambio de la cámara y una bandera en la regla por cada marcador de la toma. Las formas de onda siguen el volumen del panel Audio y quedan planas al silenciar con el botón del encabezado (una edición, como en el panel); un tramo a más de 4× tiene la onda plana, porque va sin sonido.
- **Cortes.** Borrar un tramo que tiene adentro, entero, un zoom o un cambio de la cámara: el bloque o el rombo desaparece. Deshacer: vuelve.
- **Escala.** ⌘+ y ⌘− acercan y alejan con un movimiento corto, alrededor del cabezal si está a la vista (si no, del medio). El pellizco del trackpad sigue a los dedos, sin demora ni animación, alrededor de ellos; ⌥ con la rueda o con dos dedos, alrededor del puntero. ⇧Z, con la línea de tiempo con el foco (un clic en ella), vuelve a ajustarla a la ventana. Lo más cerca son 600 pt por segundo (10 pt por cuadro a 60 fps): la regla dice décimas (`19:27,2`).
- **Desplazamiento.** Dos dedos de lado, o la rueda de un mouse, la desplazan; con más pistas que alto, dos dedos arriba y abajo las desplazan con sus encabezados, y la regla queda fija. Reproduciendo, cuando el cabezal llega al borde derecho la vista pasa de página con un movimiento suave; si se la desplazó a mano mientras suena, no vuelve sola hasta que el cabezal esté otra vez a la vista.
- **Cabezal.** Una línea roja que avanza suave al reproducir, sin que nada más tiemble. Un clic en la regla lo lleva ahí, y arrastrarlo muestra en la vista previa cada instante enseguida (el cuadro clave, sin sonido); al soltar, el cuadro exacto.
- **Rendimiento** (diseño §7.9). En la Mac del dueño (ProMotion, 120 Hz) y en la M1 (60 Hz), con una toma de una hora con cientos de tramos y zooms: pellizcar de ajustada a lo más cerca y desplazarla de punta a punta va a la frecuencia de la pantalla, sin saltos. Anotar si se ve alguno, y a qué escala. La medida del agente (el hilo principal, en Debug) y el comando para repetirla están en `docs/performance.md`, sección "La línea de tiempo (Task 40)": con la pantalla de la Mac encendida, su línea `paced pinch` dice cuántos refrescos llegaron tarde; anotarla.
- **Rayado.** En un proyecto con un segmento de la pantalla vaciado (como el de las franjas, arriba), esa parte de la pista Video sale rayada y, con el puntero encima, aparece la ayuda "Esta parte de la grabación no se pudo leer: se muestra el cuadro anterior."
- **Apariencia y accesibilidad.** En modo claro y oscuro los colores siguen la apariencia. Con Accesibilidad ▸ Pantalla ▸ Aumentar contraste, los tramos, los bloques y los rombos tienen un borde de 1 pt. Con Reducir movimiento, ⌘+, ⌘−, ⇧Z y el paso de página son un fundido corto en lugar del movimiento; el pellizco sigue a los dedos igual.

**Menús, deshacer y estado de la ventana** (35)

Con la copia de prueba, en inglés y en español (Ajustes del Sistema ▸ General ▸ Idioma y región, o `defaults write dev.toma.Toma AppleLanguages '("en")'` y de vuelta), y con un proyecto ya editado y uno grabado con la copia del hito 1a.
- **Abrir.** Archivo ▸ Abrir… (⌘O) y "Abrir…" del menú del ícono de la barra de menú, junto a "Abrir último proyecto": el panel empieza en la carpeta de proyectos y solo deja elegir proyectos `.toma` (un paquete se elige como un archivo, no se entra en él). Elegir uno lo abre en el editor. Abrir otra vez el mismo proyecto (con ⌘O, con doble clic en el Finder o con "Abrir último proyecto"), también después de renombrarlo en el Finder con la ventana abierta o por un alias simbólico (`ln -s`): trae su ventana adelante, aunque esté minimizada, y nunca abre una segunda ni la franja "Este proyecto está abierto en otra app".
- **Deshacer con nombre.** Cambiar el formato en la barra: Edición ▸ dice "Deshacer Cambiar el formato" (⌘Z) y, después de deshacer, "Rehacer Cambiar el formato" (⇧⌘Z); sin nada para deshacer dice solo "Deshacer", deshabilitado. Dividir un tramo con C: "Deshacer Dividir". Cerrar la ventana, abrir el proyecto otra vez: Edición ▸ sigue diciendo "Deshacer Dividir" (o el último cambio) y ⌘Z lo deshace. Mientras se arrastra un control del panel, Deshacer queda deshabilitado. En inglés: "Undo Change Format", "Redo Change Format", "Undo Split".
- **Menú Proyecto.** Con un editor adelante, Proyecto ▸ Formato tiene "16:9 horizontal", "9:16 vertical" y "1:1 cuadrado", con una marca en el actual, y Proyecto ▸ Cuadros por segundo tiene 24, 25, 30, 50 y 60, con una marca en el del proyecto. Elegir 1:1: la vista previa pasa a cuadrada, la marca se mueve (también la del selector de la barra) y ⌘Z vuelve atrás ("Deshacer Cambiar el formato"). Elegir 30: "Deshacer Cambiar los cuadros por segundo", y un export sale a 30 cuadros por segundo. En un proyecto abierto solo para ver (el mismo proyecto en dos copias de la app), los dos submenús están deshabilitados; con la ventana de Ajustes adelante, también.
- **Cerrar con cambios sin guardar.** El proyecto en el disco lleno de "La ventana del editor" (arriba): con la franja ámbar a la vista, cerrar la ventana (botón rojo o ⌘W): una alerta "Hay cambios que no se pudieron guardar" · "Si se cierra la ventana ahora, se pierden.", con "Dejar abierta" como botón por defecto (Retorno) y "Cerrar igual" en rojo. "Dejar abierta" deja la ventana como estaba; borrar el archivo de relleno, esperar a que se vaya la franja y cerrar: se cierra sin preguntar. Repetir y elegir "Cerrar igual": se cierra, y al abrirlo otra vez falta el último cambio. Sin la franja, cerrar nunca pregunta.
- **La ventana recuerda.** Mover y agrandar la ventana, ocultar el panel (⌥⌘I), elegir la pestaña Zoom y dejar el cabezal en 0:05; cerrar y abrir otra vez: la ventana aparece directamente donde quedó (sin saltar desde el centro), con el panel oculto, en Zoom y con el cabezal en 0:05. Lo mismo saliendo de Toma (⌘Q) con la ventana abierta en vez de cerrarla, y después de forzar la salida (Monitor de Actividad) unos 10 s después del último cambio. Con la ventana en una pantalla externa, desconectarla y abrir el proyecto: aparece centrada en la pantalla de la Mac. Con la ventana en pantalla completa al cerrar, abrirla otra vez: vuelve al tamaño que tenía antes de la pantalla completa.

**El teclado y VoiceOver** (42)

Con una toma real (con cámara, clics y un marcador) abierta en el editor; después de un clic para empezar, sin el mouse. VoiceOver se prende y se apaga con ⌘F5. Ningún agente tiene permiso de Accesibilidad para probarlo con VoiceOver ni con el teclado de verdad.
- **El foco.** Tab y ⇧Tab llevan el foco entre la vista previa, el panel y la línea de tiempo (y la barra, con Ajustes del Sistema ▸ Teclado ▸ Navegación con el teclado prendida), en el orden en que están en la pantalla. La vista previa y la línea de tiempo muestran el anillo de foco del sistema; un clic en una de las dos también le da el foco. Recién abierta la ventana, sin ningún clic, Espacio reproduce y las letras de abajo funcionan; después de un clic en un control del panel, no (son del control) hasta volver a la vista previa o a la línea de tiempo.
- **Reproducir y moverse** (con el foco en la vista previa o en la línea de tiempo). Espacio reproduce y pausa. L reproduce, y L otra vez pasa a 2×, 4× y 8× (sin sonido salvo a 1×); J hace lo mismo hacia atrás (puede mostrar menos cuadros) y se detiene al llegar al principio; K detiene. ← y → mueven un cuadro, con ⇧ un segundo, y dejándolas apretadas repiten; ↑ y ↓ van al punto de edición anterior y al siguiente (bordes de tramos y de bloques, rombos, marcadores, principio y final); Inicio y Fin (fn← y fn→) van al principio y al final.
- **Editar solo con el teclado.** Llevar el cabezal a un punto, I; a otro, O: las marcas se ven en la regla. ⌫ borra el rango en un solo paso (Edición ▸ "Deshacer Borrar") y las marcas se van; ⌥X las quita sin borrar. C (o ⌘B) divide en el cabezal; ⌥[ y ⌥] recortan el inicio y el final del tramo hasta el cabezal. Z agrega un zoom de 3 s en el cabezal, que queda seleccionado: , y . lo mueven un cuadro, con ⇧ diez; con Esc se deselecciona, y ⌫ con un bloque o un rombo seleccionado lo borra. N prende y apaga el ajuste (el botón Ajuste de la barra de pistas lo sigue). ⌘+ y ⌘− escalan la línea de tiempo con el foco en cualquier parte de la ventana, y ⇧Z la ajusta con el foco en la vista previa o en la línea de tiempo. ⌘1 a ⌘6 cambian la pestaña del panel (lo muestran si estaba oculto; sin cámara, ⌘3 no hace nada) y ⌥⌘I lo oculta. ⌘E exporta, también durante los 8 s de "Exportación terminada"; ⌘O abre. Mientras se arrastra un tramo o un bloque con el mouse, Esc cancela el arrastre sin cambiar nada.
- **En un campo de texto** (el título del marco, en la pestaña Marco): escribir "c", "z", "n", "i" o un espacio escribe la letra: no divide, no agrega un zoom ni reproduce. ⌘B sí divide.
- **VoiceOver en la línea de tiempo** (VO-⇧-↓ para entrar en ella; VO es Control-Opción): un elemento por tramo, bloque y rombo a la vista, que dice "Tramo de 0:12 a 0:31, velocidad 1×", "Zoom automático de 2×, de 0:40 a 0:44" (o "Zoom de…" en uno propio) y "Cambio de la cámara en 0:42". VO-Espacio lo selecciona (se ve el contorno y VoiceOver dice que está seleccionado). El menú de acciones (VO-⌘-Espacio) de un tramo ofrece Dividir, Borrar, "Recortar el inicio hasta el cabezal" y "Recortar el final hasta el cabezal" (las que usan el cabezal no hacen nada si el cabezal no está en ese tramo); el de un bloque o un rombo, Borrar. El cabezal dice "Cabezal, 0:42 de 2:14", y VO-↑ y VO-↓ lo mueven un segundo y dicen dónde quedó. Anotar si alguno no se lee o no responde.
- **VoiceOver en el resto.** La vista previa se llama "Vista previa" y su valor es el tiempo; cada control del panel dice su nombre y su valor ("Margen, 40").
- **Reducir movimiento, Reducir transparencia y Aumentar contraste** (Accesibilidad ▸ Pantalla). Con Reducir movimiento, el cambio de pestaña del panel, los tramos que se acomodan, ⌘+, ⌘−, ⇧Z y el paso de página son fundidos cortos, y el zoom del video no cambia (es lo que se exporta). Con Reducir transparencia, la barra y el panel son sólidos. Con Aumentar contraste, los tramos, los bloques y los rombos tienen un borde de 1 pt.
- **La escala recordada** (35). Acercar la línea de tiempo con ⌘+ y desplazarla a un costado; cerrar y abrir otra vez el proyecto: vuelve a esa escala y a ese desplazamiento. Ajustada con ⇧Z al cerrar, vuelve ajustada.

**La hoja de exportar** (43)

Con la copia de prueba, en inglés y en español, con una toma real de una pantalla Retina grabada en píxeles (como graba Toma por defecto) y otra grabada en puntos (la escala de la pantalla en los ajustes rápidos de la isla), y con un proyecto grabado con la copia del hito 1a.
- **La hoja.** Exportar en la barra (o ⌘E) abre una hoja sobre la ventana: "Exportar el video", Formato con el del proyecto ("16:9 horizontal"; no se puede cambiar ahí), Resolución con 720p, 1080p, 1440p y 4K, Cuadros por segundo con el del proyecto elegido, Calidad Estándar o Alta, "Aprox. 120 MB" (o lo que corresponda) abajo a la izquierda, y "Cancelar" (Esc) y "Exportar…" (Retorno). La primera vez, 1080p y Estándar. Cambiar la resolución, los cuadros o la calidad cambia el tamaño aproximado al instante. "Más que la grabación" aparece al lado de las resoluciones más grandes que el lado corto de la pantalla grabada: en una pantalla de 1512 × 982 puntos, por ejemplo, con la toma en píxeles (1964 de lado corto) solo al lado de 4K, y con la grabada en puntos (982) al lado de 1080p, 1440p y 4K. Con la app en inglés, "Higher than the recording".
- **Exportar.** "Exportar…" cierra la hoja y abre el panel de guardado en la carpeta del proyecto con `<proyecto>.mp4`. Exportar en 9:16 (cambiado antes en la barra) a 4K, 30 cuadros por segundo y Alta: el MP4 mide 2160 × 3840 y tiene 30 cuadros por segundo (QuickTime ▸ Ventana ▸ Mostrar inspector de películas). Exportar no es una edición: Edición ▸ Deshacer sigue diciendo lo mismo que antes, y el proyecto de la copia del hito 1a exportado así sigue con `"formatVersion" : 2` en `manifest.json`, sin `edit.json` ni `edit.lock`.
- **Lo que recuerda.** Abrir la hoja otra vez: 4K y Alta ya elegidos, y los cuadros por segundo otra vez los del proyecto. La vista previa en pausa se dibuja a la resolución recordada (con 4K, igual de nítida que el MP4 en QuickTime al mismo tamaño), también en otro proyecto abierto en ese momento; salir de Toma y volver a abrirla: la hoja sigue recordando 4K y Alta.
- **Exportar mientras se edita.** Empezar un export de una toma larga (un minuto o más, a 4K) y, mientras corre, cortar un tramo y cambiar el fondo: el MP4 sale con la edición de cuando se tocó "Exportar…" (con el tramo y el fondo de antes), y el editor queda con los cambios.
- **El anillo.** Durante el export, Exportar es un anillo con el progreso; su menú tiene "Cancelar la exportación", que lo para: en la carpeta no queda el MP4 ni un `.partial.mp4`, y el botón vuelve a ser Exportar. Al terminar un export, "Exportación terminada · Mostrar en Finder" durante 8 s; "Mostrar en Finder" abre la carpeta con el MP4 seleccionado. Si a la toma le faltaba audio o video, la alerta de lo que faltó, como antes.
- **Un export a la vez.** Con dos proyectos abiertos, mientras uno exporta, Exportar del otro está deshabilitado; con la hoja abierta en el otro, su "Exportar…" se deshabilita.
- **El tamaño estimado.** Exportar el mismo proyecto a 1080p Estándar y a 4K Alta, anotar el "Aprox." de la hoja y el tamaño real del MP4 (Finder ▸ Obtener información) en la tabla: el estimado es el bitrate pedido por la duración, más el audio; anotar cuánto se aleja.

**La revisión final** (tanda de arreglos)

Con la copia de prueba en español y una toma real abierta en el editor.
- **Salir con cambios sin guardar.** Con el proyecto en el disco lleno de «La ventana del editor» (arriba) y la franja ámbar a la vista, ⌘Q: una alerta «Hay cambios que no se pudieron guardar», «Si se sale ahora, se pierden.», con «Cancelar» (el de Retorno) y «Salir igual». «Cancelar» deja todo abierto; «Salir igual» sale. Lo mismo al cerrar la sesión (menú Apple ▸ Cerrar sesión). Con el disco con lugar: editar algo y enseguida ⌘Q: sale sin preguntar, y al abrir otra vez el proyecto la última edición está (la app cierra cada editor antes de salir).
- **Cerrar la ventana durante un export.** Empezar un export de un minuto o más y cerrar la ventana del editor (botón rojo o ⌘W): una alerta «Hay una exportación en curso. ¿Cerrar la ventana y cancelarla?», con «Cancelar» (el de Retorno) y «Cerrar». «Cancelar» deja la ventana y el export; «Cerrar» los cancela y en la carpeta no queda el MP4 ni un `.partial.mp4`.
- **La vista previa sigue al arrastre.** En pausa, arrastrar despacio el control de Margen del panel, el borde de un tramo, el recuadro de un zoom de punto fijo y la burbuja de la cámara: la vista previa cambia con el puntero durante todo el arrastre, no solo al soltar. Al soltar la burbuja, nunca se ven dos burbujas mientras vuela a su lugar.
- **⌥[ y ⌥] en un teclado en español.** Con la fuente de entrada «Español - ISO» o «Latinoamericano» (Ajustes del Sistema ▸ Teclado ▸ Fuentes de entrada), con un tramo elegido y el cabezal en el medio: ⌥[ recorta su comienzo hasta el cabezal y ⌥] su final.
- **⌘A en una pista.** Con el foco en la línea de tiempo, ⌘A elige todos los tramos; con un bloque de zoom elegido, todos los bloques. En un campo de texto (el título del marco), ⌘A elige el texto.
- **Los avisos con VoiceOver.** Con VoiceOver prendido (⌘F5), llenar el disco como en «La ventana del editor» y editar: VoiceOver dice la frase de la franja ámbar cuando aparece.
- **Proyecto ▸ Velocidad.** Con un tramo elegido, Proyecto ▸ Velocidad tiene las velocidades de la barra del tramo, con una marca en la actual, y «Velocidad personalizada…», que abre la hoja con la velocidad escrita con coma («1,5»). Elegir 2× cambia el tramo y se deshace con ⌘Z, como desde la línea de tiempo.

| Comprobación | Fecha | macOS | Resultado |
|---|---|---|---|
| 0. Preparación: copia de prueba (firmada o ad hoc), permisos | pendiente | pendiente | pendiente |
| 1. Recorrido completo (§10.3): una toma real con todo; el cursor y sus efectos; editar y `kill -9`; exportar en 16:9, 9:16 y 1:1 a 1080p y a 4K; la vista previa fluida; dos pantallas; fondos; teclado y VoiceOver; un proyecto de 1a; las metas de rendimiento | pendiente | pendiente | pendiente |
| 2. Imágenes del cursor (macOS 15 y 26) | pendiente | pendiente | pendiente |
| 2. Los nueve cursores de Toma: nítidos a 1080p, 4K y con zoom 3×, con el punto de clic en su lugar; cuáles redibujar | pendiente | pendiente | pendiente |
| 2. Los sonidos de clic `soft-1` y `mechanical-1`: limpios, distinguibles y en el cuadro del clic, con la Mac, con AirPods y exportados | pendiente | pendiente | pendiente |
| 2. Scroll y actividad del teclado sin Monitoreo de entrada (macOS 15 y 26) | pendiente | pendiente | pendiente |
| 2. Audio con velocidad en macOS 15: deriva, comienzo y determinismo | pendiente | pendiente | pendiente |
| 2. Micrófonos a 44,1, 24 y 16 kHz en macOS 15: empezar en el medio | pendiente | pendiente | pendiente |
| 2. Esquinas de las tomas de ventana: ninguna negra con el estilo por defecto; radio de las negras en píxeles y en puntos (macOS 26 y 15) | pendiente | pendiente | pendiente |
| 2. Dos pantallas y cambios de forma: el cambio de pantalla y el de resolución se animan sin saltos ni estirar; nada fuera del Área | pendiente | pendiente | pendiente |
| 2. El export: 16:9, 9:16 y 1:1 a 1080p60 y a 4K se abren en QuickTime y se ven como la vista previa; en la M1, 1080p60 con todo ≥ 1× (velocidad y memoria) | pendiente | pendiente | pendiente |
| 2. La vista previa: en la M1, `bench-preview --synthetic --width 1920 --height 1080 --view-width 1920 --view-height 1080` (fuente 4K60 dibujada a 1080p: 60 fps, p95 ≤ 16,7 ms, arrastre ≥ 20 por segundo, ≤ 150 ms al soltar, hilo principal ≤ 4 ms) y `bench-preview --synthetic` (el tamaño al que bajó); en la del dueño, tan nítida como el MP4 en QuickTime | pendiente | pendiente | pendiente |
| 2. La ventana del editor: tamaño inicial y mínimo; la barra en Liquid Glass (26), estándar (15) y sólida con Reducir transparencia; el gris en modo claro y oscuro; transporte y clic; cada franja con su texto | pendiente | pendiente | pendiente |
| 2. El sonido de la vista previa: sincronía con la salida de la Mac y con AirPods, cambiar de salida mientras suena, un salto con AirPods, el hueco de 85 ms | pendiente | pendiente | pendiente |
| 2. Superposiciones de la vista previa: arrastrar el recuadro de un zoom de punto fijo y sus esquinas (la vista previa muestra el cuadro sin zoom mientras se arrastra y el de verdad al soltar; el recuadro no sale de la pantalla); arrastrar y soltar la burbuja de la cámara con fuerza (sigue al puntero, se ven los 8 puntos, ancla con un movimiento suave y vibra el trackpad); un clic en la vista previa fuera de las superposiciones sigue reproduciendo o pausando; un `kill -9` en medio de un arrastre pierde solo ese arrastre | pendiente | pendiente | pendiente |
| 2. El panel del editor: cada fondo (los 12 fondos de pantalla a 1080p y a 4K, los 10 degradados y el personalizado, colores, una imagen propia PNG, JPEG y HEIC (el panel de abrir no ofrece TIFF), el escritorio desenfocado) se ve bien y la vista previa cambia sin espera al arrastrar las barras; "Usar este estilo en los proyectos nuevos" vale para la toma siguiente y "Volver al estilo de Toma" lo deshace; el marco de ventana de macOS (apariencia, título, botones); con el disco lleno, "Elegir imagen…" espera y "Cancelar" lo deja; el panel se ve como el inspector del sistema (Liquid Glass en 26, estándar en 15, sólido con Reducir transparencia), mide 300 pt (260–380), ⌥⌘I lo oculta y ⌘1–⌘6 cambian de pestaña | pendiente | pendiente | pendiente |
| 2. El panel: Cámara y Cursor (suavizado Rápido, Medio y Suave aterrizan en cada clic; Ondas y Círculo a 1080p y 4K; los dos sonidos de clic limpios y en su lugar; ocultar en reposo; la cámara y su lista de cambios) | pendiente | pendiente | pendiente |
| 2. El panel: Zoom y Audio (los zooms automáticos caen en los clics y el tipeo los sostiene; cambiar Profundidad o Velocidad regenera y se deshace en un paso; el desenfoque del zoom se ve natural; volumen, silenciar y el limitador se oyen) | pendiente | pendiente | pendiente |
| 2. La línea de tiempo: editar con el mouse (dividir, recortar, 2×, crear y mover zooms, rombos y pantallas, selección y ajuste, un solo ⌘Z por edición, `kill -9` en medio de una edición) | pendiente | pendiente | pendiente |
| 2. La línea de tiempo: 236 pt y su divisor; las pistas, sus nombres y sus elementos ("2×", "A" con borde punteado, rombos, banderas); miniaturas sin trabar; ⌘+, ⌘−, pellizco, ⌥ + rueda y ⇧Z; el paso de página al reproducir; el cabezal y el arrastre en la regla; una hora con cientos de tramos y zooms a la frecuencia de la pantalla (ProMotion y M1; la línea `paced pinch`); el rayado y su ayuda; silenciar desde el encabezado; Aumentar contraste y Reducir movimiento | pendiente | pendiente | pendiente |
| 2. Menús, deshacer y estado de la ventana: ⌘O y "Abrir…" del ícono; abrir otra vez (también renombrado o por un alias) trae la ventana; "Deshacer Dividir" después de reabrir; Proyecto ▸ Formato y Cuadros por segundo con su marca, deshechos con ⌘Z; la alerta al cerrar con el disco lleno; la ventana, el panel, la pestaña y el cabezal recordados (también tras ⌘Q); en inglés y en español | pendiente | pendiente | pendiente |
| 2. El teclado y VoiceOver: Tab entre las partes con su anillo de foco; cada tecla de diseño §5.7 (J y L a 2×, 4× y 8×; I, O y ⌫ en un paso; ⌥[ y ⌥]; , y .; Esc en un arrastre; ⌘E durante "Exportación terminada"); las letras no cortan en un campo de texto; VoiceOver en la línea de tiempo (tramos, bloques, rombos, sus acciones y el cabezal) y en la vista previa; Reducir movimiento, Reducir transparencia y Aumentar contraste; la escala de la línea de tiempo recordada | pendiente | pendiente | pendiente |
| 2. La revisión final: ⌘Q y cerrar la sesión con cambios sin guardar (y sin ellos, la última edición al reabrir); cerrar la ventana durante un export; la vista previa durante un arrastre (Margen, un borde, el recuadro de un zoom, la burbuja); ⌥[ y ⌥] en un teclado en español; ⌘A en una pista; VoiceOver dice la franja ámbar; Proyecto ▸ Velocidad | pendiente | pendiente | pendiente |
| 2. La hoja de exportar: valores por defecto y "Más que la grabación"; 9:16 a 4K, 30 cuadros y Alta (tamaño y cuadros del MP4, el proyecto sin editar ni pasar a v3); lo que recuerda (también la vista previa); exportar mientras se edita; cancelar desde el anillo y "Mostrar en Finder"; un export a la vez; el tamaño estimado contra el real (1080p Estándar y 4K Alta); en inglés y en español | pendiente | pendiente | pendiente |

## Pendientes del dueño del hito 1c

Una sola pasada de fin de hito, contra la app de esta rama, en orden: la preparación, el recorrido completo y el detalle por área. Cada comprobación dice qué se tiene que ver. Si se ve otra cosa, o algo molesta, anotar lo que se ve (con la versión exacta de macOS) en la tabla del final: los agentes trabajan con esas notas. Ninguna comprobación pide cambiar código. Entre paréntesis, la tarea de origen.

### 0. Preparación

1. **Antes de recibir la copia de 1c, guardar un proyecto de 1b.** La copia de 1c reemplaza `build/prueba/Toma.app`: antes, copiar la del hito 1b a otra carpeta (`cp -R build/prueba/Toma.app ~/Desktop/Toma-1b.app`) y, con ella, abrir un proyecto con cámara, editarlo (un corte y otro margen alcanzan), exportarlo y cerrarlo. Ese proyecto y su video son los de la comprobación 7 del recorrido, que lo abre en 1c y después otra vez con la copia de 1b.
2. **Abrir la copia de prueba.** La arma el controlador después de unir la rama: `open build/prueba/Toma.app`. `codesign -dv build/prueba/Toma.app 2>&1 | grep Authority` dice `Authority=Toma Project Signing` cuando salió firmada con el certificado (paso 1 de la preparación del hito 1a); si no, es ad hoc.
3. Si se creó el certificado de firma después de recibir la copia de prueba, pedir una copia nueva: la anterior quedó ad hoc y macOS no conserva sus permisos.
4. **Permisos.** Los mismos del hito 1a (paso 3 de su preparación): Toma pide cada uno cuando hace falta. El hito 1c no pide ninguno nuevo.

### 1. Recorrido completo (la salida del hito)

Con la copia de prueba abierta desde Finder, en la Mac del dueño y, donde se dice, en macOS 15. Las diez comprobaciones del diseño del hito (§16.2), en ese orden; el detalle de cada una está en «2. Detalle por área», en el área que dice entre paréntesis:

1. **Una toma con cámara y los cinco layouts** (La pista Cámara, La pestaña Cámara, La vista previa con la división). Grabar una toma con cámara. En el editor: 5 s de Cámara a pantalla completa al principio, un tramo de Pantalla dividida con clics, un bloque Burbuja arriba a la izquierda y volver al layout del proyecto. Se tiene que ver: la cámara llena el video de borde a borde sin esquinas, borde ni sombra, y la pantalla no se ve; en la división, la pantalla entera en su tarjeta (nunca recortada) y la cámara en la suya, y **el zoom de cada clic queda dentro de la tarjeta de la pantalla**, con el fondo quieto; la burbuja del bloque aparece arriba a la izquierda y al terminar el bloque vuelve a su lugar. Las transiciones se sienten como las de la burbuja de la isla (el mismo resorte): suaves, sin saltos, lo que aparece crece desde el 90 % y lo que se va se achica y se desvanece. Exportar en 16:9 y comparar con la vista previa en los mismos instantes (en cada borde y a mitad de cada transición): es el mismo cuadro. Con Reducir movimiento, las transiciones se ven igual (son parte del video).
2. **«Duplicar como 9:16»** (Las acciones de la biblioteca). Del proyecto de la comprobación 1: aparece «… vertical» y se abre en el editor ya en 9:16, con la división **apilada** (pantalla arriba, cámara abajo, o al revés según el lado) y la burbuja del tamaño que se espera en un video vertical (una Mediana, un cuarto del ancho, no casi la mitad). Exportarlo y verlo en el iPhone: no se recorta nada de la pantalla.
3. **Espejo, borde y sombra** (El aspecto de la cámara en el video). Espejar sí y no: con espejo la cámara se ve como en un espejo, sin espejo como la ve otra persona; el lugar y la forma de la burbuja no cambian. Borde y sombra a 1080p y a 4K, mirados a pantalla completa: el borde es un trazo parejo por dentro del contorno, el canto suave; la sombra, suave y hacia abajo; en 4K se ven igual de proporcionados que en 1080p.
4. **La biblioteca con los proyectos propios** (La ventana de la biblioteca, Abrir la biblioteca, Las acciones de la biblioteca, Renombrar y duplicar desde el editor). Buscar, ordenar, marcar favoritos, renombrar desde la biblioteca y desde el título del editor, duplicar, mandar a la papelera y deshacer, restaurar y vaciar la papelera (la alerta dice cuántos son y cuánto pesan, y que no se puede deshacer). «Reiniciar toma» (⇧⌘2 con la isla) deja la toma en la papelera, y el aviso de la isla abre la biblioteca ahí. Renombrar un proyecto en Finder con la biblioteca abierta se ve enseguida (en 1 s o menos).
5. **Otros lugares y discos externos** (Las acciones de la biblioteca). Un proyecto de un disco externo abierto con ⌘O aparece en Otros lugares. Con el disco desconectado, la biblioteca no pide nada ni se traba, y la tarjeta queda «No disponible» recién al tocarla; en ningún momento aparece un aviso de privacidad nuevo de macOS al abrir la biblioteca.
6. **Un GIF** (La hoja de exportar: GIF, rango y Copiar). Un GIF de 10 s (con I y O) a 800 px y 15 cuadros por segundo: el tamaño real contra el «Aprox.» de la hoja (dentro de ± 30 %); abrirlo en Safari, Slack y un issue de GitHub, y se ve bien (el tramado se juzga a tamaño real); «Copiar» y pegarlo donde se pueda; sin «Repetir siempre», se reproduce una sola vez. (Sale 1,25 a 1,5 veces más grande que un GIF de Apple con los mismos cuadros: es lo medido y está anotado en `docs/backlog.md`.)
7. **Un proyecto de 1b en 1c** (Un proyecto de 1b abierto en 1c). El de la preparación (paso 1): se ve igual en 1c, y abrirlo sin editar no lo cambia: la copia de 1b lo sigue abriendo. Al editarlo en 1c y cerrar, la copia de 1b dice que el proyecto se editó con una versión más nueva de Toma.
8. **Estilos** (Estilos con nombre). Guardar un estilo, aplicarlo a otro proyecto (un solo ⌘Z lo deshace; no toca bloques, formato ni burbuja), marcarlo «Usar en los proyectos nuevos» y grabar una toma: el proyecto nuevo se abre con ese estilo.
9. **Accesibilidad.** VoiceOver por la biblioteca (cada tarjeta se lee entera y tiene sus acciones), la pista Cámara (cada bloque es un elemento con sus acciones) y la hoja del GIF (la estimación nueva se dice cuando llega); todo alcanzable solo con el teclado; Reducir movimiento (la biblioteca y la vista previa del GIF no se mueven solas).
10. **Las metas de rendimiento** de diseño §15 en la Mac del dueño y, para el piso, en la M1: las medidas del agente están en [`docs/performance.md`](performance.md), «La tabla de metas del hito 1c (diseño §15)», con la columna de la M1 vacía; cada fila dice cómo se mide. Lo que solo mide el dueño: el desplazamiento de la grilla y la lista a 120 fps (ProMotion), la memoria de la biblioteca con 1 000 proyectos, y el **primer cuadro de la biblioteca en una Mac tranquila** (ver «La ventana de la biblioteca», la última comprobación).

### 2. Detalle por área

**Un proyecto de 1b abierto en 1c** (3)

Un proyecto editado con la app de 1b sigue siendo de 1b en el disco hasta que se lo edita en 1c: mirarlo no lo cambia.
- Con el proyecto de 1b de la preparación (paso 1): abrirlo en 1c, reproducirlo y moverse por la línea de tiempo sin tocar nada, y cerrarlo. Abrirlo otra vez con la copia de 1b (`~/Desktop/Toma-1b.app`): abre igual que antes, con sus ediciones y sin ningún aviso.
- Abrirlo en 1c y editarlo (otro margen alcanza), y cerrarlo. Abrirlo con la copia de 1b: ahora dice que el proyecto se editó con una versión más nueva de Toma.
- En 1c, en ese mismo proyecto, deshacer hasta el final: también se deshacen las ediciones hechas en 1b (el corte y el margen), hasta el proyecto como se grabó.

**Estilos con nombre** (29)

Arriba de las pestañas del panel, la fila **Estilo** dice el estilo guardado que el proyecto tiene tal cual, "Estilo de Toma" o "Personalizado". Los botones del pie de Fondo de 1b ya no están.
- **El estilo de 1b.** Si en 1b se usó "Usar este estilo en los proyectos nuevos": la primera vez que se abre 1c, el menú de la fila tiene «Mi estilo» con una estrella (es el de los proyectos nuevos). Un proyecto nuevo grabado después se abre con ese fondo, ese margen y ese cursor, y con la cámara espejada y con sombra. Cerrar y abrir 1c otra vez: sigue habiendo un solo «Mi estilo».
- **Guardar, aplicar, marcar y grabar** (comprobación 8 de diseño §16.2). En un proyecto grabado con 1c, cambiar el fondo, el margen y el espejo de la cámara, y "Guardar como estilo nuevo…" con un nombre: la fila dice ese nombre (en un proyecto de antes de 1c sigue diciendo "Personalizado": el estilo se guarda con la burbuja medida contra el lado corto y el proyecto la mide contra el alto, hasta que se le aplica uno). Abrir otro proyecto y elegir ese estilo en el menú: toma el fondo, el margen, el cursor y la cámara, pero no la forma, el tamaño ni el lugar de la burbuja, ni el formato. ⌘Z lo deshace de una vez ("Deshacer Aplicar un estilo"). Marcarlo en "Usar en los proyectos nuevos ▸" (la estrella pasa a él), grabar una toma corta y abrirla: se abre con ese estilo y la fila lo nombra.
- **Actualizar.** En el proyecto del paso anterior, cambiar el margen: la fila dice "Personalizado" y el menú ofrece "Actualizar «nombre» con este proyecto". Elegirlo: la fila vuelve a decir el nombre, y el otro proyecto, que tenía el estilo, ahora dice "Personalizado" (aplicar copia los valores: no se enlaza). Un proyecto que nunca tuvo un estilo guardado en esa ventana (por ejemplo, uno de 1b recién abierto) no ofrece "Actualizar".
- **Administrar estilos….** Renombrar uno en el lugar (escribir y ↩); escribir otro nombre y apretar Escape: vuelve el nombre que tenía. Duplicar ("nombre copia"), Mostrar en Finder (selecciona su `.tomastyle` en `~/Library/Application Support/Toma/Styles/`) y "Mover a la Papelera…": pregunta "¿Borrar el estilo «nombre»?" · "Va a la Papelera." con el botón "Mover a la Papelera", y el paquete aparece en la Papelera de macOS. Mover a la Papelera el que tiene la estrella: la estrella pasa al Estilo de Toma. Con la hoja cerrada, borrar un `.tomastyle` desde Finder y abrir la hoja otra vez: ya no está en la lista. Escape sin un nombre a medio escribir cierra la hoja.
- **Imagen perdida.** Guardar un estilo con un fondo de imagen propia, mostrarlo en Finder y, dentro del paquete, borrar la imagen de `assets/`. Aplicarlo a otro proyecto: debajo de la fila, "No se encontró la imagen de este estilo: el fondo queda como estaba."; lo demás se aplica. Con el disco lleno, aplicar un estilo con imagen: la franja ámbar dice "Esperando espacio en el disco para aplicar el estilo…" hasta que se libera lugar, y después se aplica.
- **Mandarlo a otra Mac.** "Mostrar en Finder" de un estilo con imagen, mandar el `.tomastyle` por Mail a otra Mac con la copia de 1c y abrirlo con doble clic desde el adjunto: aviso "Se agregó el estilo «nombre»." y el estilo, con su imagen, en el menú de la fila. Abrir un `.tomastyle` dañado (por ejemplo, uno con su `style.json` borrado): "No se pudo importar el estilo: el archivo está dañado." En Finder, el tipo de un `.tomastyle` dice "Estilo de Toma". Abrir con doble clic un estilo de la carpeta `Styles` misma no agrega otra copia y avisa "«nombre» ya está en los estilos." En "Importar…" de la hoja, elegir a la vez uno dañado y uno bueno: se dicen los dos, primero "No se pudo importar «archivo»: el archivo está dañado." y después "Se agregó el estilo «nombre»."
- **"Aplicar el estilo por defecto" en un proyecto de antes de 1b.** En un proyecto con la franja "Este proyecto se grabó con una versión anterior y conserva su aspecto.", el botón aplica el aspecto del estilo marcado con la estrella para los proyectos nuevos (fondo, margen, esquinas, sombra, cursor y zoom), sin tocar la cámara; sin ninguno marcado, el del Estilo de Toma. ⌘Z lo deshace.

**La pestaña Cámara** (16)

Hace falta un proyecto con cámara. La pestaña tiene la tarjeta "Bloque seleccionado" (solo con un bloque), los cinco mosaicos de Disposición, el lado y el tamaño de la división, la burbuja de 1b, "Cambios durante la toma" y "Aspecto de la cámara".
- **Cada mosaico se ve como su disposición.** En un proyecto horizontal 16:9, en uno vertical 9:16 y en uno cuadrado 1:1: cada mosaico se dibuja en el formato del proyecto y se parece a lo que hace (Burbuja: la pantalla con la cámara en una esquina; Solo pantalla: sin cámara; Dividida: pantalla y cámara lado a lado, o una sobre otra en 9:16 y 1:1; Solo cámara: la cámara en lugar de la pantalla; Pantalla completa: la cámara de borde a borde). El elegido tiene un anillo que se mueve de uno a otro; con Reducir movimiento, solo se atenúa. Con VoiceOver, cada uno dice "Disposición, Burbuja, 1 de 5".
- **Burbuja → Dividida → Burbuja recupera los dos ajustes.** En un bloque Burbuja, cambiar su forma y su posición; pasarlo a Dividida y cambiar el lado y el tamaño de la cámara; volver a Burbuja: la forma y la posición son las que se habían elegido; volver a Dividida: el lado y el tamaño también.
- **Se edita.** Sin nada seleccionado, la línea dice "Se edita: la disposición del proyecto"; con un bloque, "Se edita: el bloque de 0:28". Con el cabezal dentro de un bloque Burbuja y sin selección, los controles de la burbuja editan el bloque.
- **Borrar todos los cambios.** En un proyecto con varios cambios de la burbuja, "Borrar todos los cambios" vacía la lista y un solo ⌘Z los devuelve todos. Con bloques, los cambios que caen dentro de uno siguen en la lista, atenuados, con "oculto por el bloque «Pantalla dividida» de 0:28", y debajo de la lista está la nota de que los de adentro siguen contando después.
- **Aspecto.** Espejar da vuelta la cámara; Borde (0 a 100) y sus seis colores más el selector; Sombra (0 a 100). Cada barra es un gesto: arrastrarla se ve en la vista previa y un ⌘Z la deshace entera.

**La pista Cámara** (15)

Hace falta un proyecto con cámara y, para ver la división, uno con la cámara en Dividida. La fila Cámara mide 32 pt; su encabezado dice "Cámara" y debajo el layout del proyecto ("Burbuja").
- **Crear bloques.** Arrastrar en un lugar vacío de la fila: aparece un bloque que sigue al puntero, y con menos de 0,5 s no se crea ninguno. Doble clic en un lugar vacío: un bloque de 3 s desde ese punto, recortado al espacio libre; con otro bloque a 1 s, dura 1 s. En "Disposición ▾" de la barra de pistas (junto a "Agregar zoom"), elegir cada uno de los cinco: crea un bloque en el cabezal, o sobre el rango marcado con I y O. El primer bloque de un proyecto es Cámara a pantalla completa; los siguientes, el último layout elegido.
- **Lo que dice cada bloque.** Ícono y nombre del layout; con Dividida, el lado de la cámara ("Dividida · cámara a la derecha"; en 9:16 y 1:1, "arriba" o "abajo"). Un bloque instantáneo tiene las esquinas rectas. Al soltar un bloque que se mueve o se recorta, se acomoda con el resorte de las demás pistas (con Reducir movimiento, sin resorte).
- **Mover, recortar y borrar.** Arrastrar el cuerpo de un bloque lo mueve y se frena en el vecino; arrastrar un borde (el cursor cambia a flechas) lo recorta con la etiqueta "−1,20 s · 0:18,40", nunca a menos de 0,5 s; se ajusta al cabezal, a las marcas y a los bordes de otros bloques (⌘ invierte el ajuste). Cada gesto es un solo ⌘Z. ⌫ borra el bloque seleccionado; `,` y `.` lo mueven un cuadro (⇧ diez).
- **Selección y panel.** Un clic en un bloque lo selecciona (contorno de color) y la pestaña Cámara muestra "Bloque seleccionado" con sus tiempos; un clic en el encabezado "Cámara" deselecciona y muestra la pestaña Cámara con "Se edita: la disposición del proyecto".
- **Menú contextual de un bloque.** Los cinco layouts (el actual con marca), "Lado de la cámara" (solo en Dividida), "Tamaño automático" (solo en Dividida con un tamaño fijo), "Transición instantánea" y "Borrar el bloque"; cada elección es un solo ⌘Z.
- **Rombos dentro de un bloque.** Un cambio de la burbuja grabado dentro de un bloque se dibuja al 40 %; al pasar el puntero, la ayuda dice "No se ve mientras rige el bloque «Pantalla dividida»; después sigue contando." Fuera de los bloques se ven normales y se siguen seleccionando, arrastrando y borrando como en 1b.
- **Cámara ilegible.** En una copia de un proyecto a la que se le borró a mano el archivo de la cámara dentro del paquete, la fila Cámara dice "No se puede leer la cámara: se ve solo la pantalla."
- **VoiceOver.** Cada bloque es un elemento: "Disposición Pantalla dividida, de 0:12 a 0:31", con las acciones Borrar, Recortar el comienzo y el final hasta el cabezal y "Cambiar la disposición" (abre el menú de los cinco). El encabezado "Cámara" es un botón.

**La vista previa con la división y los atajos de disposición** (17)

Hace falta un proyecto con cámara, con un bloque (o el layout del proyecto) en Pantalla dividida, y el cabezal dentro de él.
- **La manija.** Al pasar el puntero por la separación entre las dos tarjetas aparece una manija (una barrita blanca) y el cursor cambia a flechas izquierda-derecha (en 9:16 y 1:1, arriba-abajo). Arrastrarla cambia el tamaño de la cámara: la separación sigue al puntero sin desfase, con la etiqueta "34 %" junto a ella, y nunca baja del 25 % ni pasa del 60 %. Al soltar, un solo ⌘Z deshace el cambio entero; en la pestaña Cámara, "Tamaño de la cámara" ya no está en Automático y su barra dice lo mismo que la etiqueta. Con el cabezal en un bloque, cambia el tamaño de ese bloque; fuera de los bloques, el de la disposición del proyecto.
- **Volver a Automático.** Doble clic en la manija: el tamaño vuelve a Automático (un solo paso de deshacer) y la cámara recupera la parte que le da la pantalla.
- **La burbuja de un bloque.** Con el cabezal dentro de un bloque Burbuja, arrastrar la burbuja de la vista previa cambia el estilo de ese bloque (lugar) y no los rombos de la toma: la barra de la pista no suma ningún rombo y fuera del bloque la burbuja sigue donde estaba. Con el cabezal dentro de un bloque de otra disposición, o fuera de los bloques con otra disposición en el proyecto, no hay burbuja que arrastrar.
- **El recuadro del zoom en una división.** Con un zoom de foco fijo seleccionado y el cabezal en una división, el recuadro se dibuja sobre la tarjeta de la pantalla y no sale de ella; moverlo y cambiar su profundidad (las esquinas) sigue funcionando.
- **⌥1 a ⌥5.** Con el foco en la vista previa o en la línea de tiempo: ⌥1 Burbuja, ⌥2 Solo pantalla, ⌥3 Pantalla dividida, ⌥4 Solo cámara, ⌥5 Cámara a pantalla completa. Con un bloque seleccionado, cambia su disposición (un solo ⌘Z); sin selección, crea un bloque en el cabezal (3 s), o sobre el rango marcado con I y O, con esa disposición. Con el cursor dentro de un campo de texto del panel, no hacen nada.
**La ventana de la biblioteca** (36)

Con 1 000 proyectos de prueba, en una copia de esta rama armada con `make build`. `TOMA_BENCH=1 TOMA_BENCH_DIR="$TMPDIR/lib1000" swift test --package-path Packages/RecorderKit --filter reconcileAndIndexAThousand` deja los proyectos y su índice en `$TMPDIR/lib1000` (que tiene que estar vacía o no existir), y `build/Build/Products/Debug/Toma.app/Contents/MacOS/Toma -TomaLibraryBench "$TMPDIR/lib1000" -TomaLibraryBenchKeepOpen` abre la biblioteca sobre esa carpeta y la deja abierta (⌘Q la cierra). Al terminar, borrar la carpeta (`rm -rf "$TMPDIR/lib1000"`).
- La ventana: a la izquierda la barra lateral de 200 pt, con el material del sistema, Todos los proyectos (1000), Favoritos, Otros lugares y Papelera; al pie, "Quedan … en «…»". Arriba, el botón de la barra lateral, "Biblioteca", Como grilla · Como lista, Ordenar por (dice "Fecha de grabación") y Buscar. Las tarjetas, en columnas de 200 a 260 pt que se acomodan al ancho de la ventana: la miniatura en un marco 16:9 con esquinas redondeadas sobre el gris oscuro del editor, la duración abajo a la derecha, el nombre en una línea (cortado al medio si no entra) y "hora · 16:9" debajo, bajo el encabezado "Hoy" (los proyectos de prueba tienen fecha de 2027, que va en Hoy). Al pasar el puntero, la tarjeta se resalta y aparece una estrella vacía arriba a la izquierda.
- Desplazar la grilla de punta a punta, y después la lista (⌘2), con el trackpad: a la frecuencia de la pantalla (120 Hz con ProMotion), sin saltos ni huecos; las miniaturas llegan con un fundido.
- Memoria: con la grilla y la lista desplazadas de punta a punta dos veces, Monitor de actividad muestra a Toma con 250 MB o menos.
- Clic, ⇧-clic y ⌘-clic seleccionan como en Finder; un clic en el espacio vacío no deja nada seleccionado; doble clic abre el editor del proyecto (de prueba: puede decir que no se puede reproducir, alcanza con que abra).
- Solo con el teclado: Tab pasa entre la barra lateral, la búsqueda y las tarjetas; las flechas mueven la selección (arriba y abajo por columnas), ⇧ con una flecha la extiende, ⌘A selecciona todo, Esc nada; ↩, ⌘O y ⌘↓ abren lo seleccionado; ⌘1 y ⌘2 cambian entre grilla y lista; ⌘F va a Buscar. Escribir "0999" deja una sola tarjeta, "SYNTHÉTIC 0999" también (sin distinguir mayúsculas ni acentos), y "zzz" dice "Nada coincide con «zzz».".
- Lista: las columnas Nombre (con la miniatura chica), Fecha de grabación, Duración, Formato, Tamaño, Lugar ("lib1000") y Estado. Un clic en Nombre, Fecha de grabación, Duración o Tamaño ordena por esa columna, otro clic al revés, y el menú Ordenar por muestra lo mismo; Abierto por última vez, solo desde el menú.
- Ordenar por Nombre: la grilla deja de tener secciones y cada tarjeta dice la fecha con la hora.
- Las secciones vacías: Favoritos dice "Marcar proyectos con ☆ para encontrarlos aquí.", Otros lugares "Los proyectos que se abran desde otras carpetas aparecen aquí." y Papelera "La papelera está vacía.". Con una carpeta vacía (`mkdir "$TMPDIR/lib0"` y el mismo comando sobre ella), Todos los proyectos dice "Todavía no hay grabaciones." y "Grabar desde el notch o con ⇧⌘2." con el botón Grabar (que en esta prueba no abre nada: la isla no está).
- VoiceOver (⌘F5): cada tarjeta se lee entera, por ejemplo "Synthetic 0999, 39 segundos, 16:9, grabado el …"; el rotor de encabezados lista las secciones por fecha; la lista es una tabla; los botones de la barra dicen su nombre.
- Reducir movimiento (Ajustes del Sistema ▸ Accesibilidad ▸ Pantalla): las miniaturas aparecen con un fundido simple, sin subir.
- Con la app entera (después de las tareas 37 y 38, que abren la biblioteca desde la app y le avisan lo que graba): una tarjeta de una toma en curso dice "● Grabando", con el punto latiendo cada 1,8 s y quieto con Reducir movimiento, y no se abre ("Se está grabando."); las demás tarjetas conservan su miniatura durante la toma. Cerrar la biblioteca y volver a abrirla: vuelve al mismo lugar y tamaño, con la misma vista, orden y sección.
- **Volver a medir el primer cuadro y la espera más larga, en una Mac tranquila** (Task 36). El agente midió con la Mac cargada y no llegó a la meta: el primer cuadro con 1 000 proyectos e índice en caché tardó **168 a 197 ms** (meta ≤ 150 ms) y la espera más larga del hilo principal fue de **4,3 a 7,1 ms** (meta ≤ 4 ms; 1,7 a 4,3 ms en la mejor serie). Con la Mac sin otro trabajo (cerrar todo lo demás, y que `uptime` diga una carga menor que 2): con la carpeta de 1 000 que deja `TOMA_BENCH=1 TOMA_BENCH_DIR="$TMPDIR/lib1000" swift test --package-path Packages/RecorderKit --filter reconcileAndIndexAThousand`, correr seis veces `build/Build/Products/Debug/Toma.app/Contents/MacOS/Toma -TomaLibraryBench "$TMPDIR/lib1000"` y anotar en la tabla del final `first-frame` y `longest-main-wait` de cada línea y la carga. Se cumple si el primer cuadro da ≤ 150 ms (≤ 300 ms en la M1) y la espera más larga ≤ 4 ms (≤ 8 ms en la M1) en todas. Si no se cumple en la Mac tranquila, queda en `docs/backlog.md` («Lo que deja abierto el hito 1c»), no se arregla acá.

**Abrir la biblioteca** (38)

- Cada entrada abre la misma ventana, una sola: el menú del ícono de la barra de menús ("Biblioteca…", ⇧⌘L; reemplaza a "Mostrar la papelera en Finder"), el botón "Biblioteca" del panel abierto de la isla (junto a Ajustes; la isla se cierra), Ventana ▸ Biblioteca con un editor adelante, y reabrir Toma. Una segunda vez trae la ventana adelante sin hacer otra.
- ⇧⌘L con la app activa (con un editor o la biblioteca adelante) abre la biblioteca; con otra app activa no hace nada (no es un atajo global).
- Reabrir desde el Launchpad (o Finder o Spotlight) con la app abierta y ninguna ventana: abre la biblioteca. Con un editor abierto, no abre otra ventana. Cerrar el último editor no abre la biblioteca: la app vuelve a la barra de menús y el ícono del Dock se va.
- Grabar con la biblioteca abierta: al empezar la toma la app sale del Dock y de Cmd-Tab y la ventana sigue abierta; la tarjeta del proyecto que se graba dice "Grabando" y su miniatura no se redibuja; al terminar la toma el ícono vuelve al Dock y la tarjeta muestra la toma terminada.
- Reiniciar una toma (⇧⌘2 con la isla, "Reiniciar toma"): el aviso "La toma fue a la papelera." de la isla se puede tocar y abre la biblioteca en la Papelera, con la toma ahí. Con la biblioteca abierta, la toma reiniciada aparece en la Papelera sin reabrirla.
- Abrir con doble clic en Finder un `.toma` que está fuera de la carpeta de proyectos: abre el editor y, en la biblioteca (abierta antes o después), está en "Otros lugares". Un proyecto abierto en otra app aparece como abierto en otra app.
- Editar un proyecto en un editor con la biblioteca abierta: su tarjeta cambia (duración, estado) un segundo después de dejar de editar. La biblioteca marca "Abierto" el proyecto que un editor de Toma tiene abierto.
**Las acciones de la biblioteca** (37)

Con la app entera (después de la tarea 38, que abre la biblioteca desde la app), sobre los proyectos propios. Cada acción que falla deja el proyecto como estaba y lo dice en una franja arriba del contenido ("No se pudo renombrar «…»: …"), que se cierra con su ×.
- Menú contextual de una tarjeta (y de una fila de la lista): Abrir, Renombrar, Duplicar (⌘D), Duplicar como ▸ (solo los dos formatos que el proyecto no tiene), Mostrar en Finder, Agregar a Favoritos o Quitar de Favoritos (.), y Mover a la papelera (⌘⌫). Con varias tarjetas seleccionadas, sin Renombrar ni Duplicar como, y cada acción vale para todas. Mientras dura una acción, la tarjeta muestra un indicador y ninguna acción que la mueva (ni ⌘Z) empieza sobre ella; Abrir, la estrella y Mostrar en Finder siguen andando. En la Papelera, ⌘D y "." no hacen nada. Si varias tarjetas fallan, la franja dice la primera falla y "(y N más)".
- **Comprobación 4 del diseño (§16.2) desde la biblioteca:** buscar y ordenar; marcar y desmarcar favoritos con la estrella de la tarjeta, con "." y con el menú (Favoritos los muestra); renombrar con el menú y con un clic sobre el nombre de la tarjeta ya seleccionada (un doble clic abre, no renombra): escribir "a/b", ".x", nada o el nombre de otro proyecto de la misma carpeta muestra al lado del campo "El nombre no puede tener «/» ni «:».", "No puede empezar con un punto.", "El nombre no puede estar vacío." y "Ya hay un proyecto con ese nombre."; ↩ renombra, Esc deja el nombre como estaba. Duplicar da «… copia» y después «… copia 2»; la tarjeta nueva aparece sola. Mover a la papelera: la tarjeta se achica y se desvanece mientras las demás se corren, y abajo aparece 8 s "«…» se movió a la papelera. · Deshacer" (con varias, "3 proyectos se movieron a la papelera."); Deshacer la devuelve por el mismo camino. ⌘Z y ⇧⌘Z deshacen y rehacen renombrar, mandar a la papelera, restaurar, favoritos, quitar de la biblioteca y duplicar (varias tarjetas juntas se deshacen juntas). En la Papelera: al pasar el puntero, Restaurar; arriba, Vaciar la papelera… con una alerta "¿Eliminar para siempre N proyectos (… GB)?" · "No se puede deshacer." donde ↩ es Cancelar; Eliminar borra, y la barra lateral dice "Vaciando… 3 de 12" mientras tanto. Eliminar ahora… de una sola tarjeta pregunta "¿Eliminar «…» para siempre?". Con la alerta abierta, Esc también cancela. Mientras se vacía, ⌘Z no hace nada; al terminar, deshace lo de antes. "Reiniciar toma" en la isla deja la toma en la Papelera de la biblioteca.
- Deshacer un duplicado después de abrirlo: "No se puede deshacer: la copia se abrió o cambió desde que se hizo." y la copia queda. Deshacer un "Duplicar como" recién hecho, con su editor cerrado sin tocarlo, manda la copia a la papelera.
- Mover a la papelera un proyecto abierto en un editor: la ventana del editor se cierra primero y el proyecto va a la papelera. Con el proyecto abierto en otra copia de Toma (la de 1b, por ejemplo): "No se puede: está abierto en otra app."
- Grabar y, durante la toma, renombrar o mandar a la papelera un proyecto: "Se está grabando.". Vaciar la papelera con proyectos grandes y empezar a grabar a la mitad: la barra lateral dice "Vaciando… en pausa mientras se graba" y sigue al terminar la toma.
- **Comprobación 2 del diseño (§16.2):** "Duplicar como ▸ Vertical 9:16" del proyecto con cámara del recorrido: aparece «… vertical» y se abre en el editor ya en 9:16, con la división apilada y la burbuja del tamaño de un video vertical; el original sigue en 16:9. Exportar la copia y verla en el iPhone. Con un proyecto de 1b (el de la preparación), Duplicar como: la copia de 1b de Toma (`~/Desktop/Toma-1b.app`) sigue abriendo el original sin aviso. Duplicar como sobre un disco lleno: la copia queda con su nombre, no se abre y la franja dice "No se pudo cambiar el formato de «…»: …".
- Un proyecto «Sin terminar» (una toma cortada con `kill -9` mientras graba, por ejemplo): su menú y el botón al pasar el puntero dicen Recuperar, que abre la recuperación de esa toma.
- Arrastrar a la ventana un paquete `.toma` de otra carpeta (del Escritorio, por ejemplo): aparece en Otros lugares. Arrastrar uno que ya está en la carpeta de proyectos: queda seleccionado (uno de la Papelera de Toma, en la Papelera). Uno a más de cuatro carpetas de la de proyectos, o en una carpeta oculta: la franja dice por qué no se muestra. Un archivo o un enlace con nombre `.toma`: no pasa nada. En Otros lugares, el menú dice Actualizar y Quitar de la biblioteca (no Mover a la papelera; ⌘⌫ dice "«…» está fuera de la carpeta de Toma: quitarlo de la biblioteca deja el archivo donde está."); Quitar de la biblioteca deja el archivo donde está, y ⌘Z lo vuelve a mostrar.
- **Comprobación 5 del diseño (§16.2):** abrir con ⌘O un proyecto de un disco externo: aparece en Otros lugares. Expulsar el disco y abrir la biblioteca: no pide nada, no se traba, ningún aviso de privacidad nuevo de macOS, y la tarjeta se ve como antes; recién al tocarla (Abrir, Actualizar o Mostrar en Finder) queda atenuada con "No disponible" y la ayuda "El disco «…» no está conectado.". Nunca se quita sola de la lista.
- Salir de Toma (⌘Q) mientras se duplica un proyecto grande en un disco sin clones (un disco externo con HFS+ o exFAT, como Otros lugares): la app espera a que la copia termine antes de cerrarse, y la copia queda entera.
- VoiceOver sobre una tarjeta: el rotor de acciones lista Abrir, Renombrar, Duplicar, Mostrar en Finder, Agregar a Favoritos (o Quitar de Favoritos) y Mover a la papelera; en la Papelera, Abrir, Restaurar, Mostrar en Finder y Eliminar ahora…. Con Reducir movimiento, las tarjetas que se acomodan y la que va a la papelera solo se funden.
**El GIF: el corpus** (25)

- *Opcional:* si tiene gifski instalado, comparar a ojo un GIF del corpus. `TOMA_BENCH=1 TOMA_GIF_CORPUS_OUT=~/Desktop/corpus-gif swift test --package-path Packages/RecorderKit -c release -Xswiftc -enable-testing --filter gifCorpusBeatsImageIO` deja en `~/Desktop/corpus-gif/<toma>/` los cuadros (`frames/*.png`), el GIF de Toma (`toma.gif`) y el de ImageIO (`imageio.gif`) de cada toma del corpus (ver `docs/performance.md`, fila 25). Con `gifski --fps 15 -o gifski.gif frames/*.png`, abrir los tres en Safari a tamaño real: el de Toma no tiene bandas que molesten en el fondo `aurora-1` ni en la cámara, el tramado no titila en lo quieto, y el texto se lee como en los otros. Anotar el tamaño de los tres.

**El aspecto de la cámara en el video** (10)

Hace falta un proyecto con cámara grabado con 1c (se abre espejado y con sombra, como todo proyecto nuevo) y el proyecto de 1b de la preparación.
- **Espejo sí y no.** En la pestaña Cámara, con "Espejar" encendido la imagen de la cámara se ve como en un espejo, igual que en la burbuja mientras se graba; apagado, como la ve otra persona. El lugar y la forma de la burbuja no cambian, solo la imagen de adentro, y el video exportado es igual a la vista previa. Grabar una toma corta con la burbuja abajo a la derecha señalando la pantalla con la mano (hacia la izquierda de uno): con el espejo encendido, en el video la mano apunta hacia la pantalla, adonde se apuntó al grabar; apagado, hacia afuera.
- **Borde y sombra a 1080p y a 4K.** Borde en 50, blanco, y Sombra en 40. Exportar en 1080p y en 4K y mirar los dos a pantalla completa: el borde es un trazo parejo por dentro del contorno de la cámara (no la agranda ni la corre), con el canto suave como el resto del contorno, de unos 6,5 px en 1080p y 13 en 4K (el mismo grosor a la vista); la sombra cae suave y un poco hacia abajo, igual en los dos tamaños. Con un color de borde semitransparente (el selector), se ve la imagen a través del borde, no el fondo. Con el cuadrado redondeado y las formas vertical y horizontal, el borde y la sombra siguen las esquinas.
- **La burbuja en un video vertical.** En el proyecto de 1c, pasar el formato a 9:16: la burbuja Mediana se ve del mismo tamaño que en 16:9 (un cuarto del ancho, no casi la mitad), en la vista previa y en el video exportado; al arrastrarla en la vista previa, el contorno y los ocho puntos coinciden con la cámara que se ve debajo, y al soltarla cae en el punto más cercano a donde se soltó. En el proyecto de 1b pasado a 9:16, la burbuja se sigue midiendo contra el alto, como en 1b.
- **Un proyecto de 1b.** Abierto en 1c sin tocar el aspecto de la cámara, se ve igual que en 1b: sin espejo, sin borde y sin sombra.
**Renombrar y duplicar desde el editor, y la papelera solo para ver** (39)

Con la app entera, sobre proyectos propios, con la biblioteca abierta al lado del editor.
- **Renombrar desde el título del editor mientras está abierto en la biblioteca.** Un clic sobre el nombre de la barra del editor lo vuelve un campo de texto con el nombre escrito. Escribir "a/b", ".x", nada o el nombre de otro proyecto de la misma carpeta muestra al lado del campo, en rojo, "El nombre no puede tener «/» ni «:».", "No puede empezar con un punto.", "El nombre no puede estar vacío." y "Ya hay un proyecto con ese nombre."; ↩ no hace nada mientras el nombre no sirve. Esc deja el nombre como estaba. Un nombre válido y ↩: el título del editor, el de Ventana y la tarjeta de la biblioteca cambian enseguida (la tarjeta sigue con su punto "Abierto"); seguir editando: los cambios se guardan (cerrar y abrir el proyecto desde la biblioteca los muestra) y ⌘Z del editor no deshace el renombre. ⌘Z mientras se escribe el nombre deshace lo escrito, no una edición. Archivo ▸ Renombrar hace lo mismo que el clic.
- Con un editor adelante, el menú Archivo tiene Renombrar, Duplicar (⇧⌘S), Duplicar como ▸ (solo los dos formatos que el proyecto no tiene), Mostrar en Finder y Mover a la papelera; Ventana ▸ Biblioteca (⇧⌘L). Duplicar abre «… copia» en otro editor y la biblioteca la muestra; Duplicar como ▸ Vertical 9:16 abre «… vertical» ya en 9:16 y el original sigue en 16:9. Salir de Toma (⌘Q) mientras un Duplicar del editor copia un proyecto grande a un disco sin clones: la app espera a que la copia termine. Mostrar en Finder selecciona el paquete donde está ahora (también después de renombrarlo).
- Mover a la papelera desde el editor: la ventana se cierra y el proyecto aparece en la Papelera de la biblioteca. Con el disco lleno y el aviso ámbar de cambios sin guardar, no se mueve y una alerta dice "No se pudo mover «…» a la papelera: su editor tiene cambios que no se pudieron guardar" (la ventana queda abierta). Desde la biblioteca, mover a la papelera o eliminar un proyecto abierto en un editor cierra primero la ventana del editor (antes decía "No se puede: está abierto en otra app.").
- **Abrir un proyecto de la papelera desde Finder (solo para ver) y Restaurar.** Doble clic en Finder sobre un paquete de `~/Movies/Toma/Trash/` (o Abrir sobre una tarjeta de la Papelera): el editor muestra el proyecto con la franja "Este proyecto está en la papelera: se abre solo para ver." y el botón Restaurar; no se puede editar nada (el formato, el panel y la línea de tiempo no cambian el proyecto) y en el menú Archivo, Renombrar, Duplicar y Mover a la papelera están apagados. La fecha de modificación de los archivos del paquete no cambia por abrirlo (Finder ▸ Obtener información). Restaurar: la franja se va, el proyecto vuelve a su carpeta (la tarjeta sale de la Papelera) y se reabre editable en la misma ventana. Restaurarlo desde la biblioteca con el editor abierto hace lo mismo. Eliminar ahora… sobre un proyecto de la Papelera abierto así cierra antes su ventana.
- En la biblioteca, Edición ▸ Deshacer y Rehacer (y ⌘Z, ⇧⌘Z) deshacen y rehacen sus acciones una sola vez por pulsación (renombrar una tarjeta y ⌘Z una vez la devuelve, no dos pasos); con el cursor en la búsqueda o en el nombre de una tarjeta, deshacen lo escrito. Archivo ▸ Renombrar con una sola tarjeta seleccionada edita su nombre. Renombrar una tarjeta al nombre de otro proyecto que la biblioteca todavía no muestra y apretar Esc enseguida después de ↩: la franja dice "No se pudo renombrar «…»: ya hay un proyecto con ese nombre". Arrastrar a la ventana, con Favoritos a la vista, un paquete que ya está en Favoritos: queda seleccionado y la sección sigue siendo Favoritos.
- Un proyecto «Sin terminar» en la biblioteca: Recuperar recupera solo esa toma, sin volver a preguntar, y dice "Se recuperó 1 grabación" (o "No hay grabaciones para recuperar." si ya no hacía falta).
- **Renombrar y seguir mirando.** Con un proyecto con cámara y una pausa en la toma (dos tramos), abierto en el editor sin haber pasado todavía por la parte después de la pausa: renombrarlo desde el título, después mover el cabezal más allá de la pausa y poner una disposición con cámara (Pantalla dividida): se ven la pantalla y la cámara, sin la franja "No se pudo leer esta parte de la grabación". Renombrarlo (desde el editor o la biblioteca) mientras se exporta: la exportación termina y el video tiene todas sus partes.
- **Cerrar un editor que exporta.** Con un proyecto exportándose, Mover a la papelera desde la biblioteca o desde el menú Archivo del editor: el editor pasa adelante y pregunta "Hay una exportación en curso. ¿Cerrar la ventana y cancelarla?". Cancelar: la exportación sigue, el proyecto queda donde estaba y aparece "No se pudo mover «…» a la papelera: su ventana quedó abierta para terminar la exportación" (nunca "está abierto en otra app"). Cerrar: la exportación se cancela, la ventana se cierra y el proyecto va a la papelera. Lo mismo con Eliminar ahora… sobre un proyecto de la Papelera abierto (para ver) que exporta.
- **Una toma sin terminar en la papelera.** Un proyecto «Sin terminar» que está en `~/Movies/Toma/Trash/`, abierto desde Finder: el editor dice "Esta grabación no terminó de guardarse" con "Este proyecto está en la papelera: se abre solo para ver." y el botón Restaurar (no Recuperar). Restaurar lo devuelve a su carpeta y entonces ofrece Recuperar.
- **Lo que sigue al proyecto, no a su ruta.** Renombrar «A» a «A2» desde el editor y después renombrar otro proyecto a «A» en la biblioteca: la tarjeta del nuevo «A» no tiene el punto "Abierto", y mandarlo a la papelera no cierra la ventana de «A2». Un proyecto abierto solo para ver porque otra app lo tiene abierto: Mover a la papelera desde la biblioteca cierra primero esa ventana. Mover con Finder a la papelera de Toma un proyecto abierto en el editor y volver a esa ventana: se reabre solo para ver, con la franja de la papelera.

**Las disposiciones al reproducir, al exportar y en el sonido** (13)

Con un proyecto con cámara grabado con 1c.
- **Las transiciones se sienten como las de la burbuja de la isla** (comprobación 1 de diseño §16.2). Poner 5 s de Cámara a pantalla completa al principio, un tramo de Pantalla dividida con clics (el zoom queda dentro de la tarjeta de la pantalla), un bloque Burbuja arriba a la izquierda y volver a la burbuja del proyecto. Reproducir de punta a punta: cada cambio se mueve con el mismo resorte que la burbuja de la isla cuando se la arrastra, sin saltos ni dobles contornos, y la pantalla que vuelve después de Cámara a pantalla completa aparece ya moviéndose, nunca con un cuadro viejo ni un instante en negro. Exportar en 16:9 y comparar con la vista previa: los mismos cuadros.
- **Los clics que no se ven no suenan.** Con un sonido de clic elegido (pestaña Cursor, Sonido de clic), un clic grabado mientras rige Cámara a pantalla completa o Solo cámara no suena, ni en la vista previa ni en el video exportado; el mismo clic en la Burbuja, en Pantalla dividida o en Solo pantalla suena como en 1b. Justo al empezar un bloque de Cámara a pantalla completa, el clic suena mientras la pantalla todavía se ve más de la mitad.
- **La manija y el recuadro del zoom durante una transición.** Pausar a mitad de la transición hacia una Pantalla dividida (dos décimas de segundo después del borde del bloque): la manija entre las tarjetas no aparece ni cambia el puntero hasta que las tarjetas se asientan, y con un zoom fijo seleccionado su recuadro se dibuja sobre la tarjeta de la pantalla donde se la ve en ese cuadro. Un proyecto sin cámara con Pantalla dividida como disposición del proyecto (un estilo guardado) no muestra la manija: se ve solo la pantalla, como en el video.
- **La meta del piso en la Mac M1** (diseño §15). En la Mac M1 de piso: `swift build --package-path Packages/RecorderKit -c release --product recorder-dev` y `Packages/RecorderKit/.build/release/recorder-dev bench-preview --synthetic --layouts --width 1920 --height 1080 --view-width 1920 --view-height 1080`. Se tiene que ver `frame p50 … p95 …` con el p95 en 16,7 ms o menos y `transitions: 0 frames skipped, 0 late`. Anotar las líneas `playing`, `transition at …` y `transitions:` con la carga (`uptime`) en la columna del piso de `docs/performance.md`.

**La hoja de exportar: GIF, rango y Copiar** (26)

Con la app entera, sobre un proyecto propio con cámara y sonido de más de un minuto, grabado en una pantalla Retina.
- **Comprobación 6 del diseño (§16.2).** Marcar con I y O 10 s del proyecto y Exportar (⌘E). Elegir "Exportar como" GIF animado: el Rango pasa solo a "Entre las marcas (0:…–0:…)", con los tiempos de las marcas como los dice el transporte. Con Tamaño 800 × 450, 15 cuadros por segundo, Calidad Equilibrada y Tramado y Repetir siempre encendidos, la línea dice "Aprox. … MB · 0:10 · 150 cuadros"; anotar ese tamaño. Exportar…: el panel de guardado propone «<proyecto>.gif» en la carpeta del proyecto. Comparar el tamaño del archivo (Finder ▸ Obtener información) con la estimación y anotar los dos en la tabla del final (en el corpus del GIF la estimación quedó de 3 a 11 % por encima). Abrirlo en Safari, mandarlo por Slack y soltarlo en un comentario de un issue de GitHub (sin enviarlo alcanza): en los tres se ve y se repite. Al terminar, la barra dice "Exportación terminada · Mostrar en Finder · Copiar" durante 8 s: Copiar y pegar (⌘V) en Slack, en Mail y en el issue pega el archivo, no su ruta. Exportarlo otra vez con "Repetir siempre" apagado: en Safari se reproduce una vez y queda en el último cuadro.
- **La primera estimación y la vista previa, a tiempo.** Con el proyecto anterior y la hoja recordando GIF, Exportar (⌘E): la vista previa (3 s desde el cabezal, en bucle) y la primera estimación aparecen en 1,5 s o menos en la M1 y en 0,6 s o menos en la del dueño. Medirlo desde la tecla (un video de la pantalla con QuickTime, contando cuadros, sirve) y anotarlo en `docs/performance.md`.
- **Cambiar opciones.** Al cambiar Tamaño, Cuadros por segundo, Calidad, Tramado, Repetir siempre o el Rango, la línea dice "Calculando…" y la vista previa se atenúa con "Generando la vista previa…"; las nuevas llegan sin trabar la hoja. Cambiar varias cosas seguidas y rápido no rehace nada hasta que se deja de cambiar (300 ms). Con el Rango en "Todo el video" (más de 8 s), la estimación aparece primero aproximada y un momento después se corrige.
- **Tamaños.** El menú Tamaño dice 480 × 270, 640 × 360, 800 × 450, 1080 × 608, 1280 × 720 y 1920 × 1080 en un proyecto 16:9; en uno 9:16, 270 × 480 … 1080 × 1920 (608 × 1080 para 1080); en uno 1:1, 480 × 480 … 1920 × 1920. En una toma de una ventana de unos 640 × 400 pt en una pantalla Retina (800 px de lado corto), "Más que la grabación" aparece junto a 1920 × 1080, y solo ahí.
- **Avisos y "Los GIF no tienen sonido."** En GIF, debajo de la estimación, siempre dice "Los GIF no tienen sonido.". Con el Rango en "Todo el video" de un proyecto de más de un minuto: "Un GIF de más de un minuto pesa mucho. Conviene marcar un rango (I y O) o exportar en MP4."; a 1920 × 1080 y 30 cuadros por segundo, cuando la estimación pasa de 10 MB, "Con más de 10 MB, algunos sitios no lo muestran.", y de 50 MB, también "Un GIF así pesa mucho: conviene exportar en MP4.". Ninguno bloquea: Exportar… sigue habilitado.
- **Un rango de menos de un cuadro.** En un proyecto a 60 cuadros por segundo, poner I, mover el cabezal un cuadro con → y poner O. En GIF a 10 cuadros por segundo, la hoja dice "El rango tiene que durar al menos un cuadro." y Exportar… está apagado (no hay vista previa ni estimación). En Video MP4 a 60 cuadros, con "Entre las marcas", se puede exportar: el MP4 dura un cuadro. En GIF a 30 cuadros con I y O a dos cuadros del proyecto (33 ms), la estimación dice "… · 1 cuadro" (no "1 cuadros"; en inglés, "1 frame"). En un proyecto a 60 cuadros, poner la I tres cuadros antes del final y arrastrar la O hasta el final de la regla: en Video MP4 a 24 cuadros la hoja dice "El rango tiene que durar al menos un cuadro." si lo que queda hasta el último cuadro entero del MP4 dura menos de uno (Exportar… apagado; nunca "No se pudo exportar el video" después de elegir el destino).
- **El MP4 de un rango.** Con marcas, "Exportar como" Video MP4: el Rango empieza en "Todo el video"; elegir "Entre las marcas": "Aprox." baja en proporción. El MP4 dura lo que va de I a O, empieza en el cuadro de la marca I y el sonido va con la imagen (un clic o una palabra cerca del comienzo y del final suena con lo que se ve). Al terminar, Copiar también pega el MP4. Elegir un rango y cambiar "Exportar como" no lo cambia.
- **Lo que recuerda.** Exportar un GIF a 640 × 360, 10 cuadros, Liviana, sin Tramado: la próxima hoja (también en otro proyecto, y después de salir y volver a abrir Toma) abre en GIF animado con esas opciones; la resolución del MP4 que se tenía y el tamaño al que se dibuja la vista previa del editor no cambian por un GIF. Exportar un MP4 vuelve a abrir en Video MP4. El rango no se recuerda: sin marcas, siempre "Todo el video".
- **Tamaño real y Reducir movimiento.** "Tamaño real" muestra el GIF a un píxel de la pantalla por píxel del GIF, centrado en el recuadro, y se desplaza con el trackpad; otro clic lo vuelve a ajustar a 320 × 180. Con Reducir movimiento (Ajustes del Sistema ▸ Accesibilidad ▸ Pantalla), la vista previa queda quieta en su primer cuadro con un botón Reproducir, que la pone en bucle y pasa a Pausar.
- **VoiceOver.** La vista previa se lee "Vista previa del GIF" con "En reproducción" (o "En pausa" con Reducir movimiento); al cambiar una opción, VoiceOver dice la estimación nueva cuando llega ("Aprox. … · … · … cuadros"). Todo se alcanza con Tab y se cambia con el teclado.
- **Un export a la vez, cerrar y salir, con un GIF.** Mientras se exporta un GIF: el anillo de la barra y su menú "Cancelar la exportación" (cancelar no deja nada junto al destino, ni un `.partial.gif`); Exportar está apagado en los demás editores; cerrar la ventana pregunta "Hay una exportación en curso. ¿Cerrar la ventana y cancelarla?" y ⌘Q pregunta antes de cancelarla, igual que con un MP4.
- **Cerrar la hoja la suelta.** Con un proyecto abierto desde un disco externo (Otros lugares), abrir la hoja en GIF animado y, mientras dice "Calculando…", Cancelar: en Monitor de actividad, el uso de CPU de Toma vuelve enseguida a reposo (la vista previa y la estimación se detienen). Lo mismo con Exportar… (solo la exportación sigue) y con la hoja abierta al mover el proyecto a la papelera desde la biblioteca. Después de cerrar el editor, Monitor de actividad ▸ Toma ▸ Archivos y puertos abiertos no lista la carpeta `.toma`, y el disco se expulsa sin decir que Toma lo está usando.
- **Disco lleno.** Crear y abrir una imagen de disco chica (`hdiutil create -size 20m -fs HFS+ -volname Lleno ~/Desktop/lleno.dmg`, doble clic) y exportar ahí un GIF del video entero a 1920 × 1080: "No se pudo exportar el GIF: el disco está lleno" y en el disco no queda ningún archivo del GIF. Exportar a una carpeta sin permiso de escritura (por ejemplo, una de otro usuario en `/Users/Shared` con permisos de solo lectura): "No se pudo exportar el GIF: no hay permiso".
- **En inglés.** Con Toma en inglés (Ajustes del Sistema ▸ General ▸ Idioma y región ▸ Apps): Export As, MP4 Video, Animated GIF, Range, Whole Video, Between the Marks, Size, Light, Balanced, High, Dithering, Loop Forever, Actual Size, "About … · … · … frames", "GIFs have no sound." y, después de exportar, Copy.

### 3. Textos que no están en diseño §12

Las tareas tuvieron que escribir textos que la tabla de diseño §12 no trae. Están en `App/Resources/Localizable.xcstrings` con un español neutro que sigue a los de §12. Son decisiones de redacción pendientes: si alguno no suena como querés, anotar el texto que preferís en la tabla del final y un agente lo cambia (es solo el catálogo). Entre paréntesis, la tarea de origen.

**Biblioteca: errores y avisos** (37)
- «El nombre no puede tener caracteres de control.» · «El nombre es demasiado largo.» (el campo de renombrar, junto a los cuatro de §12).
- Los motivos, en minúscula, que van después de «No se pudo …: »: «ya hay un proyecto con ese nombre» · «el nombre no se puede usar» · «el nombre es demasiado largo» · «ya no está en la papelera» · «su editor tiene cambios que no se pudieron guardar» · «no se pudo guardar el cambio» · «la copia no se puede abrir» · «la copia no se puede editar» · «el disco está lleno» · «el disco es de solo lectura» · «el disco no lo permitió».
- Los dos avisos que §12 no trae: «No se pudo eliminar «%1$@»: %2$@» (§12 trae renombrar, duplicar, mover a la papelera y restaurar) y «No se pudo cambiar el formato de «%1$@»: %2$@» (el «Duplicar como»), y el sufijo «%1$@ (y %2$lld más)» cuando la acción falló en varios proyectos.
- «Rehacer» (el botón del aviso, junto a «Deshacer»).
- Las palabras de los nombres de las copias, cada una en su clave: «copia», «copia %lld», «horizontal», «vertical» y «cuadrado» (§12 trae los nombres armados: «%@ copia», «%@ copia %d»…).
- Por qué un `.toma` arrastrado a la ventana no aparece, cuatro textos: ««%@» está en una carpeta dentro de la papelera: la biblioteca no lo muestra.» · ««%@» está en una carpeta oculta: …» · ««%@» está dentro de otro proyecto: …» · ««%@» está a más de cuatro carpetas de la de proyectos: …».

**Estilos con nombre** (29)
- «No se pudo aplicar el estilo.» (un estilo que no se pudo aplicar a este proyecto) · «No se pudo importar el estilo.» (un error del disco; §12 solo trae el del archivo dañado) · «No se pudo mover el estilo a la Papelera.» · «No se pudo guardar el estilo.».
- «Administrar estilos» (el título de la hoja) · «Guardar como estilo nuevo» (el título del pedido del nombre) · «Guardar» · «Borrar…» (el elemento del menú; §8 dice «Borrar»).

**Cámara** (14 y 16)
- Los nombres de los colores del borde que §12 no trae: «Violeta», «Turquesa» y «Coral» (§12 trae Blanco, Negro y Gris; la pestaña Cámara ofrece seis colores y un selector).

### Resultados de la pasada

Una fila por comprobación; anotar la fecha, la versión exacta de macOS y lo que se vio (o el texto que preferís, en la comprobación 3 de arriba).

| Comprobación | Fecha | macOS | Resultado |
|---|---|---|---|
| 0. Preparación: la copia de 1b guardada antes, copia de prueba (firmada o ad hoc), permisos | pendiente | pendiente | pendiente |
| 1. Recorrido completo (§16.2): una toma con los cinco layouts y sus transiciones, exportada y comparada con la vista previa; «Duplicar como 9:16»; espejo, borde y sombra; la biblioteca con los proyectos propios; Otros lugares y un disco externo; un GIF; un proyecto de 1b; estilos; accesibilidad; las metas de §15 | pendiente | pendiente | pendiente |
| 2. Un proyecto de 1b abierto en 1c: igual que en 1b, sin escribir; la copia de 1b lo abre hasta que se edita en 1c; deshacer hasta el final | pendiente | pendiente | pendiente |
| 2. Estilos con nombre: la fila Estilo, guardar, aplicar, marcar y grabar, actualizar, administrar, imagen perdida, mandarlo a otra Mac, «Aplicar el estilo por defecto» | pendiente | pendiente | pendiente |
| 2. La pestaña Cámara: los cinco mosaicos en 16:9, 9:16 y 1:1, Burbuja → Dividida → Burbuja, «Se edita», borrar todos los cambios, aspecto | pendiente | pendiente | pendiente |
| 2. La pista Cámara: crear, mover, recortar y borrar bloques, el menú contextual, los rombos atenuados, la cámara ilegible, VoiceOver | pendiente | pendiente | pendiente |
| 2. La vista previa con la división y los atajos: la manija, volver a Automático, la burbuja de un bloque, el recuadro del zoom, ⌥1 a ⌥5 | pendiente | pendiente | pendiente |
| 2. El aspecto de la cámara en el video: espejo, borde y sombra a 1080p y a 4K, la burbuja en 9:16, un proyecto de 1b | pendiente | pendiente | pendiente |
| 2. La ventana de la biblioteca (1 000 proyectos): desplazar a 120 Hz, memoria ≤ 250 MB, teclado, lista, secciones vacías, VoiceOver, Reducir movimiento, la toma en curso | pendiente | pendiente | pendiente |
| 2. La biblioteca en una Mac tranquila: `first-frame` ≤ 150 ms y `longest-main-wait` ≤ 4 ms (seis corridas); el agente midió 168 a 197 ms y 4,3 a 7,1 ms con la Mac cargada | pendiente | pendiente | pendiente |
| 2. Abrir la biblioteca: el menú del ícono, el botón de la isla, ⇧⌘L, reabrir desde el Launchpad, grabar con la biblioteca abierta, «Reiniciar toma», abrir un `.toma` de afuera | pendiente | pendiente | pendiente |
| 2. Las acciones de la biblioteca: el menú contextual, favoritos, renombrar, duplicar y «Duplicar como», deshacer, la papelera, vaciar, Otros lugares, un disco externo, ⌘Q mientras se duplica, VoiceOver | pendiente | pendiente | pendiente |
| 2. Renombrar y duplicar desde el editor, y la papelera solo para ver: el título del editor, el menú Archivo, abrir de la papelera, Deshacer de la biblioteca, «Sin terminar», cerrar un editor que exporta | pendiente | pendiente | pendiente |
| 2. La hoja de exportar: GIF, rango y Copiar: marcas, la primera estimación y la vista previa a tiempo (≤ 1,5 s en la M1, ≤ 0,6 s en la del dueño), tamaños, avisos, un rango de menos de un cuadro, el MP4 de un rango, lo que recuerda, Tamaño real, VoiceOver, cerrar y salir, disco lleno, en inglés | pendiente | pendiente | pendiente |
| 2. El GIF: el corpus (opcional, contra gifski) | pendiente | pendiente | pendiente |
| 2. Las disposiciones al reproducir, al exportar y en el sonido (Task 13): transiciones como las de la burbuja, clics que no se ven no suenan, la meta del piso en la M1 | pendiente | pendiente | pendiente |
| 3. Textos que no están en diseño §12: los que cambiarías | pendiente | pendiente | pendiente |

## Pendientes del dueño de la fase 2

Una sola pasada de fin de fase, contra la app de la rama `fase-2`, en orden: la preparación y el detalle por área. Cada comprobación dice qué se tiene que ver; si se ve otra cosa, anotarlo con la versión exacta de macOS. Cada tarea de la fase 2 suma sus comprobaciones al final de esta sección.

### 0. Preparación

1. **Antes de instalar la app de la fase 2, guardar un proyecto de la fase 1.** La app de la fase 1 queda comprimida en `build/fase1/Toma-fase1.zip` (para que macOS no la confunda con la de la fase 2): descomprimirla en otra carpeta (`ditto -x -k build/fase1/Toma-fase1.zip ~/Desktop/ && mv ~/Desktop/Toma.app ~/Desktop/Toma-fase1.app`) y, con ella, abrir un proyecto con cámara, editarlo (un corte y otro margen alcanzan), exportarlo y cerrarlo. Si queda alguno de 1b sin abrir en 1c, guardarlo también. Esos proyectos son los de «Un proyecto de la fase 1 abierto en la fase 2», abajo.

### 2. Detalle por área

**Un proyecto de la fase 1 abierto en la fase 2** (B2a)

Un proyecto de 1b o de 1c sigue siendo de su versión en el disco hasta que se lo edita en la fase 2: mirarlo no lo cambia.
- Con el proyecto de la preparación: abrirlo en la app de la fase 2, reproducirlo, moverse por la línea de tiempo, exportarlo sin tocar nada y cerrarlo. Se ve y se oye igual que en la fase 1. Abrirlo otra vez con `~/Desktop/Toma-fase1.app`: abre igual que antes, con sus ediciones y sin ningún aviso.
- Una toma grabada con la copia de la fase 1 y nunca abierta en el editor: abrirla en la fase 2 sin tocar nada y cerrarla. La copia de la fase 1 la sigue abriendo como una toma suya, sin aviso.
- Editarlo en la fase 2 (otro margen) y cerrarlo. Abierto con la copia de la fase 1, dice que el proyecto se editó con una versión más nueva de Toma (nunca que está dañado) y no escribe nada.
- Deshacer en la fase 2 después de esa edición: vuelve paso a paso hasta las ediciones de 1c, también un cambio de volumen o de silencio de una pista y un estilo aplicado (la pista y el estilo quedan como estaban antes de cada uno), y Rehacer las trae de vuelta en orden.

**Monitoreo de entrada** (B4a)

En la ventana de permisos, «Permitir…» de «Monitoreo de entrada» muestra el aviso del sistema; después de negarlo, «Abrir Ajustes del Sistema» lo vuelve a pedir y Toma aparece en la lista de Monitoreo de entrada.

- **iPhone o iPad por cable: descubrir y capturar** (P14; se recorre con la isla en modo iPhone de P15 y P17). Con un iPhone conectado por cable, desbloqueado y con «Confiar» tocado:
  1. El iPhone aparece en la lista del modo iPhone a los pocos segundos de abrirlo, con su nombre. En la lista de cámaras de Toma (la isla y Ajustes) nunca aparece la pantalla del iPhone, ni con el modo iPhone abierto (el iPhone como Cámara de Continuidad es otra cosa y sí puede estar).
  2. Grabar 20 s con el iPhone en vertical y un video sonando en el iPhone. En `manifest.json` del paquete: `formatVersion` 4, una pista `device` con `globalFrame` `{x: 0, y: 0}` y el tamaño en píxeles de la pantalla del iPhone (por ejemplo 1179 × 2556 en un iPhone 15), `pixelScale` 1, y una pista `deviceAudio` con el mismo `deviceUniqueID`. El primer segmento de `device` tiene exactamente ese tamaño (Información de QuickTime) y se ve fluido cuando la pantalla se mueve; el de `deviceAudio` se oye entero y en sincronía con la imagen. Si a `device` le faltan `globalFrame` y `pixelScale`, anotarlo: el iPhone no dijo su tamaño ni al empezar a grabar.
  3. Girar el iPhone a horizontal y volver a vertical durante la toma: `device` sigue en segmentos nuevos (`formatChanged`) y la toma no se corta.
  4. Desconectar el cable 10 s a mitad de la toma y volver a conectarlo: la toma sigue; las dos pistas terminan su segmento y siguen en uno nuevo del mismo iPhone. Con otro iPhone conectado mientras el primero no está, Toma no lo graba en su lugar.
- **Formatos** (I1): los siete en la barra y en Proyecto ▸ Formato; «Como la grabación» con una toma de un área ancha (el editor, la vista previa, el GIF y el MP4 salen con esa proporción).
- **Marcos de dispositivo** (I3): iPhone, iPad y MacBook, oscuro y claro, en 16:9 y en 9:16, con una toma ancha y con una vertical: bien proporcionados, el iPhone acostado con un contenido ancho, sin una línea de fondo entre la pantalla y el bisel ni entre la tapa y la base, nítidos en un export 4K; con zoom (y con su desenfoque) se mueven con la pantalla; la isla y el notch tapan el cursor, no los efectos de clic; con Pantalla dividida, el dispositivo entero en su tarjeta; la vista previa es igual al MP4.
- **Privacidad en el render** (P2; los bloques se agregan con P6). En una toma con texto chico y grande en pantalla (un correo, una clave), tapar tres partes con Desenfoque (intensidad por defecto y en 0), Pixelado y Relleno:
  1. En la vista previa y en el MP4 exportado no se lee ninguna letra de lo tapado, ni con la intensidad en 0; los bordes del rectángulo son rectos y duros, sin un halo del texto alrededor.
  2. Con un zoom de 4× que entra rápido (con desenfoque de movimiento) y con un cambio de forma de la pantalla, el rectángulo sigue pegado al mismo texto en cada cuadro, también avanzando cuadro a cuadro.
  3. En la M1: la vista previa a 1080p con ocho bloques de Desenfoque grandes y un zoom que entra rápido con desenfoque de movimiento se reproduce a 60 fps, sin cuadros salteados (en el M5 Pro, el peor cuadro de la GPU es de unos 4 ms: `docs/performance.md`, fila P2).
  5. Girar el iPhone a horizontal justo al tocar Grabar (durante la cuenta atrás): en `manifest.json`, el `globalFrame` de `device` tiene el tamaño de su primer segmento (el horizontal), no el de antes de girarlo.
  6. Con la toma grabando, abrir QuickTime Player ▸ Archivo ▸ Nueva grabación de película y elegir el iPhone (otra app toma el dispositivo). Si Toma avisa que la captura de la pantalla se interrumpió, no debe decir que se reanudó mientras QuickTime lo tenga; al cerrar QuickTime, `device` sigue en un segmento nuevo con imagen (nunca un segmento sin imagen ni un «se reanudó» sin imagen). Si Toma no se entera de nada y las dos apps graban a la vez, anotarlo.
  7. Con el permiso de Cámara negado a Toma (Ajustes del Sistema ▸ Privacidad y seguridad ▸ Cámara): si una toma de iPhone llega a intentarse, el error dice «El acceso a la cámara está desactivado.» y nunca un texto de AVFoundation.

**Grabar las teclas** (P9)

- Con Monitoreo de entrada sin pedir nunca (`tccutil reset ListenEvent dev.toma.Toma` y `defaults delete dev.toma.Toma permissionRequested.inputMonitoring`): en Ajustes ▸ Grabación, prender «Grabar las teclas para mostrarlas» muestra el aviso del sistema. Negado, debajo aparece «Monitoreo de entrada · No permitido» con «Abrir Ajustes del Sistema», que abre Ajustes en Monitoreo de entrada con Toma en la lista. Permitido allí, al volver a Toma la fila se va (si macOS pide salir y volver a abrir Toma para aplicarlo, anotarlo).
- Con la opción prendida y el permiso negado: la toma graba igual, sin pedir nada, y avisa «Las teclas no se grabaron: falta el permiso de Monitoreo de entrada.», entero en el aviso corto y en la isla abierta. El proyecto sigue en la versión 3: lo abre la app de la fase 1.
- Con el permiso: escribir en Notas y en el campo de contraseña de Safari (y en el de una contraseña de Ajustes del Sistema): solo lo de Notas queda en la toma (Cursor ▸ Teclas en pantalla ▸ Todas), ni la contraseña ni la ↩ que cierra su campo. Pausar y reanudar escribiendo: las teclas de justo después de reanudar se ven como las de antes.
- Con la distribución Español (Latinoamérica) o Español: ⌘⇧4 y ⌘⇧7 en una toma se ven «⌘ ⇧ 4» y «⌘ ⇧ 7» en Teclas en pantalla (no «$» ni «/»), y lo escrito con ⇧ en la píldora de Todas se ve como se escribió («$», «/»).
- **Cámara: fondo, encuadre y color** (I10): con la cámara real (pelo, manos, anteojos, una persona que se mueve), Desenfocado y Quitado en Burbuja y en Pantalla dividida: el borde de la persona limpio, sin halo ni escalones en un export 4K; con Quitado en Burbuja, la persona sobre la pantalla sin círculo, borde ni sombra, y en la tarjeta, con su forma y su borde sobre el fondo del proyecto. Los seis looks (Natural a Blanco y negro) con la intensidad al 100 % y al 50 %, y un `.cube` real de otra app: solo la cámara cambia de color, la pantalla queda igual. Seguir la cara con una persona que se mueve: el encuadre la sigue sin saltos. La vista previa es igual al MP4.

**Privacidad a mano** (P6)

- Privacidad: Agregar desenfoque desde la barra y desde Edición; mover y agrandar el rectángulo con zoom y sin él; mover, recortar y borrar en la pista; el export tapa lo mismo que la vista previa.
- En detalle: «Agregar desenfoque» (la barra de la línea de tiempo y Edición ▸ Agregar desenfoque) crea un bloque de 3 s desde el cabezal, aparece la pista Privacidad y la vista previa muestra un rectángulo centrado de 40 % × 20 % con 8 manijas. Arrastrar el cuerpo lo mueve 1:1 con el puntero, una esquina o un lado lo agranda; cerca de los bordes y del centro de la pantalla dibujada se pega (con una línea de acento y un toque del trackpad) y con ⌘ apretado no. Lo mismo con un zoom de 2× a 4× parado sobre el bloque, con Pantalla dividida y con Seguir el cursor del reencuadre: el rectángulo queda sobre lo que tapa el desenfoque, sin corrimiento. Soltar es un paso: Edición ▸ Deshacer «Cambiar el desenfoque».
- En la pista: dos bloques pisados se ven uno sobre otro, el más corto arriba, y el que se agarra es el de arriba; moverlo y recortarlo no frena en el otro; doble clic lleva el cabezal al bloque; el menú cambia entre Desenfoque, Pixelado y Relleno y borra; ⌫ borra los elegidos. VoiceOver lee «Desenfoque, de 0:02 a 0:05».
**Máscaras y caras con Vision** (I8; se recorre con la pestaña Cámara de I13)

- Con una toma real con cámara (una persona que se mueve, gira la cara y sale del cuadro unos segundos): con Fondo Desenfocado, en `~/Library/Caches/dev.toma.Toma/Projects/<id>/masks/<toma>/<pista>/` aparece un `…-personMask-1.mov` por segmento de la cámara. Abierto en QuickTime, dura lo mismo que el segmento, la silueta blanca sigue a la persona sin parpadear y queda negro mientras no hay nadie. Con Seguir la cara, `faces/…/…-faceTrack-1.json` tiene `face` en las muestras con la cara a la vista y no la tiene mientras la persona no está.
**Subtítulos quemados** (A8; se prenden y se eligen en la pestaña Subtítulos de A11)

En una toma transcrita en español, con Clásico, Destacado y Mínimo, en Chico y en Grande, abajo y arriba, con y sin mayúsculas: la vista previa y el MP4 exportado (1080p y 4K, 16:9 y 9:16) se ven iguales y nítidos, sin acentos, eñes ni colas cortados (Á, ñ, ¿, g, p); el contorno de Destacado es parejo en todas las letras y tamaños; la palabra que se dice se pinta de amarillo y pasa a la siguiente sin parpadear entre palabras; con zoom y su desenfoque de movimiento los subtítulos quedan quietos y nítidos. En la M1, la vista previa a 1080p con Destacado se reproduce a 60 fps sin cuadros salteados cuando cambia la palabra (fila A8 de `docs/performance.md`).

**Acelerar el tipeo** (P13)

- Edición ▸ Acelerar el tipeo… (y el menú contextual del Video) en una toma real con escritura: la ventanita ofrece 2× · 3× · 4× · 8× (3× elegido) y el resultado («Se aceleran 5 tramos: 1:23 → 0:28») coincide con lo que queda; Acelerar lo hace en un solo paso y Edición ▸ Deshacer «Acelerar el tipeo» lo deshace entero. Sin tramos de tipeo de 2 s o más dice «No hay tramos de tipeo de 2 s o más.» y Acelerar queda apagado.

**El análisis de la imagen en el editor** (I12; se recorre con la pestaña Cámara de I13)

- Con Quitado elegido, la vista previa muestra Original hasta que la pestaña llega al 100 % y después la persona sin fondo; exportar antes espera y el archivo la tiene; la vista previa del GIF también. Con la hoja de exportar en GIF abierta mientras se prepara, la vista previa del GIF se rehace sola al llegar al 100 % y muestra la persona sin fondo.
- «Cancelar la exportación» mientras espera la cámara: no aparece ningún aviso, el análisis sigue y la pestaña llega al 100 %. Exportar otra vez ya no espera.
- Con el editor abierto y la persona ya sin fondo, borrar la carpeta `masks/` de `~/Library/Caches/dev.toma.Toma/Projects/<id>/` y cambiar Fondo a Original y de nuevo a Quitado: la pestaña vuelve a preparar el recorte y la persona aparece otra vez sin fondo; exportar sin cambiar nada espera a que se regenere.

**Privacidad automática** (P7)

- Buscar datos sensibles en una toma real con un correo, una tarjeta de prueba (4242…), una clave y una videollamada: la hoja los lista enmascarados, Desenfocar los tapa en el export, se deshace en un paso y volver a buscar es instantáneo.
- En detalle: mientras busca, la pestaña muestra «Buscando… N %» con la barra y Cancelar (con otro análisis del proyecto corriendo, «En espera…»); Cancelar vuelve al botón sin dejar nada en `~/Library/Caches/dev.toma.Toma/Projects/<id>/scan/`. Cambiar de pestaña y volver mientras busca: sigue donde iba. La hoja agrupa Correos, Teléfonos, Tarjetas, Claves y tokens y Caras, cada hallazgo con su casilla marcada, su texto enmascarado («an•••@g•••.com», «•••• 4242», «sk-•••», «Cara») y su tramo; dice el límite del desplazamiento rápido; «Desenfocar N» cuenta las marcadas. Desenfocar agrega los bloques con ✦ en la pista y Edición ▸ Deshacer «Desenfocar datos sensibles» los quita todos juntos. Ver los hallazgos otra vez después de desenfocar: cada uno dice «Ya desenfocado», desmarcado, y el botón queda en «Desenfocar 0». El JSON de `scan/` no contiene el correo ni la clave enteros, y Consola (proceso Toma) tampoco.
- Con un bloque elegido: Efecto cambia entre Desenfoque, Pixelado y Relleno con el anillo que se mueve; Intensidad se arrastra con la vista previa siguiéndola y deshace en un paso; Relleno ofrece negro, blanco, gris y el selector de color; «De 0:12 a 0:15» coincide con la pista; Borrar el desenfoque lo quita. La lista de abajo elige el bloque y lleva el cabezal a él. VoiceOver lee las fichas («Efecto, Pixelado, 2 de 3») y las filas («Desenfoque, de 0:02 a 0:05»).
**Teclas en pantalla** (P11; se prenden en la pestaña Cursor de P12)

- En una toma real con teclas grabadas, con Atajos y con Todas, en Chico, Mediano y Grande y en las cuatro posiciones: la vista previa y el MP4 exportado (1080p y 4K, 16:9 y 9:16) se ven iguales y nítidos; ⌘ ⇧ ⌥ y la letra del atajo quedan alineados en las tapas y ⌃ centrado; ⌘␣, ⌘⇥ y ⌘↩ se ven del mismo grosor que las demás; la píldora crece al escribir, se corta por la izquierda con «…» y un atajo la reemplaza con un fundido cruzado, sin saltos. Con los subtítulos abajo las teclas quedan encima de ellos, también entre subtítulos. Repetirlo en macOS 15 (la fuente del sistema cambia con macOS: anotar si falta algún símbolo o se ve de otra fuente).
**El modo iPhone en la toma** (P15; se recorre con la isla en modo iPhone de P17)

- Con el permiso de Grabación de pantalla negado a Toma y el de Cámara permitido: una toma de iPhone graba igual, sin abrir la ventana de permisos. Con el de Cámara sin pedir nunca (`tccutil reset Camera dev.toma.Toma`): Grabar en modo iPhone muestra el aviso del sistema durante la cuenta atrás y, permitido, graba; negado ahí (o negado de antes), no graba nada y se abre la ventana de permisos con Cámara.
- Con «Grabar las teclas para mostrarlas» prendido y el Monitoreo de entrada negado: una toma de iPhone no avisa «Las teclas no se grabaron…» y su `events.jsonl` no tiene líneas `keyPress` ni del cursor.
- Con la cámara y el micrófono de la Mac elegidos: en `manifest.json`, las pistas `device`, `deviceAudio`, `camera` y `microphone`, en ese orden; la burbuja de la cámara se ve en la pantalla de la isla mientras graba, y «Ocultar los íconos del escritorio» no tapa el escritorio (no se graba la Mac).
**La toma de iPhone en el editor** (P16; se graba con la isla en modo iPhone de P15 y P17)

- Con un iPhone real, grabar 20 s en vertical, girarlo a horizontal a los 10 s y abrir la toma en el editor: empieza con el marco de iPhone Oscuro (Marco ▸ iPhone), sin cursor (la pestaña Cursor lo dice y sus controles quedan apagados) y sin zooms automáticos. Después del giro, la pantalla del iPhone se ve entera, achicada y centrada en el mismo marco vertical, con barras negras arriba y abajo: nada recortado ni estirado, y el marco no cambia de tamaño ni salta en el giro. Lo mismo avanzando cuadro a cuadro, arrastrando el cabezal por el giro y en el MP4 exportado (la vista previa es igual al MP4).
- Un zoom agregado a mano en la pista Zoom entra y sale sobre la pantalla del iPhone, también con el foco fijo movido.
- La pista del sonido del iPhone aparece en la línea de tiempo como «iPhone» (o «iPad»), con su botón de silencio, y en la pestaña Audio como «iPhone o iPad» con el nombre del dispositivo, volumen y silencio; el MP4 lo tiene. Con un iPad, la toma empieza con el marco de iPad; un iPhone grabado empezando en horizontal empieza con el de iPhone, acostado.

**Seguir el cursor en el render** (I5; se recorre con la pestaña Marco de I14)

- Con una toma real 16:9 en 9:16 y Seguir el cursor: la pantalla llena el lugar dentro del margen y la ventana sigue al cursor sin marear (sin saltos en los cortes ni al cambiar de clip, nunca muestra fondo fuera del contenido); con un zoom, el zoom actúa dentro de la pantalla reencuadrada; con Ventana de macOS o un dispositivo elegidos, no se dibuja ningún marco. Un clic deja su efecto sobre lo que se clicó mientras la ventana se mueve. La vista previa es igual al MP4 exportado, también en 1:1.

**La isla en modo iPhone** (P17)

- Recién abierta la app, sin nada conectado: la pestaña «iPhone o iPad» abre sin trabar la isla y muestra el cable y «Conectar el iPhone o el iPad con un cable, desbloquearlo y tocar Confiar.»; Grabar está apagado y su ayuda dice «No se eligió ningún iPhone o iPad para grabar.».
- Con la isla abierta en esa pestaña, conectar el iPhone por cable, desbloquearlo y tocar Confiar: aparece en la lista con su nombre, el ícono de iPhone y «Conectado por cable», con su animación (con Reducir movimiento, un fundido), queda elegido por ser el único y Grabar se prende. Con un iPad también conectado: su ícono es el de iPad, ninguno cambia de elegido solo y un clic elige el otro; desconectar el elegido deja elegido el que queda.
- Grabar con el micrófono y la cámara de la Mac; rotar el iPhone dos veces; desconectarlo y volver a conectarlo a mitad. El editor abre la toma con el marco de iPhone, sin cursor, cada orientación entera; una toma de iPad toma el marco de iPad; el iPhone nunca aparece en la lista de cámaras de la isla ni del editor.
- Con el permiso de Cámara sin pedir (`tccutil reset Camera dev.toma.Toma`): la columna muestra «Grabar un iPhone o un iPad necesita el permiso de Cámara.» con «Dar permiso…», que muestra el aviso del sistema con la isla debajo; permitido, la fila desaparece. Negado, «Dar permiso…» abre Ajustes del Sistema en Cámara. Ningún texto de la columna se corta.
- Con VoiceOver: cada dispositivo se lee con su nombre, «Conectado por cable» y si está elegido; el estado vacío y la fila del permiso se leen enteros.
**La pestaña Cámara: fondo, encuadre y color** (I13)

- Pestaña Cámara: el encuadre manual se arrastra y hace zoom con la rueda; importar un `.cube` 1D dice por qué no.
- En detalle, con una toma real con cámara y Espejar prendido y apagado: en Manual, la vista chica muestra el cuadro del cabezal como se ve en la vista previa (espejado igual) con el recorte en la forma de la cámara; arrastrarlo lo mueve 1:1 hacia donde va el puntero (también espejado) y la vista previa lo sigue; soltar es un paso (Edición ▸ Deshacer «Cambiar el encuadre de la cámara»). La rueda del mouse y desplazar con dos dedos sobre la vista cambian el zoom (alejar la rueda acerca), pellizcar también; desplazar el panel y pasar por encima de la vista no hace zoom. Con la vista enfocada (Tab), las flechas lo mueven y + y − cambian el zoom; VoiceOver lee «Encuadre manual, Centro: 50 % horizontal, 50 % vertical; zoom 1,4×» y lo mueve con sus acciones.
- Fondo Desenfocado o Quitado: «Preparando el recorte… N %» avanza hasta irse, y mientras tanto la cámara se ve como se grabó; Seguir la cara: «Buscando la cara… N %» con la cámara centrada mientras tanto. En una Mac sin Vision (o con el análisis fallando), el motivo aparece en su lugar.
- Color: cada mosaico muestra el cuadro del cabezal de la cámara con su look (al pausar en otro lugar, cambian). Personalizado… abre el panel de archivos solo con `.cube`; un `.cube` 1D dice «No se pudo usar el .cube. Es una LUT 1D; se necesita una 3D.», uno con filas de menos «Tiene 35.000 filas; su tamaño necesita 35.937.», una imagen renombrada a `.cube` «No es texto…»; uno bueno queda elegido (Personalizado, «El archivo .cube importado», Cambiar…) y se ve en la vista previa. Intensidad queda apagada con Natural. Con el panel en su ancho mínimo, en español ningún texto se corta.

**Voz y audio: transcribir** (A10)

- Con Transcribir automáticamente prendido y el español instalado, una toma nueva se transcribe sola al abrirla; no aparece ningún aviso de permiso de macOS; grabar mientras transcribe la frena y sigue al terminar; Transcribir de nuevo después de corregir una palabra avisa antes de reemplazar; un export con la limpieza pendiente espera y la barra lo muestra.
- En detalle: Ajustes ▸ General muestra «Transcribir automáticamente» con «Al abrir un proyecto en el editor, si su idioma está instalado.» debajo, sin cortes; apagado, abrir una toma sin transcripción no transcribe nada. Después de la transcripción automática, Edición ▸ Deshacer «Transcribir» saca la transcripción y los subtítulos en un paso. Con una palabra corregida, Transcribir de nuevo pregunta «Transcribir de nuevo reemplaza 1 palabra corregida.» (en plural con dos o más): Conservar la actual no cambia nada y Reemplazar pone la nueva. Recién elegidas la Limpieza Suave y Normalizar el volumen, exportar enseguida a MP4: el anillo de la barra sube hasta un 20 % mientras espera la limpieza y la sonoridad y sigue de ahí con el export; el archivo suena limpio y normalizado como la vista previa. Cancelar la exportación mientras espera no muestra ningún aviso y la limpieza sigue. Un GIF no espera la limpieza.

**La pestaña Marco** (I14)

- Con una toma 16:9 en 9:16, en la pestaña Marco (⌘2): elegir Ninguno, Ventana de macOS, iPhone, iPad y MacBook; cada mosaico se ve como queda (el iPhone acostado con un contenido ancho), el anillo violeta se mueve con un resorte (con Reducir movimiento, un fundido) y la vista previa cambia. Con un dispositivo, «Acabado: Oscuro / Claro» lo cambia; pasar de un dispositivo a otro conserva el acabado. Cada cambio es un deshacer.
- «Encuadre de la pantalla: Completa / Seguir el cursor»: con la toma 16:9 en 16:9 (y en «Como la grabación») Seguir el cursor está apagado y debajo dice «La grabación no es lo bastante ancha para este formato.»; en 9:16, 1:1, 4:5, 3:4 y 4:3 se puede elegir. Con Seguir el cursor, la pestaña dice «Con Seguir el cursor no se dibuja el marco.» y los mosaicos y el acabado se ven atenuados, sin marco en la vista previa; volver a Completa lo dibuja otra vez.
- Con Seguir el cursor en 9:16, cambiar el formato a 16:9: el control sigue usable para volver a Completa y dice por qué Seguir el cursor no se ofrece.
- Con una toma de iPhone: Seguir el cursor está apagado y dice «Un iPhone o un iPad no tiene cursor que seguir.».
- Con el panel en su ancho mínimo, en español: ningún texto de la pestaña se corta. Con VoiceOver: cada mosaico se lee «Marco, iPhone, 3 de 5» y si está elegido; el control de Encuadre apagado lee su motivo.
**Voz y audio: editar por el texto** (A11)

- En una toma real en español: el texto tiene los párrafos en las pausas; borrar tres palabras corta el video con la pausa de antes y sin la de después; Restaurar las devuelve; corregir una palabra cambia el subtítulo y no el audio; Quitar muletillas y Acortar pausas son un ⌘Z cada uno; Empezar un subtítulo acá parte el subtítulo; Exportar subtítulos en .srt y .vtt abre en QuickTime/VLC con los mismos tiempos que los quemados; los tres estilos se ven bien en 16:9 y 9:16.
- En detalle, pestaña Subtítulos (⌘7) con la ventana del tamaño de siempre y el panel en su ancho mínimo, en español ningún texto se corta. Sin transcripción: «Transcribir el audio para editar el video por su texto…», Idioma con «En esta Mac» y «Para descargar», Transcribir (o «Descargar el idioma» con su porcentaje); al transcribir, «Transcribiendo… N %» y Cancelar. Con transcripción, el texto llena el alto que queda y, debajo, se ve el título «Estilo» plegado. Un clic en una palabra lleva el cabezal a ella; arrastrar y ⇧clic eligen palabras enteras (en el violeta de la marca); ⌫ las corta: quedan tachadas y atenuadas, elegidas, con Restaurar debajo. Doble clic (o Retorno con una palabra elegida) la edita en un campo encima: Retorno la corrige, Esc la deja como estaba. El menú contextual tiene Cortar, Restaurar, Corregir la palabra… y Empezar un subtítulo acá (con su marca; la palabra lleva una barrita violeta delante). Al reproducir, la palabra que suena se marca y el texto la sigue deslizándose; con la rueda o el trackpad se deja de seguir hasta que la palabra vuelve a verse o se reproduce de nuevo; con Reducir movimiento salta en vez de deslizarse. Con el puntero sobre Quitar muletillas se tiñen las muletillas; sobre Acortar pausas aparece un «‖» en cada pausa; el menú «> 1 s» cambia el umbral y el número. Espacio reproduce y pausa con el texto enfocado; ⌘F busca en el texto. En un texto de una hora (unas 9000 palabras) hacer clic, elegir y borrar no se traba. Estilo: Mostrar los subtítulos, los tres mosaicos, Tamaño, Posición, Mayúsculas, Resaltar y el color (las muestras y el panel de colores: arrastrar en el panel se ve en la vista previa y es un solo ⌘Z). VoiceOver lee «Transcripción» con el texto y ofrece Cortar, Restaurar, Corregir la palabra… y Empezar un subtítulo acá como acciones. Archivo ▸ Exportar subtítulos… está deshabilitado sin transcripción; con ella, el panel de guardar propone el nombre del proyecto y Formato SubRip (.srt) o WebVTT (.vtt), y recuerda el último. En macOS 15, la pestaña dice «La transcripción necesita macOS 26.» y nada más de la voz.

## Pendientes del dueño de la fase 3

Una sola pasada de fin de fase, contra la app de la rama `fase-3`, en orden: la preparación y el detalle por área. Cada comprobación dice qué se tiene que ver; si se ve otra cosa, anotarlo con la versión exacta de macOS. Cada tarea de la fase 3 suma sus comprobaciones al final de esta sección.

### 0. Preparación

1. **Antes de instalar la app de la fase 3, guardar un proyecto de la fase 2.** Con la app de la fase 2 (`build/fase2/Toma.app`), abrir un proyecto con cámara, editarlo (un corte, otro margen y el volumen de una pista alcanzan), exportarlo y cerrarlo. Si queda alguno de la fase 1 (1b o 1c) sin abrir en la fase 2, guardarlo también. Esos proyectos son los de «Un proyecto de la fase 1 o 2 abierto en la fase 3», abajo.

### 2. Detalle por área

**Un proyecto de la fase 1 o 2 abierto en la fase 3** (B2)

Un proyecto de la fase 1 o 2 sigue siendo de su versión en el disco hasta que se lo edita en la fase 3: mirarlo no lo cambia.
- Con el proyecto de la preparación: abrirlo en la app de la fase 3, reproducirlo, moverse por la línea de tiempo, exportarlo sin tocar nada y cerrarlo. Se ve y se oye igual que en la fase 2. Abrirlo otra vez con `build/fase2/Toma.app`: abre igual que antes, con sus ediciones y sin ningún aviso.
- Abrirlo en la app de la fase 3 y deshacer (⌘Z) hasta el principio: cada paso de la fase 2 se deshace en orden (el volumen, el margen, el corte) y Edición ▸ Deshacer nombra cada uno. Rehacer los devuelve. Con un paso nuevo (otro margen), cerrar y abrirlo con la app de la fase 2: dice que es de una versión más nueva y no lo cambia.

**El editor de la fase 3, vacío** (B11)

- Con el proyecto de la preparación abierto, en español, con la ventana del tamaño de siempre: la barra del editor muestra, antes del botón del panel, los menús Tomas (una pila) y Marcadores (un marcador), los dos atenuados y sin abrirse; con el puntero encima dicen «Tomas» y «Marcadores». La barra no corta el nombre del proyecto ni Exportar. Lo mismo en macOS 15.
- El panel tiene nueve pestañas; la última (⌘9, un garabato, «Anotaciones») está vacía. ⌘1 a ⌘8 siguen mostrando las de antes, y al cerrar y abrir el proyecto en Anotaciones vuelve a ella.
- La línea de tiempo tiene las mismas filas, en el mismo orden y con los mismos nombres que en la fase 2: ninguna fila de Anotaciones, Clips importados ni Música. El volumen y Silenciar de cada pista, en el panel y en la cabecera de la fila, hacen lo mismo que en la fase 2 y son un solo ⌘Z.
**Una pista por app** (U9)

- En la isla, Audio del sistema ▸ Por app ▸ «Elegir apps…»: el menú se titula «Una pista por app». Con 8 apps elegidas, arriba dice «Hasta 8 apps» y las demás están apagadas (las elegidas se pueden sacar). Con el panel en español, ningún texto se corta.
- Elegir Safari y Música en Por app y grabar 20 s con las dos sonando: en `manifest.json` de la toma hay dos pistas, `system-audio-com-apple-Safari` y `system-audio-com-apple-Music`, cada una con su `appBundleID` y su `appName` («Safari», «Música» o «Music» según el idioma del sistema), y cada una tiene solo lo suyo: en el editor, silenciar una calla solo esa app.
- Con Música cerrada al empezar y abierta a los 10 s: su pista está en el manifiesto desde el principio y suena en silencio hasta que Música abre; después graba su sonido.
- Ese proyecto lo abre la app de la fase 2 (`build/fase2/Toma.app`) sin aviso y mezcla las dos apps.
- «Todo» sigue en una sola pista `system-audio`; Por app sin apps elegidas graba una pista `system-audio` en silencio, como en la fase 2.
**Regrabar en el mismo paquete** (T6, con «Regrabar desde acá» de T12)

Antes de cada caso, en Finder, «Mostrar contenido del paquete» del proyecto y anotar las carpetas de `takes/`. Después de cada uno, siguen todas, y la toma nueva (si la hay) es la carpeta siguiente; nunca aparece un proyecto nuevo en la carpeta de Toma ni en su `Trash/`.
- Con cámara y micrófono reales, regrabar, hablar unos segundos y parar con «Al parar» en «Quedarse acá»: el editor vuelve igual (no se abre otra ventana) con la toma nueva desde el cursor; se oye la voz nueva.
- Regrabar y, en la cuenta regresiva, cancelarla: el editor vuelve sin cambios y `takes/` no cambió. Regrabar, grabar unos segundos y «Reiniciar»: graba otra vez en el mismo proyecto; al parar quedan las dos tomas nuevas en `takes/`, la del reinicio sin usar en el menú Tomas.
- Desenchufar la cámara elegida justo antes de que termine la cuenta regresiva (o elegir una que falle): graba sin cámara, con el aviso, en el mismo proyecto. Con una toma regrabándose, salir de la app (⌘Q): al abrirla otra vez el proyecto tiene la toma, y nada se perdió.
**Filas de audio** (U11)

Con una toma con micrófono y dos apps en Por app (Safari y Música, por ejemplo), partida en dos clips (C en la mitad), en claro y en oscuro.
- Las cabeceras de las apps dicen su nombre entero con su ícono («Safari», «Música»); el panel ▸ Audio las titula igual. Cada fila de audio tiene Silenciar y Solo (una «S»); Clips importados y Música, si están, solo Solo. Nada se corta en español.
- Solo en el micrófono: se oye solo él, las otras filas se ven atenuadas y la música (si hay) sigue bajando cuando se habla como sin el solo. Dos solos a la vez se oyen los dos. Prender y apagar el solo reproduciendo cambia lo que se oye enseguida. Exportar con un solo prendido exporta todo. Al cerrar y abrir el proyecto, ningún solo queda prendido.
- Arrastrar de lado sobre la onda del micrófono marca un tramo punteado con la cápsula «0 dB»; Esc o un clic afuera lo sacan sin cambiar nada (Edición ▸ Deshacer no tiene un paso nuevo). Subir la línea dentro del tramo lo crea (un ⌘Z) y la cápsula sigue el valor: a +6 dB se oye más fuerte con fundidos suaves, sin clic; bajarla del todo dice «−∞ dB» y calla. Doble clic en la cápsula y escribir «-12» lo pone a −12 dB. Los bordes del tramo se arrastran (el cursor cambia); un clic lo selecciona y ⌫ o «Borrar el tramo» (menú contextual) lo borran.
- Fuera de los tramos, arrastrar la línea cambia el volumen de toda la fila (llega a +6 dB y se imanta a 0 dB), igual que el control de Volumen del panel.
- ⌥ y arrastrar en el borde entre los dos clips sobre una fila de audio: hacia la izquierda la muesca dice «J» y se oye antes el clip que viene; hacia la derecha dice «L» y sigue el que se fue; la etiqueta dice «Corte J · 0,30 s». La imagen corta donde cortaba y la cámara también. Cerca del corte de la imagen se imanta a 0; no pasa de la mitad del clip más corto. Doble clic en la muesca o «Restablecer el corte del audio» lo vuelve a 0; ⌘Z deshace cada cambio.
- Con VoiceOver, un tramo se lee «Volumen del tramo, −6 dB, de 0:01 a 0:03» con la acción Borrar el tramo, y un corte movido «Corte del audio 0,30 s antes» con Restablecer el corte del audio; al soltar un corte J o L lo anuncia.

**Escuchar Calma, Piano y Brisa** (U2)

La vara del agente fueron las medidas (sonoridad, pico, costura, mono, graves y agudos, la escala y las frases de cada tema); el oído es del dueño. Calma es ambiental en re lidio (pads anchos que cambian cada 2 compases, un bajo suave, una campana al empezar cada frase de 8 compases, reverb larga); Piano, un piano de fieltro solo en la menor y do mayor (acordes partidos en la izquierda, una melodía simple en frases de 8 compases); Brisa, una guitarra de nylon en arpegios en sol mayor con un bajo cálido, un shaker suave en las frases del medio y una melodía pulsada.
- En la app, en un proyecto de más de 4 min con voz, Audio ▸ Agregar música… y cada uno de los tres, entero y dos vueltas seguidas, con auriculares y con los parlantes de la Mac: suena musical y en su estilo, no cansa en la segunda vuelta, la vuelta no se oye (ni un clic, ni la reverb que se corta, ni un salto de volumen; en Brisa la vuelta cae dentro del rasguido que abre la estrofa y el bajo entra un poco antes), nada satura ni zumba (tampoco los graves de Calma en los parlantes).
- Debajo de la voz, a −14 dB y con «Bajar la música cuando se habla» prendido, ninguno tapa la voz.
- Anotar el que no convence y por qué (un instrumento, el tempo, una parte que cansa, la campana de Calma, el ataque de la guitarra de Brisa): se cambia antes del merge a `main` (decisión 4 del plan 3c); después del merge, otro sonido es `music-2`.
- Sin la app: `swift run -c release --package-path Packages/RecorderKit recorder-dev music --out /tmp/toma-music --theme piano` y `afplay /tmp/toma-music/piano.caf` (`docs/music.md`, «Escucharlos»); `afplay` toca una vuelta sola.

**Escuchar Foco, Impulso y Pulso** (U3)

La vara del agente fueron las medidas (sonoridad, pico, costura, mono, graves y agudos, la escala y las frases de cada tema, el bombo en su lugar y el swing de Foco); el oído es del dueño. Foco es lo-fi a 80 BPM en do mayor (un piano eléctrico en acordes de séptima y novena arpegiados, un bajo redondo, una batería con los 16avos pares atrasados, el crujido de un disco, un pad oscuro y una guitarra de nylon que canta en cuatro de sus cinco frases; la cuarta frase descansa sin bombo); Impulso, pop alegre a 112 BPM en mi mayor (bombo en negras, palmas en 2 y 4, bajo en corcheas, un pluck con el gancho en las estrofas y la melodía en los estribillos, punteos apagados a contratiempo, un pad en los estribillos y un puente con arpegios); Pulso, electrónica a 128 BPM en fa sostenido menor (un arpegio de sierras filtradas en 16avos, bombo en negras con todo lo demás bombeando en cada tiempo, bajo a contratiempo, un pad y una melodía que vuelven a entrar después de cada bombo, retardo de corchea con puntillo, un corte sin bombo en la quinta frase y un redoble de caja antes de la séptima).
- En la app, en un proyecto de más de 4 min con voz, Audio ▸ Agregar música… y cada uno de los tres, entero y dos vueltas seguidas, con auriculares y con los parlantes de la Mac: suena musical y en su estilo, no cansa en la segunda vuelta, la vuelta no se oye y el ritmo no se tropieza en ella (en los tres la vuelta es un anticipo: el acorde del compás 1, con su bajo, entra en el «y» del 4 del último compás y queda sonando sobre el 1, que no lleva bombo —en Impulso lo marca un platillo suave— y el bombo vuelve enseguida), nada satura ni zumba (tampoco el bombo ni el bajo en los parlantes). En Foco el swing se siente suelto, no torcido; en Pulso el bombeo se oye en cada tiempo y no marea.
- Debajo de la voz, a −14 dB y con «Bajar la música cuando se habla» prendido, ninguno tapa la voz: ni la melodía de Impulso ni la de Pulso, y el bombo tampoco.
- Anotar el que no convence y por qué (un instrumento, el tempo, una parte que cansa, el crujido de Foco, el bombeo de Pulso, el anticipo de la vuelta): se cambia antes del merge a `main` (decisión 4 del plan 3c); después del merge, otro sonido es `music-2`.
- Sin la app: `swift run -c release --package-path Packages/RecorderKit recorder-dev music --out /tmp/toma-music --theme focus` (o `drive`, `pulse`) y `afplay /tmp/toma-music/focus.caf` (`docs/music.md`, «Escucharlos»); `afplay` toca una vuelta sola.

**La voz con una pista por app** (T7)

- Grabar 30 s sin micrófono, Por app con Música (sonando todo el tiempo, con una canción con voz) y Safari con un video de alguien hablando la mitad del tiempo, y transcribir: el texto es lo que dice la persona del video, no la letra de la canción, aunque Música esté primera en el manifiesto. Con el micrófono prendido se transcribe el micrófono, como en la fase 2.

**La pista Anotaciones** (A12)

- Anotaciones: en la pista, mover y recortar una pegada a la grabación a través de un corte y una de la salida; dos que se pisan van en sublíneas; borrar con ⌫ y desde el menú; VoiceOver lee cada bloque.
- Con el proyecto de la vitrina (`TOMA_SHOWCASE_P3_ANNOTATIONS=track scripts/ui-shots.sh build/shots/a12 editor <proyecto>`, en oscuro y en claro, Ajustes ▸ Apariencia): debajo de Video, la fila Anotaciones con la barra naranja fina arriba (Todo el video), «Hola» y «Flecha» en dos sublíneas, «Paso 1» y «Forma»; la flecha elegida con el borde violeta y el cursor de reproducción adentro; un alfiler en las pegadas a la grabación (no en «Forma»); ningún texto cortado en español. El agente no pudo capturar la pantalla (estaba bloqueada): vio la fila dibujada desde sus capas (`TOMA_SHOWCASE_P3_TIMELINE_PNG`).
- Con el puntero en el borde de un bloque, el cursor de cambiar el ancho; en la barra de Todo el video, nunca (no se mueve ni se recorta). Doble clic en un bloque lo elige y lleva el cursor de reproducción adonde se ve entero. El menú de un bloque: Traer adelante, Enviar atrás, Traer al frente y Enviar al fondo (apagados donde no cambian nada o con varias elegidas), Duplicar y Borrar la anotación; cada uno es un solo ⌘Z con su nombre.
Una sola pasada de fin de fase, contra la app de la rama `fase-3`. Cada comprobación dice qué se tiene que ver; si se ve otra cosa, anotarlo con la versión exacta de macOS. Cada tarea de la fase 3 suma sus comprobaciones al final de esta sección.

**Seguir la voz: el motor en vivo** (T5)

- En Toma.app (macOS 26), con el teleprompter en Seguir la voz, grabar leyendo el guion en español con el micrófono de siempre. No aparece ningún aviso de permiso de macOS (ni de reconocimiento de voz ni de dictado): los agentes no lo pueden comprobar, heredan los permisos de la app que los lanzó. Con el modelo de dictado del español en la Mac (en la Mac de desarrollo ya estaban es-MX y es-ES), el guion avanza menos de un segundo después de cada palabra (el agente midió 0,4 s); sin él, con el de la transcripción, hasta un segundo y medio. Después, la toma suena entera: el micrófono no pierde nada mientras se lo escucha. Si macOS pide un permiso o el guion no se mueve, anotarlo con el idioma.
- Con el dictado (el modelo de dictado del español en la Mac), leer un guion de cinco minutos o más de corrido, con dos o tres pausas largas en el medio (de 15 a 30 s, como para pensar o tomar agua) y alguna frase que se repite o se improvisa: después de cada pausa el guion sigue con la palabra siguiente, sin quedarse quieto ni saltar; a los cinco minutos sigue tan rápido como al principio. Si deja de seguir después de una pausa o pasado un tiempo, anotar cuánto duró la pausa y en qué minuto.

**Placas de título** (A8)

- Con una placa de cada estilo (Centrado, A la izquierda, Grande, Mínimo) y cada fondo (el del proyecto, un color, el cuadro desenfocado), en 16:9 y en 9:16, apenas la pestaña Anotaciones permita agregarlas (A14): se ven como dice `docs/format/README.md` («Las placas»), sin un texto cortado ni una palabra partida; la vista previa reproduciendo y el export a 4K muestran la misma placa, con el fundido de 0,3 s contra el último cuadro del clip de antes y el primero del de después, quietos. Con el cuadro desenfocado sobre un tramo con un bloque de privacidad, nada de lo que el bloque esconde se ve nítido durante la placa ni su fundido.

**La voz y el texto con varias tomas** (T9)

Con macOS 26, el modelo del idioma instalado y Ajustes ▸ General ▸ «Transcribir automáticamente» prendido, en español.
- Un proyecto de dos tomas sin transcripción (la segunda agregada desde el menú Tomas), Subtítulos ▸ Transcribir: dice «Transcribiendo 1 de 2…» y después «Transcribiendo 2 de 2…», la barra avanza sobre las dos, el texto de la primera toma aparece apenas termina y el de la segunda debajo, en un párrafo nuevo, sin que se corte ningún texto de la pestaña. Cancelar a mitad de la segunda: la primera queda transcrita y la segunda sin palabras.
- Corregir una palabra de la primera toma y regrabar una tercera desde el final (Regrabar desde acá, ⇧⌘R): al volver al editor la tercera se transcribe sola («Transcribiendo…»), sin preguntar, y la corrección de la primera sigue. Transcribir otra vez: pregunta solo por las correcciones de las tomas que se vuelven a oír («Transcribir de nuevo reemplaza 1 palabra corregida.») y, con «Conservar la actual», esa toma no cambia.
- En el texto, borrar con ⌫ unas palabras de la segunda toma y Restaurarlas: vuelven exactas (se oyen y se ven como antes) y un ⌘Z deshace cada paso; lo mismo con una selección que toma el final de la primera y el principio de la segunda.
- Cámara ▸ Ocultar en los silencios con dos tomas transcritas: bloques Solo pantalla en las pausas de las dos, en un solo ⌘Z. Sin transcripción (o con una toma sin transcribir), los silencios salen del micrófono de cada toma, y una pausa que cruza el corte entre tomas es un solo bloque.
- Edición ▸ Acelerar el tipeo… con tipeo en las dos tomas: la cuenta de tramos suma los de las dos, y Acelerar los acelera en las dos en un solo ⌘Z; con una toma, lo mismo que en la fase 2.

**Congelados, placas y clips en la pista Video** (A15)

- Pista Video: estirar un congelado y una placa, recortar un clip importado, soltar un `.mov` entre dos clips; deshacer cada uno.
- En detalle: el menú de un tramo (clic derecho) tiene Congelar cuadro y Agregar placa, en el punto del clic; el congelado repite su cuadro a lo largo con un copo de nieve, la placa es índigo con su título («Título») y un ícono de texto. Su borde derecho cambia el largo (0,1 a 60 s, con la etiqueta «+0,70 s · 0:12,70»); el izquierdo no (el cursor no cambia); Duración… pide los segundos («2,5»). Un clip importado muestra los cuadros de su archivo con una tira de película; sus dos bordes recortan el archivo y nunca pasan de su principio ni de su final.
- Arrastrar un `.mov` (o `.mp4`, `.m4v`) desde Finder sobre la fila Video: una línea violeta marca el borde del clip más cercano; al soltar dice «Importando «nombre»…» abajo a la izquierda mientras lo copia (con un archivo de varios GB la línea de tiempo y la vista previa siguen respondiendo) y entra ahí, elegido, sin partir nada. Un `.png` o dos archivos a la vez no se aceptan; un `.mov` que no se reproduce dice «No se pudo abrir el archivo.».
- VoiceOver lee «Placa «Intro», 3 s», «Cuadro congelado, 2 s» y «Clip importado, 4,5 s», con la acción Borrar.
- Con el proyecto de la vitrina (`TOMA_SHOWCASE_P3_ANNOTATIONS=content scripts/ui-shots.sh build/shots/a15 editor <proyecto>`, en oscuro y en claro): «Intro» al principio, el congelado elegido a los 6 s y la toma importada como clip al final, los tres distintos de un tramo de la toma; ningún texto cortado en español. El agente no pudo capturar la pantalla (estaba bloqueada): vio la fila dibujada desde sus capas (`TOMA_SHOWCASE_P3_TIMELINE_PNG`).

**La edición con varias tomas** (T8, con la app de T10)

- En un proyecto de dos tomas (la segunda agregada con Tomas ▸ «Agregar al final» o regrabada) en «Como la grabación», con la segunda grabada en otra pantalla de otra proporción (la de la MacBook y un monitor 16:9): la vista previa, el MP4 y el GIF tienen la forma de la pantalla de la toma del primer clip; en el tramo de la otra toma su pantalla entra entera, centrada, y un zoom con foco fijo, el cursor y la burbuja caen donde apuntan, sin correrse a un costado. Mover al principio un clip de la otra toma cambia la forma de las tres a la suya.
- Con las dos tomas en la secuencia: Regenerar los zooms automáticos y Seguir el cursor cambian los bloques y las pantallas de las dos, y dejan los del usuario; Aplicar un estilo (y el estilo por defecto) cambia el estilo del proyecto y vuelve a planear los zooms de las dos; con la cámara en Fondo borroso en las dos, la tarjeta de la Biblioteca muestra la burbuja sin el cuarto y dice que el proyecto tiene cámara aunque solo la tenga la segunda.

**Las anotaciones dibujadas** (A6)

- Exportar en 4K un proyecto con un texto de cada estilo (Simple, Etiqueta, Tercio inferior y Título), una flecha curva, una forma, un globo y un paso, unos pegados a la grabación con un zoom de 2× que entra y otros de la salida: en el video los textos y los trazos se ven nítidos (sin bordes borrosos ni escalones) en reposo y mientras el zoom entra, los textos se cortan en las mismas palabras que en la vista previa, y la punta de cada flecha pegada sigue sobre el mismo botón durante todo el zoom.
- En la Mac base (M1), reproducir la vista previa en 1080p con diez anotaciones a la vista (y una flecha y una forma que se trazan al entrar): sigue a 60 fps, sin saltos cuando aparecen todas juntas.

**Capítulos en el archivo** (T2, con la hoja de export de T11)

- Con dos marcadores con nombre («Demo» a los 10 s y «Configuración ✨» a los 20 s), exportar un MP4 (H.264) y un MOV (ProRes 422) con «Capítulos en el archivo» prendido y abrirlos en QuickTime Player: su lista de capítulos tiene «Introducción» (o «Intro» con la app en inglés) en 0:00, «Demo» en 0:10 y «Configuración ✨» en 0:20, con los acentos y el emoji bien; elegir uno salta ahí. El video no muestra ningún texto encima. Lo mismo con macOS en inglés y la app en español.
- Exportar el rango de 0:15 a 0:30: la lista empieza con «Demo» en 0:00 y sigue con «Configuración ✨» en 0:05. Con «Capítulos en el archivo» apagado, QuickTime no muestra capítulos.

**La edición, la vista previa y la línea de tiempo con varias tomas** (T10)

En un proyecto de dos tomas con cámara y micrófono en las dos (la segunda agregada con Tomas ▸ «Agregar al final», o con `TOMA_SHOWCASE_P3_TAKES=use` sobre un paquete de `recorder-dev synth-record --into`).
- Pista Video: los tramos de la segunda toma muestran sus propias miniaturas (no las de la primera en el mismo instante) y la fila del micrófono dibuja la onda de cada toma bajo su clip; al agregar la segunda toma al final, sus miniaturas y su onda aparecen solas en uno o dos segundos y se la oye en la vista previa sin cerrar el proyecto.
- Recortar con el mouse los dos bordes de un clip de la segunda toma: llegan hasta el principio y el final de esa toma (no de la primera) y nunca se cruzan con otro tramo de ella; con el cursor en ese clip, ⌥[ y ⌥] recortan hasta el cursor; ⌘Z deshace cada uno.
- Zoom ▸ Regenerar los zooms automáticos y, en el menú de la pista Pantalla, «Seguir al cursor»: cambian los bloques y las pantallas de las dos tomas en un solo ⌘Z. El menú de un tramo de la pista Pantalla ofrece «Mostrar «…»» con las pantallas de la toma de ese tramo.
- Con el cursor en la segunda toma y en pausa: la burbuja de la cámara que se arrastra en la vista previa es la de esa toma (en su lugar, con su tamaño) y moverla la deja donde se suelta; con un zoom de foco fijo elegido, su recuadro cae sobre la pantalla de la toma del zoom; un bloque de privacidad de la segunda toma se edita sobre su pantalla. La pestaña Cámara muestra el cuadro de la cámara de la segunda toma en ese instante, y la lista de cambios dice «oculto por el bloque…» de los de esa toma.
- Aplicar un estilo con las dos tomas: el estilo es del proyecto y los zooms automáticos de las dos se vuelven a planear. Las pestañas Cámara, Cursor, Zoom y Teclas en pantalla se ofrecen si alguna de las tomas tiene cámara, la forma del cursor, clics o teclas; Cursor dice «Un iPhone o un iPad no tiene cursor…» solo si las dos son de un iPhone o iPad.
- Exportar con la segunda grabada a más resolución que la primera: la hoja de export no marca como «más que lo grabado» una resolución que la segunda tiene; si a una parte de la segunda le falta el audio o la cámara, el aviso del final lo cuenta.
- Con una sola toma, todo lo de arriba se comporta como en la fase 2.
- El agente no pudo capturar la pantalla (estaba bloqueada): vio la línea de tiempo y la burbuja dibujadas desde sus capas (`TOMA_SHOWCASE_P3_TAKES=use` con `TOMA_SHOWCASE_P3_TIMELINE_PNG`, `TOMA_SHOWCASE_PANEL_PNG` y `TOMA_SHOWCASE_PLAYHEAD` en la segunda toma); la imagen de la cámara de la pestaña Cámara no sale en esa captura: mirarla en la app.

**La pestaña y la pista Zoom: Resaltar, Atenuar y Lupa** (Z5)

- Con una grabación real y los zooms automáticos en Lupa (panel ▸ Zoom, «Modo» en la sección del zoom automático): la lente sigue al cursor sin marear y su borde de vidrio (el anillo y la sombra) se ve bien sobre fondos claros y oscuros.
- Resaltar y Atenuar en un video 4K se ven igual en la vista previa y en el archivo exportado: el mismo recuadro alrededor del foco, el mismo oscurecido (y en Atenuar el mismo desenfoque), sin un destello al entrar ni al salir.
- Recortar un zoom automático en Lupa (arrastrar un borde) lo deja en Lupa: pasa a ser del usuario (pierde el tinte claro) y conserva el ícono de la lupa. Lo mismo al moverlo o cambiarle la profundidad.
- Cambiar el «Modo» de los automáticos y deshacer (⌘Z) vuelve al de antes en un solo paso, y Edición ▸ Deshacer lo nombra. Cambiarlo justo después de mover «Profundidad» (mientras se vuelven a planear) no se pierde cuando el plan termina.
- VoiceOver lee el modo de cada bloque de la pista: «Zoom de 2×, Lupa, de 0:07 a 0:09» y «Zoom automático de 2×, Resaltar, de 0:10 a 0:12»; uno Clásico se lee como en la fase 2.
- La pestaña, en español, en oscuro y en claro: en «Zoom seleccionado», «Modo» es un menú con los cuatro (Clásico, Resaltar, Atenuar, Lupa), cada uno con su ícono; en Lupa aparecen «Tamaño de la lupa» (de 6 % a 40 %, 16 % por defecto) y «Forma» (Círculo o Rectángulo redondeado) con un fundido que sube un poco (con Reducir movimiento, solo el fundido), y se van al elegir otro modo. Con el zoom automático apagado, su «Modo» está atenuado. Ningún texto cortado. El agente no pudo capturar la pantalla (estaba bloqueada): vio la pestaña dibujada desde sus vistas (`TOMA_SHOWCASE_P3_CALMZOOM=loupe-rect` con `TOMA_SHOWCASE_PANEL_PNG`), sin el aspecto real de los menús ni sus íconos.
- La pista con el proyecto de la vitrina (`TOMA_SHOWCASE_P3_CALMZOOM=track scripts/ui-shots.sh build/shots/z5 editor <proyecto>`, en oscuro y en claro): un bloque Clásico sin ícono, uno con el resaltador (Resaltar), uno con el sol chico (Atenuar), uno con la lupa (elegido) y, al final, el automático más claro con la lupa. El agente la vio dibujada desde sus capas (`TOMA_SHOWCASE_P3_TIMELINE_PNG`).

**Música** (U12)

- Pestaña Audio ▸ Música ▸ Agregar música…: la lista tiene Calma, Foco, Impulso, Piano, Pulso y Brisa, cada uno con su estilo y 2:00. Reproducir cada uno y Parar; tocar otro corta el anterior, la vista previa del editor se pausa y darle Reproducir al editor corta el tema; cerrar la lista lo corta. Un tema que no está en `~/Library/Caches/dev.toma.Toma/Music/music-1/` dice «Preparando…» antes de sonar: en la app de Release menos de 3 s; **en una compilación Debug (`make build`) sintetizar un tema tarda de 27 a 123 s** (la barra se mueve sin porcentaje: la síntesis no avisa cuánto lleva), y mientras tanto el editor, la línea de tiempo y la lista responden; Parar lo cancela.
- Elegir Foco: cubre todo el video, aparece la fila Música con «Foco» y su onda, entra en 1 s y sale en 2 s (las rampas de la línea), suena a −14 dB y baja cuando se habla; con «Bajar la música cuando se habla» apagado no baja; Cantidad, Ataque y Relajación se notan. Mientras se prepara, la fila dice «Foco · Preparando…» con la barra y la vista previa lo calla; al terminar suena sin tocar nada.
- En la fila Música: arrastrar el tema lo mueve (para en el vecino, en 0 y en el final), sus bordes lo recortan (el comienzo deja la música en su lugar), ⌥ y arrastrar desliza lo que suena debajo, la línea sube y baja el volumen (se imanta a 0 dB). Un segundo tema solo entra en un hueco de 1 s o más con el cursor ahí; sin hueco, «Agregar música…» está apagado, dice «No hay lugar para más música.» y «Reemplazar la música…» cambia el tema bajo el cursor. Clic derecho: Reemplazar la música…, Borrar la música; en un hueco, Agregar música… e Importar audio…. Con Repetir apagado y un archivo corto, la fila raya lo que queda sin sonido; con Repetir, una marca punteada en cada vuelta.
- Importar audio…: un MP3 y un WAV propios entran como «Audio importado» con su onda; arrastrar un M4A desde Finder sobre un hueco de la fila Música lo marca y al soltar entra ahí. Un archivo de más de 30 minutos dice «Se usan los primeros 30 minutos.». Un `.txt` renombrado `.mp3` dice «No se pudo abrir el archivo.».
- El MP4 exportado suena como la vista previa (música, fundidos, ducking). Con `~/Library/Caches/dev.toma.Toma/Music` borrada a mano y el proyecto abierto, el export espera con el anillo («Preparando…» en la fila) y suena igual; Cancelar la exportación durante la espera la corta sin aviso. Con el disco lleno, «No se pudo preparar la música: el disco está lleno».
- VoiceOver lee «Música, Foco, de 0:00 a 0:12» en la fila, con la acción Borrar la música; la lista de la sección y la de la biblioteca leen nombre, estilo y largo. Con Reducir movimiento, la barra de «Preparando…» parpadea en vez de correr. Ningún texto de la sección ni de la lista se corta en español, en claro y en oscuro.

**Clips importados** (U12)

- Con un clip importado de 3a en la secuencia (o un clip sobre el video), aparece la fila Clips importados con su bloque y la onda del sonido de su archivo, a su volumen; Solo en esa fila deja oírse solo a ellos (y atenúa las demás), y Solo en Música, solo a la música.

**El sonido de los clips importados** (A10)

- Con auriculares, en un proyecto con voz, soltar en la pista Video un `.mov` con sonido (una canción o alguien hablando): en su tramo se oye el clip y no la toma, sin chasquidos en los bordes; a −6 dB en el inspector, más bajo; a 2×, más rápido con el mismo tono; a 8×, callado. Lo mismo exportado.
- Agregar un clip encima con sonido (Anotaciones ▸ Clip…): se oye junto con la voz desde que aparece hasta que termina el archivo, una sola vez; Silenciar lo calla en la vista previa y en el export. Recién importado, se oye apenas termina de prepararse la mezcla (unos segundos en un proyecto largo), sin cerrar el editor.
- Un clip de 5.1 (o de más de dos canales) se oye al volumen de uno estéreo, sin saturar.
- Límite conocido (no es una falla): el sonido de los clips se guarda en memoria, como se decodificó, hasta 10 min por mezcla entre todos (primero lo que se usa de cada clip, después cada clip entero); lo que pasa de ahí se lee del archivo mientras suena. Se oye igual, pero dos exportaciones del mismo proyecto pueden diferir en los últimos bits del sonido (−134 dBFS, inaudible), y también la vista previa contra el export. Lo que lo resolvería es una caché CAF del audio de cada clip, como la de la música importada (U8); queda para después.

**Los marcadores en el editor** (T11)

En una toma real con tres o cuatro marcadores grabados (⌥⌘M mientras se graba).
- Con el foco en la vista previa o en la línea de tiempo, M agrega un marcador en el cursor (también reproduciendo, sin parar); en el mismo cuadro de otro no agrega nada (suena el aviso). Con el foco en un campo de texto (el de un subtítulo, el nombre de un marcador) M se escribe y ⌥← y ⌥→ mueven por palabras, como siempre. ⌥⌘M sigue siendo de la isla.
- ⌥← y ⌥→ llevan el cursor (en pausa) al marcador anterior y al siguiente; mantenidas, siguen de marcador en marcador. ↑ y ↓ también paran en los marcadores, los de todas las tomas.
- Doble clic en una bandera de la regla abre un globo con su nombre: ↩ lo guarda (aparece al lado de la bandera si entra, cortado con «…» si no del todo), Esc o un clic afuera lo deja como estaba. El menú contextual de la bandera tiene «Renombrar…» y «Borrar». Un clic en una bandera lleva el cursor a su marcador.
- Arrastrar una bandera la mueve (la etiqueta dice cuánto y a dónde; se pega a los bordes de los clips, al cursor y a las marcas) y un solo ⌘Z la devuelve; un marcador grabado movido no deja otro en su lugar. Esc durante el arrastre lo cancela. Cortar el tramo de un marcador lo esconde; deshacer el corte lo trae con su nombre. En un proyecto abierto solo para ver, arrastrar sobre la regla mueve el cursor y no la bandera.
- El menú Marcadores de la barra lista cada marcador («0:12 Intro», «0:40 Marcador sin nombre») y un clic lleva el cursor ahí; «Agregar marcador», «Marcador anterior», «Marcador siguiente» muestran su tecla (M, ⌥←, ⌥→) debajo del nombre (comprobar que se lee bien y que la tecla no se dispara al escribir en un campo después de abrir el menú); «Renombrar el marcador…» y «Borrar el marcador» se activan solo con el cursor sobre un marcador. Sin marcadores, dice «Sin marcadores».
- «Copiar capítulos» (con algún marcador con nombre) deja en el portapapeles `00:00 Introducción` y una línea por marcador con nombre (`MM:SS Nombre`, o `H:MM:SS` en todas si el video dura una hora o más); pegado en la descripción de un video de YouTube (sin publicar), YouTube muestra los capítulos. VoiceOver dice «Capítulos copiados.».
- La hoja de exportar muestra «Capítulos en el archivo» (prendido cada vez que se abre) solo para Video con marcadores con nombre, nunca para el GIF; apagado, el archivo no tiene capítulos. El MP4 y el MOV en QuickTime (Visualización ▸ Capítulos): los mismos capítulos que «Copiar capítulos», con la app en español «Introducción» y en inglés «Intro» (la pista lleva el idioma de la app).
- VoiceOver en la línea de tiempo: al final de los elementos, una bandera por marcador («Marcador «Demo» en 0:12», «Marcador sin nombre en 0:40»); activarla lleva el cursor ahí, y sus acciones son Renombrar… y Borrar.
- El agente no pudo capturar la pantalla (estaba bloqueada): vio la regla con las banderas nombradas y la hoja con «Capítulos en el archivo» dibujadas desde sus capas (`TOMA_SHOWCASE_P3_MARKERS=named` con `TOMA_SHOWCASE_P3_MARKERS_PNG`, superficie `export` sobre un paquete de `synth-record --markers`); no vio el menú Marcadores abierto ni el globo del nombre.

**Las anotaciones sobre la vista previa** (A13)

- Anotaciones en la vista previa: elegir, mover, agrandar con ⇧, los extremos de una flecha y la punta de un globo, las guías, doble clic para editar un texto, ⌫, ⌘D, ⌘] ⌘[ ⌥⌘] ⌥⌘[ y las flechas del teclado (1 pt, ⇧ 10 pt), con un zoom en curso y en Pantalla dividida; soltar una imagen y un clip sobre la vista previa.
- En detalle, en pausa: un clic en una anotación la elige (la de más arriba si se pisan; ⇧ o ⌘ suma o saca otra) y muestra su contorno y sus manijas justo sobre lo dibujado, también con un zoom de 2× entrando y con la pantalla en su tarjeta de Pantalla dividida; un clic fuera de las anotaciones sigue reproduciendo como siempre. Arrastrar mueve (el cursor de reproducción no se mueve), con las guías violetas al centro y a los bordes del contenido (o del cuadro, en las de la salida) y un toque del trackpad al imantarse; ⌘ las apaga. Las esquinas de un texto lo agrandan con su letra, sus lados cambian el ancho y el texto se vuelve a cortar; una forma girada en el inspector se agranda desde la esquina opuesta, que no se mueve. Cada arrastre es un solo ⌘Z, y Edición ▸ Deshacer lo nombra.
- Doble clic en un texto y en un globo: el texto se edita en su lugar con su letra y su color; ↩ hace otra línea, ⌘↩ o un clic afuera lo guarda (un ⌘Z) y Esc lo deja como estaba. Mientras se edita, la vista previa no lo muestra dos veces.
- Con anotaciones elegidas y el foco en la vista previa, ← → ↑ ↓ las mueven 1 pt y con ⇧ 10 pt; con el foco en la línea de tiempo, o sin ninguna a la vista en el cursor, las flechas mueven el cursor como en la fase 2.
- Soltar un PNG y un `.mov` desde Finder sobre la vista previa: un borde violeta mientras se arrastra, «Importando «…»…» abajo, y quedan encima, centrados donde se soltaron (la imagen pegada a la grabación sobre un tramo de la toma, el clip de la salida y tan largo como su archivo), elegidos. Un `.txt` no se acepta; un archivo que no se puede leer dice «No se pudo agregar el archivo.».
- El agente no pudo capturar la pantalla (estaba bloqueada): vio la vista previa dibujada desde un renderer propio con las capas de la superposición encima (`TOMA_SHOWCASE_P3_ANNOTATIONS=edit`, `edit-flat`, `edit-split`, `edit-callout`, `edit-shape` y `text` con `TOMA_SHOWCASE_P3_PREVIEW_PNG`); el arrastre, el teclado, el soltar archivos y VoiceOver no los probó: mirarlos en la app.

**El menú Tomas y «Regrabar desde acá»** (T12)

Con un proyecto real de una toma con pantalla, cámara y micrófono, editado una vez (un corte alcanza). Antes de cada caso, anotar las carpetas de `takes/` («Mostrar contenido del paquete»): después siguen todas, y nunca aparece un proyecto nuevo en la carpeta de Toma ni en su `Trash/`.
- La barra ▸ Tomas: arriba «Regrabar desde acá» con ⇧⌘R debajo, y una fila por toma («Toma 1 · 20 nov, 14:02 · 3:12 · En uso»), cada una con «Usar desde acá» y «Agregar al final». Nada se corta en español. En un proyecto de la fase 1 o 2 sin editar, el ítem está atenuado y con el puntero encima dice «Para regrabar, hacer antes un cambio en el proyecto.»; después de un cambio, se puede. Con una exportación en curso dice «Hay una exportación en curso.».
- Pantalla: con el cursor en la mitad, ⇧⌘R (también con el foco en un campo del panel). El editor desaparece enseguida y arranca la cuenta regresiva con la misma pantalla, cámara (con su estilo en ese punto) y micrófono, sin abrir la isla. Grabar unos segundos y parar: el editor vuelve (aunque «Al parar» diga «Quedarse acá»), con lo de antes del cursor igual, la toma nueva desde ahí y el cursor en su primer cuadro. Un solo ⌘Z («Deshacer Regrabar desde acá») devuelve todo como estaba; la toma queda en el menú Tomas como «Sin usar». Medir de ⇧⌘R al primer número de la cuenta regresiva (en Consola, subsistema `dev.toma.Toma`, categoría `Rerecord`: «Re-record from Here to the countdown: N ms»; menos de 1 s) y anotarlo en `docs/performance.md`.
- Ventana: una toma de una ventana, regrabar con la app abierta: graba esa ventana sin preguntar. Cerrar esa ventana y regrabar: la isla se abre en Ventana sin ninguna elegida, con «Regrabar en «Nombre»» junto a Grabar; elegir otra y Grabar graba en el mismo proyecto. Abrirla otra vez y cerrarla con Esc, con la ✕ o con un clic afuera: el editor vuelve sin cambios.
- iPhone: una toma de un iPhone conectado regraba el mismo iPhone; con el iPhone desenchufado, la isla se abre en iPhone o iPad para elegir.
- Dentro de una regrabación, «Reiniciar» dice «¿Reiniciar la toma? Esta queda en el proyecto, sin usar.»; al parar, el menú Tomas tiene la toma del reinicio como «Sin usar» y la última aplicada. Salir de la app (⌘Q) a mitad de una regrabación: al abrir el proyecto la toma está en el menú Tomas («Sin usar») y nada se perdió.
- «Usar desde acá» de una toma sin usar reemplaza lo de después del cursor por esa toma; «Agregar al final» la pone después del último clip; cada uno es un ⌘Z («Deshacer Usar la toma»). En un proyecto con guion (teleprompter prendido al grabar), regrabar desde la mitad abre el teleprompter en la oración que se estaba diciendo en el cursor.
- El agente no pudo usar la pantalla (estaba bloqueada): vio el menú Tomas como texto (`TOMA_SHOWCASE_P3_TAKES_MENU`), el final de una regrabación aplicado en la línea de tiempo (`TOMA_SHOWCASE_P3_RERECORD=take-001`, un solo paso `take.rerecord` en `edit-log.jsonl`) y la isla `rerecord` dibujada fuera de la pantalla (`TOMA_SHOWCASE_ISLAND_PNG`); nada de una grabación real.

**El teleprompter que sigue la voz y el guion del proyecto** (T13)

Con macOS 26, el modelo del español en la Mac (Subtítulos) y el teleprompter prendido con un guion real en español de dos o tres párrafos.
- Prender «Seguir la voz» (el botón redondo de la onda con el micrófono, en la barra del teleprompter): se ilumina, la velocidad se apaga (atenuada) y antes de grabar el guion queda arriba, quieto. Grabar leyendo en voz alta: el renglón que se lee sube solo a un tercio del área de lectura con un movimiento suave (con Reducir movimiento, salta) y lo ya dicho queda más tenue; en los silencios no se mueve. Saltear unas frases (hasta unas 40 palabras): después de dos palabras seguidas de donde se retoma, el guion salta ahí, nunca con una sola. Repetir una frase ya dicha: no vuelve atrás. Improvisar una frase que no está en el guion: no se mueve, y al volver al guion sigue. Una pausa larga (15 a 30 s): al volver a leer sigue desde ahí. Pausar la toma y hablar: nada se mueve; al reanudar, sigue. Reiniciar la toma: el guion vuelve al principio y sigue de nuevo.
- Siguiendo la voz, cada renglón se ve entero y centrado, sin superponerse ni cortarse, y el que se lee queda en la línea de lectura al cambiar el tamaño del texto (− y +). Apagar «Seguir la voz» a mitad de la toma: el guion sigue subiendo a su velocidad desde donde está; prenderlo de nuevo: sigue la voz desde el renglón que se ve en la línea de lectura.
- Grabar una toma nueva con el teleprompter prendido y un guion: el proyecto tiene `script.txt` con ese guion (Finder ▸ Mostrar contenido del paquete). Con el teleprompter apagado o el guion vacío, no se escribe ninguno.
- Regrabar desde acá (⇧⌘R) con el cursor del editor a mitad de una oración ya transcrita: el teleprompter abre con el guion del proyecto (no el de los ajustes) en el comienzo de esa oración, en la línea de lectura, con lo anterior atenuado si «Seguir la voz» está prendido. Editar el guion durante la regrabación (Editar, cambiar una palabra, Listo): un segundo después, el `script.txt` del proyecto tiene el cambio; al terminar, el teleprompter vuelve a mostrar el guion de los ajustes, sin ese cambio. Regrabar un proyecto sin `script.txt`: el teleprompter usa el guion de los ajustes y lo guarda en el proyecto al empezar a grabar.
- Las notas, con «Seguir la voz» prendido: en una Mac con macOS 15, arriba del guion «Seguir la voz necesita macOS 26.» y el guion sube a su velocidad (que se puede cambiar); con el idioma de la transcripción sin su modelo en la Mac (y sin el del idioma del sistema), «Falta el idioma «…» en esta Mac: se baja en Subtítulos.»; grabando sin micrófono, «La toma no graba el micrófono.»; si el motor falla (por ejemplo, sin el permiso de reconocimiento de voz), «No se pudo seguir la voz.» y el guion sube a su velocidad hasta el final de esa toma. En ningún caso macOS pide un permiso ni se baja un modelo. Ninguna nota se corta en español.
- El video exportado de una toma grabada siguiendo la voz no muestra el teleprompter ni sus notas, y el paquete no tiene nada de Seguir la voz (solo `script.txt`). VoiceOver lee «Seguir la voz» en el botón, con su estado, y la nota.
- El agente no pudo capturar la pantalla (estaba bloqueada): vio el teleprompter dibujado desde sus vistas (`TOMA_SHOWCASE_P3_TELEPROMPTER=follow` y `follow-note` con `TOMA_SHOWCASE_P3_TELEPROMPTER_PNG=<archivo>`, isla `display`), sin el vidrio ni el movimiento del resorte (con la pantalla bloqueada no corre el display link).

**«Regrabar desde acá»: arranque fallido, burbuja y guion** (T12, revisión)

Con el proyecto de «El menú Tomas y «Regrabar desde acá»».
- Una toma con cámara: en el editor, cambiar la forma o el lugar de la burbuja a la mitad (un cambio de cámara) y regrabar desde después de ese cambio. Durante la cuenta regresiva y la toma, la burbuja de la isla tiene la forma y el lugar del editor en el cursor (no los de los ajustes de la isla); al terminar, la cámara no salta en el corte. Grabar después una toma nueva desde la isla: la burbuja vuelve a la de los ajustes, sin cambios.
- Hacer fallar el arranque de una regrabación (por ejemplo, una ventana que se cierra durante la cuenta regresiva): la isla queda abierta diciendo por qué, todavía con «Regrabar en «Nombre»», y el editor sigue escondido. Elegir otra ventana y Grabar: graba en el mismo proyecto (ningún proyecto nuevo) y la isla no recuerda esa selección para la próxima toma. Hacerlo fallar otra vez y cerrar la isla (Esc): el editor vuelve una sola vez, sin cambios.
- Regrabar con una fuente faltante: con la isla abierta (antes de Grabar), el teleprompter ya muestra el guion del proyecto en la oración del cursor. Cerrar la isla con un clic en otra app: el editor vuelve atrás de esa app, sin traer Toma al frente.

**La pestaña Anotaciones** (A14)

- Pestaña Anotaciones (⌘9): agregar cada tipo; una imagen PNG transparente, un PDF y un GIF; un clip de iPhone (HEVC) encima y en la secuencia, con su sonido; cómo se ven los cuatro estilos de texto y de placa y las cuatro fuentes; cambiar el anclaje sin que la anotación salte; congelar un cuadro y estirarlo.
- Arriba, Agregar: Texto, Flecha, Forma, Globo y Paso la agregan en el cursor de reproducción, elegida, y su inspector aparece debajo sin mover los botones (un segundo clic agrega otra). A menos de 0,3 s del final suena el aviso y no agrega nada. Imagen… ofrece PNG, JPEG, HEIC, TIFF, GIF y PDF (también Fondo ▸ Elegir imagen…); Clip…, MOV, MP4 y M4V; mientras se copia, «Importando «…»…» con una ruedita.
- El inspector: el nombre («Texto «Hola»», «Paso 2») y «De 0:02 a 0:05»; «Pegada a la grabación» y «Todo el video» (las dos apagadas: fija en la salida, con la nota de qué significa cada una; la primera apagada en un clip). Con un zoom de 2× entrando, prender y apagar cada una: la anotación y el tamaño de su letra no se mueven ni un píxel, y es un solo ⌘Z. Cada deslizador (Tamaño, Grosor, Curva, Esquinas, Volumen, Opacidad, Rotación) mueve la vista previa mientras se arrastra y es un solo ⌘Z al soltar; con las flechas del teclado, pasos sueltos que se juntan en uno. Los colores: blanco, negro y los seis de la paleta, después los que el proyecto ya usa (hasta seis), y el selector del sistema; un relleno elegido de la paleta conserva su transparencia (la etiqueta negra al 70 %). Cambiar Simple → Etiqueta pone la píldora negra; un relleno elegido a mano queda. Entrada ofrece Trazarse solo en flechas y formas; Rotación no aparece en flechas ni globos. Un clip sin sonido dice «Este clip no tiene sonido.».
- Ordenar: los cuatro botones y Edición ▸ Ordenar (⌘] ⌘[ ⌥⌘] ⌥⌘[; con el teclado en español macOS los muestra como ⌘´ ⌘ñ ⌥⌘´ ⌥⌘ñ), apagados donde no cambian nada; Edición ▸ Duplicar (⌘D) con anotaciones elegidas. Con la Biblioteca adelante, ⌘D sigue duplicando el proyecto elegido.
- Abajo, Video: «Agregar placa» en el cursor, «Al principio» y «Al final» con un clic; «Congelar cuadro» (apagado con el cursor dentro de una placa o un congelado; Edición ▸ Congelar cuadro suena el aviso ahí); «Clip en la secuencia…» lo pone en el cursor. Elegir una placa en la pista Video con la pestaña abierta muestra su inspector: título, subtítulo, Centrado / A la izquierda / Grande / Mínimo, fondo Escenario / Color / Cuadro desenfocado, color del texto y Duración (escribir «2,5» o las flechitas, de a medio segundo, entre 0,1 y 60 s); un congelado, su Duración; un clip importado, Volumen, Velocidad y «De 0:00 a 0:12 del archivo».
- VoiceOver: cada mosaico se lee por su nombre (el elegido, seleccionado) y cada color de la paleta por el suyo («Rojo», «Color del proyecto 1»).
- El agente no pudo capturar la pantalla (estaba bloqueada): vio el panel dibujado desde sus vistas (`TOMA_SHOWCASE_TAB=8` con `TOMA_SHOWCASE_P3_ANNOTATIONS=inspector`, `inspector-arrow`, `inspector-shape`, `inspector-callout`, `inspector-clip` y `card`, `TOMA_SHOWCASE_P3_NARROW=1` y `TOMA_SHOWCASE_PANEL_PNG`, en claro y oscuro), donde los bordes de los controles de AppKit (casillas, campos, menús, segmentos) no se dibujan; comprobó con `anchor` que cambiar el anclaje deja la caja y la letra en los mismos píxeles, y con `menu` que ⌘D y los cuatro de Ordenar llegan por el menú (enviados al menú principal). No probó clics reales, el selector de colores, los paneles de abrir ni VoiceOver: mirarlos en la app.

**Clips en la secuencia: el dibujo** (A9)

- Un clip vertical grabado con un iPhone (MOV HEVC, de pie) y uno horizontal (MP4 H.264 de una cámara o de otro export), cada uno en la secuencia: se ven derechos y enteros dentro del margen, con las esquinas y la sombra del estilo y sin cursor ni cámara; en pausa, reproduciendo, arrastrando el cursor de reproducción por encima y en el video exportado, igual. A 1,5× se mueven más rápido y terminan donde termina su tramo. Un ProRes 4444 con alfa se ve opaco y nada se traba.
- Con el proyecto cerrado, sacar el archivo del clip de `assets/` (o cambiarlo por un alias): al abrirlo, en su tramo se ve el fondo solo; reproducir y exportar no se traban ni dan error.

**Imágenes y clips encima** (A7)

- Desde la pestaña Anotaciones, encima del video: un PNG con transparencia (un logo), una foto JPEG o HEIC mucho más grande que su caja y un clip (un MOV HEVC de pie de un iPhone y un MP4 horizontal). La transparencia del PNG deja ver el video sin un recuadro ni una sombra adentro; la foto se ve nítida, sin escalones ni parpadeo; Encajar deja franjas vacías y Llenar recorta el medio; las esquinas, la sombra, la rotación y la opacidad se ven como en el inspector. El clip se ve derecho, avanza con el video y desaparece cuando termina su tramo; en pausa, reproduciendo y en el video exportado, igual.
- El mismo archivo en la secuencia y encima a la vez, y dos clips encima del mismo archivo a la vez en otros instantes: reproducir no se traba y cada uno avanza por su cuenta.
- En la Mac base (M1), reproducir en 1080p con diez anotaciones a la vista, dos imágenes y un clip entre ellas: sigue a 60 fps, sin un salto cuando aparece una imagen.

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
Created project at /Users/<usuario>/screen-recorder/Toma.xcodeproj
Command line invocation:
    /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -resolvePackageDependencies -project Toma.xcodeproj -scheme Toma -derivedDataPath build -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -packageAuthorizationProvider netrc

Resolve Package Graph


Resolved source packages:
  swift-argument-parser: https://github.com/apple/swift-argument-parser @ 1.8.2
  Sparkle: https://github.com/sparkle-project/Sparkle @ 2.10.1
  RecorderKit: /Users/<usuario>/screen-recorder/Packages/RecorderKit

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
created: /Users/<usuario>/screen-recorder/dist/Toma-0.0.1.dmg
hdiutil verify: checksum valid

==> Appcast
No EdDSA private key (neither SPARKLE_ED_PRIVATE_KEY nor Sparkle's key in the login keychain):
skipping dist/appcast.xml. See docs/release.md for creating the key.

==> Done
total 3456
-rw-r--r--@ 1 <usuario>  staff  1766982 Nov 13 22:52 Toma-0.0.1.dmg
drwxr-xr-x@ 3 <usuario>  staff       96 Nov 13 22:52 Toma.app

$ codesign --verify --deep --strict --verbose=2 dist/Toma.app
--prepared:/Users/<usuario>/screen-recorder/dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/Current/.
--prepared:/Users/<usuario>/screen-recorder/dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate
--validated:/Users/<usuario>/screen-recorder/dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/Current/Autoupdate
--prepared:/Users/<usuario>/screen-recorder/dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/Current/Updater.app
--validated:/Users/<usuario>/screen-recorder/dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/Current/Updater.app
--validated:/Users/<usuario>/screen-recorder/dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/Current/.
dist/Toma.app: valid on disk
dist/Toma.app: satisfies its Designated Requirement

$ codesign -dv --verbose=4 dist/Toma.app
Executable=/Users/<usuario>/screen-recorder/dist/Toma.app/Contents/MacOS/Toma
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
Executable=/Users/<usuario>/screen-recorder/dist/Toma.app/Contents/MacOS/Toma
# designated => cdhash H"cdc97b06c24e7aab9102dbec1c2d1cb46a8b6843"

$ codesign -d --entitlements - dist/Toma.app
Executable=/Users/<usuario>/screen-recorder/dist/Toma.app/Contents/MacOS/Toma
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
Executable=/Users/<usuario>/screen-recorder/dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
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
Executable=/Users/<usuario>/screen-recorder/dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater
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
Executable=/Users/<usuario>/screen-recorder/dist/Toma.app/Contents/Frameworks/Sparkle.framework/Versions/Current/Sparkle
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
/dev/disk26s1       	41504653-0000-11AA-AA11-0030654	/Users/<usuario>/screen-recorder/build/dmg-check

$ ls -l build/dmg-check
total 0
lrwxr-xr-x@ 1 <usuario>  staff  13 Nov 13 22:52 Applications -> /Applications
drwxr-xr-x@ 3 <usuario>  staff  96 Nov 13 22:52 Toma.app

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
26849   00:05 /Users/<usuario>/screen-recorder/dist/Toma.app/Contents/MacOS/Toma

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
-rw-r--r--@ 1 <usuario>  staff  1766955 Nov 13 22:50 Toma-0.0.1.dmg
drwxr-xr-x@ 3 <usuario>  staff       96 Nov 13 22:50 Toma.app
-rw-r--r--@ 1 <usuario>  staff      827 Nov 13 22:50 appcast.xml
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
-rw-r--r--@ 1 <usuario>  staff  1766955 Nov 13 22:50 Toma-0.0.1.dmg
-rw-r--r--@ 1 <usuario>  staff  1767062 Nov 13 22:51 Toma-0.0.2.dmg
drwxr-xr-x@ 3 <usuario>  staff       96 Nov 13 22:51 Toma.app
-rw-r--r--@ 1 <usuario>  staff     1298 Nov 13 22:51 Toma36-35.delta
-rw-r--r--@ 1 <usuario>  staff     1879 Nov 13 22:51 appcast.xml
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

**Zonas seguras** (I15)

- En un proyecto 9:16, 4:5 o 3:4: Visualización ▸ Mostrar las zonas seguras (o el botón de la derecha de la barra de la vista previa) atenúa arriba, abajo y la derecha con borde punteado y la leyenda. Comparada con un Reel real, el texto de abajo y los botones de la derecha caen en lo atenuado. En 16:9, 1:1 y 4:3 el menú está deshabilitado y no hay botón. Exportar un proyecto con las zonas prendidas no las dibuja.

**Voz y audio: modo del micrófono** (A14)

- Con el micrófono elegido y el medidor andando, la isla dice el modo activo ("Modo: Estándar"); Cambiar… abre el selector de macOS y al elegir Aislamiento de voz o Amplio espectro la fila lo dice enseguida. Con el micrófono apagado (o sin permiso), la fila está deshabilitada. Con el modo más largo la fila no se corta (el botón pasa abajo).

**La hoja de exportar: Códec** (I17)

- En Exportar, la fila Códec ofrece H.264, HEVC, ProRes 422 y ProRes 422 HQ (H.264 por defecto; la hoja recuerda el último). Con ProRes desaparece Calidad y el panel de guardar propone `.mov`; con H.264 y HEVC, `.mp4`.
- Un ProRes 422 HQ abre en Final Cut con su audio; un HEVC se reproduce en QuickTime y en Safari. Comparar el tamaño estimado de la hoja con el del archivo real (1080p, 60 fps, 12 s: unos 9 MB en HEVC, unos 670 MB en ProRes 422 HQ).

**Teclas en pantalla** (P12)

- En una toma con teclas grabadas, pestaña Cursor ▸ Teclas en pantalla: Atajos muestra ⌘C ⌘V y no lo escrito; Todas junta lo escrito en una píldora; las cuatro posiciones; con subtítulos abajo, las teclas quedan encima. En una toma sin teclas, la nota y el botón "Abrir los ajustes de grabación" abren Ajustes en Grabación.

**Voz y audio: limpieza, volumen y cámara** (A12)

- Una toma con ruido real (ventilador, teclado): Limpieza Suave y Fuerte se oyen distintas y la voz sigue natural; mientras limpia, la vista previa suena sin limpiar y "Limpiando el audio… N %" avanza. Normalizar el volumen deja una toma baja y una alta al mismo volumen percibido y nada satura ("Evitar la saturación" queda prendido y fijo).
- Con un aplauso frente a la cámara, Sincronía con el audio lo alinea con el golpe del sonido (positivo: la cámara se ve más tarde). Ocultar en los silencios agrega bloques Solo pantalla editables que no pisan los que había, y todo se deshace con un ⌘Z.
**Voz y audio: la pista Subtítulos** (A13)

- Aparece solo con transcripción, debajo del Video; cada bloque es un subtítulo con su texto y sigue los cortes; doble clic lleva a esa palabra en la pestaña; VoiceOver lee cada subtítulo con su tramo.

**Revisión final de la fase 2: vista previa, miniaturas e idioma** (final-fix-3)

- Con Quitar el fondo pedido y la máscara todavía analizándose, arrastrar el encuadre Manual (o un rectángulo de privacidad, o Sincronía con el audio) hasta que termine: la vista previa sigue el arrastre sin volver un instante a como estaba.
- En la Biblioteca, un proyecto con la cámara en Fondo borroso o Quitado muestra en la tarjeta a la persona sin su cuarto (o la tarjeta sin la cámara mientras falta la máscara), y uno con Seguir la cara, la cara encuadrada. Con la Mac en español (Argentina), la transcripción elige siempre el mismo idioma (es-MX) al abrir varias veces.

**Revisión final de la fase 3: aplicación** (final-fix-3, 2.ª ronda)

- Con dos tomas en la secuencia (la segunda regrabada), tocar el volumen o Silenciar del micrófono y después elegir Limpieza "Fuerte": las dos tomas suenan y se exportan limpias (ambas generan su audio limpio), y un solo Deshacer vuelve la limpieza a como estaba.
