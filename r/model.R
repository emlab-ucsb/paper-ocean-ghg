annual_spatial_co2_emissions_ais_dark |>
  dplyr::group_by(year) |>
  dplyr::summarise(across(c(emissions_co2_mt,
                            emissions_co2_dark_mt),
                          ~sum(.,na.rm=TRUE))) |>
  dplyr::ungroup()

monthly_ais_to_dark_activity_extrapolation |>
  dplyr::group_by(year = lubridate::year(month)) |>
  dplyr::summarise(across(c(emissions_co2_mt,
                            emissions_co2_mt_dark),
                          ~sum(.,na.rm=TRUE))) |>
  dplyr::ungroup()

annual_extrapolation_dataset <- monthly_ais_to_dark_activity_extrapolation |>
  dplyr::mutate(length_size_class_percentile = as.factor(length_size_class_percentile)) |>
  dplyr::mutate(year = lubridate::year(month)) |>
  dplyr::filter(year>2015)   |>
  dplyr::group_by(year,
                  fishing,
                  length_size_class_percentile) |>
  dplyr::summarise(emissions_co2_mt_total = sum(emissions_co2_mt) + sum(emissions_co2_mt_dark),
                   kw_hours_total = sum(kw_hours) + sum(kw_hours_dark),
                   distance_nm_total = sum(distance_nm) + sum(distance_nm_dark),
                   hours_total = sum(hours) + sum(hours_dark)) |>
  dplyr::ungroup() |>
  dplyr::mutate(average_speed_knots = distance_nm_total/hours_total)
# Using annual_extrapolation_dataset, use tidymodels to train a random forest model
# to predict emissions
set.seed(123)

# Set initial split of data
inital_split <- annual_extrapolation_dataset |>
  rsample::initial_split(prop = 0.8)

# Train random forest on initial split using parsnip and ranger
model <- parsnip::rand_forest() |>
  parsnip::set_engine("ranger", importance = "impurity") |>
  parsnip::set_mode("regression") |>
  parsnip::fit(emissions_co2_mt_total ~ year + fishing + length_size_class_percentile + kw_hours_total + average_speed_knots, data = rsample::training(inital_split))

# Test performance of model on testing data
predictions <- predict(model, rsample::testing(inital_split))$.pred |>
  as.numeric()

augmented_testing_dataset <- rsample::testing(inital_split) |>
  dplyr::bind_cols(predictions = predictions)

# Calculate performance metrics
metrics <- yardstick::rsq_trad(data = augmented_testing_dataset,
                           truth = emissions_co2_mt_total,
                           estimate = predictions)
theme_plot <- function(){
  theme_minimal() %+replace%
    theme(axis.title.x = element_text(face = "bold"),
          axis.title.y = element_text(angle = 90,
                                      face = "bold",
                                      vjust = 3),
          strip.text.x = element_text(angle = 0,
                                      face = "bold"),
          strip.text.y = element_text(angle = 0,
                                      face = "bold"))}
augmented_testing_dataset |> 
  ggplot(aes(x = emissions_co2_mt_total, y = predictions)) + 
  geom_point() +
  theme_plot()

vip::vi(model) |>
  ggplot(aes(x = Importance,
             y = reorder(Variable,Importance))) +
  geom_bar(stat = "identity") +
  labs(x = "Feature importance",
       y = "Model feature") +
  theme_plot()

# Find initial values of kw_hours and speed, by fishing and length_size_class_percentile, for decomposition
starting_values <- annual_extrapolation_dataset |>
  dplyr::filter(year == 2016) |>
  dplyr::select(fishing,
                length_size_class_percentile,
                kw_hours_total_starting = kw_hours_total,
                average_speed_knots_starting = average_speed_knots)

predictions_dataset <- annual_extrapolation_dataset |>
  left_join(starting_values, by  = c("fishing","length_size_class_percentile")) 

final_prediction_dataset <- predictions_dataset |>
  bind_cols(observed_kw_hours_observed_speed = predict(model, predictions_dataset)$.pred) |>
  bind_cols(observed_kw_hours_constant_speed = predict(model, predictions_dataset  |>
                                                                     dplyr::select(-average_speed_knots) |>
                                                                     dplyr::rename(average_speed_knots = average_speed_knots_starting))$.pred)|>
  bind_cols(constant_kw_hours_observed_speed = predict(model, predictions_dataset|>
                                                                     dplyr::select(-kw_hours_total) |>
                                                                     dplyr::rename(kw_hours_total = kw_hours_total_starting))$.pred)|>
  bind_cols(constant_kw_hours_constant_speed = predict(model, predictions_dataset |>
                                                         dplyr::select(-average_speed_knots) |>
                                                         dplyr::rename(average_speed_knots = average_speed_knots_starting) |>
                                                         dplyr::select(-kw_hours_total) |>
                                                         dplyr::rename(kw_hours_total = kw_hours_total_starting))$.pred)




annual_extrapolation_dataset |>
  dplyr::select(-c(distance_nm_total,hours_total)) |>
  dplyr::rename(`Total kW-hours`= kw_hours_total,
                `Total CO2 emissions (CO2)` = emissions_co2_mt_total,
                `Average speed (knots)` = average_speed_knots) |>
  tidyr::pivot_longer(-c(year,fishing,length_size_class_percentile)) |>
  dplyr::mutate(fishing = ifelse(fishing,"Fishing vessels","Non-fishing vessels")) |>
  dplyr::mutate(name = forcats::fct_relevel(name,
                                            c("Total kW-hours"))) |>
  ggplot(aes(x = year,y = value,color=length_size_class_percentile,group=length_size_class_percentile)) +
  geom_line() +
  facet_wrap(name~fishing,scales="free_y",ncol=2) + 
  paletteer::scale_color_paletteer_d(palette = "jcolors::pal10",direction = -1) +
  theme_plot()+
  guides(color = guide_legend(reverse=TRUE)) +
  scale_x_continuous(breaks = unique(final_prediction_dataset$year)) +
  scale_y_continuous(limits = c(0,NA),labels = scales::comma) +
  labs(x = "",
       y = "",
       color = "Length percentile")+
  theme(panel.grid.minor.x = element_blank())

annual_extrapolation_dataset |>
  dplyr::group_by(year) |>
  dplyr::summarise(emissions_co2_mt_total = sum(emissions_co2_mt_total),
                   kw_hours_total = sum(kw_hours_total),
                   distance_nm_total = sum(distance_nm_total),
                   hours_total = sum(hours_total)) |>
  dplyr::ungroup() |>
  dplyr::mutate(average_speed_knots = distance_nm_total/hours_total)|>
  dplyr::select(-c(distance_nm_total,hours_total))  |>
  dplyr::rename(`Total kW-hours`= kw_hours_total,
                `Total CO2 emissions (CO2)` = emissions_co2_mt_total,
                `Average speed (knots)` = average_speed_knots) |>
  tidyr::pivot_longer(-c(year)) |>
  dplyr::mutate(name = forcats::fct_relevel(name,
                                            c("Total kW-hours"))) |>
  ggplot(aes(x = year,y = value)) +
  geom_line() +
  facet_wrap(name~.,scales="free_y",ncol=1) + 
  theme_plot()+
  guides(color = guide_legend(reverse=TRUE)) +
  scale_x_continuous(breaks = unique(final_prediction_dataset$year)) +
  scale_y_continuous(limits = c(0,NA),labels = scales::comma) +
  labs(x = "",
       y = "",
       color = "Length percentile")+
  theme(panel.grid.minor.x = element_blank())

final_prediction_dataset |>
  dplyr::select(observed_kw_hours_observed_speed,
                observed_kw_hours_constant_speed,
                constant_kw_hours_observed_speed,
                constant_kw_hours_constant_speed,
                year,fishing,length_size_class_percentile) |>
  dplyr::rename(`Observed kW-hours, observed speed` = observed_kw_hours_observed_speed,
                `Observed kW-hours, constant speed` = observed_kw_hours_constant_speed,
                `Constant kW-hours, observed speed` = constant_kw_hours_observed_speed,
                `Constant kW-hours, constant speed` = constant_kw_hours_constant_speed) |>
  tidyr::pivot_longer(-c(year,fishing,length_size_class_percentile)) |>
  dplyr::mutate(fishing = ifelse(fishing,"Fishing","Non-fishing")) |>
  ggplot(aes(x = year, y = value, color = name)) +
  geom_line() +
  guides(color = guide_legend(reverse=TRUE)) +
  scale_color_manual("Scenario",
                     values = c("steelblue4",
                                "steelblue2",
                                "coral4",
                                "coral2")) +
  scale_x_continuous(breaks = unique(final_prediction_dataset$year)) +
  scale_y_continuous(limits = c(0,NA),labels = scales::unit_format(unit = "M", scale = 1e-6)) +
  labs(x = "",
       y = "Predicted CO2 emissions (MT)") +
  theme_plot() +
  theme(panel.grid.minor.x = element_blank()) +
  facet_wrap(fishing~length_size_class_percentile,scales="free_y",ncol=10)

final_prediction_dataset |>
  dplyr::group_by(year) |>
  dplyr::summarise(across(c(observed_kw_hours_observed_speed,
                            observed_kw_hours_constant_speed,
                            constant_kw_hours_observed_speed,
                            constant_kw_hours_constant_speed),
                          ~sum(.,na.rm=TRUE))) |>
  dplyr::rename(`Observed kW-hours, observed speed` = observed_kw_hours_observed_speed,
                `Observed kW-hours, constant speed` = observed_kw_hours_constant_speed,
                `Constant kW-hours, observed speed` = constant_kw_hours_observed_speed,
                `Constant kW-hours, constant speed` = constant_kw_hours_constant_speed) |>
  tidyr::pivot_longer(-year) |>
  ggplot(aes(x = year, y = value, color = name)) +
  geom_line() +
  guides(color = guide_legend(reverse=TRUE)) +
  scale_color_manual("Scenario",
                     values = c("steelblue4",
                                "steelblue2",
                                "coral4",
                                "coral2")) +
  scale_x_continuous(breaks = unique(final_prediction_dataset$year)) +
  scale_y_continuous(limits = c(0,NA),
                     labels = scales::unit_format(unit = "M", scale = 1e-6)) +
  labs(x = "",
       y = "Predicted CO2 emissions (MT)") +
  theme_plot() +
  theme(panel.grid.minor.x = element_blank())
