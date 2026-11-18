# Third-party software

Spatialize's own code is MIT-licensed (see `LICENSE`). The release app bundles these programs,
each under its own licence. They run as separate programs; Spatialize calls them.

| Component | What it does | Licence | Source |
|---|---|---|---|
| truehdd | TrueHD / Dolby Atmos decoding | Apache-2.0 | https://github.com/truehdd/truehdd |
| OpenJOC | Dolby Digital Plus Atmos (JOC) decoding | Apache-2.0 | https://github.com/chyinan/OpenJOC |
| libmysofa | Reading SOFA HRTF files (compiled into the app) | BSD-3-Clause | https://github.com/hoene/libmysofa |
| MIT KEMAR HRTF | Built-in dummy-head model | Public research data (MIT Media Lab) | https://sound.media.mit.edu/resources/KEMAR.html |
| uv | Installs the song separation engine on first use | MIT or Apache-2.0 | https://github.com/astral-sh/uv |
| FFmpeg 9.0.2 | Demuxing, video conversion, AAC | GPL-3.0-or-later (static build with GPL and version-3 parts enabled) | https://ffmpeg.org/download.html · https://ffmpeg.martin-riedl.de |

The FFmpeg binaries in the release (`ffmpeg`, `ffprobe`) are the unmodified static macOS arm64
builds by Martin Riedl (https://ffmpeg.martin-riedl.de), version 9.0.2. The complete
corresponding source for FFmpeg and the libraries in that build is published by FFmpeg and on
that site; `ffmpeg -version` inside `Spatialize.app/Contents/Resources/engine/bin` shows the exact
configuration. Licence texts: GPL-3.0 https://www.gnu.org/licenses/gpl-3.0.html,
Apache-2.0 https://www.apache.org/licenses/LICENSE-2.0, BSD-3-Clause in `vendor/libmysofa/LICENSE`.

The song separation engine is not bundled. On first use Spatialize installs, into
`~/Library/Application Support/Spatialize/stems`, Demucs (MIT, https://github.com/facebookresearch/demucs)
and PyTorch (BSD-3-Clause, https://pytorch.org) from PyPI; the htdemucs model weights (MIT) are
downloaded by Demucs from Meta's servers.

The measured heads offered by *Find Your Head Model* are downloaded from sofacoustics.org only
when you ask, under their databases' own licences (ARI CC BY-SA, CIPIC, HUTUBS CC BY,
SADIE II Apache-2.0, TH Köln CC BY-SA).

"Dolby", "Dolby Atmos", "AirPods" and "Spatial Audio" are trademarks of their owners. Spatialize
is an independent project, not affiliated with or endorsed by Dolby Laboratories or Apple.
The decoders are third-party clean-room implementations. For personal use with media you own.
