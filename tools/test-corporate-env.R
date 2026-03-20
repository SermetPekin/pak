#!/usr/bin/env Rscript
# tools/test-corporate-env.R
#
# Standalone simulation of a corporate Windows environment where
# utils::download.file is blocked (proxy/SSL failure) but curl works.
#
# Usage (after devtools::load_all() or installing the package):
#
#   Rscript tools/test-corporate-env.R
#
# Or from an R console:
#
#   source("tools/test-corporate-env.R")

message("=== Corporate environment download simulation ===\n")

# ── 1. Load pak (works both from source and as installed package) ────────────
if (file.exists("DESCRIPTION") && requireNamespace("devtools", quietly = TRUE)) {
  message("[setup] Loading pak via devtools::load_all()")
  devtools::load_all(".", quiet = TRUE)
} else {
  message("[setup] Loading installed pak")
  library(pak)
}

# ── 2. Poison utils::download.file at the namespace level ───────────────────
# This is the core of the simulation: every call to utils::download.file will
# now throw an error, just like it would on a corporate network that blocks R's
# built-in HTTP stack (no proxy support, bad SSL cert store, WinInet failures).

message("[setup] Replacing utils::download.file with a failing stub...")

original_download_file <- utils::download.file
restore <- function() {
  assignInNamespace("download.file", original_download_file, "utils")
  message("[teardown] utils::download.file restored.")
}
on.exit(restore(), add = TRUE)

assignInNamespace(
  "download.file",
  function(url, destfile, ...) {
    stop(
      "\n*** CORPORATE BLOCK ***\n",
      "utils::download.file is disabled (simulating proxy/SSL failure).\n",
      "URL: ", url
    )
  },
  "utils"
)

message("[setup] utils::download.file is now broken.\n")

# ── 3. Confirm the block is active ───────────────────────────────────────────
message("[test 1] Confirm utils::download.file fails...")
result <- tryCatch(
  utils::download.file("https://www.r-project.org", tempfile(), quiet = TRUE),
  error = function(e) e
)
if (inherits(result, "error") && grepl("CORPORATE BLOCK", result$message)) {
  message("  PASS: utils::download.file correctly blocked.\n")
} else {
  stop("  FAIL: Expected utils::download.file to be blocked but it wasn't.")
}

# ── 4. pak_download_file must succeed via curl ───────────────────────────────
message("[test 2] pak_download_file should succeed via curl despite the block...")
tmp <- tempfile()
on.exit(unlink(tmp), add = TRUE)

result2 <- tryCatch(
  pak:::pak_download_file("https://www.r-project.org", tmp, quiet = TRUE),
  error = function(e) e
)

if (inherits(result2, "error")) {
  message("  FAIL: pak_download_file errored:\n  ", result2$message)
  quit(status = 1L)
}

size <- file.info(tmp)$size
if (is.na(size) || size == 0) {
  message("  FAIL: Downloaded file is empty.")
  quit(status = 1L)
}
message(sprintf("  PASS: Downloaded %s bytes via curl.\n", size))

# ── 5. pak_update metadata fetch (exercises pak-update.R path) ───────────────
message("[test 3] pak_repo_metadata() fetch via pak_download_file...")
meta <- tryCatch(
  pak:::pak_repo_metadata(),
  error = function(e) e
)

if (inherits(meta, "error")) {
  message("  FAIL: pak_repo_metadata() errored:\n  ", meta$message)
  quit(status = 1L)
}
message(sprintf(
  "  PASS: pak_repo_metadata() returned %d rows.\n",
  nrow(meta)
))

# ── 6. Summary ────────────────────────────────────────────────────────────────
message("=== All tests passed ===")
message("pak_download_file correctly routes around a broken utils::download.file,")
message("using pak's bundled curl library instead.")
