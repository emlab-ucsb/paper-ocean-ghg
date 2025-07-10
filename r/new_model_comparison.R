library(ggplot2)
new_model_comparison_all_pollutants <- glue::glue(
  "{project_directory}/data/processed/new_model_comparison_all_pollutants.csv"
)  |>
  readr::read_csv()|>
  dplyr::filter(year<2025)

new_model_comparison_all_pollutants  |>
  tidyr::pivot_longer(-c(year,model_version)) |>
  ggplot(aes(x = year, y = value, color=model_version)) +
  geom_line() +
  facet_wrap(name~.,scales="free") +
  scale_y_continuous(limits = c(0,NA), 
                     labels = scales::comma_format(scale = 1e-9, accuracy = 0.1, suffix = "B")) +
  scale_x_continuous(breaks = seq(2015,2024)) +
  theme_bw() +
  labs(x = "", y = "Annual total CO2 emissions (MT)") +
  theme(panel.grid.minor.x = element_blank()) +
  scale_color_brewer(palette = "Dark2")

new_model_comparison_all_pollutants  |>
  tidyr::pivot_longer(-c(year,model_version))  |>
  tidyr::pivot_wider(names_from = model_version, values_from = value) |>
  dplyr::mutate(fraction_change = (v20250701 - v20241121)/v20241121) |>
  ggplot(aes(x = year, y = fraction_change)) +
  geom_bar(stat = "identity") +
  facet_wrap(name~.,scales="free") +
  scale_y_continuous(labels = scales::percent) +
  scale_x_continuous(breaks = seq(2015,2024)) +
  theme_bw() +
  geom_hline(yintercept = 0, linetype = "dashed") +
  labs(x = "", y = "Percent difference in annual CO2 emissions\nbetween new and old model") +
  theme(panel.grid.minor.x = element_blank())

new_model_comparison_voyages <- glue::glue(
  "{project_directory}/data/processed/new_model_comparison_voyages.csv"
)  |>
  readr::read_csv()|>
  dplyr::filter(year<2025)

new_model_comparison_voyages |>
  tidyr::pivot_longer(-c(year,model_version))  |>
  ggplot(aes(x = year, y = value, color=model_version)) +
  facet_wrap(name~., scales = "free") +
  geom_line() +
  scale_y_continuous(limits = c(0,NA), 
                     labels = scales::comma_format(scale = 1e-9, accuracy = 0.1, suffix = "B")) +
  scale_x_continuous(breaks = seq(2015,2024)) +
  theme_bw() +
  labs(x = "", y = "Annual total CO2 emissions attributed to voyages (MT)") +
  theme(panel.grid.minor.x = element_blank()) +
  scale_color_brewer(palette = "Dark2")

new_model_comparison_voyages  |>
  tidyr::pivot_longer(-c(year,model_version))  |>
  tidyr::pivot_wider(names_from = model_version, values_from = value) |>
  dplyr::mutate(fraction_change = (v20250701 - v20241121)/v20241121)  |>
  ggplot(aes(x = year, y = fraction_change))+
  facet_wrap(name~., scales = "free")  +
  geom_bar(stat = "identity") +
  scale_y_continuous(labels = scales::percent) +
  scale_x_continuous(breaks = seq(2015,2024)) +
  theme_bw() +
  geom_hline(yintercept = 0, linetype = "dashed") +
  labs(x = "", y = "Percent difference in annual CO2 emissions attributed to voyages\nbetween new and old model") +
  theme(panel.grid.minor.x = element_blank())

new_model_comparison_port_visits <- glue::glue(
  "{project_directory}/data/processed/new_model_comparison_port_visits.csv"
)  |>
  readr::read_csv()|>
  dplyr::filter(year<2025)

new_model_comparison_port_visits  |>
  tidyr::pivot_longer(-c(year,model_version)) |>
  ggplot(aes(x = year, y = value, color=model_version))  +
  geom_line() +
  facet_wrap(name~.,scales="free")+
  scale_y_continuous(limits = c(0,NA), 
                     labels = scales::comma_format(scale = 1e-9, accuracy = 0.1, suffix = "B")) +
  scale_x_continuous(breaks = seq(2015,2024)) +
  theme_bw() +
  labs(x = "", y = "Annual total CO2 emissions attributed to port visits (MT)") +
  theme(panel.grid.minor.x = element_blank()) +
  scale_color_brewer(palette = "Dark2")

new_model_comparison_port_visits |>
  tidyr::pivot_longer(-c(year,model_version))  |>
  tidyr::pivot_wider(names_from = model_version, values_from = value) |>
  dplyr::mutate(fraction_change = (v20250701 - v20241121)/v20241121)  |>
  ggplot(aes(x = year, y = fraction_change))+
  facet_wrap(name~., scales = "free") +
  geom_bar(stat = "identity") +
  scale_y_continuous(labels = scales::percent) +
  scale_x_continuous(breaks = seq(2015,2024)) +
  theme_bw() +
  geom_hline(yintercept = 0, linetype = "dashed") +
  labs(x = "", y = "Percent difference in annual CO2 emissions attributed to port visits\nbetween new and old model") +
  theme(panel.grid.minor.x = element_blank())

new_model_comparison_ct_schema <- glue::glue(
  "{project_directory}/data/processed/new_model_comparison_ct_schema.csv"
)  |>
  readr::read_csv()|>
  dplyr::filter(year<2025) |>
  dplyr::mutate(type = ifelse(other8,"voyage","port visit")) |>
  dplyr::select(-other8)

new_model_comparison_ct_schema |>
  dplyr::mutate(type = glue::glue("{type} ({domestic_international})")) |>
  dplyr::select(-domestic_international) |>
  tidyr::pivot_longer(cols = -c(year,type,model_version)) |>
  ggplot(aes(x = year, y = value, color=model_version)) +
  geom_line()+
  facet_wrap(type~name, scales = "free_y",ncol=9) +
  scale_y_continuous(limits = c(0,NA), 
                     labels = scales::comma_format(scale = 1e-9, accuracy = 0.1, suffix = "B")) +
  scale_x_continuous(breaks = seq(2015,2024)) +
  theme_bw() +
  labs(x = "", y = "Annual total CO2 emissions attributed to port visits (MT)") +
  theme(panel.grid.minor.x = element_blank()) +
  scale_color_brewer(palette = "Dark2")

new_model_comparison_ct_schema  |>
  dplyr::mutate(type = glue::glue("{type} ({domestic_international})")) |>
  dplyr::select(-domestic_international) |>
  tidyr::pivot_longer(cols = -c(year,type,model_version))  |>
  tidyr::pivot_wider(names_from = model_version, values_from = value) |>
  dplyr::mutate(fraction_change = (v20250701 - v20241121)/v20241121) |>
  ggplot(aes(x = year, y = fraction_change)) +
  geom_bar(stat = "identity") +
  facet_wrap(type~name, scales = "free_y",ncol=9) +
  scale_y_continuous(labels = scales::percent) +
  scale_x_continuous(breaks = seq(2015,2024)) +
  theme_bw() +
  geom_hline(yintercept = 0, linetype = "dashed") +
  labs(x = "", y = "Percent difference in annual CO2 emissions attributed to port visits\nbetween new and old model") +
  theme(panel.grid.minor.x = element_blank())

glue::glue(
  "{project_directory}/data/processed/new_monthly_data.csv"
)  |>
  readr::read_csv() |>
  ggplot(aes(x = month, y = emissions_co2_mt)) +
  geom_line() +
  labs(x = "", y = "Monthly CO2 emissions (MT)",title = "Global monthly CO2 emissions from AIS-broadcasting vessels (latest model)") +
  scale_y_continuous(limits = c(0,NA), 
                     labels = scales::comma_format(scale = 1e-6, accuracy = 1, suffix = "M")) +
  scale_x_continuous(breaks = seq(lubridate::ymd("2015-01-01"),lubridate::ymd("2025-01-01"), by = "1 year"),
                     labels = seq(2015,2025)) +
  theme_bw()

glue::glue(
  "{project_directory}/data/processed/new_monthly_data.csv"
)  |>
  readr::read_csv() |>
  dplyr::group_by(year = lubridate::year(month)) |>
  dplyr::summarise(emissions_co2_mt = sum(emissions_co2_mt, na.rm = TRUE)) |>
  dplyr::ungroup() |>
  dplyr::filter(year<2025) |>
  ggplot(aes(x = year, y = emissions_co2_mt)) +
  geom_line() +
  labs(x = "", y = "Annual CO2 emissions (MT)",title = "Global annual CO2 emissions from AIS-broadcasting vessels (latest model)") +
  scale_y_continuous(limits = c(0,NA), 
                     labels = scales::comma_format(scale = 1e-9, accuracy = 1, suffix = "B")) +
  scale_x_continuous(breaks =  seq(2015,2025),
                     labels = seq(2015,2025)) +
  theme_bw()

glue::glue(
  "{project_directory}/data/processed/old_monthly_data.csv"
)  |>
  readr::read_csv() |>
  ggplot(aes(x = month, y = emissions_co2_mt+emissions_co2_dark_mt)) +
  geom_line()+
  scale_x_continuous(breaks =  seq(2015,2024),
                     labels = seq(2015,2024)) +
  theme_bw()+
  scale_y_continuous(limits = c(0,NA), 
                     labels = scales::comma_format(scale = 1e-6, accuracy = 1, suffix = "M"))+
  labs(x = "", y = "Monthly CO2 emissions (MT)",title = "Global monthly CO2 emissions from AIS-broadcasting and non-broadcasting vessels\n(old models)") 


glue::glue(
  "{project_directory}/data/processed/old_monthly_data.csv"
)  |>
  readr::read_csv() |>
  dplyr::group_by(year = lubridate::year(month))|>
  dplyr::summarise(emissions_co2_mt = sum(emissions_co2_mt+emissions_co2_dark_mt, na.rm = TRUE)) |>
  dplyr::ungroup() |>
  dplyr::filter(year<2025)  |>
  ggplot(aes(x = year, y = emissions_co2_mt)) +
  geom_line()+
  scale_x_continuous(breaks =  seq(2015,2024),
                     labels = seq(2015,2024)) +
  theme_bw()+
  scale_y_continuous(limits = c(0,NA), 
                     labels = scales::comma_format(scale = 1e-9, accuracy = 1, suffix = "B"))+
  labs(x = "", y = "Annual CO2 emissions (MT)",title = "Global annual CO2 emissions from AIS-broadcasting and non-broadcasting vessels\n(old models)") 
