# DejaVu Sans Mono

`DejaVuSansMono.ttf` is the unmodified file `ttf/DejaVuSansMono.ttf` from the
official DejaVu Fonts 2.37 release
(sha256 `b4a6c3e4faab8773f4ff761d56451646409f29abedd68f05d38c2df667d3c582`).

- The Font module's unit tests embed it (`ttf.test_font`), so they don't
  depend on system fonts.
- Apps may ship it: the build publishes it as the named lazy path
  `dejavu_sans_mono`. Portal's browser client embeds it.
- Licence: the Bitstream Vera Fonts licence (DejaVu's own changes are
  public domain), in `LICENSE.txt`. It permits redistribution with that
  notice, so an app that ships the font must ship `LICENSE.txt` with it
  (the named lazy path `dejavu_sans_mono_licence`).
