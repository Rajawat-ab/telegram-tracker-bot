# reports.R -- the evening habit nudge and the Sunday recap with charts.
# Any run can send them: whichever run first lands after the due time sends the report
# once and records the date in state.json, so a late or skipped schedule never loses it.

local_now <- function(now = Sys.time()) {
  list(date = as.Date(format(now, "%Y-%m-%d", tz = BOT_TZ)),
       hour = as.integer(format(now, "%H", tz = BOT_TZ)),
       wday = as.integer(format(now, "%u", tz = BOT_TZ)))
}

# Which reports are due and not yet sent today. scripts/precheck.sh mirrors this logic.
due_reports <- function(state, now = Sys.time()) {
  t <- local_now(now)
  today <- format(t$date)
  due <- character(0)
  if (t$hour >= NUDGE_HOUR && !identical(state$last_nudge_date, today)) due <- c(due, "nudge")
  if (t$wday == WEEKLY_DAY && t$hour >= WEEKLY_HOUR && !identical(state$last_weekly_date, today)) {
    due <- c(due, "weekly")
  }
  due
}

# NULL when every recent habit is already done today.
nudge_text <- function(today) {
  h <- read_habits()
  done <- unique(h$habit[h$date == today])
  pending <- setdiff(active_habits(h, today), done)
  if (length(pending) == 0) return(NULL)
  streaks <- vapply(pending, function(n) calc_streak(h$date[h$habit == n], today), integer(1))
  items <- ifelse(streaks >= 3, sprintf("%s (%d-day streak)", pending, streaks), pending)
  sprintf("Evening check-in! Still open today: %s.\nA quick \"done %s\" keeps things rolling.",
          paste(items, collapse = ", "), pending[1])
}

weekly_items <- function(today, chart_dir) {
  items <- list(list(type = "text", text = cmd_week(today, title = "Your week in review")))
  charts <- tryCatch(weekly_charts(today, chart_dir), error = function(e) {
    message("Could not draw the weekly charts: ", conditionMessage(e))
    list()
  })
  c(items, charts)
}

weekly_charts <- function(today, chart_dir) {
  suppressPackageStartupMessages(library(ggplot2))
  e <- read_expenses()
  h <- read_habits()
  out <- list()

  cur <- spend_between(e, today - 6, today)
  if (nrow(cur) > 0) {
    days <- seq(today - 6, today, by = "day")
    df <- aggregate(amount ~ date + category, data = cur, FUN = sum)
    df$date <- as.Date(df$date, origin = "1970-01-01")
    p <- ggplot(df, aes(date, amount, fill = category)) +
      geom_col(width = 0.7) +
      scale_x_date(breaks = days, date_labels = "%a") +
      labs(title = "Spending by day", x = NULL, y = "Rs", fill = NULL) +
      theme_minimal(base_size = 13) +
      theme(panel.grid.minor = element_blank(), legend.position = "bottom")
    f <- file.path(chart_dir, "spending.png")
    ggsave(f, p, width = 7, height = 4, dpi = 150, bg = "white")
    out[[length(out) + 1]] <- list(type = "photo", path = f, caption = "Where the money went this week")
  }

  habs <- active_habits(h, today)
  if (length(habs) > 0) {
    days <- seq(today - 13, today, by = "day")
    grid <- data.frame(habit = rep(habs, each = length(days)),
                       date = rep(days, times = length(habs)), stringsAsFactors = FALSE)
    grid$done <- paste(grid$habit, grid$date) %in% paste(h$habit, h$date)
    p2 <- ggplot(grid, aes(date, habit, fill = done)) +
      geom_tile(color = "white", linewidth = 1) +
      scale_fill_manual(values = c(`TRUE` = "#2a9d8f", `FALSE` = "#e5e7eb"), guide = "none") +
      scale_x_date(breaks = days, date_labels = "%d") +
      labs(title = "Habits, last 14 days", x = NULL, y = NULL) +
      theme_minimal(base_size = 13) +
      theme(panel.grid = element_blank())
    f2 <- file.path(chart_dir, "habits.png")
    ggsave(f2, p2, width = 7, height = 1.4 + 0.5 * length(habs), dpi = 150, bg = "white")
    out[[length(out) + 1]] <- list(type = "photo", path = f2, caption = "Teal = done. Keep the chain going!")
  }
  out
}

# Returns outbox items for the reports that are due. force = TRUE sends both now
# (for testing) without marking them as sent, so the real ones still go out on time.
run_reports <- function(now = Sys.time(), force = FALSE, chart_dir = tempdir()) {
  due <- if (force) c("nudge", "weekly") else due_reports(.bot$state, now)
  today <- local_now(now)$date
  out <- list()
  if ("nudge" %in% due) {
    txt <- nudge_text(today)
    if (is.null(txt) && force) {
      txt <- "Test nudge: nothing is open today, so on a normal evening I'd stay quiet."
    }
    if (!is.null(txt)) out[[length(out) + 1]] <- list(type = "text", text = txt)
    if (!force) .bot$state$last_nudge_date <- format(today)
  }
  if ("weekly" %in% due) {
    out <- c(out, weekly_items(today, chart_dir))
    if (!force) .bot$state$last_weekly_date <- format(today)
  }
  out
}
