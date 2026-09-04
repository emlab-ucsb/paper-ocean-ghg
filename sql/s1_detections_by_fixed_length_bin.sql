-- Monthly S1 vessel detections and unmatched detections, disaggregated by
-- vessel length decile (t1 = shortest 10%, t10 = longest 10%) and by
-- fishing / non-fishing.
--
-- Decile cutoffs are computed ONCE over the pooled detection distribution
-- across all months, so bin edges are fixed over time and a change in a
-- line reflects a real change in that fixed size range.
--
-- Cutoffs are computed SEPARATELY within fishing and non-fishing, because
-- fishing vessels are substantially shorter as a group: pooled deciles would
-- collapse nearly all fishing vessels into the lowest few bins. So t10 means
-- "longest 10% of fishing vessels" and "longest 10% of non-fishing vessels"
-- respectively -- the two are NOT the same length range. The emitted
-- length_decile_min_m / length_decile_max_m columns give each bin's actual
-- length range so this stays legible on the figure.
--
-- Companion to s1_time_series.sql, which produces the same detection counts
-- aggregated across all length bins and fleets.
WITH
detections AS(
  SELECT
    detect_id,
    detect_timestamp,
    detect_ssvid,
    fishing,
    length_m
  FROM
    `world-fishing-827.proj_ocean_ghg.rf_s1_detections_size_classified_paper_v20260714`
  WHERE
    EXTRACT(YEAR FROM detect_timestamp) BETWEEN 2017 AND 2025
    AND length_m IS NOT NULL
    AND fishing IS NOT NULL
),
-- Global, all-months-pooled deciles over detection length, computed within
-- each fleet separately.
deciles AS(
  SELECT
    detect_id,
    detect_timestamp,
    detect_ssvid,
    fishing,
    length_m,
    NTILE(10) OVER (PARTITION BY fishing ORDER BY length_m) AS length_decile
  FROM
    detections
)
SELECT
  TIMESTAMP_TRUNC(detect_timestamp, MONTH) month,
  fishing,
  length_decile,
  CONCAT('t', CAST(length_decile AS STRING)) length_decile_label,
  MIN(length_m) length_decile_min_m,
  MAX(length_m) length_decile_max_m,
  COUNT(DISTINCT detect_id) n_s1_detections,
  COUNT(DISTINCT CASE WHEN detect_ssvid IS NULL THEN detect_id END) n_s1_detections_unmatched
FROM
  deciles
GROUP BY
  month,
  fishing,
  length_decile
ORDER BY
  month,
  fishing,
  length_decile
