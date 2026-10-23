# telegram.R -- talks to Telegram and, in fast mode, to the Cloudflare relay.
#
# Two ways to receive messages:
#   fast mode (RELAY_URL set): Telegram pushes each message to the relay, which starts
#     this job right away and keeps the message until we confirm it was saved.
#   schedule mode (RELAY_URL empty): we ask Telegram ourselves with getUpdates.
# Either way a message is only confirmed after data/ has been pushed to the repo.

suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
})

TOKEN        <- Sys.getenv("TELEGRAM_BOT_TOKEN")
OWNER        <- trimws(Sys.getenv("TELEGRAM_CHAT_ID"))
RELAY_URL    <- sub("/+$", "", Sys.getenv("RELAY_URL"))
RELAY_SECRET <- Sys.getenv("RELAY_SECRET")

if (!nzchar(TOKEN)) stop("TELEGRAM_BOT_TOKEN is not set")
if (!nzchar(OWNER)) stop("TELEGRAM_CHAT_ID is not set")
if (nzchar(RELAY_URL) && !nzchar(RELAY_SECRET)) stop("RELAY_URL is set but RELAY_SECRET is not")

# Only changed for local testing against a fake server; leave unset in real use.
API_BASE <- Sys.getenv("TELEGRAM_API_BASE", "https://api.telegram.org")

relay_mode <- function() nzchar(RELAY_URL)

id_text <- function(x) format(x, scientific = FALSE, trim = TRUE)

tg_request <- function(method) {
  request(sprintf("%s/bot%s/%s", API_BASE, TOKEN, method)) |>
    req_retry(max_tries = 3) |>
    req_timeout(30)
}

relay_request <- function(path) {
  request(paste0(RELAY_URL, path)) |>
    req_auth_bearer_token(RELAY_SECRET) |>
    req_retry(max_tries = 3) |>
    req_timeout(30)
}

# All updates newer than `after`, oldest first, fetched 100 at a time.
fetch_updates <- function(after) {
  out <- list()
  repeat {
    if (relay_mode()) {
      resp <- relay_request("/inbox") |>
        req_url_query(after = id_text(after), limit = 100) |>
        req_perform() |>
        resp_body_json()
      if (!isTRUE(resp$ok)) stop("Relay /inbox failed")
      batch <- resp$updates
    } else {
      resp <- tg_request("getUpdates") |>
        req_body_form(offset = id_text(after + 1), limit = "100", timeout = "0",
                      allowed_updates = '["message"]') |>
        req_perform() |>
        resp_body_json()
      if (!isTRUE(resp$ok)) stop("Telegram getUpdates failed")
      batch <- resp$result
    }
    out <- c(out, batch)
    if (length(batch) < 100) break
    after <- max(vapply(batch, function(u) as.numeric(u$update_id), numeric(1)))
  }
  out
}

# Tell the source we're done with everything up to `upto`. Safe to repeat.
ack_updates <- function(upto) {
  if (upto <= 0) return(invisible(TRUE))
  tryCatch({
    if (relay_mode()) {
      relay_request("/ack") |> req_body_json(list(upTo = id_text(upto))) |> req_perform()
    } else {
      tg_request("getUpdates") |>
        req_body_form(offset = id_text(upto + 1), limit = "1", timeout = "0") |>
        req_perform()
    }
    invisible(TRUE)
  }, error = function(e) {
    message("Could not confirm processed messages (the next run will): ", conditionMessage(e))
    invisible(FALSE)
  })
}

# Plain text on purpose (no Markdown), so things like "chai_tea" can't break a message.
tg_send <- function(text, reply_to = NULL, chat_id = OWNER) {
  params <- list(chat_id = chat_id, text = text)
  if (!is.null(reply_to)) {
    params$reply_parameters <- as.character(toJSON(
      list(message_id = reply_to, allow_sending_without_reply = TRUE),
      auto_unbox = TRUE, digits = NA))
  }
  tryCatch({
    tg_request("sendMessage") |>
      req_body_form(!!!params) |>
      req_perform()
    TRUE
  }, error = function(e) {
    message("Could not send message: ", conditionMessage(e))
    FALSE
  })
}

tg_send_photo <- function(path, caption = "", chat_id = OWNER) {
  tryCatch({
    tg_request("sendPhoto") |>
      req_body_multipart(chat_id = chat_id, caption = caption,
                         photo = curl::form_file(path)) |>
      req_perform()
    TRUE
  }, error = function(e) {
    message("Could not send photo: ", conditionMessage(e))
    FALSE
  })
}

# Swaps the relay's eyes reaction for a thumbs up once a message is saved. Best effort.
tg_react <- function(message_id, emoji = "\U0001F44D", chat_id = OWNER) {
  reaction <- as.character(toJSON(list(list(type = "emoji", emoji = emoji)), auto_unbox = TRUE))
  tryCatch({
    tg_request("setMessageReaction") |>
      req_body_form(chat_id = chat_id, message_id = id_text(message_id), reaction = reaction) |>
      req_perform()
    TRUE
  }, error = function(e) FALSE)
}
