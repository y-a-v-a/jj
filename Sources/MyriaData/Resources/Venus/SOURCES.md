# Venus data sources

Produced by `swift run -c release jj-data venus` (also part of `jj-data all`),
which caches raw downloads in `data/raw/`. Retrieved 2026-10-13.

| File | Source | Licence |
| --- | --- | --- |
| `elevation.grid` | Venus Magellan Global Topography 4641 m, version 2, USGS Astrogeology Science Center, derived from the Magellan Global Topographic Data Record (GTDR), NASA Planetary Data System: <https://planetarymaps.usgs.gov/mosaic/Venus_Magellan_Topography_Global_4641m_v02.tif>. Cite: Ford, P. G. and Pettengill, G. H. (1992), Venus topography and kilometer-scale slopes, *J. Geophys. Res.* 97(E8), 13103–13114, doi:10.1029/92JE01085 | Public domain (U.S. Government work, NASA/USGS) |
| `features.json` | Gazetteer of Planetary Nomenclature, International Astronomical Union (IAU) Working Group for Planetary System Nomenclature (WGPSN), USGS Astrogeology Science Center, <https://planetarynames.wr.usgs.gov/> — centre points shapefile `VENUS_nomenclature_center_pts.zip` (<https://asc-planetarynames-data.s3.us-west-2.amazonaws.com/VENUS_nomenclature_center_pts.zip>) | Public domain (U.S. Government work, USGS); names approved by the IAU |

## Elevation

- Source: an uncompressed GeoTIFF, 8192 × 4096 signed 16-bit samples, one
  strip per row, little endian, NoData −32768. Simple cylindrical on a
  sphere of 6051.0 km (GeoKeys), 4641.0589 m pixels: 22.76 px/deg, the top
  left corner at 180°W 90°N (rows north → south).
- Heights: metres above the **6051.0 km reference sphere**. The mean
  planetary radius is 6051.8 km; the area-weighted median height is +677 m.
- Conversion: every 4 px/deg cell (1440 × 720, matching the Moon and Mars)
  averages the source pixels whose centres fall inside it; rows flipped to
  south → north. Magellan's coverage gaps (7.8 % of the cells, mostly
  within 10° of the poles and between 40° and 80°S) are filled from their
  surroundings: layer by layer from the edges of each gap, then smoothed by
  Laplace iterations with the measured cells fixed. Stored as `int16`
  metres, LZFSE-compressed. Range −2951 m … +11 687 m (Maxwell Montes).

## Named features

All adopted gazetteer features with a diameter (11 of 1985 have none),
1974 kept, sorted by diameter. `type` is the gazetteer's feature type,
singular (“Crater, craters” → “Crater”): 881 craters, 340 coronae, 117
montes, 99 dorsa, 72 paterae, 72 valles among them. `lat` is
planetocentric; `lon` converted from 0…360°E to −180…180°E. `diameter` in km.
