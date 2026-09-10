-- Monthly S1 detection counts per fleet and length bin, with three measures of
-- S1 sampling effort, on the cell set that is available post-2022 (all cells
-- imaged at any point after March 2022, applied to the whole series so the
-- averaged ocean does not change at the S1B loss).
--
--   summed_km2         = SUM(per-scene intersection area)   [km2 x passes]
--   union_km2          = area imaged >=1x, bounded by pixel area  [km2]
--   union_x_scenes_km2 = union area weighted by revisit count
--
-- Detection counts are reconstructed as density x pixel_area_imaged_m2, which
-- cancels the model's denominator exactly, so they are raw counts.
--
-- History (issue #10). The recorded summed area used to change units at May
-- 2021 because detect_foot_raw repeats each scene's footprint row before then
-- and s1_pixel_area_imaged_by_scene summed over the repeats. The union x
-- scenes denominator was adopted as the one measure immune to that. Since the
-- 2026-09-09 rebuild the coverage table collapses the repeats before summing,
-- so summed area is now continuous over the record (phi = summed / (union x
-- scenes) sits at 0.455-0.462 in every year) and the two denominators are
-- proportional throughout. Both are kept so the figures can show that.
WITH
post_cells AS(
  SELECT DISTINCT lon_bin, lat_bin
  FROM `world-fishing-827.proj_ocean_ghg.s1_pixel_area_imaged_by_scene_{run_version_s1}`
  WHERE time > TIMESTAMP('2022-03-01')
    AND summed_imaged_m2 > 0
),
cov AS(
  SELECT
    c.time,
    SUM(c.summed_imaged_m2) / 1e6                        AS summed_km2,
    SUM(c.union_imaged_m2)  / 1e6                        AS union_km2,
    SUM(c.union_imaged_m2 * c.number_s1_scenes) / 1e6    AS union_x_scenes_km2,
    COUNT(*)                                             AS n_cells,
    AVG(c.number_s1_scenes)                              AS mean_scenes
  FROM `world-fishing-827.proj_ocean_ghg.s1_pixel_area_imaged_by_scene_{run_version_s1}` c
  JOIN post_cells USING(lon_bin, lat_bin)
  WHERE c.summed_imaged_m2 > 0
  GROUP BY c.time
),
dets AS(
  SELECT
    f.time,
    f.fishing,
    f.length_size_bin,
    ANY_VALUE(f.length_bin_min) AS length_bin_min,
    ANY_VALUE(f.length_bin_max) AS length_bin_max,
    SUM(f.matched_s1_detections_per_km2_area_imaged   * f.pixel_area_imaged_m2 / 1e6) AS n_matched,
    SUM(f.unmatched_s1_detections_per_km2_area_imaged * f.pixel_area_imaged_m2 / 1e6) AS n_unmatched
  FROM `world-fishing-827.proj_ocean_ghg.rf_model_features_{run_version_s1}` f
  JOIN post_cells USING(lon_bin, lat_bin)
  WHERE f.pixel_area_imaged_m2 > 0
    AND EXTRACT(YEAR FROM f.time) BETWEEN {analysis_start_year} AND {analysis_end_year}
  GROUP BY f.time, f.fishing, f.length_size_bin
)
SELECT
  dets.time,
  dets.fishing,
  dets.length_size_bin,
  dets.length_bin_min,
  dets.length_bin_max,
  dets.n_matched,
  dets.n_unmatched,
  cov.n_cells,
  cov.mean_scenes,
  cov.summed_km2,
  cov.union_km2,
  cov.union_x_scenes_km2,
  1e6 * (dets.n_matched + dets.n_unmatched) / cov.summed_km2         AS dens_summed,
  1e6 * (dets.n_matched + dets.n_unmatched) / cov.union_km2          AS dens_union,
  1e6 * (dets.n_matched + dets.n_unmatched) / cov.union_x_scenes_km2 AS dens_union_scenes
FROM dets
JOIN cov USING(time)
ORDER BY time, fishing, length_size_bin
