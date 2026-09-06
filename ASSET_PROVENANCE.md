# Asset provenance

This file records the origin, redistribution terms and reproducible SHA-256
digests for artwork maintained by Hermes Console. It does not grant rights in
third-party names or trademarks.

## Hermes Console identity

The project owner states that the current gold winged-caduceus logo was
created under their direction using ChatGPT and selected by them as original
Hermes Console artwork. It replaces the earlier gold woman-and-circuit mark,
which was retired from every surface listed here. It was not copied from or derived from Nous Research or
Hermes Agent artwork. The owner licenses the files listed below for this
repository under `GPL-3.0-only`.

This statement is limited to copyright permission for the listed files in this
repository. It makes no broader trademark claim and grants no trademark rights.

| File | Role | Source | License | SHA-256 |
|---|---|---|---|---|
| `assets/branding/hermes_logo.webp` | Canonical dark-background in-app logo | Owner-directed ChatGPT output, selected and edited for Hermes Console | GPL-3.0-only | `4f06d0852d7dc0b65b07f3b9e94a5e8a89a4410468c777688b57c5b579ea9243` |
| `assets/branding/hermes_logo_light.png` | Light-background in-app variant | Owner-directed ChatGPT output, selected and edited for Hermes Console | GPL-3.0-only | `ac8cbfc7bf521d9eacb78d023e7bdf7f3419de319629fe04b0a429e7d67864cc` |
| `assets/icon/play_store_512.png` | Store/readme rendition of the current logo | Raster preparation of the owner-selected identity | GPL-3.0-only | `817885fc57c406fa51a11d7392f8e9ed5bfebf00a628c80adfc398358b871644` |
| `assets/branding/hermes_console_hero.svg` | Editable repository hero | Project-authored vector composition using the owner-selected Hermes Console identity | GPL-3.0-only | `455f918d7fe75605831cf0e692848bf261d08ba57dafb838e9443ef6afa3e9e0` |
| `assets/branding/hermes_console_hero.png` | Raster repository hero | PNG render of `hermes_console_hero.svg` | GPL-3.0-only | `3e98932d459ab77e54bb8a30d6ab64ef6720e1821b84fc1ba9a21dbad672ae86` |

The launcher, adaptive-icon and splash PNGs below are raster derivatives of
this identity generated for Android densities and flavors. Their complete
file-by-file digest manifest is
[`assets/branding/android-launcher-splash.sha256`](assets/branding/android-launcher-splash.sha256).

The geometric Spark symbol is project-native artwork authored for Hermes
Console, not a Nous Research asset. `assets/branding/spark_mark.svg` is the
editable source; its PNG and WebP files are raster derivatives. These files are
also distributed under `GPL-3.0-only`:

| File | SHA-256 |
|---|---|
| `assets/branding/spark_mark.svg` | `ee080350da83301388a3548173d81638d975c27af3c4d6f98183476a418dee5c` |
| `assets/branding/spark_mark.png` | `af46285441375edeabe72db278a2e0d33a533cfac8c901d0153586a27c6d073c` |
| `assets/branding/spark_mark.webp` | `33d8cafd4d3906b4878cea0f2d87fe9dfc7a14475c497451f7fe316ef2bc9067` |

## Approved public demo screenshots

These screenshots were captured from the isolated Project Aurora demo and
were already approved for the Hermes Console website and store presentation.
They contain only fictional data and are reused here without modification.

| File | Role | License | SHA-256 |
|---|---|---|---|
| `docs/screenshots/1.2.4-912/home.png` | Home | GPL-3.0-only | `58a3ec17a3e6b714db71876a8bfea0601a3fd4103bf26f72dbc043644ab9bfbd` |
| `docs/screenshots/1.2.4-912/chat.png` | Conversations | GPL-3.0-only | `492fd4dcfc82d46792ecc4e9ae859113d6428c8543b9895aa995be9519568566` |
| `docs/screenshots/1.2.4-912/voice.png` | Voice | GPL-3.0-only | `334efe827a4bd3f40a174efb6b98d12f3f52471d09df9d6c95a90ca8073e70ed` |
| `docs/screenshots/1.2.4-912/tools.png` | Tools | GPL-3.0-only | `a0723d6aa97fd32c8f1d0cfb55ac2274cc84a3f454c804f81059401248be1644` |

## Local companion sprites

Nimbus, Pixel and Violet are project-owned companion artwork released by the
project owner under `CC0-1.0`. They are local Hermes Console assets and were not
downloaded from Petdex or copied from Petdex community submissions. Each
manifest repeats the license declaration. The complete CC0 legal code is in
[`assets/companions/CC0-1.0.txt`](assets/companions/CC0-1.0.txt).

| Companion | File | Provenance | License | SHA-256 |
|---|---|---|---|---|
| Nimbus | `assets/companions/nimbus/spritesheet.webp` | Created for Hermes Console by the Hermes Console team | CC0-1.0 | `3c683495dd49d552c8775552d4af73a31a3482403dcb851badb36c09feb71b9b` |
| Nimbus | `assets/companions/nimbus/pet.json` | Project-authored manifest | CC0-1.0 | `058ce99c8e51ace521f70796e27ca865dc249e2bfa2401c244b5646d739cf968` |
| Pixel | `assets/companions/pixel/spritesheet.webp` | Created for Hermes Console by the Hermes Console team | CC0-1.0 | `b3ccb5fbc29596e79071e9142d9e1167495c4b5dd6b960ab78e8c0158a7060bf` |
| Pixel | `assets/companions/pixel/pet.json` | Project-authored manifest | CC0-1.0 | `f6d534728b318f6709154e509e15ddadf6a2218faebcaa834085f0afe396dbd2` |
| Violet | `assets/companions/violet/spritesheet.webp` | Created for Hermes Console by the Hermes Console team | CC0-1.0 | `163b19c92d285e9b5c54b1d22ae9902a68af532bfd4912df0336e387b7ab918b` |
| Violet | `assets/companions/violet/pet.json` | Project-authored manifest | CC0-1.0 | `8ce3c39e29b9690b0c1a3587d38446efafbdd03fadc81b5f9a395836530d9983` |

To verify the canonical files from the repository root:

```bash
sha256sum -c assets/branding/android-launcher-splash.sha256
sha256sum assets/branding/hermes_logo.webp \
  assets/branding/hermes_logo_light.png \
  assets/branding/spark_mark.svg \
  assets/branding/spark_mark.png \
  assets/branding/spark_mark.webp \
  assets/icon/play_store_512.png \
  assets/companions/*/pet.json \
  assets/companions/*/spritesheet.webp
```
