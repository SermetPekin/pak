#!/usr/bin/env Rscript
# tools/test-corporate-env.R
#
# Simulates a Windows corporate environment where:
#   - utils::download.file fails (proxy/SSL/PAC issues)
#   - bioconductor.org is unreachable
#
# Run from repo root:
#   Rscript tools/test-corporate-env.R

cat("=== Corporate network simulation ===\n\n")

# Load pak first (before poisoning utils), if devtools is available
cat("-- Loading pak (devtools::load_all) --\n")
pak_loaded <- requireNamespace("devtools", quietly = TRUE) &&
  tryCatch({ devtools::load_all(quiet = TRUE); TRUE }, error = function(e) {
    cat("   (skipping pak tests: devtools::load_all() failed)\n"); FALSE
  })

pass <- 0L
fail <- 0L

check <- function(label, expr) {
  result <- tryCatch(expr, error = function(e) e)
  if (inherits(result, "error")) {
    cat(sprintf("[FAIL] %s\n       Error: %s\n", label, conditionMessage(result)))
    fail <<- fail + 1L
  } else {
    cat(sprintf("[PASS] %s\n", label))
    pass <<- pass + 1L
  }
  invisible(result)
}

# ---------------------------------------------------------------------------
# 1. Poison utils::download.file to simulate proxy failure
# ---------------------------------------------------------------------------
cat("-- Poisoning utils::download.file --\n")
utils_ns <- asNamespace("utils")
utils_original_download <- get("download.file", envir = utils_ns)
unlockBinding("download.file", utils_ns)
assign(
  "download.file",
  function(...) stop("Simulated corporate proxy failure"),
  envir = utils_ns
)
on.exit({
  unlockBinding("download.file", utils_ns)
  assign("download.file", utils_original_download, envir = utils_ns)
  lockBinding("download.file", utils_ns)
}, add = TRUE)

# ---------------------------------------------------------------------------
# 2. Test bioc.R fallback when config URL is unreachable
# ---------------------------------------------------------------------------
cat("\n-- Test: bioc.R offline fallback --\n")
source("src/library/pkgcache/R/bioc.R")
Sys.setenv(R_BIOC_CONFIG_URL = "https://127.0.0.1/config.yaml")

check("clear_cache() is callable", bioconductor$clear_cache())

ver <- check("get_bioc_version() returns a version with fallback", {
  withCallingHandlers(
    bioconductor$get_bioc_version(),
    warning = function(w) {
      if (grepl("Falling back", conditionMessage(w))) invokeRestart("muffleWarning")
    }
  )
})
check("Bioc version looks like a version string (e.g. '3.20')", {
  stopifnot(grepl("^\\d+\\.\\d+$", as.character(ver)))
  ver
})

# ---------------------------------------------------------------------------
# 3. Test pak_download_file() prefers curl over utils::download.file
# ---------------------------------------------------------------------------
cat("\n-- Test: pak_download_file() curl preference --\n")

if (pak_loaded && exists("pak_download_file", envir = asNamespace("pak"), mode = "function")) {
  tmp <- tempfile()
  check("pak_download_file downloads via curl (not utils)", {
    fn <- get("pak_download_file", envir = asNamespace("pak"))
    fn("https://cran.r-project.org/CRAN_mirrors.csv", tmp, quiet = TRUE)
    stopifnot(file.exists(tmp) && file.size(tmp) > 0)
  })
  unlink(tmp)
} else {
  cat("[SKIP] pak_download_file not found (only on dev2 branch)\n")
}

# ---------------------------------------------------------------------------
# 4. Verify utils::download.file is still poisoned (control check)
# ---------------------------------------------------------------------------
cat("\n-- Control: utils::download.file is still poisoned --\n")
check("utils::download.file correctly fails (control)", {
  result <- tryCatch(
    utils::download.file("https://cran.r-project.org/", tempfile()),
    error = function(e) e
  )
  if (!inherits(result, "error")) stop("Expected utils::download.file to fail")
  TRUE
})

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
cat(sprintf(
  "\n=== Results: %d passed, %d failed ===\n",
  pass, fail
))
if (fail > 0L) quit(status = 1L)
