# Mars data sources

Produced by `swift run -c release jj-data mars` (also part of `jj-data all`),
which caches raw downloads in `data/raw/`. Retrieved 2026-10-13.

| File | Source | Licence |
| --- | --- | --- |
| `elevation.grid` | MGS MOLA Mission Experiment Gridded Data Record (MEGDR) `MEGT90N000CB`, 4 px/deg median topography (data set `MGS-M-MOLA-5-MEGDR-L3-V1.0`, version 2.0, 2003), NASA Planetary Data System Geosciences Node: <https://pds-geosciences.wustl.edu/mgs/mgs-m-mola-5-megdr-l3-v1/mgsl_300x/meg004/megt90n000cb.img> with label `megt90n000cb.lbl`. Cite: Smith, D. E. et al. (2001), Mars Orbiter Laser Altimeter: Experiment summary after the first year of global mapping of Mars, *J. Geophys. Res.* 106(E10), 23689–23722, doi:10.1029/2000JE001364; MGS MOLA science team (D. E. Smith, PI; NASA GSFC) | Public domain (U.S. Government work, NASA) |
| `features.json` | Gazetteer of Planetary Nomenclature, International Astronomical Union (IAU) Working Group for Planetary System Nomenclature (WGPSN), USGS Astrogeology Science Center, <https://planetarynames.wr.usgs.gov/> — centre points shapefile `MARS_nomenclature_center_pts.zip` (GIS Downloads, <https://asc-planetarynames-data.s3.us-west-2.amazonaws.com/MARS_nomenclature_center_pts.zip>) | Public domain (U.S. Government work, USGS); names approved by the IAU |

## Elevation

- Source: 1440 × 720 signed 16-bit samples, `MSB_INTEGER` (big endian),
  simple cylindrical, 4 px/deg, pixel registered. Line 1 is centred at
  89.875°N (rows north → south); sample 1 at 0.125°E (longitudes 0…360°,
  east positive), planetocentric IAU 2000 coordinates.
- Heights: metres, no scaling: planetary radius minus the **areoid** radius
  (GMM-3 / mgm1025 equipotential to degree and order 50, mean equatorial
  radius 3396.0 km). Each cell is the median of MOLA shots in the cell,
  interpolated where a cell has none.
- Conversion: rows flipped to south → north, columns rotated by 720 so the
  grid starts at −179.875°E. Stored as `int16` metres, LZFSE-compressed.
  Cell (i, j) is centred at (−179.875 + 0.25 i, −89.875 + 0.25 j). Range
  −8068 m (Hellas, 32.9°S 62.1°E) … +21 134 m (Olympus Mons).

## Named features

All adopted gazetteer features with a diameter (127, mostly albedo features,
have none and are dropped), 1925 in all, sorted by diameter. `type` is the
gazetteer's feature type, singular (“Crater, craters” → “Crater”). `lat` is
planetocentric; `lon` converted from 0…360°E to −180…180°E. `diameter` in km.
