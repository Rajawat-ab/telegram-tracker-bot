# parse.R -- turns a chat message into a structured entry.
# Base R only, so it can be tested anywhere without installing packages.
# (Non-ASCII characters are written as \u escapes to keep the source portable.)

RUPEE <- "₹"

# Keyword -> category. Add your own words freely; first match wins.
CATEGORY_KEYWORDS <- list(
  food          = c("lunch", "dinner", "breakfast", "snack", "snacks", "tea", "chai",
                    "coffee", "food", "zomato", "swiggy", "restaurant", "biryani",
                    "pizza", "burger", "juice", "canteen", "cafe", "ice", "icecream"),
  groceries     = c("grocery", "groceries", "vegetables", "veggies", "milk", "fruits",
                    "fruit", "blinkit", "zepto", "bigbasket", "eggs", "atta"),
  transport     = c("uber", "ola", "rapido", "metro", "auto", "cab", "petrol", "fuel",
                    "diesel", "bus", "train", "parking", "toll", "fastag", "flight"),
  bills         = c("rent", "electricity", "bill", "recharge", "wifi", "internet", "gas",
                    "water", "emi", "insurance", "maid", "broadband"),
  subscriptions = c("netflix", "spotify", "prime", "hotstar", "youtube", "subscription"),
  shopping      = c("amazon", "flipkart", "myntra", "clothes", "shoes", "shirt",
                    "shopping", "jeans", "watch"),
  health        = c("medicine", "medicines", "doctor", "pharmacy", "gym", "hospital",
                    "medical", "dentist", "protein", "supplements"),
  fun           = c("movie", "movies", "game", "games", "outing", "party", "trip", "concert")
)

guess_category <- function(note) {
  words <- unlist(strsplit(tolower(note), "[^a-z]+"))
  for (cat in names(CATEGORY_KEYWORDS)) {
    if (any(words %in% CATEGORY_KEYWORDS[[cat]])) return(cat)
  }
  "other"
}

# Pulls a trailing "yesterday" off the text. Returns the cleaned text and a day offset.
extract_day_offset <- function(text) {
  if (grepl("\\s+(yesterday|yday|ydy)$", text, ignore.case = TRUE, perl = TRUE)) {
    return(list(text = trimws(sub("\\s+(yesterday|yday|ydy)$", "", text,
                                  ignore.case = TRUE, perl = TRUE)), offset = -1L))
  }
  list(text = text, offset = 0L)
}

strip_digit_commas <- function(x) gsub("(?<=\\d),(?=\\d)", "", x, perl = TRUE)

to_amount <- function(num, k) {
  v <- as.numeric(num)
  if (nzchar(k)) v <- v * 1000
  v
}

# "250 lunch" | "spent 250 on lunch" | "lunch 250" | "1.5k rent #bills" | "Rs 99 chai"
# Returns list(amount, category, note) or NULL if it doesn't look like an expense.
parse_expense <- function(text) {
  t <- trimws(text)
  t <- sub("^(?i)(spent|spend|paid|exp|expense)\\s+", "", t, perl = TRUE)
  t <- gsub(RUPEE, "", t, fixed = TRUE)
  t <- gsub("(?i)\\b(rs\\.?|inr)\\s*(?=\\d)", "", t, perl = TRUE)
  t <- strip_digit_commas(t)                            # "1,200" / "1,20,000"
  t <- trimws(gsub("\\s+", " ", t))

  amount <- NA_real_
  note <- ""

  m <- regmatches(t, regexec("^(\\d+(?:\\.\\d+)?)(k?)(?:\\s+(.*))?$", t, perl = TRUE))[[1]]
  if (length(m) > 0) {
    amount <- to_amount(m[2], m[3])
    note <- if (length(m) >= 4) m[4] else ""
  } else {
    m <- regmatches(t, regexec("^(.*\\S)\\s+(\\d+(?:\\.\\d+)?)(k?)$", t, perl = TRUE))[[1]]
    if (length(m) > 0) {
      amount <- to_amount(m[3], m[4])
      note <- m[2]
    }
  }
  if (is.na(amount) || amount <= 0) return(NULL)

  note <- sub("^(?i)on\\s+", "", note, perl = TRUE)   # "250 on lunch" -> "lunch"

  # Optional explicit category: "#food"
  tag <- regmatches(note, regexec("(?:^|\\s)#([A-Za-z]+)", note, perl = TRUE))[[1]]
  if (length(tag) > 0) {
    category <- tolower(tag[2])
    note <- trimws(gsub("(?:^|\\s)#[A-Za-z]+", "", note, perl = TRUE))
  } else {
    category <- guess_category(note)
  }
  if (!nzchar(note)) note <- category
  list(amount = amount, category = category, note = note)
}

# "done gym" | "did reading 30 min" | "done meditation yesterday"
# Returns list(habit, value) or NULL. The habit name is lower-cased and tidied.
parse_habit <- function(text) {
  t <- trimws(text)
  m <- regmatches(t, regexec("^(?i)(?:done|did|✅)\\s+(.+)$", t, perl = TRUE))[[1]]
  if (length(m) == 0) return(NULL)
  rest <- trimws(m[2])

  value <- ""
  v <- regmatches(rest, regexec("^(.*\\S)\\s+(\\d+(?:\\.\\d+)?\\s*[A-Za-z]*)$", rest, perl = TRUE))[[1]]
  if (length(v) > 0) {
    rest <- trimws(v[2])
    value <- trimws(v[3])
  }
  habit <- tolower(gsub("\\s+", " ", rest))
  if (!nzchar(habit)) return(NULL)
  list(habit = habit, value = value)
}

# Top-level classifier used by the bot. Slash commands are handled separately.
parse_message <- function(text) {
  d <- extract_day_offset(trimws(text))
  h <- parse_habit(d$text)
  if (!is.null(h)) return(c(list(type = "habit", offset = d$offset), h))
  e <- parse_expense(d$text)
  if (!is.null(e)) return(c(list(type = "expense", offset = d$offset), e))
  list(type = "unknown", offset = 0L)
}
