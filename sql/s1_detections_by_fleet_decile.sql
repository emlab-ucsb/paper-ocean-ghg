-- Monthly S1 detections / unmatched detections by length DECILE, computed
-- separately within fishing and non-fishing, pooled over all months so bin
-- edges are fixed in time.
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
),
-- Fixed decile edges over the whole period, one row per (fishing, decile).
decile_edges AS(
  SELECT
    fishing,
    length_decile,
    MIN(length_m) decile_min_m,
    MAX(length_m) decile_max_m
  FROM
    deciles
  GROUP BY
    fishing,
    length_decile
),
monthly AS(
  SELECT
    TIMESTAMP_TRUNC(detect_timestamp, MONTH) month,
    fishing,
    length_decile,
    COUNT(DISTINCT detect_id) n_s1_detections,
    COUNT(DISTINCT CASE WHEN detect_ssvid IS NULL THEN detect_id END) n_s1_detections_unmatched
  FROM
    deciles
  GROUP BY
    month,
    fishing,
    length_decile
)
SELECT
  *
FROM
  monthly
LEFT JOIN
  decile_edges
USING(fishing, length_decile)
ORDER BY
  month,
  fishing,
  length_decile
