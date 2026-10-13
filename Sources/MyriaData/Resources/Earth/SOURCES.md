# Earth data sources

Everything here except `land.geojson` and `timezones.geojson` is produced by
`scripts/prepare-data.sh` (`swift run -c release jj-data all`), which caches
raw downloads in `data/raw/`. Vector coordinates are rounded to 0.001° and
simplified with Douglas–Peucker in lon/lat degrees (borders shared between
countries or plates are simplified once, so neighbours stay gap-free).

| File | Source | Licence |
| --- | --- | --- |
| `land.geojson` | Natural Earth 1:50m land, simplified to 40% | Public domain |
| `timezones.geojson` | timezone-boundary-builder 2026e, "with oceans, now" (github.com/evansiroky/timezone-boundary-builder), simplified to 1% and cleaned | ODbL 1.0, © OpenStreetMap contributors |
| `rivers.geojson` | Natural Earth 1:50m rivers and lake centre lines (`ne_50m_rivers_lake_centerlines`), 0.01° tolerance | Public domain |
| `lakes.geojson` | Natural Earth 1:50m lakes (`ne_50m_lakes`), 0.01° tolerance | Public domain |
| `countries.geojson` | Natural Earth 1:50m admin-0 countries (`ne_50m_admin_0_countries`), 0.02° tolerance | Public domain |
| `country-borders.geojson` | Natural Earth 1:50m land boundary lines (`ne_50m_admin_0_boundary_lines_land`), 0.02° tolerance | Public domain |
| `places.json` | Natural Earth 1:10m populated places (`ne_10m_populated_places_simple`) | Public domain |
| `plates.geojson`, `plate-boundaries.geojson` | PB2002 plate model: Bird, P. (2003), An updated digital model of plate boundaries, *Geochem. Geophys. Geosyst.* 4(3), 1027, doi:10.1029/2001GC000252. GeoJSON conversion by Hugo Ahlenius (github.com/fraxen/tectonicplates); boundaries built from `PB2002_steps.json`, 0.02° tolerance | ODC-BY 1.0 (conversion); cite Bird (2003) |
| `flights.json` | OpenFlights airports and routes (openflights.org/data; routes as of June 2014) | ODbL 1.0 |
| `precipitation.grid` | GPCP v2.3 monthly precipitation, long-term mean 1991–2020: Adler, R. F. et al. (2018), *Atmosphere* 9(4), 138, doi:10.3390/atmos9040138. Provided by NOAA PSL, Boulder, Colorado, USA (psl.noaa.gov) | Public domain (U.S. Government); acknowledge NOAA PSL |
| `wind.grid` | NCEP/NCAR Reanalysis 1, sigma 0.995 monthly long-term mean u/v wind 1991–2020: Kalnay, E. et al. (1996), The NCEP/NCAR 40-Year Reanalysis Project, *Bull. Amer. Meteor. Soc.* 77(3), 437–471. Provided by NOAA PSL | Public domain (U.S. Government); acknowledge NOAA PSL |
| `elevation.grid` | ETOPO1 Global Relief Model, ice surface, grid registered: Amante, C. & Eakins, B. W. (2009), NOAA Technical Memorandum NESDIS NGDC-24, NOAA NCEI, doi:10.7289/V5C8276M. Subsampled to 6 arc-minutes via NOAA CoastWatch ERDDAP (`etopo180`) | Public domain (U.S. Government) |

Made with Natural Earth. Map data © OpenStreetMap contributors (time zones).
