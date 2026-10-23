# bot.R -- turns a batch of Telegram updates into saved data and queued replies.
# No network code here, so the whole flow can be tested offline.
# Needs parse.R, store.R and commands.R to be sourced first.

update_id <- function(u) as.numeric(u$update_id)

# updates: Telegram update objects, in any order. owner: your chat id as text.
# Writes to the CSVs as it goes and advances .bot$state$last_update_id.
# Returns the replies to send, as outbox items.
process_updates <- function(updates, owner) {
  owner <- trimws(owner)
  ids <- vapply(updates, update_id, numeric(1))
  outbox <- list()
  for (u in updates[order(ids)]) {
    id <- update_id(u)
    if (id <= .bot$state$last_update_id) next      # handled and saved by an earlier run
    .bot$state$last_update_id <- id

    msg <- u$message
    if (is.null(msg) || is.null(msg$text)) next

    # Safety: only ever act on messages from you.
    if (as.character(msg$chat$id) != owner) {
      message("Ignoring a message from a different chat.")
      next
    }

    sent_at <- as.POSIXct(as.numeric(msg$date), origin = "1970-01-01", tz = "UTC")
    date <- as.Date(format(sent_at, "%Y-%m-%d", tz = BOT_TZ))

    reply <- tryCatch(
      handle_message(msg$text, date, id),
      error = function(e) {
        message("Error handling update ", id, ": ", conditionMessage(e))
        "Oops, I tripped over that one. Could you try sending it again?"
      }
    )
    outbox[[length(outbox) + 1]] <- list(type = "text", text = reply, reply_to = msg$message_id)
  }
  outbox
}
