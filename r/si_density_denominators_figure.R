# Builds figures/figS-density-denominators-and-bins.png
#
# Aggregate Sentinel-1 detection density drawn twice, under two independent
# measures of observing effort:
#
#   A  aggregate density on the HARMONISED exact per-pass denominator - the
#      recorded per-pass areas with the pre-May-2021 values rescaled by a
#      measured factor k onto the later convention.
#
#   B  aggregate density on the ADOPTED denominator, union area x passes, built
#      only from fields that do not depend on how the footprint polygons are
#      drawn.
#
# The raw panel is dropped. A and B are the pair that matters: they are built
# from different fields and agree, which is what makes the adopted denominator
# defensible, while the raw panel's growth is the bookkeeping artifact those two
# exist to rule out.
#
# The per-length-bin split that used to sit here as panel C is dropped as well.
# si_density_by_match_status.R draws the same series as its Total row and then
# decomposes it by AIS match status, so it carries that reading in full and this
# figure can stay on the denominator question it exists to settle.
#
# The file name still says "and-bins" because inventories_comparison.md links
# the figure by that path.
#
# The figure carries no title, subtitle or panel descriptions - only the A/B
# labels and axis titles - so everything a reader needs is in the caption below.
#
# k is computed here rather than hardcoded - as the ratio of mean per-pass
# coverage fraction either side of the convention change - so panel A stays
# correct if the extract is regenerated.
#
# Run from the project root:  Rscript r/si_density_denominators_figure.R
#
# Input:  data/gfw/s1_detection_density_by_denominator.csv
#           (one-off extract; query kept at
#            sql/s1_detection_density_by_denominator.sql)

# --------------------------------------------------------------------------
# CAPTION - reference text for the SI. Not drawn on the figure; kept here so the
# description travels with the code that makes it. Numbers quoted are the ones
# this script prints, so re-check them if the extract is regenerated.
#
#   Sentinel-1 detection density, 2017-2025, under two independent measures of
#   observing effort. Monthly values are thin lines; thick lines are ordinary
#   least squares fits of log density on time over the full period. Right-edge
#   labels give the fitted trend as percent change per year, exp(slope) - 1,
#   with significance from the slope's two-sided t test (*** p < 0.001,
#   ** p < 0.01, * p < 0.05, ns otherwise).
#
#   (A) Detections per million km2 of summed per-pass footprint area, in
#   detections per 10^6 km2. This is the exact measure of area imaged, but the
#   recorded per-pass polygons change convention in May 2021; values before that
#   date are multiplied by k = 1.81, the ratio of mean per-pass coverage
#   fraction either side of the change, to splice the two conventions onto the
#   later basis. Series are the two fleets and their sum.
#
#   (B) Detections per million km2 of union area x mean passes, in detections
#   per 10^6 km2 per pass. Union footprint area and pass counts do not depend on
#   how per-pass polygons are drawn, so this denominator is immune to the May
#   2021 convention change. It overstates effort by a stable factor 1/phi, where
#   phi is the per-pass coverage fraction, so its level is an index rather than a
#   physical density while its trends and between-fleet ratios are unaffected.
#   Every density result in the analysis uses this denominator. A and B are built
#   from different fields and agree, which is the cross-check the pair exists to
#   provide.
#
#   Vertical markers in A and B: dotted line, May 2021 footprint bookkeeping
#   change; dashed line, loss of Sentinel-1B in December 2021; grey band, the
#   +/- 3 months around that loss excluded from era-split fits elsewhere in the
#   analysis (the full-period fits shown here use every month).
# --------------------------------------------------------------------------

suppressMessages({
  library(dplyr)
  library(readr)
  library(ggplot2)
  library(broom)
  library(cowplot)
})

S1B_FAILURE       <- as.Date("2021-12-01") # constellation halves
CONVENTION_CHANGE <- as.Date("2021-05-01") # recorded footprint areas change
ERA_GAP_START     <- as.Date("2021-09-01") # +/- 3 months excluded from era fits
ERA_GAP_END       <- as.Date("2022-04-01")

# One x scale for both panels, so a year sits at the same place in each and the
# right-hand strip is free for the trend labels.
X_LIMITS <- c(as.Date("2017-01-01"), as.Date("2027-06-01"))
LABEL_X  <- as.Date("2026-03-01")

# Units spelled out on each axis, because the two denominators are not the same
# quantity: A is per area imaged, B is per area-times-opportunity.
Y_TITLE_A <- "Detections per million km² of\nper-pass footprint area (harmonised)"
Y_TITLE_B <- "Detections per million km² of\nunion area × passes"

density <- read_csv(
  file.path("data", "gfw", "s1_detection_density_by_denominator.csv"),
  show_col_types = FALSE
) |>
  mutate(
    month = as.Date(time),
    fleet = ifelse(fishing, "Fishing", "Non-fishing")
  )

# Per-pass coverage fraction: the share of a cell's union footprint that each
# recorded pass covers. The adopted denominator assumes this is constant; it is,
# within each recording convention, but it halves at the convention change.
coverage_fraction <- density |>
  filter(dens_summed > 0, dens_union_scenes > 0) |>
  mutate(phi = dens_union_scenes / dens_summed) |>
  group_by(month) |>
  summarise(phi = median(phi), .groups = "drop")

k <- mean(coverage_fraction$phi[coverage_fraction$month < CONVENTION_CHANGE]) /
  mean(coverage_fraction$phi[coverage_fraction$month >= CONVENTION_CHANGE])
cat(sprintf("splice factor k = %.3f\n", k))

density <- density |>
  mutate(
    dens_summed_harmonised = dens_summed *
      ifelse(month < CONVENTION_CHANGE, k, 1)
  )

significance <- function(p) {
  case_when(p < 0.001 ~ "***", p < 0.01 ~ "**", p < 0.05 ~ "*", TRUE ~ "ns")
}

# Full-period log-linear trend per series, which is what the right-edge label
# reports: percent per year, its significance, and where the fitted line ends so
# the label can sit beside it.
trend_by_group <- function(data, ...) {
  data |>
    group_by(...) |>
    group_modify(~ {
      d <- .x |> mutate(t_years = as.numeric(month - min(month)) / 365.25)
      fit <- lm(log(density) ~ t_years, data = d)
      slope <- tidy(fit) |> filter(term == "t_years")
      tibble(
        pct_per_year = 100 * (exp(slope$estimate) - 1),
        p_value = slope$p.value,
        y_end = exp(predict(fit, newdata = tibble(t_years = max(d$t_years))))
      )
    }) |>
    ungroup() |>
    mutate(label = sprintf("%+.1f%%/yr %s", pct_per_year, significance(p_value)))
}

# Push labels apart where fitted lines end close together, walking up from the
# lowest. `transform` is identity on a linear axis and log on a log one, so the
# minimum gap is enforced in the space the axis actually draws.
spread_labels <- function(y_end, gap_fraction, transform = identity,
                         inverse = identity) {
  y <- transform(y_end)
  order_index <- order(y)
  y <- y[order_index]
  gap <- gap_fraction * diff(range(y))
  if (length(y) > 1) {
    for (i in 2:length(y)) {
      if (y[i] - y[i - 1] < gap) y[i] <- y[i - 1] + gap
    }
  }
  inverse(y)[order(order_index)]
}

# Panels A and B ----------------------------------------------------------
# Drawn as two plots rather than two facets of one, because the denominators
# carry different units and so each needs its own y title.
#
# Densities share a denominator within a month, so they are additive across
# length bins and fleets: the fleet and all-fleet series are plain sums.
aggregate_series <- function(column) {
  bind_rows(
    density |>
      group_by(month, fleet) |>
      summarise(density = sum(.data[[column]]), .groups = "drop"),
    density |>
      group_by(month) |>
      summarise(density = sum(.data[[column]]), .groups = "drop") |>
      mutate(fleet = "All fleets")
  ) |>
    mutate(
      series = factor(fleet, levels = c("All fleets", "Fishing", "Non-fishing"))
    )
}

series_colours <- c(
  "All fleets" = "grey20",
  "Fishing" = "#d95f0e",
  "Non-fishing" = "#2c7fb8"
)

aggregate_panel <- function(column, y_title) {
  series <- aggregate_series(column)
  trend <- trend_by_group(series, series) |>
    mutate(y_label = spread_labels(y_end, gap_fraction = 0.085))

  plot <- ggplot(series, aes(month, density, colour = series)) +
    annotate(
      "rect",
      xmin = ERA_GAP_START, xmax = ERA_GAP_END, ymin = -Inf, ymax = Inf,
      fill = "grey70", alpha = 0.30
    ) +
    geom_vline(
      xintercept = CONVENTION_CHANGE,
      linetype = "dotted", colour = "grey35", linewidth = 0.4
    ) +
    geom_vline(
      xintercept = S1B_FAILURE,
      linetype = "dashed", colour = "grey30", linewidth = 0.35
    ) +
    geom_line(linewidth = 0.32, alpha = 0.42) +
    geom_smooth(method = "lm", se = FALSE, linewidth = 1.0) +
    geom_text(
      data = trend,
      aes(x = LABEL_X, y = y_label, label = label, colour = series),
      hjust = 0, size = 2.8, fontface = "bold", show.legend = FALSE
    ) +
    scale_colour_manual(NULL, values = series_colours) +
    scale_x_date(
      date_breaks = "1 year", date_labels = "%Y", limits = X_LIMITS
    ) +
    scale_y_continuous(limits = c(0, NA), labels = scales::comma) +
    labs(x = "", y = y_title) +
    theme_bw(base_size = 9) +
    theme(
      legend.position = "none",
      panel.grid.minor = element_blank(),
      plot.margin = margin(14, 10, 2, 6)
    )

  list(plot = plot, trend = trend)
}

panel_a <- aggregate_panel("dens_summed_harmonised", Y_TITLE_A)
panel_b <- aggregate_panel("dens_union_scenes", Y_TITLE_B)

# One shared fleet legend for A and B, lifted off A so it is not drawn twice.
fleet_legend <- get_legend(
  panel_a$plot +
    theme(legend.position = "top", legend.justification = "center")
)

# A and B in their own grid so cowplot can align them: their y titles are
# different lengths, and without this each panel starts wherever its own title
# leaves room and the two time axes do not line up.
panel_ab <- plot_grid(
  panel_a$plot,
  panel_b$plot,
  ncol = 1,
  align = "v",
  axis = "lr",
  labels = c("A", "B"),
  label_size = 15,
  label_fontface = "bold",
  label_x = 0.002,
  hjust = 0
)

combined <- plot_grid(
  fleet_legend,
  panel_ab,
  ncol = 1,
  rel_heights = c(0.09, 2)
) +
  theme(plot.background = element_rect(fill = "white", colour = NA))

cat("\n=== Full-period trend, aggregate panels ===\n\n")
bind_rows(
  panel_a$trend |> mutate(panel = "A harmonised"),
  panel_b$trend |> mutate(panel = "B adopted")
) |>
  transmute(
    panel,
    series,
    slope = sprintf("%+.2f%%/yr", pct_per_year),
    sig = significance(p_value)
  ) |>
  as.data.frame() |>
  print(row.names = FALSE)

out_path <- file.path(
  "figures",
  "figS-density-denominators-and-bins.png"
)
ggsave(out_path, combined, width = 11, height = 6.7, dpi = 200, bg = "white")
cat("\nwrote:", out_path, "\n")
