annual_extrapolation_dataset <- annual_ais_to_dark_activity_extrapolation |>
  dplyr::mutate(emissions_co2_mt_total = emissions_co2_mt + emissions_co2_mt_dark,
                   kw_hours_total = kw_hours + kw_hours_dark,
                   distance_nm_total = distance_nm + distance_nm_dark,
                   hours_total = hours + hours_dark) |>
  dplyr::select(-c(emissions_co2_mt, emissions_co2_mt_dark, 
                   kw_hours, kw_hours_dark, 
                   distance_nm, distance_nm_dark, 
                   hours, hours_dark))
# Using annual_extrapolation_dataset, use tidymodels to train a random forest model
# to predict emissions
set.seed(123)

# Set initial split of data
inital_split <- annual_extrapolation_dataset |>
  rsample::initial_split(prop = 0.8)

training_data <-rsample::training(inital_split)
testing_data <- rsample::testing(inital_split)

# Specify recipe for model
model_recipe <- recipes::recipe(emissions_co2_mt_total ~ fishing + length_size_class_percentile + hours_total + avg_speed_knots, 
                                data = head(rsample::training(inital_split))) |>
  recipes::step_num2factor(length_size_class_percentile,
                           levels = as.character(unique(annual_extrapolation_dataset$length_size_class_percentile)))

# Specify model type
model_type <- parsnip::rand_forest() |>
  parsnip::set_engine("ranger", importance = "impurity") |>
  parsnip::set_mode("regression")

# Initialize model workflow
model_workflow <- workflows::workflow() |>
  workflows::add_recipe(model_recipe) |>
  workflows::add_model(model_type)

# Fit model on training data
workflow_fit <- parsnip::fit(model_workflow,
                             training_data)

# Make predictions on testing data, and augment this to testing data frame
worflow_predictions <- parsnip::augment(workflow_fit,
                                        testing_data)


# Calculate performance metrics
metrics <- yardstick::rsq_trad(data = worflow_predictions,
                               truth = emissions_co2_mt_total,
                               estimate = .pred)

metrics
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
worflow_predictions |> 
  ggplot(aes(x = emissions_co2_mt_total, y = .pred)) + 
  geom_abline(slope = 1,alpha=0.25,linetype=2) +
  geom_point() +
  theme_plot() +
  coord_equal() +
  labs(x = "Observed annual CO2 emissions by vessel class",
       y = "Predicted annual CO2 emissions by vessel class") +
  scale_x_continuous(labels = scales::unit_format(unit = "M", scale = 1e-6)) +
  scale_y_continuous(labels = scales::unit_format(unit = "M", scale = 1e-6))

# Final model on all data
# Fit final model on all data
workflow_fit_final <- parsnip::fit(model_workflow,
                                   annual_extrapolation_dataset)

# Make partial dependence plots
# https://juliasilge.com/blog/mario-kart/
dalex_explainer <-DALEXtra::explain_tidymodels(
  workflow_fit_final,
  data = annual_extrapolation_dataset |>
    dplyr::select(-emissions_co2_mt_total),
  y = annual_extrapolation_dataset |>
    dplyr::select(emissions_co2_mt_total),
  verbose = FALSE
)

pdp <- DALEX::model_profile(
  dalex_explainer,
  variables = c("hours_total",
                "avg_speed_knots")
)

as_tibble(pdp$agr_profiles) %>%
  mutate(`_label_` = stringr::str_remove(`_label_`, "workflow_")) %>%
  ggplot(aes(`_x_`, `_yhat_`)) +
  geom_line(size = 1.2, alpha = 0.8) +
  facet_wrap(`_vname_`~., scales = "free",ncol=1)


# Prediction wrapper
pfun <- function(object, newdata) {
  predict(object, newdata)$.pred
}

shapley_values <- fastshap::explain(workflow_fit_final$fit$fit,
                  pred_wrapper = pfun,
                  X = annual_extrapolation_dataset |>
                    dplyr::select(-emissions_co2_mt_total),
                  nsim = 10) |>
  tibble::as_tibble() |>
  dplyr::select(hours_total,
                avg_speed_knots) |>
  tidyr::pivot_longer(dplyr::everything())

shapley_values |>
  ggplot(aes(x = value,
             y = name)) +
  geom_vline(xintercept = 0, color = "red") +
  geom_jitter(size=0.1)+
  geom_violin(fill=NA)

vip::vi(workflow_fit_final$fit$fit,
        method = "shap",
        pred_wrapper = pfun,
        train = annual_extrapolation_dataset |>
          dplyr::select(-emissions_co2_mt_total),
        feature_names = c("fishing","length_size_class_percentile","hours_total","avg_speed_knots"),
        nsim = 10,
        scale = TRUE)|>
  ggplot(aes(x = Importance,
             y = reorder(Variable,Importance))) +
  geom_bar(stat = "identity") +
  labs(x = "Feature importance",
       y = "Model feature") +
  theme_plot()

# Plot variable importance
vip::vi(workflow_fit_final, scale = TRUE) |>
  ggplot(aes(x = Importance,
             y = reorder(Variable,Importance))) +
  geom_bar(stat = "identity") +
  labs(x = "Feature importance",
       y = "Model feature") +
  theme_plot()

# Find initial/starting 2016 values of hours and speed, by fishing and length_size_class_percentile, for decomposition
starting_values <- annual_extrapolation_dataset |>
  dplyr::filter(year == 2016) |>
  dplyr::select(fishing,
                length_size_class_percentile,
                kw_hours_total_starting = kw_hours_total,
                hours_total_starting = hours_total,
                avg_speed_knots_starting = avg_speed_knots)

predictions_dataset <- annual_extrapolation_dataset |>
  left_join(starting_values, by  = c("fishing","length_size_class_percentile")) 

final_prediction_dataset <- predictions_dataset |>
  # Add model predictions using observed hours and observed speed
  bind_cols(observed_hours_observed_speed = predict(workflow_fit_final, predictions_dataset)$.pred) |>
  # Add model predictions using observed hours and constant speed (from 2016)
  bind_cols(observed_hours_constant_speed = predict(workflow_fit_final, predictions_dataset  |>
                                                      dplyr::select(-avg_speed_knots) |>
                                                      dplyr::rename(avg_speed_knots = avg_speed_knots_starting))$.pred)|>
  # Add model predictions using constant hours (from 2016) and observed speed
  bind_cols(constant_hours_observed_speed = predict(workflow_fit_final, predictions_dataset|>
                                                      dplyr::select(-hours_total) |>
                                                      dplyr::rename(hours_total = hours_total_starting))$.pred)|>
  # Add model predictions using constant hours (from 2016) and constant speed (from 2016)
  bind_cols(constant_hours_constant_speed = predict(workflow_fit_final, predictions_dataset |>
                                                      dplyr::select(-avg_speed_knots) |>
                                                      dplyr::rename(avg_speed_knots = avg_speed_knots_starting) |>
                                                      dplyr::select(-hours_total) |>
                                                      dplyr::rename(hours_total = hours_total_starting))$.pred)




annual_extrapolation_dataset |>
  dplyr::select(-c(distance_nm_total,kw_hours_total)) |>
  dplyr::rename(`Total hours`= hours_total,
                `Total CO2 emissions (CO2)` = emissions_co2_mt_total,
                `Average speed (knots)` = avg_speed_knots) |>
  tidyr::pivot_longer(-c(year,fishing,length_size_class_percentile)) |>
  dplyr::mutate(fishing = ifelse(fishing,"Fishing vessels","Non-fishing vessels")) |>
  dplyr::mutate(name = forcats::fct_relevel(name,
                                            c("Total hours"))) |>
  ggplot(aes(x = year,y = value,color=as.factor(length_size_class_percentile),group=length_size_class_percentile)) +
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
                   hours_total = sum(hours_total),
                   avg_speed_knots = mean(avg_speed_knots)) |>
  dplyr::ungroup() |>
  dplyr::select(-c(distance_nm_total,kw_hours_total))  |>
  dplyr::rename(`Total hours`= hours_total,
                `Total CO2 emissions (MT)` = emissions_co2_mt_total,
                `Average speed (knots)` = avg_speed_knots) |>
  tidyr::pivot_longer(-c(year)) |>
  dplyr::mutate(name = forcats::fct_relevel(name,
                                            c("Total hours"))) |>
  ggplot(aes(x = year,y = value)) +
  geom_line() +
  facet_wrap(name~.,scales="free_y",ncol=1) + 
  theme_plot()+
  guides(color = guide_legend(reverse=TRUE)) +
  scale_x_continuous(breaks = unique(final_prediction_dataset$year)) +
  scale_y_continuous(limits = c(0,NA),
                     labels = scales::comma) +
  labs(x = "",
       y = "",
       color = "Length percentile")+
  theme(panel.grid.minor.x = element_blank())

final_prediction_dataset |>
  dplyr::select(observed_hours_observed_speed,
                observed_hours_constant_speed,
                constant_hours_observed_speed,
                constant_hours_constant_speed,
                year,fishing,length_size_class_percentile) |>
  dplyr::rename(`Observed hours, observed speed` = observed_hours_observed_speed,
                `Observed hours, constant speed` = observed_hours_constant_speed,
                `Constant hours, observed speed` = constant_hours_observed_speed,
                `Constant hours, constant speed` = constant_hours_constant_speed) |>
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
  scale_y_continuous(#limits = c(0,NA),
    labels = scales::unit_format(unit = "M", scale = 1e-6)) +
  labs(x = "",
       y = "Predicted CO2 emissions (MT)") +
  theme_plot() +
  theme(panel.grid.minor.x = element_blank()) +
  facet_wrap(fishing~length_size_class_percentile,scales="free_y",ncol=10)

final_prediction_dataset |>
  dplyr::group_by(year) |>
  dplyr::summarise(across(c(observed_hours_observed_speed,
                            observed_hours_constant_speed,
                            constant_hours_observed_speed,
                            constant_hours_constant_speed),
                          ~sum(.,na.rm=TRUE))) |>
  dplyr::rename(`Observed hours, observed speed` = observed_hours_observed_speed,
                `Observed hours, constant speed` = observed_hours_constant_speed,
                `Constant hours, observed speed` = constant_hours_observed_speed,
                `Constant hours, constant speed` = constant_hours_constant_speed) |>
  tidyr::pivot_longer(-year) |>
  ggplot(aes(x = year, y = value, color = name)) +
  geom_line() +
  guides(color = guide_legend(reverse=TRUE)) +
  scale_color_manual("Prediction scenario",
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

