# 🐇 Grabbyt

Descargador de videos, audio e imágenes para macOS (Apple Silicon). Pegas un link de X/Twitter, YouTube, TikTok, Instagram, Reddit, Vimeo, Twitch, SoundCloud, Pinterest… (más de 1800 sitios) y listo.

## Descargar

👉 **[Última versión (DMG)](../../releases/latest)**

1. Abre el DMG y arrastra **Grabbyt** a **Aplicaciones**.
2. La primera vez, macOS avisará que no puede verificar al desarrollador, porque la app no está notarizada por Apple. Para abrirla, ve a **Ajustes del Sistema → Privacidad y seguridad → “Abrir igualmente”**, o ejecuta en Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Grabbyt.app
   ```
3. Al abrirla por primera vez descarga sus herramientas (~150 MB): yt-dlp, ffmpeg y gallery-dl.

Requiere macOS 14 o superior en un Mac M1 o posterior. La app avisa cuando hay una versión nueva.

## Qué hace

- **Video** (MP4 H.264, abre en QuickTime/Fotos) con elección de calidad: Mejor, 2160p, 1440p, 1080p, 720p…
- **Audio**: MP3 o M4A.
- **Imágenes**: fotos, carruseles y galerías (Instagram, X, Pinterest, Reddit, Tumblr…).
- **Vista previa** antes de descargar: miniatura, título, duración y calidades disponibles.
- **Cola** con varias descargas a la vez, progreso, cancelar, reintentar e **historial** con búsqueda.
- Detecta links en el portapapeles y acepta links arrastrados a la ventana.
- **Barra de menú**: descarga rápida sin abrir la ventana.
- **Desde cualquier app**: selecciona un link → clic derecho → Servicios → *Descargar con Grabbyt*.
- **Desde cualquier navegador**, con un marcador (*bookmarklet*):
  ```
  javascript:location.href='grabbyt://download?url='+encodeURIComponent(location.href)
  ```
- **Atajos y Terminal**: `open 'grabbyt://download?url=<link>&mode=audio'` (modos: `video`, `audio`, `images`).

## Cómo intenta cada descarga (fallbacks)

Grabbyt no se rinde al primer error. Cada fallo se clasifica y se elige el siguiente remedio según el tipo de fallo, sin probar todo a ciegas.

**1. yt-dlp con reintentos inteligentes**

| Fallo | Remedios, en orden |
|---|---|
| Formato no disponible / sin ffmpeg | archivo único → actualizar yt-dlp → imitar Chrome |
| Extractor roto | actualizar yt-dlp → imitar Chrome → cookies → archivo único |
| Requiere sesión / +18 / contenido sensible | cookies de cada navegador (el preferido primero) → imitar Chrome → actualizar |
| 403 / Cloudflare / anti-bots | `--impersonate chrome` → cookies → actualizar |
| 429 rate limit | esperar 15 s → imitar Chrome → cookies → esperar 45 s |
| YouTube (bots, formatos) | además, otros *player clients* (`tv`, `web_safari`, `mweb`…) |
| Geo-bloqueo | se detiene con un mensaje claro |

**2. Si yt-dlp no puede, se prueban, en orden:**

1. **API de fxtwitter / vxtwitter** para X/Twitter: tweets sensibles sin sesión, y fotos.
2. **gallery-dl** para imágenes, galerías y carruseles.
3. **Descarga directa**, si el link apunta a un archivo (`.mp4`, `.jpg`, `.pdf`…) o a un stream `.m3u8`, que se baja con ffmpeg.
4. **Lectura del HTML**: `og:video`, `<video>`, JSON-LD y cualquier `.m3u8`/`.mp4` en el código.
5. **Navegador invisible (WebKit)**: abre la página, reproduce el video en silencio y captura las URLs de medios que pide el reproductor.

En modo **Imágenes**, el orden cambia: primero gallery-dl y las APIs.

Las herramientas se actualizan solas: yt-dlp a diario, y también cuando un extractor falla; gallery-dl semanalmente.
Para usar cookies de Safari, dale a Grabbyt **Acceso total al disco** en Ajustes del Sistema → Privacidad.

## Desarrollo

Compila solo con las Command Line Tools, sin Xcode completo. Por eso no se usan `@State` ni XCTest, que dependen de macros o frameworks exclusivos de Xcode.

```bash
swift build
swift run SelfTest                                       # autopruebas
swift run SelfTest download "<url>" [video|audio|images] # motor completo con todos los fallbacks
swift run SelfTest probe "<url>"                         # vista previa
swift run SelfTest html "<url>"                          # lectura del HTML
swift run SelfTest sniff "<url>"                         # navegador invisible
swift run SelfTest fx "<url de x.com>" [audio]           # API de fxtwitter
./scripts/build-app.sh [--install] [--dmg]               # arma build/Grabbyt.app (y el DMG)
```

- `Sources/Grabbyt/Core`: el motor, sin UI (`GrabbytCore`): herramientas, clasificador de errores, planificador de intentos, argumentos de yt-dlp y todos los fallbacks.
- `Sources/Grabbyt`: la app en SwiftUI (ventana, barra de menú, ajustes, historial, integraciones).

### Publicar una versión

```bash
git tag v0.3.0 && git push origin v0.3.0
```

GitHub Actions (`.github/workflows/release.yml`) corre las pruebas, arma el DMG y crea la Release. Las apps ya instaladas ven el aviso de actualización.

## Aviso

Para uso personal. Respeta los derechos de autor y los términos de cada sitio. Grabbyt no soporta contenido con DRM (Netflix, Spotify, Disney+, etc.).

Hecho sobre [yt-dlp](https://github.com/yt-dlp/yt-dlp), [gallery-dl](https://github.com/mikf/gallery-dl), [FFmpeg](https://ffmpeg.org) y las APIs de [FxEmbed](https://github.com/FxEmbed/FxEmbed) y [vxTwitter](https://github.com/dylanpdx/BetterTwitFix).
