# Builds figures/si_inventory_comparison/fig-density-denominators-and-bins.png
#
# The two figures this replaces, combined into one:
#
#   A  aggregate density on the HARMONISED exact per-pass denominator - the
#      recorded per-pass areas with the pre-May-2021 values rescaled by a
#      measured factor k onto the later convention. Panel B of
#      si_aggregate_fleet_trends_figure.R.
#
#   B  aggregate density on the ADOPTED denominator, union area x passes, built
#      only from fields that do not depend on how the footprint polygons are
#      drawn. Panel C of si_aggregate_fleet_trends_figure.R.
#
#   C  the same adopted denominator split by length bin within each fleet, which
#      is fig-density-unionscenes-fullperiod.png. Drawn here with the right-edge
#      %/yr and significance labels the aggregate panels carry, so all three
#      panels are read the same way.
#
# The raw panel is dropped. A and B are the pair that matters: they are built
# from different fields and agree, which is what makes the adopted denominator
# defensible, while the raw panel's growth is the bookkeeping artifact those two
# exist to rule out.
#
# The figure carries no title, subtitle or panel descriptions - only the A/B/C
# labels and axis titles - so everything a reader needs is in the caption below.
#
# k is computed here rather than hardcoded, the same way
# si_aggregate_fleet_trends_figure.R computes it - as the ratio of mean per-pass
# coverage fraction either side of the convention change - so both figures move
# together if the extract is regenerated.
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
#   (C) The denominator of (B) split by vessel length bin within each fleet, on a
#   log10 y axis, same units as (B). Length bins are the Sentinel-1 estimated
#   length classes; the two fleets carry different bin sets because they occupy
#   different size ranges.
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
  library(forcats)
  library(cowplot)
})

S1B_FAILURE       <- as.Date("2021-12-01") # constellation halves
CONVENTION_CHANGE <- as.Date("2021-05-01") # recorded footprint areas change
ERA_GAP_START     <- as.Date("2021-09-01") # +/- 3 months excluded from era fits
ERA_GAP_END       <- as.Date("2022-04-01")

# One x scale for all three panels, so a year sits at the same place in each and
# the right-hand strip is free for the trend labels.
X_LIMITS <- c(as.Date("2017-01-01"), as.Date("2027-06-01"))
LABEL_X  <- as.Date("2026-03-01")

# Units spelled out on each axis, because the two denominators are not the same
# quantity: A is per area imaged, B and C are per area-times-opportunity.
Y_TITLE_A <- "Detections per million km² of\nper-pass footprint area (harmonised)"
Y_TITLE_B <- "Detections per million km² of\nunion area × passes"
Y_TITLE_C <- "Detections per million km² of union area × passes\n(log scale)"

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

# Panel C ----------------------------------------------------------------
# The adopted denominator again, now split by length bin. Same fit and label
# format as the panels above; the difference is that these are drawn on a log
# axis, so the labels are spread apart in log space.
bins <- density |>
  mutate(
    bin_max = suppressWarnings(as.numeric(length_bin_max)),
    bin = ifelse(
      is.na(bin_max) | is.infinite(bin_max),
      sprintf("%.0f+m", as.numeric(length_bin_min)),
      sprintf("%.0f-%.0fm", as.numeric(length_bin_min), bin_max)
    ),
    bin = fct_reorder(bin, length_size_bin),
    density = dens_union_scenes
  )

bin_trend <- trend_by_group(bins, fleet, length_size_bin, bin) |>
  group_by(fleet) |>
  mutate(
    # A tighter gap than the aggregate panels use: ten bins end close together
    # in the non-fishing fleet, and a generous gap walks the whole cluster far
    # enough up the axis that a label stops reading as belonging to its line.
    # 0.05 of the log range is about one line of text at this size.
    y_label = spread_labels(
      y_end,
      gap_fraction = 0.05,
      transform = log10,
      inverse = function(x) 10^x
    )
  ) |>
  ungroup()

length_palette <- viridisLite::turbo(10, end = 0.92)

# The legend sits above each subpanel, which frees the width the right-hand
# legend used to take. It also carries the fleet name, so the facet strip that
# used to identify the subpanel is dropped rather than stacked under a legend
# saying the same thing.
#
# Both legends are laid out on two rows even though the five fishing bins would
# fit on one, so the two legend blocks are the same height. That keeps them level
# with each other and, with the align call below, keeps a legend's size from
# deciding how tall its plot panel is.
fleet_panel <- function(fleet_name) {
  panel_data <- bins |> filter(fleet == fleet_name)
  panel_bins <- panel_data |>
    distinct(length_size_bin, bin) |>
    arrange(length_size_bin)

  ggplot(panel_data, aes(month, density, colour = bin)) +
    geom_line(linewidth = 0.3, alpha = 0.45) +
    geom_smooth(method = "lm", se = FALSE, linewidth = 0.9) +
    geom_text(
      data = bin_trend |> filter(fleet == fleet_name),
      aes(x = LABEL_X, y = y_label, label = label, colour = bin),
      hjust = 0, size = 2.4, fontface = "bold", show.legend = FALSE
    ) +
    scale_y_log10(
      labels = scales::comma,
      expand = expansion(mult = c(0.04, 0.10))
    ) +
    scale_x_date(
      date_breaks = "1 year", date_labels = "%Y", limits = X_LIMITS
    ) +
    scale_colour_manual(
      name = paste0(fleet_name, " length bin"),
      values = setNames(length_palette[seq_len(nrow(panel_bins))], panel_bins$bin)
    ) +
    guides(
      colour = guide_legend(
        nrow = 2,
        byrow = TRUE,
        # Above the keys rather than beside them: the title is as wide as two
        # keys, and beside them it pushed the last bin of each row off the
        # panel.
        title.position = "top"
      )
    ) +
    labs(x = "", y = Y_TITLE_C) +
    theme_bw(base_size = 9) +
    theme(
      legend.position = "top",
      legend.direction = "horizontal",
      legend.justification = "left",
      legend.key.height = unit(0.6, "lines"),
      legend.key.width = unit(1.1, "lines"),
      legend.title = element_text(size = 8, face = "bold"),
      legend.text = element_text(size = 7),
      legend.margin = margin(0, 0, 0, 0),
      legend.box.margin = margin(0, 0, 1, 0),
      legend.box.spacing = unit(3, "pt"),
      panel.grid.minor = element_blank(),
      plot.margin = margin(14, 6, 2, 6)
    )
}

# align/axis so the two panel areas are laid out to the same height and their top
# and bottom edges line up, rather than each plot dividing its own strip of the
# figure between legend and panel independently.
panel_c <- plot_grid(
  fleet_panel("Non-fishing"),
  fleet_panel("Fishing"),
  ncol = 2,
  align = "h",
  axis = "tb"
)

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
  panel_c,
  ncol = 1,
  rel_heights = c(0.09, 2, 1.42),
  labels = c("", "", "C"),
  label_size = 15,
  label_fontface = "bold",
  label_x = 0.002,
  hjust = 0
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

cat("\n=== Full-period trend, panel C by length bin ===\n\n")
bin_trend |>
  transmute(
    fleet,
    bin,
    slope = sprintf("%+.2f%%/yr", pct_per_year),
    sig = significance(p_value)
  ) |>
  as.data.frame() |>
  print(row.names = FALSE)

out_path <- file.path(
  "figures",
  "si_inventory_comparison",
  "fig-density-denominators-and-bins.png"
)
ggsave(out_path, combined, width = 11, height = 11.2, dpi = 200, bg = "white")
cat("\nwrote:", out_path, "\n")
