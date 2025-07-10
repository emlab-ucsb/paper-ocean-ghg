WITH
  new_table AS(
  SELECT
    EXTRACT(YEAR
    FROM
      date_formatted) year,
      domestic_international,
      other8,
    SUM(CO2_emissions) CO2_emissions,
  SUM(CH4_emissions) CH4_emissions,
 SUM( N2O_emissions) N2O_emissions,
  SUM(SOX_emissions) SOX_emissions,
  SUM(NOX_emissions) NOX_emissions,
  SUM(VOCS_emissions) VOCS_emissions,
  SUM(PM2_5_emissions) PM2_5_emissions,
  SUM(PM10_emissions) PM10_emissions,
  SUM(CO_emissions) CO_emissions,
  'v20250701' model_version
  FROM
    `world-fishing-827.proj_ocean_ghg.climate_trace_schema_v20250701`
  GROUP BY
    year,
      domestic_international,
      other8),
  old_table AS(
 SELECT
    EXTRACT(YEAR
    FROM
      date_formatted) year,
      domestic_international,
      other8,
    SUM(CO2_emissions) CO2_emissions,
  SUM(CH4_emissions) CH4_emissions,
 SUM( N2O_emissions) N2O_emissions,
  SUM(SOX_emissions) SOX_emissions,
  SUM(NOX_emissions) NOX_emissions,
  SUM(VOCS_emissions) VOCS_emissions,
  SUM(PM2_5_emissions) PM2_5_emissions,
  SUM(PM10_emissions) PM10_emissions,
  SUM(CO_emissions) CO_emissions,
  'v20241121' model_version
  FROM
    `world-fishing-827.proj_ocean_ghg.climate_trace_schema_v20241121`
  GROUP BY
    year,
      domestic_international,
      other8)
SELECT
  *
FROM
  new_table
UNION ALL
  (SELECT
  *
FROM
  old_table)