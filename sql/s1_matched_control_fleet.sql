-- MATCHED-DETECTIONS CONTROL TEST.
--
-- AIS-measured vessel presence (ais_vessel_hours) is independent of S1
-- coverage. Matched S1 detections are detections of vessels AIS also saw.
-- Their ratio -- matched detections per (vessel-hour x pass) -- is S1's
-- detection efficiency for known-present vessels. If efficiency is flat
-- across the S1B break, the residual density steps (+10% non-fishing,
-- -15% fishing) are real presence changes; if efficiency reproduces them,
-- they are detectability artifacts.
--
-- ais_hours_x_scenes is the per-cell product summed over cells, so the
-- expected matched count in each cell scales with (presence x passes)
-- and effort redistribution across cells does not bias the ratio.
WITH
post_cells AS(
  SELECT DISTINCT lon_bin, lat_bin
  FROM `world-fishing-827.proj_ocean_ghg.s1_pixel_area_imaged_by_scene_v20260714`
  WHERE time > TIMESTAMP('2022-03-01')
    AND summed_imaged_m2 > 0
),
cov AS(
  -- per imaged cell-month: revisit count and bounded footprint
  SELECT
    c.time, c.lon_bin, c.lat_bin,
    c.number_s1_scenes AS scenes,
    c.union_imaged_m2
  FROM `world-fishing-827.proj_ocean_ghg.s1_pixel_area_imaged_by_scene_v20260714` c
  JOIN post_cells USING(lon_bin, lat_bin)
  WHERE c.summed_imaged_m2 > 0
),
feat AS(
  -- per imaged cell-month-fleet: detections and AIS presence
  -- (ais_vessel_hours is per length bin -> SUM across bins; verified)
  SELECT
    f.time, f.lon_bin, f.lat_bin, f.fishing,
    SUM(f.matched_s1_detections_per_km2_area_imaged   * f.pixel_area_imaged_m2 / 1e6) AS n_matched,
    SUM(f.unmatched_s1_detections_per_km2_area_imaged * f.pixel_area_imaged_m2 / 1e6) AS n_unmatched,
    SUM(IFNULL(f.ais_vessel_hours, 0)) AS ais_hours
  FROM `world-fishing-827.proj_ocean_ghg.rf_model_features_paper_v20260714` f
  JOIN post_cells USING(lon_bin, lat_bin)
  WHERE f.pixel_area_imaged_m2 > 0
  GROUP BY f.time, f.lon_bin, f.lat_bin, f.fishing
)
SELECT
  feat.time,
  feat.fishing,
  COUNT(*)                                    AS n_cells,
  SUM(feat.n_matched)                         AS n_matched,
  SUM(feat.n_unmatched)                       AS n_unmatched,
  SUM(feat.ais_hours)                         AS ais_vessel_hours,
  SUM(feat.ais_hours * cov.scenes)            AS ais_hours_x_scenes,
  SUM(cov.union_imaged_m2) / 1e6              AS union_km2,
  SUM(cov.union_imaged_m2 * cov.scenes) / 1e6 AS union_x_scenes_km2,
  AVG(cov.scenes)                             AS mean_scenes
FROM feat
JOIN cov USING(time, lon_bin, lat_bin)
GROUP BY feat.time, feat.fishing
ORDER BY feat.time, feat.fishing
