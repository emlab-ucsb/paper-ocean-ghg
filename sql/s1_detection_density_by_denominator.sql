-- Three-denominator comparison of detection density, on the cell set that is
-- available post-2022 (all such cells, not the >=80% core).
--
--   summed_imaged_m2  = SUM(per-scene intersection area)  [km2 x passes]
--   union_imaged_m2   = area imaged >=1x, bounded by pixel area  [km2]
--   union x scenes    = union area weighted by revisit count
--
-- Whichever denominator makes the S1B step vanish has the scaling assumption
-- that matches how detections actually accumulate.
WITH
post_cells AS(
  SELECT DISTINCT lon_bin, lat_bin
  FROM `world-fishing-827.proj_ocean_ghg.s1_pixel_area_imaged_by_scene_v20260714`
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
  FROM `world-fishing-827.proj_ocean_ghg.s1_pixel_area_imaged_by_scene_v20260714` c
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
  FROM `world-fishing-827.proj_ocean_ghg.rf_model_features_paper_v20260714` f
  JOIN post_cells USING(lon_bin, lat_bin)
  WHERE f.pixel_area_imaged_m2 > 0
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
