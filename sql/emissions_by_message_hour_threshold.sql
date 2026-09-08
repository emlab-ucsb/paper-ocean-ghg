-- Cumulative share of AIS CO2 emissions as a function of the per-message time
-- threshold: for each cutoff from 0.1 to 24.0 hours, how much of the total is
-- carried by pings whose attributed duration falls at or below that cutoff.
--
-- Each ping in ping_level_emissions carries an `hours` value (the time the
-- message is taken to represent) and the emissions accrued over it. Long
-- `hours` mean a sparse message stream, where emissions are extrapolated
-- across a gap rather than observed. This quantifies how much of the emissions
-- total rests on those interpolated stretches, so a gap threshold can be
-- chosen -- or its irrelevance shown -- with the cost in coverage known.
--
-- Returns one row per threshold (240 of them): cumulative emissions, the grand
-- total, and the fraction. Pings longer than 24 h count towards the total but
-- never towards a cumulative, so the fraction need not reach 1.
WITH
-- Emissions per 0.1-hour bin of message duration, as integer tenths so that
-- bins and thresholds compare exactly. CEIL rounds up, so bin 9 holds
-- durations in (0.8, 0.9] and belongs to the 0.9-hour threshold. GREATEST puts
-- zero-duration pings in the first bin rather than a bin 0 no threshold covers.
ping_bins AS (
  SELECT
    CAST(GREATEST(CEIL(hours * 10), 1) AS INT64) AS hour_bin_tenths,
    SUM(emissions_co2_mt) AS emissions_co2_mt
  FROM
    `world-fishing-827.proj_ocean_ghg.ping_level_emissions_{run_version_ais}`
  WHERE
    -- Drops NULL hours as well, which would bin to NULL and match no threshold.
    hours >= 0
    AND emissions_co2_mt IS NOT NULL
    AND EXTRACT(YEAR FROM timestamp) BETWEEN {analysis_start_year} AND {analysis_end_year}
  GROUP BY hour_bin_tenths
),
total AS (
  SELECT SUM(emissions_co2_mt) AS total_emissions_co2_mt
  FROM ping_bins
),
-- Running sum up the threshold grid. Every threshold gets a row whether or not
-- its bin has any pings in it.
cumulative AS (
  SELECT
    threshold_tenths,
    SUM(IFNULL(ping_bins.emissions_co2_mt, 0))
      OVER (ORDER BY threshold_tenths) AS cumulative_emissions_co2_mt
  FROM
    UNNEST(GENERATE_ARRAY(1, 240)) AS threshold_tenths
  LEFT JOIN ping_bins
    ON ping_bins.hour_bin_tenths = threshold_tenths
)
SELECT
  threshold_tenths / 10 AS threshold_hours,
  cumulative_emissions_co2_mt,
  total_emissions_co2_mt,
  SAFE_DIVIDE(cumulative_emissions_co2_mt, total_emissions_co2_mt) AS fraction_of_total
FROM
  cumulative
CROSS JOIN total
ORDER BY threshold_hours
