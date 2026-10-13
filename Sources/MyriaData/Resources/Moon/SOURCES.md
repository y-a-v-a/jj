# Moon data sources

Produced by `swift run -c release jj-data moon` (also part of `jj-data all`),
which caches raw downloads in `data/raw/`. Retrieved 2026-10-13.

| File | Source | Licence |
| --- | --- | --- |
| `elevation.grid` | LRO LOLA Gridded Data Record `LDEM_4` (data set `LRO-L-LOLA-4-GDR-V1.0`, product V3.0, 2017; altimetry through mission phase LRO_ES_52), NASA Planetary Data System Geosciences Node: <https://pds-geosciences.wustl.edu/lro/lro-l-lola-3-rdr-v1/lrolol_1xxx/data/lola_gdr/cylindrical/img/ldem_4.img> with label `ldem_4.lbl`. Cite: Smith, D. E. et al. (2010), Initial observations from the Lunar Orbiter Laser Altimeter (LOLA), *Geophys. Res. Lett.* 37, L18204, doi:10.1029/2010GL043751; LRO LOLA science team (D. E. Smith, PI; NASA GSFC) | Public domain (U.S. Government work, NASA) |
| `features.json` | Gazetteer of Planetary Nomenclature, International Astronomical Union (IAU) Working Group for Planetary System Nomenclature (WGPSN), USGS Astrogeology Science Center, <https://planetarynames.wr.usgs.gov/> — centre points shapefile `MOON_nomenclature_center_pts.zip` (GIS Downloads, <https://asc-planetarynames-data.s3.us-west-2.amazonaws.com/MOON_nomenclature_center_pts.zip>) | Public domain (U.S. Government work, USGS); names approved by the IAU |

## Elevation

- Source: 1440 × 720 signed 16-bit samples, `LSB_INTEGER` (little endian),
  simple cylindrical, 4 px/deg, pixel registered. Line 1 is centred at
  89.875°N (rows north → south); sample 1 at 0.125°E (longitudes 0…360°,
  east positive). Mean Earth/polar axis (DE421) frame.
- Heights: `DN × 0.5` m above a **1737.4 km reference sphere** (the label's
  `SCALING_FACTOR` and `OFFSET`; planetary radius = height + 1737.4 km). This
  is radius minus a sphere, not topography above a selenoid.
- Conversion: rows flipped to south → north, columns rotated by 720 so the
  grid starts at −179.875°E. Stored as `int16` with `scale` 0.5 (the source
  DNs unchanged), LZFSE-compressed. Cell (i, j) is centred at
  (−179.875 + 0.25 i, −89.875 + 0.25 j). Range −8878.5 m (Antoniadi crater,
  South Pole–Aitken basin) … +10 504 m (near Engel'gardt).

## Named features

All adopted gazetteer features with a diameter (4 of 9087 have none), largest
2500 kept (diameter ≥ 30.7 km), sorted by diameter. `type` is the gazetteer's
feature type, singular (“Crater, craters” → “Crater”); “Satellite Feature” is
the gazetteer's type for lettered satellite craters such as “Hertzsprung D”
(1131 of the 2500). `lat` is planetocentric; `lon` converted from 0…360°E to
−180…180°E. `diameter` in km.
