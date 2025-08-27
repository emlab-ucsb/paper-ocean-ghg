--Get matched vessels between vessel_info_v20241121 and snp_fuel_consumption_v20250404
WITH vessel_info_snp_match AS (
  SELECT 
    vi.*
  FROM 
    `world-fishing-827.proj_ocean_ghg.vessel_info_v20250701` AS vi
  WHERE 
    CAST(COALESCE(vi.imo_registry, vi.imo_ais) AS INT64) IN (
      SELECT DISTINCT imo 
      FROM `world-fishing-827.proj_ocean_ghg.snp_fuel_consumption_v20250607`
    )
),

-- Get repeated imo_ais
repeated_imo_ais AS (
  SELECT imo_ais
  FROM vessel_info_snp_match
  GROUP BY imo_ais
  HAVING COUNT(*) > 1
),

-- Filter repeated_imo_ais matches
filtered_repeated AS (
  SELECT vim.*, sf.*
  FROM vessel_info_snp_match AS vim
  JOIN repeated_imo_ais AS rep ON vim.imo_ais = rep.imo_ais
  JOIN `world-fishing-827.proj_ocean_ghg.snp_fuel_consumption_v20250607` AS sf
    ON CAST(vim.imo_ais AS STRING) = CAST(sf.imo AS STRING)
  WHERE CAST(vim.ssvid AS STRING) = CAST(sf.mmsi AS STRING)
     OR vim.ship_name_registry = sf.ship_name
     OR vim.ship_name_ais = sf.ship_name
),

-- Get non-repeated and add S&P variables
non_repeated_matches AS (
  SELECT vim.*, sf.*
  FROM vessel_info_snp_match AS vim
  LEFT JOIN repeated_imo_ais AS rep ON vim.imo_ais = rep.imo_ais
  JOIN `world-fishing-827.proj_ocean_ghg.snp_fuel_consumption_v20250607` AS sf
    ON CAST(vim.imo_ais AS STRING) = CAST(sf.imo AS STRING)
  WHERE rep.imo_ais IS NULL
),

-- Generate final combined dataset
combined_dataset AS ( 
  SELECT * FROM non_repeated_matches
  UNION ALL
  SELECT * FROM filtered_repeated
)


-- Apply BQ function to calculate main engine use
SELECT *,
  `world-fishing-827.proj_ocean_ghg.calculate_main_engine_energy_use_kwh_old`(
    24,  -- hours
    consumption_speed_1, ---speed_knots
    imo_table_81_avg_design_speed_knots,
    imo_table_81_avg_main_engine_power_kw,
    `world-fishing-827.proj_ocean_ghg.hull_fouling_correction_factor`(),
    `world-fishing-827.proj_ocean_ghg.weather_correction_factor`(10000),  -- distance_from_shore_m (set to 10000m to define offshore navigation)
    `world-fishing-827.proj_ocean_ghg.draft_correction_factor`(),
    vessel_class,
    on_fishing_list_best,
    FALSE  -- fishing_activity
  ) AS main_engine_energy_use_kwh_imo,

  `world-fishing-827.proj_ocean_ghg.calculate_main_engine_energy_use_kwh_old`(
    24,  -- hours
    consumption_speed_1, ---speed_knots
    design_speed_knots,
    main_engine_power_kw,
    `world-fishing-827.proj_ocean_ghg.hull_fouling_correction_factor`(),
    `world-fishing-827.proj_ocean_ghg.weather_correction_factor`(10000),  -- distance_from_shore_m (set to 10000m to define offshore navigation)
    `world-fishing-827.proj_ocean_ghg.draft_correction_factor`(),
    vessel_class,
    on_fishing_list_best,
    FALSE  -- fishing_activity
  ) AS main_engine_energy_use_kwh_rf,


  `world-fishing-827.proj_ocean_ghg.calculate_main_engine_energy_use_kwh_old`(
    24,  -- hours
    consumption_speed_1, ---speed_knots
    max_speed,
    engine_power,
    `world-fishing-827.proj_ocean_ghg.hull_fouling_correction_factor`(),
    `world-fishing-827.proj_ocean_ghg.weather_correction_factor`(10000),  -- distance_from_shore_m (set to 10000m to define offshore navigation)
    `world-fishing-827.proj_ocean_ghg.draft_correction_factor`(),
    vessel_class,
    on_fishing_list_best,
    FALSE  -- fishing_activity
  ) AS main_engine_energy_use_kwh_registered
FROM combined_dataset