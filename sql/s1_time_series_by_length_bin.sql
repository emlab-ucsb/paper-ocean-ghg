-- Monthly S1 vessel detections and unmatched detections, disaggregated by
-- the predefined vessel length size bin and by fishing / non-fishing.
--
-- Uses the length_size_bin already assigned in the size-classified table,
-- joined to rf_vessel_length_bins_* for the bin edges -- the same bin
-- definition used by length_size_bin_distributions.sql, so this figure stays
-- consistent with the length bin distributions figure.
--
-- Companion to s1_time_series.sql, which produces the same detection counts
-- aggregated across all length bins and fleets.
WITH
monthly AS(
  SELECT
    TIMESTAMP_TRUNC(detect_timestamp, MONTH) month,
    fishing,
    length_size_bin,
    COUNT(DISTINCT detect_id) n_s1_detections,
    COUNT(DISTINCT CASE WHEN detect_ssvid IS NULL THEN detect_id END) n_s1_detections_unmatched
  FROM
    `world-fishing-827.proj_ocean_ghg.rf_s1_detections_size_classified_{run_version_dark}`
  WHERE
    EXTRACT(YEAR FROM detect_timestamp) BETWEEN {analysis_start_year} AND {analysis_end_year}
  GROUP BY
    month,
    fishing,
    length_size_bin
)
SELECT
  *
FROM
  monthly
LEFT JOIN
  (SELECT * FROM `world-fishing-827.proj_ocean_ghg.rf_vessel_length_bins_{run_version_dark}`)
USING(fishing, length_size_bin)
ORDER BY
  month,
  fishing,
  length_size_bin
