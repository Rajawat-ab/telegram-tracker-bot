# commands.R -- what the bot does with each message, and the replies it writes back.
# Needs parse.R and store.R to be sourced first. No network code lives here.

# Shared, mutable bot state (last_update_id, budget, report dates). run.R loads it
# from disk at the start of a run and saves it at the end.
.bot <- new.env()
.bot$state <- list(last_update_id = 0, budget = 0, last_nudge_date = "", last_weekly_date = "")

TICK  <- "✅"
FIRE  <- "\U0001F525"
MONEY <- "\U0001F4B8"

HELP_TEXT <- paste(
  "Hey! I'm your little spending and habit tracker. Here's what I understand:",
  "",
  "Spending",
  "  250 lunch",
  "  spent 1.5k on rent #bills",
  "  chai 20 yesterday",
  "",
  "Habits",
  "  done gym",
  "  done reading 30 min",
  "  done meditation yesterday",
  "",
  "Check-ins",
  "  /today  /week  /month  /habits",
  "  /budget 20000  (set a monthly budget)",
  "  /undo  (remove the last thing I logged)",
  "  /ping  (check that I'm working)",
  "",
  "\U0001F44D on your message means it's saved (in fast mode, \U0001F440 means I've received it).",
  sep = "\n"
)

speed_note <- function() {
  if (nzchar(Sys.getenv("RELAY_URL"))) {
    "Fast mode is on, so I usually reply within a minute or two."
  } else {
    "I check for messages on a schedule, so replies can take a while. Everything you send is still counted."
  }
}

UNKNOWN_TEXT <- paste(
  "I couldn't make sense of that one.",
  "Try something like \"250 lunch\" or \"done gym\", or send /help for the full list.",
  sep = "\n"
)

day_label <- function(offset) if (offset < 0) "yesterday" else "today"

plural <- function(n, one, many) if (n == 1) one else many

# ---- budget -----------------------------------------------------------------

budget_line <- function(spent, budget) {
  if (is.null(budget) || is.na(budget) || budget <= 0) return(NULL)
  pct <- round(100 * spent / budget)
  base <- sprintf("Budget: %s of %s used (%d%%).", money(spent), money(budget), pct)
  if (pct >= 100) {
    paste(base, "We've gone past it, so maybe pause before the next big spend.")
  } else if (pct >= 80) {
    paste(base, "Getting close, so go easy for the rest of the month.")
  } else {
    base
  }
}

cmd_budget <- function(arg) {
  budget <- .bot$state$budget
  if (!nzchar(arg)) {
    if (!is.null(budget) && budget > 0) {
      return(sprintf("Your monthly budget is %s. Change it any time with /budget 25000.", money(budget)))
    }
    return("No budget set yet. Try /budget 20000 and I'll keep an eye on the month for you.")
  }
  arg <- strip_digit_commas(arg)
  m <- regmatches(arg, regexec("^\\D*(\\d+(?:\\.\\d+)?)(k?)\\s*$", arg, perl = TRUE))[[1]]
  if (length(m) == 0) return("I couldn't read that amount. Try something like /budget 20000.")
  .bot$state$budget <- to_amount(m[2], m[3])
  sprintf("Done. Your monthly budget is now %s.", money(.bot$state$budget))
}

# ---- logging ----------------------------------------------------------------

log_expense <- function(id, entry_date, msg_date, offset, p) {
  df <- read_expenses()
  if (!(id %in% df$id)) {
    row <- data.frame(id = id, date = entry_date, amount = p$amount,
                      category = p$category, note = substr(clean_text(p$note), 1, 100),
                      stringsAsFactors = FALSE)
    write_table(rbind(df, row), EXP_FILE)
    df <- rbind(df, row)
  }
  day_total   <- sum(spend_between(df, entry_date, entry_date)$amount)
  month_total <- sum(spend_between(df, month_start(entry_date), entry_date)$amount)

  lines <- c(
    sprintf("Noted! %s for %s (%s) %s", money(p$amount), p$note, p$category, MONEY),
    sprintf("Spent %s so far: %s.", day_label(offset), money(day_total)),
    sprintf("This month: %s.", money(month_total))
  )
  b <- budget_line(month_total, .bot$state$budget)
  paste(c(lines, b), collapse = "\n")
}

log_habit <- function(id, entry_date, msg_date, offset, p) {
  h <- read_habits()
  already <- any(h$habit == p$habit & h$date == entry_date)
  if (already) {
    return(sprintf("You've already got \"%s\" down for %s, so I won't count it twice.",
                   p$habit, day_label(offset)))
  }
  if (!(id %in% h$id)) {
    row <- data.frame(id = id, date = entry_date, habit = p$habit,
                      value = clean_text(p$value), stringsAsFactors = FALSE)
    h <- rbind(h, row)
    write_table(h, HAB_FILE)
  }
  streak <- calc_streak(h$date[h$habit == p$habit], msg_date)
  val <- if (nzchar(p$value)) sprintf(" (%s)", p$value) else ""
  out <- sprintf("Nice work! \"%s\"%s logged for %s %s", p$habit, val, day_label(offset), TICK)
  if (streak >= 2) out <- paste0(out, sprintf("\nStreak: %d days in a row %s", streak, FIRE))
  out
}

# ---- reports ----------------------------------------------------------------

cat_lines <- function(df) {
  if (nrow(df) == 0) return(character(0))
  bc <- by_category(df)
  sprintf("  %s: %s (%d%%)", bc$category, money(bc$amount),
          round(100 * bc$amount / sum(df$amount)))
}

cmd_today <- function(today) {
  e <- spend_between(read_expenses(), today, today)
  h <- read_habits()
  done <- unique(h$habit[h$date == today])
  pending <- setdiff(active_habits(h, today), done)

  out <- sprintf("Here's %s:", format(today, "%A, %d %b"))
  if (nrow(e) == 0) {
    out <- c(out, "No spending logged yet.")
  } else {
    out <- c(out,
             sprintf("Spent %s so far (%d %s)", money(sum(e$amount)), nrow(e),
                     plural(nrow(e), "entry", "entries")),
             sprintf("  - %s  %s", money(e$amount), e$note))
  }
  if (length(done))    out <- c(out, paste("Habits done:", paste(done, collapse = ", ")))
  if (length(pending)) out <- c(out, paste("Still open:", paste(pending, collapse = ", ")))
  paste(out, collapse = "\n")
}

cmd_week <- function(today, title = "Your last 7 days") {
  e <- read_expenses()
  h <- read_habits()
  cur  <- spend_between(e, today - 6, today)
  prev <- spend_between(e, today - 13, today - 7)

  out <- title
  if (nrow(cur) == 0) {
    out <- c(out, "No spending logged this week.")
  } else {
    total <- sum(cur$amount)
    out <- c(out, sprintf("Spent %s (about %s a day)", money(total), money(total / 7)))
    if (nrow(prev) > 0) {
      diff <- total - sum(prev$amount)
      out <- c(out, sprintf("That's %s %s than the week before.", money(abs(diff)),
                            if (diff > 0) "more" else "less"))
    }
    out <- c(out, "By category:", cat_lines(cur))
  }
  habs <- active_habits(h, today)
  if (length(habs)) {
    out <- c(out, "Habits (days done out of 7):",
             sprintf("  %s: %d/7", habs, vapply(habs, habit_days, numeric(1),
                                                 habits = h, from = today - 6, to = today)))
  }
  paste(out, collapse = "\n")
}

cmd_month <- function(today) {
  e <- spend_between(read_expenses(), month_start(today), today)
  out <- sprintf("%s so far", format(today, "%B %Y"))
  if (nrow(e) == 0) {
    out <- c(out, "No spending logged yet this month.")
  } else {
    out <- c(out, sprintf("Spent %s across %d entries", money(sum(e$amount)), nrow(e)),
             "By category:", cat_lines(e))
  }
  paste(c(out, budget_line(sum(e$amount), .bot$state$budget)), collapse = "\n")
}

cmd_habits <- function(today) {
  h <- read_habits()
  habs <- active_habits(h, today)
  if (length(habs) == 0) {
    return("No habits yet. Send something like \"done gym\" and I'll start tracking it.")
  }
  lines <- vapply(habs, function(name) {
    s <- calc_streak(h$date[h$habit == name], today)
    n7 <- habit_days(h, name, today - 6, today)
    sprintf("  %s: %d-day streak, %d/7 this week", name, s, n7)
  }, character(1))
  paste(c("Your habits:", lines), collapse = "\n")
}

cmd_undo <- function() {
  e <- read_expenses()
  h <- read_habits()
  last_e <- if (nrow(e)) max(e$id) else -Inf
  last_h <- if (nrow(h)) max(h$id) else -Inf
  if (is.infinite(last_e) && is.infinite(last_h)) return("There's nothing to undo yet.")
  if (last_e > last_h) {
    row <- e[e$id == last_e, ][1, ]
    write_table(e[e$id != last_e, , drop = FALSE], EXP_FILE)
    sprintf("Removed: %s for %s (%s).", money(row$amount), row$note, format(row$date, "%d %b"))
  } else {
    row <- h[h$id == last_h, ][1, ]
    write_table(h[h$id != last_h, , drop = FALSE], HAB_FILE)
    sprintf("Removed: \"%s\" on %s.", row$habit, format(row$date, "%d %b"))
  }
}

# ---- entry point used by the bot --------------------------------------------

# text: the message; date: the day it was sent (IST); id: Telegram update_id.
handle_message <- function(text, date, id) {
  t <- trimws(text)
  if (startsWith(t, "/")) {
    parts <- strsplit(t, "\\s+")[[1]]
    cmd <- tolower(sub("@.*$", "", sub("^/", "", parts[1])))
    arg <- if (length(parts) > 1) paste(parts[-1], collapse = " ") else ""
    return(switch(cmd,
      start = , help = paste(HELP_TEXT, speed_note(), sep = "\n"),
      ping = paste("Pong", TICK, "I'm up and running.", speed_note()),
      today = cmd_today(date),
      week = cmd_week(date),
      month = cmd_month(date),
      habits = , streaks = cmd_habits(date),
      undo = cmd_undo(),
      budget = cmd_budget(arg),
      "Hmm, I don't know that one. Send /help to see what I can do."
    ))
  }
  p <- parse_message(t)
  entry_date <- date + p$offset
  switch(p$type,
    expense = log_expense(id, entry_date, date, p$offset, p),
    habit   = log_habit(id, entry_date, date, p$offset, p),
    UNKNOWN_TEXT
  )
}
