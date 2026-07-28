-- This query simulates emissions using registered data to validate the model
WITH

-- Normalize imo number to facilitate match between datasets
snp_fuel_consumption AS (
    SELECT
    *,
    CAST(mmsi AS STRING) AS mmsi_registered,
    `world-fishing-827.udfs.normalize_imo`(CAST(imo AS STRING)) AS imo_normalized
    FROM
    `world-fishing-827.proj_ocean_ghg.snp_fuel_consumption_v20250607`
),

-- The IMO Table 81 defaults (main engine power, design speed) used to be columns
-- on vessel_info. As of v20260714 they live in their own lookup table, so we match
-- them on vessel class and gross tonnage band here instead.
-- Bump each band's lower bound up to the previous band's upper bound so no vessel
-- falls through the bins. Same approach as the table 17 join in
-- ocean-ghg/sql/ais/vessel_info.sql.
imo_table_81 AS(
  SELECT
  vessel_class,
  CASE
    WHEN LAG(size_upper_gt) OVER (PARTITION BY vessel_class ORDER BY size_lower_gt) IS NOT NULL THEN LAG(size_upper_gt+1e-10) OVER (PARTITION BY vessel_class ORDER BY size_lower_gt)
    ELSE CAST(size_lower_gt AS FLOAT64)
    END
  AS size_lower_gt,
  size_upper_gt,
  avg_main_engine_power_kw,
  avg_design_speed_knots
  FROM
  `world-fishing-827.proj_ocean_ghg.main_engine_power_design_speed_by_vessel_type_imo`
),

vessel_info AS(
  SELECT
  vessel_info.*,
  `world-fishing-827.udfs.normalize_imo`(CAST(imo_ais AS STRING)) AS imo_ais_normalized,
  imo_table_81.avg_main_engine_power_kw AS imo_table_81_avg_main_engine_power_kw,
  imo_table_81.avg_design_speed_knots AS imo_table_81_avg_design_speed_knots
  FROM
  `world-fishing-827.proj_ocean_ghg.vessel_info_{run_version_ais}` vessel_info
  -- LEFT JOIN rather than the inner JOIN used upstream, so vessels whose class is
  -- absent from table 81 keep a NULL IMO estimate instead of dropping out of the
  -- validation sample entirely
  LEFT JOIN
  imo_table_81
  ON vessel_info.vessel_class = imo_table_81.vessel_class
  AND ROUND(vessel_info.tonnage_gt) >= imo_table_81.size_lower_gt
  AND (ROUND(vessel_info.tonnage_gt) <= imo_table_81.size_upper_gt
    OR imo_table_81.size_upper_gt IS NULL)
),

-- Match vessels between datasets by mmsi/ssvid and imo number
--- We conducted additional matching tests using normalized ship names
--- however, they proved unreliable and yielded few additional observations.
combined_dataset AS(
    SELECT
    *            
    FROM vessel_info
    JOIN snp_fuel_consumption
    ON imo_ais_normalized = imo_normalized
    AND ssvid = mmsi_registered
),

-- Simulate emissions using main engine model for 24h using registered data consumption speeds
-- First calculate load factors
load_factor_dataset AS (
    SELECT *,

    -- Calculate load factors using design speeds from IMO lookup table
    `world-fishing-827.proj_ocean_ghg.calculate_main_engine_energy_load_factor`( 
        consumption_speed_1, ---speed_knots
        imo_table_81_avg_design_speed_knots,
        `world-fishing-827.proj_ocean_ghg.hull_fouling_correction_factor`(),
        `world-fishing-827.proj_ocean_ghg.weather_correction_factor`(10000),  -- distance_from_shore_m (set to 10000m to define offshore navigation)
        `world-fishing-827.proj_ocean_ghg.draft_correction_factor`(),
        vessel_class,
        is_fishing_vessel_class,
        FALSE  -- fishing_activity
        ) AS main_engine_load_factor_imo,

    -- Calculate load factors using our RF design speeds
    `world-fishing-827.proj_ocean_ghg.calculate_main_engine_energy_load_factor`(
        consumption_speed_1, ---speed_knots
        design_speed_knots,
        `world-fishing-827.proj_ocean_ghg.hull_fouling_correction_factor`(),
        `world-fishing-827.proj_ocean_ghg.weather_correction_factor`(10000),  -- distance_from_shore_m (set to 10000m to define offshore navigation)
        `world-fishing-827.proj_ocean_ghg.draft_correction_factor`(),
        vessel_class,
        is_fishing_vessel_class,
        FALSE  -- fishing_activity
        ) AS main_engine_load_factor_rf,

    -- Calculate load factors using the registered data max speeds
    `world-fishing-827.proj_ocean_ghg.calculate_main_engine_energy_load_factor`( 
        consumption_speed_1, ---speed_knots
        max_speed,
        `world-fishing-827.proj_ocean_ghg.hull_fouling_correction_factor`(),
        `world-fishing-827.proj_ocean_ghg.weather_correction_factor`(10000),  -- distance_from_shore_m (set to 10000m to define offshore navigation)
        `world-fishing-827.proj_ocean_ghg.draft_correction_factor`(),
        vessel_class,
        is_fishing_vessel_class,
        FALSE  -- fishing_activity
        ) AS main_engine_load_factor_registered,
    
    FROM combined_dataset),

-- Calculate energy use
energy_use AS(
    SELECT *,
    
    -- Calculate energy use using main engine power from IMO lookup table
    `world-fishing-827.proj_ocean_ghg.calculate_main_engine_energy_use_kwh`(
        24,  -- hours
        imo_table_81_avg_main_engine_power_kw,
        main_engine_load_factor_imo
        ) AS main_engine_energy_use_kwh_imo,

    -- Calculate energy use using using our RF main engine power estimates
    `world-fishing-827.proj_ocean_ghg.calculate_main_engine_energy_use_kwh`(
        24,  -- hours
        main_engine_power_kw,
        main_engine_load_factor_rf
        ) AS main_engine_energy_use_kwh_rf,

    -- Calculate energy use using the registered data main engine power values
    `world-fishing-827.proj_ocean_ghg.calculate_main_engine_energy_use_kwh`(
        24,  -- hours
        engine_power,
        main_engine_load_factor_registered
        ) AS main_engine_energy_use_kwh_registered
    
    FROM load_factor_dataset
)

-- Generate emissions estimates
SELECT 
    -- Convert energy use to emissions using the corresponding emissions factors
    (main_engine_energy_use_kwh_imo * 629.83333)/1e6 AS co2_emissions_tonnes_estimate_imo,
    (main_engine_energy_use_kwh_rf * 629.83333)/1e6 AS co2_emissions_tonnes_estimate_rf,
    (main_engine_energy_use_kwh_registered * 629.83333)/1e6 AS co2_emissions_tonnes_estimate_registered,
    -- Convert registered data consumption values to emissions
    consumption_value_1 * 3.12 AS co2_emissions_tonnes_registered
FROM energy_use
