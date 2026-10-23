# Run from the project root:  Rscript tests/test_bot.R
# Tests the parser, the whole message -> CSV -> reply flow, replay safety and reports.
# No Telegram needed.

source("R/parse.R")
source("R/store.R")
source("R/commands.R")
source("R/reports.R")
source("R/bot.R")

`%||%` <- function(a, b) if (is.null(a)) b else a

ok <- function(cond, label) {
  if (!isTRUE(cond)) stop("FAILED: ", label, call. = FALSE)
  cat("ok  -", label, "\n")
}

# ---- parser -----------------------------------------------------------------
p <- parse_message("250 lunch")
ok(p$type == "expense" && p$amount == 250 && p$category == "food", "250 lunch")

p <- parse_message("lunch 250")
ok(p$type == "expense" && p$amount == 250 && p$note == "lunch", "lunch 250 (amount last)")

p <- parse_message("spent 1.5k on rent #bills")
ok(p$amount == 1500 && p$category == "bills" && p$note == "rent", "spent 1.5k on rent #bills")

p <- parse_message(paste0("₹", "99 chai yesterday"))
ok(p$amount == 99 && p$category == "food" && p$offset == -1L, "rupee sign + yesterday")

p <- parse_message("Rs. 40 auto")
ok(p$amount == 40 && p$category == "transport", "Rs. 40 auto")

p <- parse_message("250 kitchen stuff")
ok(p$amount == 250 && p$note == "kitchen stuff", "'250 kitchen' is not 250k")

p <- parse_message("1,200 rent")
ok(p$amount == 1200 && p$category == "bills", "1,200 rent (comma)")

p <- parse_message("rent 1,20,000")
ok(p$amount == 120000, "Indian grouping 1,20,000")

p <- parse_message("done gym")
ok(p$type == "habit" && p$habit == "gym" && p$value == "", "done gym")

p <- parse_message("Done Reading 30 min")
ok(p$type == "habit" && p$habit == "reading" && p$value == "30 min", "done reading 30 min")

p <- parse_message("done morning walk yesterday")
ok(p$type == "habit" && p$habit == "morning walk" && p$offset == -1L, "done morning walk yesterday")

ok(parse_message("hello there")$type == "unknown", "gibberish -> unknown")
ok(parse_message("0 nothing")$type == "unknown", "zero amount -> unknown")

# ---- streaks ----------------------------------------------------------------
today <- as.Date("2026-10-23")
ok(calc_streak(today - 0:4, today) == 5, "streak through today")
ok(calc_streak(today - 1:3, today) == 3, "streak still alive if today not yet logged")
ok(calc_streak(today - 3:5, today) == 0, "broken streak is 0")

# ---- end-to-end in a scratch folder -----------------------------------------
root <- getwd()
tmp <- tempfile("tracker"); dir.create(file.path(tmp, "data"), recursive = TRUE)
invisible(file.copy(file.path(root, "data", c("expenses.csv", "habits.csv", "state.json")),
                    file.path(tmp, "data")))
setwd(tmp)

d <- as.Date("2026-10-23")
r <- handle_message("250 lunch", d, 1001)
ok(grepl("Noted", r) && grepl("250", r), "expense reply")

r <- handle_message("zomato 400", d, 1002)
ok(grepl("650", r), "day total accumulates (250 + 400)")

ok(grepl("1,000", handle_message("/budget 1,000", d, 1003)), "/budget accepts a comma")
r <- handle_message("100 chai", d, 1004)
ok(grepl("Budget", r) && grepl("75%", r), "budget line appears")

r <- handle_message("done gym", d, 1005)
ok(grepl("Nice work", r), "habit logged")
r <- handle_message("done gym", d, 1006)
ok(grepl("already", r), "duplicate habit not double counted")
r <- handle_message("done gym yesterday", d, 1007)
ok(grepl("Streak: 2", r), "yesterday entry builds a 2-day streak")

ok(grepl("750", handle_message("/today", d, 1008)), "/today total")
ok(grepl("gym", handle_message("/habits", d, 1009)), "/habits lists gym")
ok(grepl("food", handle_message("/week", d, 1010)), "/week shows categories")
ok(grepl("October", handle_message("/month", d, 1011)), "/month header")
ok(grepl("Pong", handle_message("/ping", d, 1012)), "/ping")
ok(grepl("/ping", handle_message("/help", d, 1013)), "/help lists /ping")

r <- handle_message("/undo", d, 1014)
ok(grepl("gym", r), "/undo removes the latest entry (the gym habit)")
ok(nrow(read_habits()) == 1, "habit row actually removed")

ok(grepl("don't know", handle_message("/nonsense", d, 1015)), "unknown command")
ok(grepl("couldn't make sense", handle_message("blah", d, 1016)), "unknown text hint")

# Re-processing the same update id must not duplicate rows.
n <- nrow(read_expenses())
invisible(handle_message("250 lunch", d, 1001))
ok(nrow(read_expenses()) == n, "same update id is idempotent")

# ---- a batch of updates, as the workflow sees them --------------------------
noon <- as.numeric(as.POSIXct("2026-10-23 12:00", tz = "Asia/Kolkata"))
upd <- function(id, text, chat = 42, date = noon) {
  list(update_id = id, message = list(message_id = id + 5000, date = date,
                                      chat = list(id = chat), text = text))
}

.bot$state$last_update_id <- 2000
n <- nrow(read_expenses())
out <- process_updates(list(upd(2002, "100 chai"), upd(2001, "50 auto"), upd(2003, "hi", chat = 99),
                            list(update_id = 2004, message = list(message_id = 1, chat = list(id = 42)))),
                       owner = "42")
ok(length(out) == 2, "two replies: stranger and non-text message skipped")
ok(out[[1]]$reply_to == 7001 && grepl("auto", out[[1]]$text), "oldest message handled first, reply threaded")
ok(.bot$state$last_update_id == 2004, "watermark moves past skipped updates too")
ok(nrow(read_expenses()) == n + 2, "both expenses saved")

late <- as.numeric(as.POSIXct("2026-10-22 23:50", tz = "Asia/Kolkata"))
out <- process_updates(list(upd(2005, "30 tea", date = late)), owner = "42")
e <- read_expenses()
ok(e$date[e$id == 2005] == as.Date("2026-10-22"), "dated by IST send time, not processing time")

out <- process_updates(list(upd(2001, "50 auto"), upd(2006, "/undo")), owner = "42")
ok(length(out) == 1 && nrow(read_expenses()) == n + 2, "replayed update skipped; /undo removed one row")
out <- process_updates(list(upd(2006, "/undo")), owner = "42")
ok(length(out) == 0 && nrow(read_expenses()) == n + 2, "replayed /undo does nothing")

# ---- reports ----------------------------------------------------------------
ist <- function(x) as.POSIXct(x, tz = "Asia/Kolkata")
ok(identical(due_reports(list(), ist("2026-10-25 20:30")), "weekly"), "Sunday 20:30: weekly only")
ok(identical(due_reports(list(), ist("2026-10-25 21:15")), c("nudge", "weekly")), "Sunday 21:15: both")
ok(length(due_reports(list(last_nudge_date = "2026-10-25", last_weekly_date = "2026-10-25"),
                      ist("2026-10-25 22:00"))) == 0, "nothing twice on the same day")
ok(identical(due_reports(list(last_nudge_date = "2026-10-25"), ist("2026-10-26 21:01")), "nudge"),
   "Monday 21:01: nudge only")
ok(length(due_reports(list(), ist("2026-10-26 09:00"))) == 0, "Monday morning: nothing")

.bot$state$last_nudge_date <- ""
.bot$state$last_weekly_date <- ""
out <- run_reports(ist("2026-10-25 21:15"), chart_dir = tmp)
ok(.bot$state$last_nudge_date == "2026-10-25" && .bot$state$last_weekly_date == "2026-10-25",
   "sent reports are recorded")
ok(any(vapply(out, function(m) grepl("week in review", m$text %||% ""), logical(1))), "weekly text queued")
ok(length(run_reports(ist("2026-10-25 22:00"), chart_dir = tmp)) == 0, "not sent again")

forced <- run_reports(ist("2026-10-26 09:00"), force = TRUE, chart_dir = tmp)
ok(length(forced) >= 2 && .bot$state$last_nudge_date == "2026-10-25", "forced reports don't mark as sent")

if (requireNamespace("ggplot2", quietly = TRUE)) {
  photos <- Filter(function(m) identical(m$type, "photo"), out)
  ok(length(photos) == 2 && all(file.exists(vapply(photos, `[[`, "", "path"))), "both charts drawn")
} else {
  cat("skip - charts (ggplot2 not installed)\n")
}

setwd(root)
cat("\nAll tests passed.\n")
