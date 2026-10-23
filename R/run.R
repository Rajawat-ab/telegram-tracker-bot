# run.R -- what GitHub Actions runs (see .github/workflows/bot.yml).
#   Rscript R/run.R process   read new messages, update data/, queue replies and due reports
#   Rscript R/run.R deliver   after data/ is pushed: send the replies, then confirm the messages
# Splitting the two means you never get a reply for something that wasn't saved.

invisible(Sys.setlocale("LC_CTYPE", "C.UTF-8"))   # so the rupee sign and emoji survive

source("R/parse.R")
source("R/store.R")
source("R/commands.R")
source("R/reports.R")
source("R/bot.R")
source("R/telegram.R")

OUTBOX_DIR  <- Sys.getenv("OUTBOX_DIR", file.path(tempdir(), "outbox"))
OUTBOX_FILE <- file.path(OUTBOX_DIR, "outbox.json")

mode <- commandArgs(trailingOnly = TRUE)[1]

if (identical(mode, "process")) {
  dir.create(OUTBOX_DIR, showWarnings = FALSE, recursive = TRUE)
  .bot$state <- read_state()

  updates <- fetch_updates(.bot$state$last_update_id)
  message(length(updates), " new update(s).")
  outbox <- process_updates(updates, OWNER)

  force <- identical(tolower(Sys.getenv("FORCE_REPORTS")), "true")
  outbox <- c(outbox, run_reports(force = force, chart_dir = OUTBOX_DIR))

  write_state(.bot$state)
  writeLines(toJSON(outbox, auto_unbox = TRUE, digits = NA, pretty = TRUE), OUTBOX_FILE)
  message(length(outbox), " message(s) queued.")

} else if (identical(mode, "deliver")) {
  outbox <- if (file.exists(OUTBOX_FILE)) fromJSON(OUTBOX_FILE, simplifyVector = FALSE) else list()
  for (m in outbox) {
    if (identical(m$type, "photo")) {
      tg_send_photo(m$path, m$caption)
    } else if (tg_send(m$text, reply_to = m$reply_to) && !is.null(m$reply_to)) {
      tg_react(m$reply_to)
    }
    Sys.sleep(0.3)
  }
  ack_updates(read_state()$last_update_id)
  message("Sent ", length(outbox), " message(s).")

} else {
  stop("Usage: Rscript R/run.R process|deliver")
}
