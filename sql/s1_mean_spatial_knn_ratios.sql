WITH
within_footprint AS(SELECT
  fishing,
  lon_bin,
  lat_bin,
  AVG(avg_neighbor_ratio) avg_neighbor_ratio,
  TRUE within_footprint
FROM
  `world-fishing-827.proj_ocean_ghg.s1_knn_ratios_within_footprint_{run_version_dark}`
    WHERE EXTRACT(YEAR FROM time) BETWEEN {analysis_start_year} and {analysis_end_year}

GROUP BY
  fishing,
  lon_bin,
  lat_bin),
outside_footprint AS(
  SELECT
  fishing,
  lon_bin,
  lat_bin,
  AVG(avg_neighbor_ratio) avg_neighbor_ratio,
  FALSE within_footprint
FROM
  `world-fishing-827.proj_ocean_ghg.s1_knn_ratios_outside_footprint_{run_version_dark}`
   # Need to remove inside footprint ratios
  LEFT JOIN (
    SELECT
      fishing,
      lon_bin,
      lat_bin,
      TRUE inside_footprint
    FROM
      within_footprint)
    USING(lon_bin,lat_bin,fishing)
    WHERE EXTRACT(YEAR FROM time) BETWEEN {analysis_start_year} and {analysis_end_year}
    AND inside_footprint IS NULL
GROUP BY
  fishing,
  lon_bin,
  lat_bin
)
SELECT
*
FROM
within_footprint
UNION ALL
(SELECT * FROM outside_footprint)