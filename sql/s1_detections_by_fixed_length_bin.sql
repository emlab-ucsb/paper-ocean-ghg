-- Monthly S1 vessel detections and unmatched detections, by fishing /
-- non-fishing and by the model's fixed length bins (25 m steps: ten bins for
-- non-fishing up to 225+ m, five for fishing up to 100+ m). Bin edges come from
-- rf_vessel_length_bins, the same table the model features use, so a line on
-- the figure is a fixed size range over the whole record and a change in it is
-- a change within that range.
--
-- Bins are defined separately for fishing and non-fishing, so the same
-- length_size_bin index is a different length range in the two fleets; the
-- emitted length_bin_min / length_bin_max give each bin's actual range.
--
-- Feeds the SI unmatched-share figures (issue #9). Companion to
-- s1_time_series.sql, which gives the same counts pooled across bins and fleets.
SELECT
  fishing,
  length_size_bin,
  TIMESTAMP_TRUNC(detect_timestamp, MONTH) month,
  COUNT(DISTINCT detect_id) n_s1_detections,
  COUNT(DISTINCT CASE WHEN detect_ssvid IS NULL THEN detect_id END) n_s1_detections_unmatched,
  ANY_VALUE(length_bin_min) length_bin_min,
  ANY_VALUE(length_bin_max) length_bin_max
FROM
  `world-fishing-827.proj_ocean_ghg.rf_s1_detections_size_classified_{run_version_dark}`
LEFT JOIN
  `world-fishing-827.proj_ocean_ghg.rf_vessel_length_bins_{run_version_dark}`
USING (fishing, length_size_bin)
WHERE
  EXTRACT(YEAR FROM detect_timestamp) BETWEEN {analysis_start_year} AND {analysis_end_year}
GROUP BY
  fishing,
  length_size_bin,
  month
ORDER BY
  month,
  fishing,
  length_size_bin
