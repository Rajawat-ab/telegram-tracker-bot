# store.R -- reading/writing the CSV + JSON files that act as our free "database".
# Base R only.

# Settings shared with the workflow (.github/workflows/bot.yml sets the same env vars).
BOT_TZ      <- Sys.getenv("BOT_TZ", "Asia/Kolkata")
NUDGE_HOUR  <- as.integer(Sys.getenv("NUDGE_HOUR", "21"))
WEEKLY_DAY  <- as.integer(Sys.getenv("WEEKLY_DAY", "7"))    # ISO weekday, 7 = Sunday
WEEKLY_HOUR <- as.integer(Sys.getenv("WEEKLY_HOUR", "20"))

Sys.setenv(TZ = BOT_TZ)

DATA_DIR   <- "data"
EXP_FILE   <- file.path(DATA_DIR, "expenses.csv")
HAB_FILE   <- file.path(DATA_DIR, "habits.csv")
STATE_FILE <- file.path(DATA_DIR, "state.json")

EXP_COLS <- c("id", "date", "amount", "category", "note")
HAB_COLS <- c("id", "date", "habit", "value")

read_table <- function(path, cols) {
  if (!file.exists(path) || file.size(path) == 0) {
    df <- as.data.frame(setNames(replicate(length(cols), character(0), simplify = FALSE), cols))
  } else {
    df <- read.csv(path, stringsAsFactors = FALSE, colClasses = "character")
  }
  df
}

read_expenses <- function() {
  df <- read_table(EXP_FILE, EXP_COLS)
  df$id     <- as.numeric(df$id)
  df$date   <- as.Date(df$date)
  df$amount <- as.numeric(df$amount)
  df
}

read_habits <- function() {
  df <- read_table(HAB_FILE, HAB_COLS)
  df$id   <- as.numeric(df$id)
  df$date <- as.Date(df$date)
  df
}

write_table <- function(df, path) {
  df$date <- format(df$date, "%Y-%m-%d")
  df$id   <- format(df$id, scientific = FALSE, trim = TRUE)
  write.csv(df, path, row.names = FALSE, na = "")
}

clean_text <- function(x) trimws(gsub("[\r\n]+", " ", x))

# last_update_id is the "already saved" watermark: anything at or below it is never
# processed again, which makes replays after a failed run harmless (even /undo).
read_state <- function() {
  s <- list(last_update_id = 0, budget = 0, last_nudge_date = "", last_weekly_date = "")
  if (file.exists(STATE_FILE)) {
    loaded <- jsonlite::fromJSON(STATE_FILE)
    for (n in names(loaded)) s[[n]] <- loaded[[n]]
  }
  s
}

write_state <- function(state) {
  writeLines(jsonlite::toJSON(state, auto_unbox = TRUE, pretty = TRUE, digits = NA), STATE_FILE)
}

# ---- formatting helpers -----------------------------------------------------

money <- function(x) {
  paste0(RUPEE, format(round(x), big.mark = ",", scientific = FALSE, trim = TRUE))
}

# ---- habit maths ------------------------------------------------------------

# Consecutive days ending today (or yesterday, if today isn't logged yet).
calc_streak <- function(dates, today) {
  d <- sort(unique(as.Date(dates)), decreasing = TRUE)
  if (length(d) == 0) return(0L)
  if (today %in% d) {
    cur <- today
  } else if ((today - 1) %in% d) {
    cur <- today - 1
  } else {
    return(0L)
  }
  n <- 0L
  while (cur %in% d) {
    n <- n + 1L
    cur <- cur - 1
  }
  n
}

# Habits seen in the last `days` days (so retired habits quietly drop off).
active_habits <- function(habits, today, days = 30) {
  recent <- habits[habits$date > today - days, , drop = FALSE]
  sort(unique(recent$habit))
}

habit_days <- function(habits, name, from, to) {
  h <- habits[habits$habit == name & habits$date >= from & habits$date <= to, , drop = FALSE]
  length(unique(h$date))
}

# ---- spending maths ---------------------------------------------------------

spend_between <- function(expenses, from, to) {
  expenses[expenses$date >= from & expenses$date <= to, , drop = FALSE]
}

by_category <- function(df) {
  if (nrow(df) == 0) return(data.frame(category = character(0), amount = numeric(0)))
  out <- aggregate(amount ~ category, data = df, FUN = sum)
  out[order(-out$amount), , drop = FALSE]
}

month_start <- function(today) as.Date(format(today, "%Y-%m-01"))
