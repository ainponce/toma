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

1. **Las suites:** `make test`, `make tsan` y `make crash-test` (cuatro casos: el tercero con dos pantallas, cámara, micrófono y audio del sistema; el cuarto con una ventana) pasan.
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

Una sola pasada de fin de hito, contra la app de esta rama, en orden: la preparación, el recorrido completo y el detalle por área. Cada comprobación dice qué se tiene que ver. Si se ve otra cosa, o algo molesta, anotar lo que se ve (con la versión exacta de macOS) en la tabla del final: los agentes trabajan con esas notas. Ninguna comprobación pide cambiar código. Entre paréntesis, la tarea de origen.

### 0. Preparación

1. **Abrir la copia de prueba.** La arma el controlador después de unir la rama: `open build/prueba/Toma.app`. `codesign -dv build/prueba/Toma.app 2>&1 | grep Authority` dice `Authority=Toma Project Signing` cuando salió firmada con el certificado (paso 1 de la preparación del hito 1a); si no, es ad hoc.
2. Si se creó el certificado de firma después de recibir la copia de prueba, pedir una copia nueva: la anterior quedó ad hoc y macOS no conserva sus permisos.
3. **Permisos.** Los mismos del hito 1a (paso 3 de su preparación): Toma pide cada uno cuando hace falta.

### 2. Detalle por área

**Imágenes del cursor** (16)
- En macOS 15 y en macOS 26, grabar una toma con el cursor en I-beam (un campo de texto), en la mano (un enlace en Safari), en las flechas de redimensionar (el borde lateral, el de arriba y una esquina de una ventana) y en uno propio de una app (una de dibujo): `takes/<toma>/cursors/` tiene una imagen por forma (una sola aunque la forma vuelva varias veces), el editor muestra cada una y, en estilo Toma, los bordes salen con las flechas de Toma (la esquina, con la imagen grabada).
- En `events.jsonl` de esa toma, los `cursorImage` del I-beam, la mano y los bordes tienen `"kind"` (`iBeam`, `pointingHand`, `resizeLeftRight`, `resizeUpDown`); el de la esquina y el de la app de dibujo, no.
- Toma no aparece en ninguna lista nueva de Ajustes del Sistema ▸ Privacidad y seguridad.
- Grabando con el cursor quieto, el uso de CPU de Toma (Monitor de Actividad) es a lo sumo 2 puntos más que con la copia del hito 1a en la misma toma: anotar los dos números.
- Con Accesibilidad ▸ Pantalla ▸ Puntero en un tamaño más grande, o con otros colores del puntero, grabar 10 s moviéndolo: anotar el tamaño en píxeles de las imágenes de `cursors/` (una de más de 512 px de lado no se lee y el editor muestra la flecha) y si tienen `"kind"`.

**Scroll y actividad del teclado** (17)

Lo de "sin permiso" solo vale con Toma abierta desde Finder: la que se abre desde Terminal o Xcode recibe sus permisos, y la de los agentes también. El registro de la app se lee con `log show --last 10m --predicate 'subsystem == "dev.toma.Toma" AND category == "KeyActivityRecorder"'`.
- Antes, `tccutil reset ListenEvent dev.toma.Toma`, y abrir Toma desde Finder. Anotar si aparece algún aviso, al abrirla o al grabar (no tiene que aparecer ninguno).
- En macOS 15 y en macOS 26, sin Monitoreo de entrada otorgado, con "Anotar cuándo se escribe (nunca qué)" prendido (Ajustes, lo está por defecto), escribir en un campo de texto mientras se graba: `events.jsonl` de la toma tiene líneas `{"t":…,"type":"keyActivity"}`, a lo sumo una cada 250 ms, y el registro de la app dice, al empezar la toma, "Input Monitoring is granted" o "not granted" (lo que dio `CGPreflightListenEventAccess`). Si no hay ninguna línea `keyActivity`, anotarlo, con lo que dice el registro: es el plan B, y "Mantener el zoom al escribir" queda deshabilitado con su nota.
- Mover el mouse sin escribir durante 10 s: ninguna `keyActivity` en ese lapso. Si el registro dice "follows the mouse, not the keyboard", anotarlo: en esa Mac la lectura sigue al mouse y la toma deja de anotar.
- Escribir en un campo de contraseña de Safari y la contraseña de `sudo` en Terminal: ninguna línea `keyActivity` en ese lapso, ni la del Enter que cierra el campo. Con Terminal ▸ "Secure Keyboard Entry" prendido, ninguna línea mientras se escribe en Terminal.
- Con "Anotar cuándo se escribe (nunca qué)" apagado, grabar escribiendo: ninguna línea `keyActivity`, y el registro no dice nada de esa toma.
- Después de grabar, Ajustes del Sistema ▸ Privacidad y seguridad ▸ Monitoreo de entrada: Toma no aparece.
- Hacer scroll en Safari con el trackpad y con un mouse de rueda de líneas: `events.jsonl` tiene líneas `scroll` con `dx` y `dy` en puntos de un orden razonable (un giro corto de la rueda, unas decenas de puntos; la rueda cuenta 10 pt por línea). Anotar, para cada uno, cuánto se movió la página y qué sumaron los `dy`.

| Comprobación | Fecha | macOS | Resultado |
|---|---|---|---|
| 0. Preparación: copia de prueba (firmada o ad hoc), permisos | pendiente | pendiente | pendiente |
| 2. Imágenes del cursor (macOS 15 y 26) | pendiente | pendiente | pendiente |
| 2. Scroll y actividad del teclado sin Monitoreo de entrada (macOS 15 y 26) | pendiente | pendiente | pendiente |

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
