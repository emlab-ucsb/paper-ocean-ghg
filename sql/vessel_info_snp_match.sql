WITH

snp_fuel_consumption AS (
  SELECT
  *,
  CAST(mmsi AS STRING) AS mmsi_registered,
  `world-fishing-827.udfs.normalize_imo`(CAST(imo AS STRING)) AS imo_normalized,
  --`world-fishing-827.udfs.normalize_shipname`(ship_name) AS ship_name_normalized
FROM
  `world-fishing-827.proj_ocean_ghg.snp_fuel_consumption_v20250607`
),

vessel_info AS(
  SELECT
  *,
  --`world-fishing-827.udfs.normalize_imo`(CAST(imo_registry AS STRING)) AS imo_registry_normalized,
  `world-fishing-827.udfs.normalize_imo`(CAST(imo_ais AS STRING)) AS imo_ais_normalized,
  -- `world-fishing-827.udfs.normalize_shipname`(ship_name_registry) AS ship_name_registry_normalized,
  -- `world-fishing-827.udfs.normalize_shipname`(ship_name_ais) AS ship_name_ais_normalized

FROM
  `world-fishing-827.proj_ocean_ghg.vessel_info_v20250701`
),

combined_dataset AS(

  SELECT
    *,                       
    'imo_mmsi_name' AS match_type
  FROM vessel_info
  JOIN snp_fuel_consumption
    ON imo_ais_normalized = imo_normalized
    AND   ssvid    = mmsi_registered
),



-- Apply BQ function to calculate main engine use
load_factor_dataset AS (SELECT *,

  `world-fishing-827.proj_ocean_ghg.calculate_main_engine_energy_load_factor`( 
            consumption_speed_1, ---speed_knots
            imo_table_81_avg_design_speed_knots,
            `world-fishing-827.proj_ocean_ghg.hull_fouling_correction_factor`(),
            `world-fishing-827.proj_ocean_ghg.weather_correction_factor`(10000),  -- distance_from_shore_m (set to 10000m to define offshore navigation)
            `world-fishing-827.proj_ocean_ghg.draft_correction_factor`(),
            vessel_class,
            on_fishing_list_best,
            FALSE  -- fishing_activity
        ) AS main_engine_load_factor_imo,

  `world-fishing-827.proj_ocean_ghg.calculate_main_engine_energy_load_factor`(
            consumption_speed_1, ---speed_knots
            design_speed_knots,
            `world-fishing-827.proj_ocean_ghg.hull_fouling_correction_factor`(),
            `world-fishing-827.proj_ocean_ghg.weather_correction_factor`(10000),  -- distance_from_shore_m (set to 10000m to define offshore navigation)
            `world-fishing-827.proj_ocean_ghg.draft_correction_factor`(),
            vessel_class,
            on_fishing_list_best,
            FALSE  -- fishing_activity
        ) AS main_engine_load_factor_rf,

      `world-fishing-827.proj_ocean_ghg.calculate_main_engine_energy_load_factor`( 
            consumption_speed_1, ---speed_knots
            max_speed,
            `world-fishing-827.proj_ocean_ghg.hull_fouling_correction_factor`(),
            `world-fishing-827.proj_ocean_ghg.weather_correction_factor`(10000),  -- distance_from_shore_m (set to 10000m to define offshore navigation)
            `world-fishing-827.proj_ocean_ghg.draft_correction_factor`(),
            vessel_class,
            on_fishing_list_best,
            FALSE  -- fishing_activity
        ) AS main_engine_load_factor_registered,
FROM combined_dataset),

energy_use AS(
  

-- Apply BQ function to calculate main engine use
    SELECT *,
    `world-fishing-827.proj_ocean_ghg.calculate_main_engine_energy_use_kwh`(
          24,  -- hours
          imo_table_81_avg_main_engine_power_kw,
          main_engine_load_factor_imo
          ) AS main_engine_energy_use_kwh_imo,

  `world-fishing-827.proj_ocean_ghg.calculate_main_engine_energy_use_kwh`(
          24,  -- hours
          main_engine_power_kw,
          main_engine_load_factor_rf
          ) AS main_engine_energy_use_kwh_rf,

    `world-fishing-827.proj_ocean_ghg.calculate_main_engine_energy_use_kwh`(
          24,  -- hours
          engine_power,
          main_engine_load_factor_registered
          ) AS main_engine_energy_use_kwh_registered
FROM load_factor_dataset
)


SELECT *,
 (main_engine_energy_use_kwh_imo * 629.83333)/1e6 AS co2_emissions_tonnes_estimate_imo,
 (main_engine_energy_use_kwh_rf * 629.83333)/1e6 AS co2_emissions_tonnes_estimate_rf,
 (main_engine_energy_use_kwh_registered * 629.83333)/1e6 AS co2_emissions_tonnes_estimate_registered,
 consumption_value_1 * 3.12 AS co2_emissions_tonnes_registered
FROM energy_use
