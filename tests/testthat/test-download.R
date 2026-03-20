test_that("pak_download_file uses curl from private lib when available", {
  tmp <- tempfile()
  on.exit(unlink(tmp), add = TRUE)

  # Intercept the two loadNamespace calls inside pak_download_file.
  # First call (private lib) returns a fake curl ns with curl_download.
  downloaded_via <- NULL
  fake_curl_ns <- list(
    curl_download = function(url, destfile, quiet, mode) {
      downloaded_via <<- "curl_private"
      writeLines("ok", destfile)
      invisible(destfile)
    }
  )

  local_mocked_bindings(
    loadNamespace = function(package, lib.loc = NULL, ...) {
      if (package == "curl" && !is.null(lib.loc)) {
        return(fake_curl_ns)
      }
      base::loadNamespace(package, lib.loc = lib.loc, ...)
    },
    .package = "pak"
  )

  pak_download_file("https://example.com/file", tmp, quiet = TRUE)
  expect_equal(downloaded_via, "curl_private")
})

test_that("pak_download_file falls back to user curl when private lib curl missing", {
  tmp <- tempfile()
  on.exit(unlink(tmp), add = TRUE)

  downloaded_via <- NULL
  fake_curl_ns <- list(
    curl_download = function(url, destfile, quiet, mode) {
      downloaded_via <<- "curl_user"
      writeLines("ok", destfile)
      invisible(destfile)
    }
  )

  local_mocked_bindings(
    loadNamespace = function(package, lib.loc = NULL, ...) {
      if (package == "curl" && !is.null(lib.loc)) {
        stop("curl not found in private lib")  # private lib curl missing
      }
      if (package == "curl") {
        return(fake_curl_ns)                   # user-installed curl works
      }
      base::loadNamespace(package, lib.loc = lib.loc, ...)
    },
    .package = "pak"
  )

  pak_download_file("https://example.com/file", tmp, quiet = TRUE)
  expect_equal(downloaded_via, "curl_user")
})

test_that("pak_download_file falls back to utils::download.file when curl unavailable", {
  tmp <- tempfile()
  on.exit(unlink(tmp), add = TRUE)

  downloaded_via <- NULL

  local_mocked_bindings(
    loadNamespace = function(package, lib.loc = NULL, ...) {
      if (package == "curl") {
        stop("curl not available")  # simulate both curl paths failing
      }
      base::loadNamespace(package, lib.loc = lib.loc, ...)
    },
    .package = "pak"
  )

  # Intercept utils::download.file at the utils namespace level.
  original <- utils::download.file
  on.exit(assignInNamespace("download.file", original, "utils"), add = TRUE)
  assignInNamespace(
    "download.file",
    function(url, destfile, ...) {
      downloaded_via <<- "utils"
      writeLines("ok", destfile)
      invisible(0L)
    },
    "utils"
  )

  pak_download_file("https://example.com/file", tmp, quiet = TRUE)
  expect_equal(downloaded_via, "utils")
})

test_that("corporate environment simulation: download.file blocked, curl succeeds", {
  skip_if_not_installed("curl")
  skip_if_offline()

  # Simulate corporate breakage by making utils::download.file always error.
  original <- utils::download.file
  on.exit(assignInNamespace("download.file", original, "utils"), add = TRUE)
  assignInNamespace(
    "download.file",
    function(url, destfile, ...) {
      stop(
        "Simulated corporate network block: ",
        "utils::download.file is disabled"
      )
    },
    "utils"
  )

  # Verify base download.file is truly broken.
  expect_error(
    utils::download.file("https://www.r-project.org", tempfile()),
    "Simulated corporate"
  )

  # pak_download_file must succeed via curl despite download.file being blocked.
  tmp <- tempfile()
  on.exit(unlink(tmp), add = TRUE)
  expect_no_error(
    pak_download_file("https://www.r-project.org", tmp, quiet = TRUE)
  )
  expect_gt(file.info(tmp)$size, 0)
})
