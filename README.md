# 🐇 Grabbyt

Descargador de videos y audio para macOS (Apple Silicon). Pega un link de X/Twitter, YouTube, TikTok, Instagram, Reddit, Vimeo… (más de 1800 sitios vía [yt-dlp](https://github.com/yt-dlp/yt-dlp)) y listo.

## Uso

```bash
./scripts/build-app.sh            # crea build/Grabbyt.app
./scripts/build-app.sh --install  # y la copia a /Applications
```

- Pega el link (o arrástralo a la ventana). Si copiaste un link antes de abrir la app, aparece solo.
- **Video** (MP4 H.264, abre en QuickTime) o **Audio** (MP3).
- Se guarda en `~/Downloads/Grabbyt` (se puede cambiar en Ajustes, ⌘,).
- La primera vez descarga yt-dlp y ffmpeg (~100 MB) a `~/Library/Application Support/Grabbyt/bin`.

## Cadena de fallbacks

Cada error de yt-dlp se clasifica (`ErrorClassifier`) y el `AttemptPlanner` elige el siguiente remedio según el tipo de fallo; no prueba todo a ciegas:

| Fallo | Remedios, en orden |
|---|---|
| Formato no disponible / sin ffmpeg | archivo único → actualizar yt-dlp → imitar Chrome |
| Extractor roto | actualizar yt-dlp → imitar Chrome → cookies → archivo único |
| Requiere sesión / +18 / contenido sensible | cookies de cada navegador (el preferido primero) → imitar Chrome → actualizar |
| 403 / Cloudflare / anti-bots | `--impersonate chrome` → cookies → actualizar |
| 429 rate limit | esperar 15 s → imitar Chrome → cookies → esperar 45 s |
| Red | esperar y reintentar |
| No existe / sin video | actualizar → cookies |
| Geo-bloqueo / URL no soportada | se detiene con un mensaje claro |

Si yt-dlp agota sus estrategias con un link de **X/Twitter**, se prueba la API de **fxtwitter → vxtwitter**. Suele funcionar con tweets marcados como sensibles y también baja fotos.

Además: yt-dlp se actualiza solo una vez al día, solo si hay una versión nueva en GitHub. Si varias descargas fallan a la vez, esperan una sola actualización.

Cookies: solo se usan navegadores con cookies legibles. Para Safari, dale a Grabbyt **Acceso total al disco** en Ajustes del Sistema → Privacidad.

## Desarrollo

Compila solo con las Command Line Tools, sin Xcode. Por eso no se usan `@State` ni XCTest, que dependen de macros o frameworks que solo trae Xcode.

```bash
swift build
swift run SelfTest                                  # autopruebas (clasificador, planificador, parsers)
swift run SelfTest download "<url>" [audio]         # prueba real del motor completo
swift run SelfTest fx "<url de x.com>" [audio]      # prueba solo el fallback de fxtwitter
```

- `Sources/Grabbyt/Core`: motor sin UI (`GrabbytCore`): herramientas, clasificador, planificador, yt-dlp y fallbacks.
- `Sources/Grabbyt`: la app SwiftUI.

## Pendiente (fases 3–4)

gallery-dl (galerías de Instagram/Pinterest/Reddit), descarga directa de archivos, lectura del HTML (`og:video`, `.m3u8`), elegir calidad y vista previa, historial persistente, detección con WebView, icono en la barra de menú, Share Extension y DMG.

Uso personal. Grabbyt no soporta contenido con DRM (Netflix, Spotify, etc.).
