SELECT 
    vi.*
FROM 
--- Use `world-fishing-827.proj_ocean_ghg.vessel_info_v20241121` for original metadata
--- or `world-fishing-827.proj_ocean_ghg.vessel_info_rf_experimental_v20250516` for updated rf metadata
    `world-fishing-827.proj_ocean_ghg.vessel_info_rf_experimental_v20250516` AS vi 
WHERE 
    CAST(COALESCE(vi.imo_registry, vi.imo_ais) AS INT64) IN (
        SELECT DISTINCT imo 
        FROM `world-fishing-827.proj_ocean_ghg.snp_fuel_consumption_v20250404`
    )
